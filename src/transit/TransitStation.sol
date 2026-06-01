// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { Auth, Authority } from "@solmate/auth/Auth.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { OAppAuth, MessagingFee, Origin, MessagingReceipt } from "src/base/Roles/CrossChain/OAppAuth/OAppAuth.sol";
import { OptionsBuilder } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";

contract TransitStation is OAppAuth {

    using SafeTransferLib for ERC20;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using OptionsBuilder for bytes;

    struct Route {
        uint32 destEID;
        address offerAsset;
        address wantAsset;
    }

    struct RouteConfig {
        bool isSupported;
        uint256 flatFeeProtocol;
        uint256 percentFeeProtocolBps;
        uint256 flatFeeSigner;
        uint256 percentFeeSignerBps;
        uint256 minAmount;
    }

    struct Order {
        bytes32 uuid;
        address wantAsset;
        uint256 amountDue;
        address receiver;
        uint32 sourceEID;
        address offerAsset;
        uint256 offerAmount;
        uint64 receiveTime;
    }

    struct PeerChain {
        bool allowFrom;
        bool allowTo;
        address peerStation;
        uint64 messageGasLimit;
        uint64 minimumMessageGas;
    }

    uint256 internal constant ONE_HUNDRED_PERCENT = 10_000;
    string public constant DEFAULT_POLICY = "DEFAULT";

    uint32 public immutable thisChainEID;
    address public protocolFeeRecipient;

    mapping(uint32 => PeerChain) public selectorToChains;
    mapping(address => string) public signerPolicies;
    mapping(string => mapping(bytes32 => RouteConfig)) internal routeConfigForPolicy;
    mapping(bytes32 => bool) public usedDigests;

    EnumerableSet.Bytes32Set internal pendingOrderIds;
    mapping(bytes32 => Order) public pendingOrders;

    uint256 internal orderNonce;

    event OrderSubmitted(bytes32 indexed uuid, Route route, Order order, address indexed user);
    event OrderReceived(bytes32 indexed uuid, Order order);
    event OrderExecuted(bytes32 indexed uuid, uint256 amount, uint256 remaining);
    event OrderForceRemoved(bytes32 indexed uuid, Order order);
    event PolicyRouteSet(string policy, Route route, RouteConfig config);
    event SignerPolicySet(address indexed signer, string policy);
    event ProtocolFeeRecipientSet(address recipient);
    event PeerChainSet(uint32 indexed eid, PeerChain chain);

    error RouteNotSupported();
    error AmountBelowMin();
    error InvalidPolicy(address recoveredSigner);
    error ChainNotAllowedFrom(uint32 eid);
    error ChainNotAllowedTo(uint32 eid);
    error PeerStationNotSet();
    error GasOutOfBounds();
    error OrderNotFound();
    error FeesExceedAmount();
    error AmountExceedsDue();
    error LengthMismatch();
    error BadSignature();
    error CallFailed();
    error ZeroAddress();
    error NotAContract(address target);
    error SignatureAlreadyUsed();

    constructor(
        address _owner,
        Authority _authority,
        address _endpoint,
        address _protocolFeeRecipient
    )
        Auth(_owner, _authority)
        OAppAuth(_endpoint, _owner)
    {
        if (_owner == address(0) || _protocolFeeRecipient == address(0)) revert ZeroAddress();
        if (address(_authority).code.length == 0) revert NotAContract(address(_authority));

        thisChainEID = endpoint.eid();
        protocolFeeRecipient = _protocolFeeRecipient;
    }

    function submitOrder(
        Route calldata route,
        uint256 amount,
        address receiver,
        uint256 feFeePercentBps,
        bytes32 salt,
        bytes calldata signature
    )
        external
        payable
        returns (bytes32 uuid)
    {
        uint256 net = _validateAndCollect(route, amount, receiver, feFeePercentBps, salt, signature);

        uuid = _newUuid(msg.sender);
        Order memory order = Order({
            uuid: uuid,
            wantAsset: route.wantAsset,
            amountDue: net,
            receiver: receiver,
            sourceEID: thisChainEID,
            offerAsset: route.offerAsset,
            offerAmount: amount,
            receiveTime: uint64(block.timestamp)
        });

        if (route.destEID == thisChainEID) {
            _pushOrder(order);
        } else {
            _sendOrder(route.destEID, order);
        }

        emit OrderSubmitted(uuid, route, order, msg.sender);
    }

    function _validateAndCollect(
        Route calldata route,
        uint256 amount,
        address receiver,
        uint256 feFeePercentBps,
        bytes32 salt,
        bytes calldata signature
    )
        internal
        returns (uint256 net)
    {
        (string memory policy, address signer) =
            _resolvePolicy(route, amount, receiver, feFeePercentBps, salt, signature);

        RouteConfig memory config = routeConfigForPolicy[policy][_routeHash(route)];
        if (!config.isSupported) revert RouteNotSupported();
        if (amount < config.minAmount) revert AmountBelowMin();

        (uint256 signerFee, uint256 protocolFee) = _calcFees(config, feFeePercentBps, amount);
        if (signerFee + protocolFee >= amount) revert FeesExceedAmount();
        net = amount - signerFee - protocolFee;

        ERC20 offer = ERC20(route.offerAsset);
        offer.safeTransferFrom(msg.sender, address(this), amount);
        if (signerFee > 0 && signer != address(0)) offer.safeTransfer(signer, signerFee);
        if (protocolFee > 0) offer.safeTransfer(protocolFeeRecipient, protocolFee);
    }

    function executePendingOrders(bytes32[] calldata uuids, uint256[] calldata amounts) external requiresAuth {
        if (uuids.length != amounts.length) revert LengthMismatch();

        for (uint256 i; i < uuids.length; ++i) {
            bytes32 uuid = uuids[i];
            if (!pendingOrderIds.contains(uuid)) revert OrderNotFound();

            Order storage order = pendingOrders[uuid];
            uint256 fillAmount = amounts[i];
            if (fillAmount > order.amountDue) revert AmountExceedsDue();

            ERC20(order.wantAsset).safeTransferFrom(msg.sender, order.receiver, fillAmount);
            order.amountDue -= fillAmount;
            uint256 remaining = order.amountDue;

            if (remaining == 0) {
                pendingOrderIds.remove(uuid);
                delete pendingOrders[uuid];
            }

            emit OrderExecuted(uuid, fillAmount, remaining);
        }
    }

    function forceRemovePendingOrder(bytes32 uuid) external requiresAuth {
        if (!pendingOrderIds.contains(uuid)) revert OrderNotFound();
        Order memory order = pendingOrders[uuid];
        pendingOrderIds.remove(uuid);
        delete pendingOrders[uuid];
        emit OrderForceRemoved(uuid, order);
    }

    function recoverETH(uint256 amount) external requiresAuth {
        (bool success,) = owner.call{ value: amount }("");
        if (!success) revert CallFailed();
    }

    function recoverTokens(ERC20 token, uint256 amount) external requiresAuth {
        token.safeTransfer(owner, amount);
    }

    function setPolicyRoutes(
        string calldata policy,
        Route[] calldata routes,
        RouteConfig[] calldata configs
    )
        external
        requiresAuth
    {
        if (routes.length != configs.length) revert LengthMismatch();
        for (uint256 i; i < routes.length; ++i) {
            routeConfigForPolicy[policy][_routeHash(routes[i])] = configs[i];
            emit PolicyRouteSet(policy, routes[i], configs[i]);
        }
    }

    function setSignerPolicies(address[] calldata signers, string[] calldata policies) external requiresAuth {
        if (signers.length != policies.length) revert LengthMismatch();
        for (uint256 i; i < signers.length; ++i) {
            signerPolicies[signers[i]] = policies[i];
            emit SignerPolicySet(signers[i], policies[i]);
        }
    }

    function setProtocolFeeRecipient(address recipient) external requiresAuth {
        if (recipient == address(0)) revert ZeroAddress();
        protocolFeeRecipient = recipient;
        emit ProtocolFeeRecipientSet(recipient);
    }

    function setPeerChain(uint32 eid, PeerChain calldata chain) external requiresAuth {
        selectorToChains[eid] = chain;
        emit PeerChainSet(eid, chain);
    }

    function _lzReceive(
        Origin calldata _origin,
        bytes32, /*_guid*/
        bytes calldata payload,
        address, /*executor*/
        bytes calldata /*extra*/
    )
        internal
        override
    {
        if (!selectorToChains[_origin.srcEid].allowFrom) revert ChainNotAllowedFrom(_origin.srcEid);

        Order memory order = abi.decode(payload, (Order));
        order.receiveTime = uint64(block.timestamp);
        _pushOrder(order);
    }

    function quoteSend(uint32 destEID, Order calldata order) external view returns (uint256) {
        PeerChain memory chain = selectorToChains[destEID];
        bytes memory payload = abi.encode(order);
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(chain.messageGasLimit, 0);
        MessagingFee memory fee = _quote(destEID, payload, options, false);
        return fee.nativeFee;
    }

    function _sendOrder(uint32 destEID, Order memory order) internal {
        PeerChain memory chain = selectorToChains[destEID];
        if (!chain.allowTo) revert ChainNotAllowedTo(destEID);
        if (chain.peerStation == address(0)) revert PeerStationNotSet();
        if (chain.messageGasLimit == 0) revert GasOutOfBounds();

        bytes memory payload = abi.encode(order);
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(chain.messageGasLimit, 0);

        _lzSend(destEID, payload, options, MessagingFee(msg.value, 0), payable(msg.sender));
    }

    function _pushOrder(Order memory order) internal {
        pendingOrderIds.add(order.uuid);
        pendingOrders[order.uuid] = order;
        emit OrderReceived(order.uuid, order);
    }

    function _resolvePolicy(
        Route calldata route,
        uint256 amount,
        address receiver,
        uint256 feFeePercentBps,
        bytes32 salt,
        bytes calldata signature
    )
        internal
        returns (string memory policy, address signer)
    {
        if (signature.length == 0) return (DEFAULT_POLICY, address(0));

        // salt makes each signed quote single-use: the same (route, amount, receiver, fee, sender)
        // can be re-signed with a fresh salt for a legitimate repeat order, but a given signature
        // can only be redeemed once.
        bytes32 digest = keccak256(
            abi.encode(block.chainid, address(this), route, amount, receiver, feFeePercentBps, msg.sender, salt)
        );
        signer = _recover(digest, signature);
        policy = signerPolicies[signer];
        if (bytes(policy).length == 0) revert InvalidPolicy(signer);

        if (usedDigests[digest]) revert SignatureAlreadyUsed();
        usedDigests[digest] = true;
    }

    function _calcFees(
        RouteConfig memory config,
        uint256 feFeePercentBps,
        uint256 amount
    )
        internal
        pure
        returns (uint256 signerFee, uint256 protocolFee)
    {
        protocolFee = config.flatFeeProtocol + (amount * config.percentFeeProtocolBps) / ONE_HUNDRED_PERCENT;
        signerFee =
            config.flatFeeSigner + (amount * (config.percentFeeSignerBps + feFeePercentBps)) / ONE_HUNDRED_PERCENT;
    }

    function _routeHash(Route calldata route) internal pure returns (bytes32) {
        return keccak256(abi.encode(route.destEID, route.offerAsset, route.wantAsset));
    }

    function _newUuid(address user) internal returns (bytes32 uuid) {
        unchecked {
            ++orderNonce;
        }
        uuid = keccak256(abi.encode(thisChainEID, address(this), user, orderNonce));
    }

    function _recover(bytes32 digest, bytes calldata signature) internal pure returns (address) {
        if (signature.length != 65) revert BadSignature();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert BadSignature();
        return signer;
    }

    function getRouteConfig(string calldata policy, Route calldata route) external view returns (RouteConfig memory) {
        return routeConfigForPolicy[policy][_routeHash(route)];
    }

    function getPendingOrderIds() external view returns (bytes32[] memory) {
        return pendingOrderIds.values();
    }

    function pendingOrderCount() external view returns (uint256) {
        return pendingOrderIds.length();
    }

    receive() external payable { }

}
