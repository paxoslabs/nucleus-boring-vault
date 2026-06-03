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

    // A PXL-backend-signed quote authorizing a single order. The contract holds no fee/route config:
    // the backend computes fees + rate dynamically and signs the result, which the contract verifies.
    struct Quote {
        Route route;
        uint256 offerAmount; // offerAsset units, pulled from the payer
        uint256 amountDue; // wantAsset units owed to the receiver (the backend's rate)
        address receiver;
        uint256 fee; // offerAsset units, paid to protocolFeeRecipient (capped at MAX_FEE_BPS of offerAmount)
        address payer; // must equal msg.sender
        uint256 deadline; // quote is invalid once block.timestamp passes this
        bytes32 salt; // anti-replay: re-sign with a fresh salt for a legitimate repeat order
    }

    uint256 internal constant ONE_HUNDRED_PERCENT = 10_000;
    // Max total fee a quote may charge, in bps of offerAmount. Hardcoded (not owner-settable) so the cap
    // holds even if the quote signer key is compromised, bounding the blast radius of a bad signature.
    uint256 public constant MAX_FEE_BPS = 50; // 0.5%

    uint32 public immutable thisChainEID;
    address public protocolFeeRecipient;
    address public quoteSigner;

    // Per-destination-EID LayerZero executor gas limit for the lzReceive on the peer station.
    mapping(uint32 => uint64) public messageGasLimit;
    // Global per-station directional route allowlist: destEID => offerAsset => wantAsset => approved.
    // On-chain so a compromised quoteSigner cannot bypass it; also gates which asset pairs are accepted
    // in normal operation. Nested (not a routeHash) so callers can read approvedRoutes(eid, offer, want).
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
    event MessageGasLimitSet(uint32 indexed eid, uint64 gasLimit);
    event RouteApprovalSet(Route route, bool approved);

    error GasLimitNotSet(uint32 eid);
    error OrderNotFound(bytes32 uuid);
    error AmountExceedsDue(bytes32 uuid);
    error LengthMismatch();
    error BadSignature();
    error CallFailed();
    error ZeroAddress();
    error NotAContract(address target);
    error SignatureAlreadyUsed();
    error QuoteExpired();
    error FeeTooHigh();
    error NotQuotePayer();
    error InvalidSigner(address recoveredSigner);
    error RouteNotApproved();

    constructor(
        address _owner,
        Authority _authority,
        address _endpoint,
        address _protocolFeeRecipient,
        address _quoteSigner
    )
        Auth(_owner, _authority)
        OAppAuth(_endpoint, _owner)
    {
        if (_owner == address(0) || _protocolFeeRecipient == address(0) || _quoteSigner == address(0)) {
            revert ZeroAddress();
        }
        if (address(_authority).code.length == 0) revert NotAContract(address(_authority));

        thisChainEID = endpoint.eid();
        protocolFeeRecipient = _protocolFeeRecipient;
        quoteSigner = _quoteSigner;
    }

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
            receiveTime: uint64(block.timestamp)
        });

        if (quote.route.destEID == thisChainEID) {
            _pushOrder(order);
        } else {
            _sendOrder(quote.route.destEID, order);
        }

        emit OrderSubmitted(uuid, quote.route, order, msg.sender);
    }

    function _verifyAndCollect(Quote calldata quote, bytes calldata signature) internal {
        if (block.timestamp > quote.deadline) revert QuoteExpired();
        if (msg.sender != quote.payer) revert NotQuotePayer();
        if (!_isRouteApproved(quote.route)) revert RouteNotApproved();
        if (quote.fee > (quote.offerAmount * MAX_FEE_BPS) / ONE_HUNDRED_PERCENT) revert FeeTooHigh();

        bytes32 digest = keccak256(abi.encode(block.chainid, address(this), quote));
        address signer = _recover(digest, signature);
        if (signer != quoteSigner) revert InvalidSigner(signer);

        if (usedDigests[digest]) revert SignatureAlreadyUsed();
        usedDigests[digest] = true;

        ERC20 offer = ERC20(quote.route.offerAsset);
        offer.safeTransferFrom(msg.sender, address(this), quote.offerAmount);
        if (quote.fee > 0) offer.safeTransfer(protocolFeeRecipient, quote.fee);
    }

    function executePendingOrders(bytes32[] calldata uuids, uint256[] calldata amounts) external requiresAuth {
        if (uuids.length != amounts.length) revert LengthMismatch();

        for (uint256 i; i < uuids.length; ++i) {
            bytes32 uuid = uuids[i];
            if (!pendingOrderIds.contains(uuid)) revert OrderNotFound(uuid);

            Order storage order = pendingOrders[uuid];
            uint256 fillAmount = amounts[i];
            uint256 due = order.amountDue;
            if (fillAmount > due) revert AmountExceedsDue(uuid);

            // Cache the fields we need before mutating/deleting the order.
            uint256 remaining = due - fillAmount;
            address wantAsset = order.wantAsset;
            address receiver = order.receiver;

            // Checks-effects-interactions: settle order state BEFORE paying out, so a token with a
            // transfer hook (e.g. ERC-777) cannot reenter against a stale/unfilled order.
            if (remaining == 0) {
                pendingOrderIds.remove(uuid);
                delete pendingOrders[uuid];
            } else {
                order.amountDue = remaining;
            }

            // KDD 20: pay the want asset from the station's own balance, after state is settled.
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

    function setMessageGasLimit(uint32 eid, uint64 gasLimit) external requiresAuth {
        messageGasLimit[eid] = gasLimit;
        emit MessageGasLimitSet(eid, gasLimit);
    }

    function setRouteApprovals(Route[] calldata routes, bool[] calldata approved) external requiresAuth {
        if (routes.length != approved.length) revert LengthMismatch();
        for (uint256 i; i < routes.length; ++i) {
            approvedRoutes[routes[i].destEID][routes[i].offerAsset][routes[i].wantAsset] = approved[i];
            emit RouteApprovalSet(routes[i], approved[i]);
        }
    }

    function _lzReceive(
        Origin calldata, /*_origin*/
        bytes32, /*_guid*/
        bytes calldata payload,
        address, /*executor*/
        bytes calldata /*extra*/
    )
        internal
        override
    {
        // Sender authenticity is already enforced upstream by OAppAuthReceiver.lzReceive (peers[srcEid]).
        Order memory order = abi.decode(payload, (Order));
        // Independently re-validate the route on the destination: even a fully compromised backend
        // (signer + executor) can only ever land orders for globally-approved asset pairs here. The
        // route's destEID is this chain, since the order arrived here.
        Route memory route = Route({ destEID: thisChainEID, offerAsset: order.offerAsset, wantAsset: order.wantAsset });
        if (!_isRouteApproved(route)) revert RouteNotApproved();

        order.receiveTime = uint64(block.timestamp);
        _pushOrder(order);
    }

    function quoteSend(uint32 destEID, Order calldata order) external view returns (uint256) {
        bytes memory payload = abi.encode(order);
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(messageGasLimit[destEID], 0);
        MessagingFee memory fee = _quote(destEID, payload, options, false);
        return fee.nativeFee;
    }

    function _sendOrder(uint32 destEID, Order memory order) internal {
        uint64 gasLimit = messageGasLimit[destEID];
        if (gasLimit == 0) revert GasLimitNotSet(destEID);

        bytes memory payload = abi.encode(order);
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(gasLimit, 0);

        // Destination peer authenticity + existence is enforced by _lzSend -> _getPeerOrRevert(destEID).
        _lzSend(destEID, payload, options, MessagingFee(msg.value, 0), payable(msg.sender));
    }

    function _pushOrder(Order memory order) internal {
        pendingOrderIds.add(order.uuid);
        pendingOrders[order.uuid] = order;
        emit OrderReceived(order.uuid, order);
    }

    function _isRouteApproved(Route memory route) internal view returns (bool) {
        return approvedRoutes[route.destEID][route.offerAsset][route.wantAsset];
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

    function getPendingOrderIds() external view returns (bytes32[] memory) {
        return pendingOrderIds.values();
    }

    function pendingOrderCount() external view returns (uint256) {
        return pendingOrderIds.length();
    }

    receive() external payable { }

}
