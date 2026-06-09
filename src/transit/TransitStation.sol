// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { Auth, Authority } from "@solmate/auth/Auth.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import { OAppAuth, MessagingFee, MessagingReceipt, Origin } from "src/base/Roles/CrossChain/OAppAuth/OAppAuth.sol";
import { OptionsBuilder } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import { Pausable } from "src/helper/Pausable.sol";

/// @title TransitStation
/// @notice Per-chain entrypoint for Paxos Labs Transit. A user submits a backend-signed `Quote`,
///         deposits the offer asset, and receives the want asset on the same chain or a peer chain. The actual
///         swap is priced off-chain and fulfilled by a privileged executor; the station does not custody funds.
/// @dev Funds never bridge — only order data does. On submit, the net offer is pulled to `offerReceiver`; on
///      fulfilment, the want asset is pulled from `wantAssetSource` straight to the receiver. A cross-chain order
///      travels as a LayerZero message carrying the full `Order` to the peer station's `_lzReceive`, where it is
///      queued exactly as a same-chain order would be. Access control is solmate RolesAuthority (`requiresAuth`);
///      the public submit entrypoints are opened via `setPublicCapability` at deploy.
contract TransitStation is OAppAuth, Pausable {

    using SafeTransferLib for ERC20;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using OptionsBuilder for bytes;

    /// @notice A directional asset pair on a destination chain. Doubles as the swap descriptor and the
    ///         `approvedRoutes` allowlist key. `destEID == thisChainEID` denotes a same-chain swap.
    struct Route {
        uint32 destEID;
        address offerAsset;
        address wantAsset;
    }

    /// @notice A swap queued for fulfilment on the destination chain.
    struct Order {
        bytes32 uuid;
        address wantAsset;
        uint256 amountDue; // remaining want owed to receiver (want-asset units); decremented on partial fills
        address receiver;
        uint32 sourceEID;
        address offerAsset;
        uint256 offerAmount;
        uint64 queuedAt; // when it entered a pending set; 0 on a cross-chain source (it never queues there)
    }

    /// @notice Backend-priced swap terms, EIP-712 signed by `quoteSigner`. Bearer instrument: anyone may submit a
    ///         valid quote (they pay `offerAmount`; the want asset goes to the fixed `receiver`, so reuse only
    ///         self-griefs). `amountDue` is want-asset units; both fees are offer-asset units.
    struct Quote {
        Route route;
        uint256 offerAmount;
        uint256 amountDue;
        address receiver;
        uint256 protocolFee; // PXL's cut; capped at MAX_PROTOCOL_FEE_BPS
        uint256 integratorFee; // frontend's cut; uncapped on-chain (user sees amountDue before submitting)
        address integratorFeeReceiver;
        uint256 deadline;
        bytes32 salt; // entropy so otherwise-identical quotes get distinct digests (and thus distinct UUIDs)
    }

    /// @dev Basis-points denominator.
    uint256 internal constant ONE_HUNDRED_PERCENT = 10_000;
    /// @notice Hard cap on `protocolFee` (0.5%). Bounds what a compromised `quoteSigner` can skim as protocol fee;
    ///         `integratorFee` is intentionally uncapped, so signer-key separation + off-chain limits remain the
    ///         real backstop against total extraction.
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 50;

    // EIP-712 type hashes. The domain separator is hand-rolled (OZ's EIP712 base pulls in StorageSlot which needs
    // solc >=0.8.24, and this repo pins 0.8.21) and recomputed live in `_domainSeparator`, so it is fork-safe.
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant ROUTE_TYPEHASH = keccak256("Route(uint32 destEID,address offerAsset,address wantAsset)");
    bytes32 internal constant QUOTE_TYPEHASH = keccak256(
        "Quote(Route route,uint256 offerAmount,uint256 amountDue,address receiver,uint256 protocolFee,uint256 integratorFee,address integratorFeeReceiver,uint256 deadline,bytes32 salt)Route(uint32 destEID,address offerAsset,address wantAsset)"
    );

    /// @notice This chain's LayerZero endpoint id, read from the endpoint at deploy.
    uint32 public immutable thisChainEID;
    /// @notice Receives `protocolFee` on every submit.
    address public protocolFeeRecipient;
    /// @notice Trusted backend key; every `Quote` must carry its EIP-712 signature.
    address public quoteSigner;
    /// @notice Destination for the net deposit on submit (in practice a BoringVault). The station only transfers
    ///         to it — it is not held by the station.
    address public offerReceiver;
    /// @notice Address the executor pulls the want asset FROM on fulfilment; must approve this station. The station
    ///         holds nothing between blocks.
    address public wantAssetSource;

    /// @notice Per-destination-EID gas the LZ executor supplies to the peer's `lzReceive`.
    mapping(uint32 => uint64) public messageGasLimit;
    /// @notice Global directional route allowlist (destEID => offerAsset => wantAsset). Enforced on both the source
    ///         (`submitOrder`) and the destination (`_lzReceive`), so a compromised backend can only ever land
    ///         globally-approved asset pairs. Nested (not a hashed key) for free readable getters.
    mapping(uint32 => mapping(address => mapping(address => bool))) public approvedRoutes;
    /// @notice Spent EIP-712 digests — replay guard.
    mapping(bytes32 => bool) public usedDigests;

    /// @dev Pending orders, addressed by UUID: an enumerable set of ids plus a UUID-keyed data mapping. Because the
    ///      executor references orders by UUID (not by position), removing one never disturbs another mid-batch.
    EnumerableSet.Bytes32Set internal pendingOrderIds;
    mapping(bytes32 => Order) public pendingOrders;

    /// @notice Emitted once a submitted order has been fully collected and either queued locally or bridged.
    event OrderSubmitted(bytes32 indexed uuid, Route route, Order order, address indexed user);
    /// @notice Emitted when an order is dispatched cross-chain. Carries the full order plus the LayerZero message
    ///         `guid`, so trackers need no join: `guid` traces the message and matches the destination's
    ///         `OrderBridgeReceived`. `order.queuedAt` is 0 here (the source never queues a bridged order).
    event OrderBridged(bytes32 indexed uuid, uint32 indexed destEID, bytes32 guid, Order order);
    /// @notice Emitted when an order enters a pending set (local submit or cross-chain receive).
    event OrderReceived(bytes32 indexed uuid, Order order);
    /// @notice Emitted when a bridged order arrives via LayerZero. Carries the full (now-queued) order plus the
    ///         `guid`, which matches the source's `OrderBridged`.
    event OrderBridgeReceived(bytes32 indexed uuid, uint32 indexed srcEID, bytes32 guid, Order order);
    /// @notice Emitted per fill; `remaining` is the want still owed after this fill (0 == fully filled).
    event OrderExecuted(bytes32 indexed uuid, uint256 amount, uint256 remaining);
    /// @notice Emitted when the admin force-removes a pending order (no on-chain refund).
    event OrderForceRemoved(bytes32 indexed uuid, Order order);
    event ProtocolFeeRecipientSet(address indexed recipient);
    event QuoteSignerSet(address indexed signer);
    event OfferReceiverSet(address indexed offerReceiver);
    event WantAssetSourceSet(address indexed wantAssetSource);
    event MessageGasLimitSet(uint32 indexed eid, uint64 gasLimit);
    event RouteApprovalSet(Route route, bool indexed approved);

    error GasLimitNotSet(uint32 eid);
    error OrderNotFound(bytes32 uuid);
    error AmountExceedsDue(bytes32 uuid, uint256 requested, uint256 due);
    error LengthMismatch(uint256 lengthA, uint256 lengthB);
    error CallFailed();
    error ZeroAddress();
    error NoCode(address target);
    error SignatureAlreadyUsed(bytes32 digest);
    error QuoteExpired(uint256 deadline);
    error FeeTooHigh(uint256 protocolFee, uint256 maxProtocolFee);
    error FeesExceedOffer(uint256 protocolFee, uint256 integratorFee, uint256 offerAmount);
    error ResidualApproval(address token, address wantAssetSource, uint256 remaining);
    error PermitFailedAndAllowanceTooLow();
    error InvalidSigner(address recoveredSigner);
    error RouteNotApproved(Route route);
    error ZeroAmountDue();

    /// @param _owner Owner (bypasses auth) and initial LZ delegate.
    /// @param _authority RolesAuthority granting `requiresAuth` capabilities; an EXECUTOR role is needed from day one.
    /// @param _endpoint LayerZero endpoint for this chain.
    /// @param _protocolFeeRecipient Initial `protocolFeeRecipient`.
    /// @param _quoteSigner Initial trusted `quoteSigner`.
    /// @param _offerReceiver Initial `offerReceiver`.
    /// @param _wantAssetSource Initial `wantAssetSource`.
    /// @dev `Auth` is initialized directly because `OAppAuthCore` inherits it without calling its constructor.
    constructor(
        address _owner,
        Authority _authority,
        address _endpoint,
        address _protocolFeeRecipient,
        address _quoteSigner,
        address _offerReceiver,
        address _wantAssetSource
    )
        Auth(_owner, _authority)
        OAppAuth(_endpoint, _owner)
    {
        if (
            _owner == address(0) || _protocolFeeRecipient == address(0) || _quoteSigner == address(0)
                || _offerReceiver == address(0) || _wantAssetSource == address(0)
        ) {
            revert ZeroAddress();
        }
        if (_endpoint.code.length == 0) revert NoCode(_endpoint);

        thisChainEID = endpoint.eid();
        protocolFeeRecipient = _protocolFeeRecipient;
        quoteSigner = _quoteSigner;
        offerReceiver = _offerReceiver;
        wantAssetSource = _wantAssetSource;
    }

    /// @notice Submit a backend-signed quote: collects the offer asset, then queues (same-chain) or bridges the order.
    /// @param quote Backend-priced swap terms.
    /// @param signature EIP-712 signature over `quote` by `quoteSigner`.
    /// @return uuid Identifier of the created order.
    /// @dev `payable` to fund the LZ native fee on cross-chain orders (unused/refundable for same-chain).
    function submitOrder(
        Quote calldata quote,
        bytes calldata signature
    )
        external
        payable
        requiresAuth
        whenNotPaused
        returns (bytes32 uuid)
    {
        uuid = _submitOrder(quote, signature);
    }

    /// @notice Same as `submitOrder` but consumes an EIP-2612 permit first, so approve + submit happen in one tx.
    /// @param quote Backend-priced swap terms.
    /// @param signature EIP-712 signature over `quote` by `quoteSigner`.
    /// @param permitDeadline Permit expiry.
    /// @param v Permit signature component.
    /// @param r Permit signature component.
    /// @param s Permit signature component.
    /// @return uuid Identifier of the created order.
    /// @dev A failed permit (already approved / front-run) falls back to an allowance check rather than reverting.
    function submitOrderWithPermit(
        Quote calldata quote,
        bytes calldata signature,
        uint256 permitDeadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
        payable
        requiresAuth
        whenNotPaused
        returns (bytes32 uuid)
    {
        ERC20 offer = ERC20(quote.route.offerAsset);
        try offer.permit(msg.sender, address(this), quote.offerAmount, permitDeadline, v, r, s) { }
        catch {
            if (offer.allowance(msg.sender, address(this)) < quote.offerAmount) {
                revert PermitFailedAndAllowanceTooLow();
            }
        }
        uuid = _submitOrder(quote, signature);
    }

    /// @notice Executor fulfils pending orders by pulling the want asset to each receiver; partial fills supported.
    /// @param uuids Orders to fill.
    /// @param amounts Per-order fill amount (want-asset units), index-aligned with `uuids`.
    /// @dev The station custodies nothing: the want asset is pulled `wantAssetSource` -> receiver, and after
    ///      the batch we assert no approval is left dangling for any touched token (a dangling approval is custody).
    ///      The distinct touched tokens are derived on-chain (O(n^2) dedup) to keep the backend interface a plain
    ///      list of fills. `whenNotPaused`: pausing halts fulfilment, the kill-switch for a compromised backend.
    function executePendingOrders(
        bytes32[] calldata uuids,
        uint256[] calldata amounts
    )
        external
        requiresAuth
        whenNotPaused
    {
        if (uuids.length != amounts.length) revert LengthMismatch(uuids.length, amounts.length);

        address[] memory usedTokens = new address[](uuids.length);
        uint256 usedCount;

        for (uint256 i; i < uuids.length;) {
            bytes32 uuid = uuids[i];
            if (!pendingOrderIds.contains(uuid)) revert OrderNotFound(uuid);

            Order storage order = pendingOrders[uuid];
            uint256 fillAmount = amounts[i];
            uint256 due = order.amountDue;
            if (fillAmount > due) revert AmountExceedsDue(uuid, fillAmount, due);

            uint256 remaining = due - fillAmount;
            address wantAsset = order.wantAsset;
            address receiver = order.receiver;

            // Effects before interaction: drop or decrement the order before the external transfer.
            if (remaining == 0) {
                pendingOrderIds.remove(uuid);
                delete pendingOrders[uuid];
            } else {
                order.amountDue = remaining;
            }

            ERC20(wantAsset).safeTransferFrom(wantAssetSource, receiver, fillAmount);

            // Track distinct want tokens touched, for the post-batch residual-approval assertion below.
            bool seen;
            for (uint256 j; j < usedCount;) {
                if (usedTokens[j] == wantAsset) {
                    seen = true;
                    break;
                }
                unchecked {
                    ++j;
                }
            }
            if (!seen) {
                usedTokens[usedCount] = wantAsset;
                unchecked {
                    ++usedCount;
                }
            }

            emit OrderExecuted(uuid, fillAmount, remaining);

            // unchecked: counter bounded by array length, cannot overflow.
            unchecked {
                ++i;
            }
        }

        // No approval may survive the batch — a leftover allowance would let the station pull later, i.e. custody.
        for (uint256 i; i < usedCount;) {
            uint256 remainingAllowance = ERC20(usedTokens[i]).allowance(wantAssetSource, address(this));
            if (remainingAllowance != 0) revert ResidualApproval(usedTokens[i], wantAssetSource, remainingAllowance);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Admin removal of a pending order (full only). No on-chain refund — the source-side deposit is
    ///         refundable off-chain by the vault holding it.
    /// @param uuid Order to remove.
    function forceRemovePendingOrder(bytes32 uuid) external requiresAuth {
        if (!pendingOrderIds.contains(uuid)) revert OrderNotFound(uuid);
        Order memory order = pendingOrders[uuid];
        pendingOrderIds.remove(uuid);
        delete pendingOrders[uuid];
        emit OrderForceRemoved(uuid, order);
    }

    /// @notice Sweep stray ETH to the owner (the station is not meant to hold ETH between txs).
    /// @param amount Wei to send.
    /// @dev Owner is trusted, so the low-level call is not reentrancy-guarded.
    function recoverETH(uint256 amount) external requiresAuth {
        (bool success,) = owner.call{ value: amount }("");
        if (!success) revert CallFailed();
    }

    /// @notice Sweep stray tokens to the owner. The station is not meant to hold tokens so these are assumed to be sent
    /// by mistake. @param token Token to sweep.
    /// @param amount Amount to send.
    function recoverTokens(ERC20 token, uint256 amount) external requiresAuth {
        token.safeTransfer(owner, amount);
    }

    /// @notice Emergency stop: halts both submission and fulfilment (`submitOrder`, `submitOrderWithPermit`,
    ///         `executePendingOrders`), so a compromised backend can be frozen before funds leave. `_lzReceive` is
    ///         intentionally not gated — no value moves on receive (only on execute, which is gated), and gating it
    ///         would strand in-flight cross-chain messages.
    function pause() external requiresAuth {
        _pause();
    }

    /// @notice Resume submissions. Only owner, the highest trust assumption, may unpause.
    function unpause() external requiresAuth {
        _unpause();
    }

    /// @notice Set the protocol fee recipient.
    /// @param recipient New recipient.
    function setProtocolFeeRecipient(address recipient) external requiresAuth {
        if (recipient == address(0)) revert ZeroAddress();
        protocolFeeRecipient = recipient;
        emit ProtocolFeeRecipientSet(recipient);
    }

    /// @notice Rotate the trusted quote signer
    /// @param signer New signer.
    function setQuoteSigner(address signer) external requiresAuth {
        if (signer == address(0)) revert ZeroAddress();
        quoteSigner = signer;
        emit QuoteSignerSet(signer);
    }

    /// @notice Set where the net offer deposit is sent on submit.
    /// @param newOfferReceiver New offer receiver.
    function setOfferReceiver(address newOfferReceiver) external requiresAuth {
        if (newOfferReceiver == address(0)) revert ZeroAddress();
        offerReceiver = newOfferReceiver;
        emit OfferReceiverSet(newOfferReceiver);
    }

    /// @notice Set the address the want asset is pulled from on fulfilment.
    /// @param newWantAssetSource New want-asset source.
    function setWantAssetSource(address newWantAssetSource) external requiresAuth {
        if (newWantAssetSource == address(0)) revert ZeroAddress();
        wantAssetSource = newWantAssetSource;
        emit WantAssetSourceSet(newWantAssetSource);
    }

    /// @notice Set the LZ executor gas for the peer's `lzReceive` on a given destination EID.
    /// @param eid Destination endpoint id.
    /// @param gasLimit Gas to supply (must be enough for `_lzReceive`, else delivery reverts and the message stalls).
    function setMessageGasLimit(uint32 eid, uint64 gasLimit) external requiresAuth {
        messageGasLimit[eid] = gasLimit;
        emit MessageGasLimitSet(eid, gasLimit);
    }

    /// @notice Batch-set the global route allowlist.
    /// @param routes Routes to toggle.
    /// @param approved Index-aligned approval flags.
    function setRouteApprovals(Route[] calldata routes, bool[] calldata approved) external requiresAuth {
        if (routes.length != approved.length) revert LengthMismatch(routes.length, approved.length);
        for (uint256 i; i < routes.length;) {
            approvedRoutes[routes[i].destEID][routes[i].offerAsset][routes[i].wantAsset] = approved[i];
            emit RouteApprovalSet(routes[i], approved[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Preview the LZ native fee for bridging an order to `destEID` (pass as `msg.value` to `submitOrder`).
    /// @param destEID Destination endpoint id.
    /// @param order Order that would be bridged.
    /// @return native fee in wei.
    /// @dev Builds the same options as `_sendOrder` so the quote matches the real send cost.
    function quoteSend(uint32 destEID, Order calldata order) external view returns (uint256) {
        bytes memory payload = abi.encode(order);
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(messageGasLimit[destEID], 0);
        MessagingFee memory fee = _quote(destEID, payload, options, false);
        return fee.nativeFee;
    }

    /// @notice All pending orders, fully materialized.
    /// @return orders The pending orders.
    /// @dev O(n) with a full struct copy per order — for off-chain readers only; an on-chain caller risks large gas
    /// costs.
    function getPendingOrders() external view returns (Order[] memory orders) {
        bytes32[] memory ids = pendingOrderIds.values();
        orders = new Order[](ids.length);
        for (uint256 i; i < ids.length;) {
            orders[i] = pendingOrders[ids[i]];
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Number of pending orders.
    function pendingOrderCount() external view returns (uint256) {
        return pendingOrderIds.length();
    }

    /// @dev Shared submit core (reused by both entrypoints).
    ///      Verifies + collects, then either queues locally or bridges. The UUID is the quote's EIP-712 digest, so it
    ///      is fully determined by the signed quote — identical no matter who submits it or in what order — and
    /// unique
    ///      per source station/chain (the domain separator binds both). `queuedAt` is left 0 here; `_pushOrder` stamps
    ///      it when the order actually enters a pending set (0 on the source of a cross-chain order).
    function _submitOrder(Quote calldata quote, bytes calldata signature) internal returns (bytes32 uuid) {
        uuid = _verifyAndCollect(quote, signature);

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

    /// @dev Validates the quote, pulls the offer asset, and returns the EIP-712 digest (which is used as the order
    ///      UUID). Order of effects matters: the digest is marked used (the replay-critical effect) before any
    ///      transfer. Fees and net are split out of `offerAmount` so the station never holds the offer asset.
    function _verifyAndCollect(Quote calldata quote, bytes calldata signature) internal returns (bytes32 digest) {
        if (block.timestamp > quote.deadline) revert QuoteExpired(quote.deadline);
        if (!_isRouteApproved(quote.route)) revert RouteNotApproved(quote.route);
        if (quote.receiver == address(0)) revert ZeroAddress();
        if (quote.integratorFee > 0 && quote.integratorFeeReceiver == address(0)) revert ZeroAddress();
        // An order owing 0 want would be born already "fully filled" (remaining == 0); reject it to avoid confusion in
        // the event of a 0 order being passed in.
        if (quote.amountDue == 0) revert ZeroAmountDue();

        uint256 maxProtocolFee = (quote.offerAmount * MAX_PROTOCOL_FEE_BPS) / ONE_HUNDRED_PERCENT;
        if (quote.protocolFee > maxProtocolFee) revert FeeTooHigh(quote.protocolFee, maxProtocolFee);
        // Strict `>=`: the net pulled to `offerReceiver` must be strictly positive (no zero-value transfer).
        if (quote.protocolFee + quote.integratorFee >= quote.offerAmount) {
            revert FeesExceedOffer(quote.protocolFee, quote.integratorFee, quote.offerAmount);
        }

        digest = keccak256(abi.encodePacked(hex"1901", _domainSeparator(), _hashQuote(quote)));
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

    /// @dev Destination handler for a bridged order. Sender authenticity is already enforced by
    ///      `OAppAuthReceiver.lzReceive` (LZ `peers`); here we re-check the route against this chain's allowlist
    ///      (`destEID = thisChainEID`). A revert here is safe: delivery is unordered, so the message simply stays
    ///      retryable on the endpoint until the route is (re-)approved — nothing is consumed.
    function _lzReceive(
        Origin calldata origin,
        bytes32 guid,
        bytes calldata payload,
        address,
        bytes calldata
    )
        internal
        override
    {
        Order memory order = abi.decode(payload, (Order));
        Route memory route = Route({ destEID: thisChainEID, offerAsset: order.offerAsset, wantAsset: order.wantAsset });
        if (!_isRouteApproved(route)) revert RouteNotApproved(route);

        Order memory stored = _pushOrder(order);
        emit OrderBridgeReceived(stored.uuid, origin.srcEid, guid, stored);
    }

    /// @dev Bridge an order to its destination via LayerZero. The native fee comes from `msg.value`; any excess is
    ///      refunded to `msg.sender`. Reverts if no gas limit is configured for the destination.
    function _sendOrder(uint32 destEID, Order memory order) internal {
        uint64 gasLimit = messageGasLimit[destEID];
        if (gasLimit == 0) revert GasLimitNotSet(destEID);

        bytes memory payload = abi.encode(order);
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(gasLimit, 0);

        MessagingReceipt memory receipt =
            _lzSend(destEID, payload, options, MessagingFee(msg.value, 0), payable(msg.sender));
        emit OrderBridged(order.uuid, destEID, receipt.guid, order);
    }

    /// @dev Stamp `queuedAt`, record the order, and return the stamped copy (so callers can log the stored state).
    function _pushOrder(Order memory order) internal returns (Order memory) {
        order.queuedAt = uint64(block.timestamp);
        pendingOrderIds.add(order.uuid);
        pendingOrders[order.uuid] = order;
        emit OrderReceived(order.uuid, order);
        return order;
    }

    /// @dev EIP-712 domain separator, computed live (reads `block.chainid`) to differentiate chains
    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH, keccak256(bytes("TransitStation")), keccak256(bytes("1")), block.chainid, address(this)
            )
        );
    }

    /// @dev Allowlist lookup for a route.
    function _isRouteApproved(Route memory route) internal view returns (bool) {
        return approvedRoutes[route.destEID][route.offerAsset][route.wantAsset];
    }

    /// @dev EIP-712 hashStruct of the nested `Route`.
    function _hashRoute(Route calldata route) internal pure returns (bytes32) {
        return keccak256(abi.encode(ROUTE_TYPEHASH, route.destEID, route.offerAsset, route.wantAsset));
    }

    /// @dev EIP-712 hashStruct of `Quote` (the `route` member is encoded as its own hashStruct, per the spec).
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
