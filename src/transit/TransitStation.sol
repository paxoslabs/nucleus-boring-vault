// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { Auth, Authority } from "@solmate/auth/Auth.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

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

    struct Order {
        bytes32 uuid;
        address wantAsset;
        uint256 amountDue;
        address receiver;
        uint32 sourceEID;
        address offerAsset;
        uint256 offerAmount;
        uint64 queuedAt;
    }

    struct Quote {
        Route route;
        uint256 offerAmount;
        uint256 amountDue;
        address receiver;
        uint256 protocolFee;
        uint256 integratorFee;
        address integratorFeeReceiver;
        uint256 deadline;
        bytes32 salt;
    }

    uint256 internal constant ONE_HUNDRED_PERCENT = 10_000;
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 50;

    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant ROUTE_TYPEHASH = keccak256("Route(uint32 destEID,address offerAsset,address wantAsset)");
    bytes32 internal constant QUOTE_TYPEHASH = keccak256(
        "Quote(Route route,uint256 offerAmount,uint256 amountDue,address receiver,uint256 protocolFee,uint256 integratorFee,address integratorFeeReceiver,uint256 deadline,bytes32 salt)Route(uint32 destEID,address offerAsset,address wantAsset)"
    );

    uint32 public immutable thisChainEID;
    address public protocolFeeRecipient;
    address public quoteSigner;
    address public offerReceiver;

    mapping(uint32 => uint64) public messageGasLimit;
    mapping(uint32 => mapping(address => mapping(address => bool))) public approvedRoutes;
    mapping(bytes32 => bool) public usedDigests;

    EnumerableSet.Bytes32Set internal pendingOrderIds;
    mapping(bytes32 => Order) public pendingOrders;

    uint256 internal orderNonce;

    event OrderSubmitted(bytes32 indexed uuid, Route route, Order order, address indexed user);
    event OrderReceived(bytes32 indexed uuid, Order order);
    event OrderExecuted(bytes32 indexed uuid, uint256 amount, uint256 remaining);
    event OrderForceRemoved(bytes32 indexed uuid, Order order);
    event ProtocolFeeRecipientSet(address recipient);
    event QuoteSignerSet(address indexed signer);
    event OfferReceiverSet(address offerReceiver);
    event MessageGasLimitSet(uint32 indexed eid, uint64 gasLimit);
    event RouteApprovalSet(Route route, bool approved);

    error GasLimitNotSet(uint32 eid);
    error OrderNotFound(bytes32 uuid);
    error AmountExceedsDue(bytes32 uuid, uint256 requested, uint256 due);
    error LengthMismatch(uint256 lengthA, uint256 lengthB);
    error CallFailed();
    error ZeroAddress();
    error NotAContract(address target);
    error SignatureAlreadyUsed(bytes32 digest);
    error QuoteExpired(uint256 deadline);
    error FeeTooHigh(uint256 protocolFee, uint256 maxProtocolFee);
    error FeesExceedOffer(uint256 protocolFee, uint256 integratorFee, uint256 offerAmount);
    error InvalidSigner(address recoveredSigner);
    error RouteNotApproved(Route route);

    constructor(
        address _owner,
        Authority _authority,
        address _endpoint,
        address _protocolFeeRecipient,
        address _quoteSigner,
        address _offerReceiver
    )
        Auth(_owner, _authority)
        OAppAuth(_endpoint, _owner)
    {
        if (
            _owner == address(0) || _protocolFeeRecipient == address(0) || _quoteSigner == address(0)
                || _offerReceiver == address(0)
        ) {
            revert ZeroAddress();
        }
        if (address(_authority).code.length == 0) revert NotAContract(address(_authority));

        thisChainEID = endpoint.eid();
        protocolFeeRecipient = _protocolFeeRecipient;
        quoteSigner = _quoteSigner;
        offerReceiver = _offerReceiver;
    }

    receive() external payable { }

    function submitOrder(Quote calldata quote, bytes calldata signature) external payable returns (bytes32 uuid) {
        _verifyAndCollect(quote, signature);

        uuid = _newUuid(msg.sender);
        Order memory order = Order({
            uuid: uuid,
            wantAsset: quote.route.wantAsset,
            amountDue: quote.amountDue,
            receiver: quote.receiver,
            sourceEID: thisChainEID,
            offerAsset: quote.route.offerAsset,
            offerAmount: quote.offerAmount,
            queuedAt: 0
        });

        if (quote.route.destEID == thisChainEID) {
            _pushOrder(order);
        } else {
            _sendOrder(quote.route.destEID, order);
        }

        emit OrderSubmitted(uuid, quote.route, order, msg.sender);
    }

    function executePendingOrders(bytes32[] calldata uuids, uint256[] calldata amounts) external requiresAuth {
        if (uuids.length != amounts.length) revert LengthMismatch(uuids.length, amounts.length);

        for (uint256 i; i < uuids.length; ++i) {
            bytes32 uuid = uuids[i];
            if (!pendingOrderIds.contains(uuid)) revert OrderNotFound(uuid);

            Order storage order = pendingOrders[uuid];
            uint256 fillAmount = amounts[i];
            uint256 due = order.amountDue;
            if (fillAmount > due) revert AmountExceedsDue(uuid, fillAmount, due);

            uint256 remaining = due - fillAmount;
            address wantAsset = order.wantAsset;
            address receiver = order.receiver;

            if (remaining == 0) {
                pendingOrderIds.remove(uuid);
                delete pendingOrders[uuid];
            } else {
                order.amountDue = remaining;
            }

            ERC20(wantAsset).safeTransfer(receiver, fillAmount);

            emit OrderExecuted(uuid, fillAmount, remaining);
        }
    }

    function forceRemovePendingOrder(bytes32 uuid) external requiresAuth {
        if (!pendingOrderIds.contains(uuid)) revert OrderNotFound(uuid);
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

    function setProtocolFeeRecipient(address recipient) external requiresAuth {
        if (recipient == address(0)) revert ZeroAddress();
        protocolFeeRecipient = recipient;
        emit ProtocolFeeRecipientSet(recipient);
    }

    function setQuoteSigner(address signer) external requiresAuth {
        if (signer == address(0)) revert ZeroAddress();
        quoteSigner = signer;
        emit QuoteSignerSet(signer);
    }

    function setOfferReceiver(address newOfferReceiver) external requiresAuth {
        if (newOfferReceiver == address(0)) revert ZeroAddress();
        offerReceiver = newOfferReceiver;
        emit OfferReceiverSet(newOfferReceiver);
    }

    function setMessageGasLimit(uint32 eid, uint64 gasLimit) external requiresAuth {
        messageGasLimit[eid] = gasLimit;
        emit MessageGasLimitSet(eid, gasLimit);
    }

    function setRouteApprovals(Route[] calldata routes, bool[] calldata approved) external requiresAuth {
        if (routes.length != approved.length) revert LengthMismatch(routes.length, approved.length);
        for (uint256 i; i < routes.length; ++i) {
            approvedRoutes[routes[i].destEID][routes[i].offerAsset][routes[i].wantAsset] = approved[i];
            emit RouteApprovalSet(routes[i], approved[i]);
        }
    }

    function quoteSend(uint32 destEID, Order calldata order) external view returns (uint256) {
        bytes memory payload = abi.encode(order);
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(messageGasLimit[destEID], 0);
        MessagingFee memory fee = _quote(destEID, payload, options, false);
        return fee.nativeFee;
    }

    function getPendingOrderIds() external view returns (bytes32[] memory) {
        return pendingOrderIds.values();
    }

    function pendingOrderCount() external view returns (uint256) {
        return pendingOrderIds.length();
    }

    function _verifyAndCollect(Quote calldata quote, bytes calldata signature) internal {
        if (block.timestamp > quote.deadline) revert QuoteExpired(quote.deadline);
        if (!_isRouteApproved(quote.route)) revert RouteNotApproved(quote.route);

        uint256 maxProtocolFee = (quote.offerAmount * MAX_PROTOCOL_FEE_BPS) / ONE_HUNDRED_PERCENT;
        if (quote.protocolFee > maxProtocolFee) revert FeeTooHigh(quote.protocolFee, maxProtocolFee);
        if (quote.protocolFee + quote.integratorFee >= quote.offerAmount) {
            revert FeesExceedOffer(quote.protocolFee, quote.integratorFee, quote.offerAmount);
        }

        bytes32 digest = keccak256(abi.encodePacked(hex"1901", _domainSeparator(), _hashQuote(quote)));
        address signer = ECDSA.recover(digest, signature);
        if (signer != quoteSigner) revert InvalidSigner(signer);

        if (usedDigests[digest]) revert SignatureAlreadyUsed(digest);
        usedDigests[digest] = true;

        ERC20 offer = ERC20(quote.route.offerAsset);
        if (quote.protocolFee > 0) offer.safeTransferFrom(msg.sender, protocolFeeRecipient, quote.protocolFee);
        if (quote.integratorFee > 0) {
            offer.safeTransferFrom(msg.sender, quote.integratorFeeReceiver, quote.integratorFee);
        }
        uint256 net = quote.offerAmount - quote.protocolFee - quote.integratorFee;
        offer.safeTransferFrom(msg.sender, offerReceiver, net);
    }

    function _lzReceive(Origin calldata, bytes32, bytes calldata payload, address, bytes calldata) internal override {
        Order memory order = abi.decode(payload, (Order));
        Route memory route = Route({ destEID: thisChainEID, offerAsset: order.offerAsset, wantAsset: order.wantAsset });
        if (!_isRouteApproved(route)) revert RouteNotApproved(route);

        _pushOrder(order);
    }

    function _sendOrder(uint32 destEID, Order memory order) internal {
        uint64 gasLimit = messageGasLimit[destEID];
        if (gasLimit == 0) revert GasLimitNotSet(destEID);

        bytes memory payload = abi.encode(order);
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(gasLimit, 0);

        _lzSend(destEID, payload, options, MessagingFee(msg.value, 0), payable(msg.sender));
    }

    function _pushOrder(Order memory order) internal {
        order.queuedAt = uint64(block.timestamp);
        pendingOrderIds.add(order.uuid);
        pendingOrders[order.uuid] = order;
        emit OrderReceived(order.uuid, order);
    }

    function _newUuid(address user) internal returns (bytes32 uuid) {
        unchecked {
            ++orderNonce;
        }
        uuid = keccak256(abi.encode(thisChainEID, address(this), user, orderNonce));
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH, keccak256(bytes("TransitStation")), keccak256(bytes("1")), block.chainid, address(this)
            )
        );
    }

    function _isRouteApproved(Route memory route) internal view returns (bool) {
        return approvedRoutes[route.destEID][route.offerAsset][route.wantAsset];
    }

    function _hashRoute(Route calldata route) internal pure returns (bytes32) {
        return keccak256(abi.encode(ROUTE_TYPEHASH, route.destEID, route.offerAsset, route.wantAsset));
    }

    function _hashQuote(Quote calldata quote) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                QUOTE_TYPEHASH,
                _hashRoute(quote.route),
                quote.offerAmount,
                quote.amountDue,
                quote.receiver,
                quote.protocolFee,
                quote.integratorFee,
                quote.integratorFeeReceiver,
                quote.deadline,
                quote.salt
            )
        );
    }

}
