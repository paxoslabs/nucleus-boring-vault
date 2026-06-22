// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Test } from "forge-std/Test.sol";
import { TransitStation } from "src/transit/TransitStation.sol";
import { Authority } from "@solmate/auth/Auth.sol";
import { RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { Pausable } from "src/helper/Pausable.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IOAppCore } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppCore.sol";
import { OAppAuthReceiver } from "src/base/Roles/CrossChain/OAppAuth/OAppAuthReceiver.sol";
import {
    ILayerZeroEndpointV2,
    MessagingParams,
    MessagingFee,
    MessagingReceipt,
    Origin
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { SetConfigParam } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";

/// @notice LayerZero endpoint mock sufficient for construction and cross-chain dispatch tests.
/// @dev Implements the minimal subset of `ILayerZeroEndpointV2` used by `TransitStation`:
///      `eid()`, `setDelegate(address)`, `quote(...)`, and `send{value}(...)`. All other
///      interface methods are stubbed out with empty or reverting implementations.
contract MockEndpoint is ILayerZeroEndpointV2 {

    uint32 public immutable override eid;
    uint256 public quoteFee;

    constructor(uint32 _eid) {
        eid = _eid;
    }

    function setQuoteFee(uint256 _quoteFee) external {
        quoteFee = _quoteFee;
    }

    // ---- Methods actually exercised by TransitStation ----

    function setDelegate(address) external pure override { }

    function quote(MessagingParams calldata, address) external view override returns (MessagingFee memory) {
        return MessagingFee(quoteFee, 0);
    }

    function send(MessagingParams calldata, address) external payable override returns (MessagingReceipt memory) {
        require(msg.value >= quoteFee, "LZ fee insufficient");
        return MessagingReceipt(bytes32(0), 0, MessagingFee(msg.value, 0));
    }

    // ---- ILayerZeroEndpointV2 stubs ----

    function clear(address, Origin calldata, bytes32, bytes calldata) external pure override {
        revert("unsupported");
    }

    function setLzToken(address) external pure override {
        revert("unsupported");
    }

    function nativeToken() external pure override returns (address) {
        return address(0);
    }

    function lzToken() external pure override returns (address) {
        return address(0);
    }

    function verify(Origin calldata, address, bytes32) external pure override {
        revert("unsupported");
    }

    function verifiable(Origin calldata, address) external pure override returns (bool) {
        return false;
    }

    function initializable(Origin calldata, address) external pure override returns (bool) {
        return false;
    }

    function lzReceive(Origin calldata, address, bytes32, bytes calldata, bytes calldata) external payable override {
        revert("unsupported");
    }

    // ---- IMessagingChannel stubs ----

    function skip(address, uint32, bytes32, uint64) external pure override {
        revert("unsupported");
    }

    function nilify(address, uint32, bytes32, uint64, bytes32) external pure override {
        revert("unsupported");
    }

    function burn(address, uint32, bytes32, uint64, bytes32) external pure override {
        revert("unsupported");
    }

    function nextGuid(address, uint32, bytes32) external pure override returns (bytes32) {
        return bytes32(0);
    }

    function inboundNonce(address, uint32, bytes32) external pure override returns (uint64) {
        return 0;
    }

    function outboundNonce(address, uint32, bytes32) external pure override returns (uint64) {
        return 0;
    }

    function inboundPayloadHash(address, uint32, bytes32, uint64) external pure override returns (bytes32) {
        return bytes32(0);
    }

    function lazyInboundNonce(address, uint32, bytes32) external pure override returns (uint64) {
        return 0;
    }

    // ---- IMessagingComposer stubs ----

    function composeQueue(address, address, bytes32, uint16) external pure override returns (bytes32) {
        return bytes32(0);
    }

    function sendCompose(address, bytes32, uint16, bytes calldata) external pure override {
        revert("unsupported");
    }

    function lzCompose(address, address, bytes32, uint16, bytes calldata, bytes calldata) external payable override {
        revert("unsupported");
    }

    // ---- IMessagingContext stubs ----

    function isSendingMessage() external pure override returns (bool) {
        return false;
    }

    function getSendContext() external pure override returns (uint32, address) {
        return (0, address(0));
    }

    // ---- IMessageLibManager stubs ----

    function registerLibrary(address) external pure override {
        revert("unsupported");
    }

    function isRegisteredLibrary(address) external pure override returns (bool) {
        return false;
    }

    function getRegisteredLibraries() external pure override returns (address[] memory) {
        return new address[](0);
    }

    function setDefaultSendLibrary(uint32, address) external pure override {
        revert("unsupported");
    }

    function defaultSendLibrary(uint32) external pure override returns (address) {
        return address(0);
    }

    function setDefaultReceiveLibrary(uint32, address, uint256) external pure override {
        revert("unsupported");
    }

    function defaultReceiveLibrary(uint32) external pure override returns (address) {
        return address(0);
    }

    function setDefaultReceiveLibraryTimeout(uint32, address, uint256) external pure override {
        revert("unsupported");
    }

    function defaultReceiveLibraryTimeout(uint32) external pure override returns (address, uint256) {
        return (address(0), 0);
    }

    function isSupportedEid(uint32) external pure override returns (bool) {
        return true;
    }

    function isValidReceiveLibrary(address, uint32, address) external pure override returns (bool) {
        return false;
    }

    function setSendLibrary(address, uint32, address) external pure override {
        revert("unsupported");
    }

    function getSendLibrary(address, uint32) external pure override returns (address) {
        return address(0);
    }

    function isDefaultSendLibrary(address, uint32) external pure override returns (bool) {
        return false;
    }

    function setReceiveLibrary(address, uint32, address, uint256) external pure override {
        revert("unsupported");
    }

    function getReceiveLibrary(address, uint32) external pure override returns (address, bool) {
        return (address(0), false);
    }

    function setReceiveLibraryTimeout(address, uint32, address, uint256) external pure override {
        revert("unsupported");
    }

    function receiveLibraryTimeout(address, uint32) external pure override returns (address, uint256) {
        return (address(0), 0);
    }

    function setConfig(address, address, SetConfigParam[] calldata) external pure override {
        revert("unsupported");
    }

    function getConfig(address, address, uint32, uint32) external pure override returns (bytes memory) {
        return "";
    }

    receive() external payable { }

    }

    contract tERC20 is ERC20 {

        constructor(uint8 _decimals) ERC20("test", "TEST", _decimals) { }

    }

    contract RevertingReceiver {

        receive() external payable {
            revert();
        }

    }

    contract tERC20Permit is ERC20 {

        constructor(uint8 _decimals) ERC20("test", "TEST", _decimals) { }

    }

    contract TransitStationTest is Test {

        RolesAuthority rolesAuthority;
        MockEndpoint endpoint;

        address owner = makeAddr("owner");
        address protocolFeeRecipient = makeAddr("protocolFeeRecipient");
        address quoteSigner;
        uint256 quoteSignerPk;
        address offerReceiver = makeAddr("offerReceiver");
        address wantAssetSource = makeAddr("wantAssetSource");

        address user = makeAddr("user");
        address executor = makeAddr("executor");
        ERC20 offerAsset;
        ERC20 wantAsset;

        uint256 constant DEFAULT_OFFER_AMOUNT_NORMALIZED = 100e18;
        uint256 constant DEFAULT_OFFER_AMOUNT = 100e6; // token units for the default 6-decimal tokens
        uint32 constant DEST_EID = 2;
        uint256 constant LZ_QUOTE_FEE = 0.01 ether;
        uint8 constant EXECUTOR_ROLE = 1;

        bytes32 constant DOMAIN_TYPEHASH =
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        bytes32 constant ROUTE_TYPEHASH = keccak256("Route(uint32 destEID,address offerAsset,address wantAsset)");
        bytes32 constant QUOTE_TYPEHASH = keccak256(
            "Quote(Route route,uint256 offerAmount,address receiver,uint256 protocolFee,uint256 integratorFee,address integratorFeeReceiver,bytes32 distributorCode,uint256 deadline,bytes32 salt)Route(uint32 destEID,address offerAsset,address wantAsset)"
        );

        // Events re-declared here so `vm.expectEmit` can match them without needing an external emitter.
        event OrderSubmitted(
            bytes32 indexed uuid,
            uint32 sourceEID,
            TransitStation.Route route,
            TransitStation.OrderTerms terms,
            address indexed user,
            bytes32 indexed distributorCode
        );
        event OrderReceived(bytes32 indexed uuid, TransitStation.Order order);
        event OrderBridged(bytes32 indexed uuid, uint32 indexed destEID, bytes32 guid, TransitStation.OrderTerms terms);
        event OrderBridgeReceived(bytes32 indexed uuid, uint32 indexed srcEID, bytes32 guid, TransitStation.Order order);
        event OrderForceRemoved(bytes32 indexed uuid, TransitStation.Order order);
        event OrderExecuted(bytes32 indexed uuid, uint256 amount, uint256 remaining);
        event ProtocolFeeRecipientSet(address indexed recipient);
        event QuoteSignerSet(address indexed signer);
        event OfferReceiverSet(address indexed offerReceiver);
        event WantAssetSourceSet(address indexed wantAssetSource);
        event MessageGasLimitSet(uint32 indexed eid, uint64 gasLimit);
        event RouteApprovalSet(TransitStation.Route route, bool indexed approved);

        function setUp() public {
            rolesAuthority = new RolesAuthority(owner, Authority(address(0)));
            endpoint = new MockEndpoint(1);
            endpoint.setQuoteFee(LZ_QUOTE_FEE);
            (quoteSigner, quoteSignerPk) = makeAddrAndKey("quoteSigner");
            offerAsset = new tERC20(6);
            wantAsset = new tERC20(6);
        }

        /// @notice Deploy a station with the default valid constructor args, overriding one field.
        function _deploy(
            address _owner,
            address _protocolFeeRecipient,
            address _quoteSigner,
            address _offerReceiver,
            address _wantAssetSource,
            address _endpoint
        )
            internal
            returns (TransitStation)
        {
            return new TransitStation(
                _owner,
                Authority(address(rolesAuthority)),
                _endpoint,
                _protocolFeeRecipient,
                _quoteSigner,
                _offerReceiver,
                _wantAssetSource
            );
        }

        // ========================================= HELPERS =========================================

        function _deployDefaultStation() internal returns (TransitStation station) {
            station = _deploy(
                owner, protocolFeeRecipient, quoteSigner, offerReceiver, wantAssetSource, address(endpoint)
            );

            TransitStation.Route[] memory routes = new TransitStation.Route[](1);
            routes[0] = TransitStation.Route({
                destEID: endpoint.eid(), offerAsset: address(offerAsset), wantAsset: address(wantAsset)
            });
            bool[] memory approved = new bool[](1);
            approved[0] = true;

            vm.startPrank(owner);
            station.setRouteApprovals(routes, approved);
            rolesAuthority.setPublicCapability(address(station), TransitStation.submitOrder.selector, true);
            rolesAuthority.setPublicCapability(address(station), TransitStation.submitOrderWithPermit.selector, true);
            vm.stopPrank();

            deal(address(offerAsset), user, DEFAULT_OFFER_AMOUNT * 10);
            vm.prank(user);
            offerAsset.approve(address(station), type(uint256).max);
        }

        function _deployStationWithAssets(
            ERC20 _offerAsset,
            ERC20 _wantAsset
        )
            internal
            returns (TransitStation station)
        {
            station = _deploy(
                owner, protocolFeeRecipient, quoteSigner, offerReceiver, wantAssetSource, address(endpoint)
            );

            TransitStation.Route[] memory routes = new TransitStation.Route[](1);
            routes[0] = TransitStation.Route({
                destEID: endpoint.eid(), offerAsset: address(_offerAsset), wantAsset: address(_wantAsset)
            });
            bool[] memory approved = new bool[](1);
            approved[0] = true;

            vm.startPrank(owner);
            station.setRouteApprovals(routes, approved);
            rolesAuthority.setPublicCapability(address(station), TransitStation.submitOrder.selector, true);
            rolesAuthority.setPublicCapability(address(station), TransitStation.submitOrderWithPermit.selector, true);
            vm.stopPrank();

            deal(address(_offerAsset), user, DEFAULT_OFFER_AMOUNT * 10);
            vm.prank(user);
            _offerAsset.approve(address(station), type(uint256).max);
        }

        function _deployDefaultStationWithCrossChainRoute() internal returns (TransitStation station) {
            station = _deployDefaultStation();

            TransitStation.Route[] memory routes = new TransitStation.Route[](1);
            routes[0] =
                TransitStation.Route({
                destEID: DEST_EID, offerAsset: address(offerAsset), wantAsset: address(wantAsset)
            });
            bool[] memory approved = new bool[](1);
            approved[0] = true;

            vm.prank(owner);
            station.setRouteApprovals(routes, approved);
        }

        /// @notice Returns a baseline valid, same-chain `Quote` intended to be modified by callers.
        /// @dev The purpose of this helper is to provide a fully valid quote so that each test only needs
        ///      to override the single property it wants to test. Properties of the default quote:
        ///      - Route uses `endpoint.eid()` as the destination, so the order is same-chain.
        ///      - Offer and want assets are the 6-decimal test tokens deployed in `setUp`.
        ///      - `offerAmount` is `DEFAULT_OFFER_AMOUNT` (100e6 token units for the 6-decimal offer asset), large enough
        ///        to avoid truncation-to-zero issues.
        ///      - Both fees are zero and `integratorFeeReceiver` is `address(0)`.
        ///      - `receiver` is the test `user`.
        ///      - `deadline` is `block.timestamp + 1 hours`.
        ///      - `distributorCode` and `salt` are empty.
        function _defaultQuote() internal view returns (TransitStation.Quote memory) {
            return TransitStation.Quote({
                route: TransitStation.Route({
                    destEID: endpoint.eid(), offerAsset: address(offerAsset), wantAsset: address(wantAsset)
                }),
                offerAmount: DEFAULT_OFFER_AMOUNT,
                receiver: user,
                protocolFee: 0,
                integratorFee: 0,
                integratorFeeReceiver: address(0),
                distributorCode: bytes32(0),
                deadline: block.timestamp + 1 hours,
                salt: bytes32(0)
            });
        }

        function _defaultOrderTerms() internal view returns (TransitStation.OrderTerms memory) {
            return TransitStation.OrderTerms({
                uuid: keccak256("test-uuid"),
                wantAsset: address(wantAsset),
                receiver: user,
                offerAsset: address(offerAsset),
                offerAmountNormalized18AfterFees: DEFAULT_OFFER_AMOUNT_NORMALIZED
            });
        }

        function _deployStationWithPendingOrder() internal returns (TransitStation station, bytes32 uuid) {
            station = _deployDefaultStation();

            vm.startPrank(owner);
            rolesAuthority.setUserRole(executor, EXECUTOR_ROLE, true);
            rolesAuthority.setRoleCapability(
                EXECUTOR_ROLE, address(station), TransitStation.executePendingOrders.selector, true
            );
            vm.stopPrank();

            TransitStation.Quote memory quote = _defaultQuote();
            bytes memory signature = _signQuote(station, quote);
            vm.prank(user);
            uuid = station.submitOrder{ value: 0 }(quote, signature);

            deal(address(wantAsset), wantAssetSource, DEFAULT_OFFER_AMOUNT * 10);
            vm.prank(wantAssetSource);
            wantAsset.approve(address(station), DEFAULT_OFFER_AMOUNT);
        }

        function _singleFillBatch(
            address wantAsset_,
            bytes32 uuid,
            uint256 amount
        )
            internal
            pure
            returns (TransitStation.FillBatch[] memory)
        {
            TransitStation.FillBatch[] memory batches = new TransitStation.FillBatch[](1);
            bytes32[] memory uuids = new bytes32[](1);
            uuids[0] = uuid;
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = amount;
            batches[0] = TransitStation.FillBatch({ wantAsset: wantAsset_, uuids: uuids, amounts: amounts });
            return batches;
        }

        function _hashRoute(TransitStation.Route memory route) internal pure returns (bytes32) {
            return keccak256(abi.encode(ROUTE_TYPEHASH, route.destEID, route.offerAsset, route.wantAsset));
        }

        function _hashQuote(TransitStation.Quote memory quote) internal pure returns (bytes32) {
            return keccak256(
                abi.encode(
                    QUOTE_TYPEHASH,
                    _hashRoute(quote.route),
                    quote.offerAmount,
                    quote.receiver,
                    quote.protocolFee,
                    quote.integratorFee,
                    quote.integratorFeeReceiver,
                    quote.distributorCode,
                    quote.deadline,
                    quote.salt
                )
            );
        }

        function _domainSeparator(TransitStation station) internal view returns (bytes32) {
            return keccak256(
                abi.encode(
                    DOMAIN_TYPEHASH,
                    keccak256(bytes("TransitStation")),
                    keccak256(bytes("1")),
                    block.chainid,
                    address(station)
                )
            );
        }

        function _signQuote(
            TransitStation station,
            TransitStation.Quote memory quote
        )
            internal
            view
            returns (bytes memory)
        {
            bytes32 digest = keccak256(abi.encodePacked(hex"1901", _domainSeparator(station), _hashQuote(quote)));
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(quoteSignerPk, digest);
            return abi.encodePacked(r, s, v);
        }

        function _getPermitSignature(
            tERC20Permit token,
            uint256 ownerKey,
            address spender,
            uint256 value,
            uint256 deadline
        )
            internal
            view
            returns (uint8 v, bytes32 r, bytes32 s)
        {
            address permitOwner = vm.addr(ownerKey);
            bytes32 permitTypehash =
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
            bytes32 structHash =
                keccak256(abi.encode(permitTypehash, permitOwner, spender, value, token.nonces(permitOwner), deadline));
            bytes32 digest = keccak256(abi.encodePacked(hex"1901", token.DOMAIN_SEPARATOR(), structHash));
            (v, r, s) = vm.sign(ownerKey, digest);
        }

        // ========================================= CONSTRUCTOR REVERTS =========================================

        function testConstructor_RevertIf_OwnerIsZeroAddress() external {
            // `OAppAuthCore` reverts first because `_delegate == _owner == address(0)`.
            vm.expectRevert(IOAppCore.InvalidDelegate.selector);
            _deploy(address(0), protocolFeeRecipient, quoteSigner, offerReceiver, wantAssetSource, address(endpoint));
        }

        function testConstructor_RevertIf_ProtocolFeeRecipientIsZeroAddress() external {
            vm.expectRevert(TransitStation.ZeroAddress.selector);
            _deploy(owner, address(0), quoteSigner, offerReceiver, wantAssetSource, address(endpoint));
        }

        function testConstructor_RevertIf_QuoteSignerIsZeroAddress() external {
            vm.expectRevert(TransitStation.ZeroAddress.selector);
            _deploy(owner, protocolFeeRecipient, address(0), offerReceiver, wantAssetSource, address(endpoint));
        }

        function testConstructor_RevertIf_OfferReceiverIsZeroAddress() external {
            vm.expectRevert(TransitStation.ZeroAddress.selector);
            _deploy(owner, protocolFeeRecipient, quoteSigner, address(0), wantAssetSource, address(endpoint));
        }

        function testConstructor_RevertIf_WantAssetSourceIsZeroAddress() external {
            vm.expectRevert(TransitStation.ZeroAddress.selector);
            _deploy(owner, protocolFeeRecipient, quoteSigner, offerReceiver, address(0), address(endpoint));
        }

        function testConstructor_RevertIf_EndpointHasNoCode() external {
            // `OAppAuthCore` calls `endpoint.setDelegate(_owner)` before `TransitStation`'s explicit `NoCode`
            // check is reached, so the deployment reverts with an empty reason when the endpoint is an EOA.
            vm.expectRevert();
            _deploy(owner, protocolFeeRecipient, quoteSigner, offerReceiver, wantAssetSource, address(0xdead));
        }

        // ========================================= submitOrder REVERTS =========================================

        function testSubmitOrder_RevertIf_CallerNotAuthorized() external {
            // Deploy without making `submitOrder` public so the only failure is auth.
            TransitStation station =
                _deploy(owner, protocolFeeRecipient, quoteSigner, offerReceiver, wantAssetSource, address(endpoint));

            TransitStation.Route[] memory routes = new TransitStation.Route[](1);
            routes[0] = TransitStation.Route({
                destEID: endpoint.eid(), offerAsset: address(offerAsset), wantAsset: address(wantAsset)
            });
            bool[] memory approved = new bool[](1);
            approved[0] = true;
            vm.prank(owner);
            station.setRouteApprovals(routes, approved);

            deal(address(offerAsset), user, DEFAULT_OFFER_AMOUNT * 10);
            vm.prank(user);
            offerAsset.approve(address(station), type(uint256).max);

            TransitStation.Quote memory quote = _defaultQuote();
            bytes memory signature = _signQuote(station, quote);

            address unauthorized = makeAddr("unauthorized");
            vm.prank(unauthorized);
            vm.expectRevert("UNAUTHORIZED");
            station.submitOrder(quote, signature);
        }

        function testSubmitOrder_RevertIf_Paused() external {
            TransitStation station = _deployDefaultStation();

            vm.prank(owner);
            station.pause();
            assertTrue(station.paused());

            TransitStation.Quote memory quote = _defaultQuote();
            bytes memory signature = _signQuote(station, quote);

            vm.expectRevert(Pausable.EnforcedPause.selector);
            station.submitOrder(quote, signature);
        }

        function testSubmitOrder_RevertIf_QuoteExpired() external {
            TransitStation station = _deployDefaultStation();

            TransitStation.Quote memory quote = _defaultQuote();
            quote.deadline = block.timestamp - 1;
            bytes memory signature = _signQuote(station, quote);

            vm.prank(user);
            vm.expectRevert(abi.encodeWithSelector(TransitStation.QuoteExpired.selector, block.timestamp - 1));
            station.submitOrder(quote, signature);
        }

        function testSubmitOrder_RevertIf_RouteNotApproved() external {
            TransitStation station = _deployDefaultStation();

            TransitStation.Quote memory quote = _defaultQuote();
            quote.route.destEID = endpoint.eid() + 1;
            bytes memory signature = _signQuote(station, quote);

            vm.prank(user);
            vm.expectRevert(
                abi.encodeWithSelector(
                    TransitStation.RouteNotApproved.selector,
                    TransitStation.Route({
                        destEID: endpoint.eid() + 1, offerAsset: address(offerAsset), wantAsset: address(wantAsset)
                    })
                )
            );
            station.submitOrder(quote, signature);
        }

        function testSubmitOrder_RevertIf_ReceiverIsZeroAddress() external {
            TransitStation station = _deployDefaultStation();

            TransitStation.Quote memory quote = _defaultQuote();
            quote.receiver = address(0);
            bytes memory signature = _signQuote(station, quote);

            vm.prank(user);
            vm.expectRevert(TransitStation.ZeroAddress.selector);
            station.submitOrder(quote, signature);
        }

        function testSubmitOrder_RevertIf_IntegratorFeeReceiverIsZeroAddress() external {
            TransitStation station = _deployDefaultStation();

            TransitStation.Quote memory quote = _defaultQuote();
            quote.integratorFee = 1;
            bytes memory signature = _signQuote(station, quote);

            vm.prank(user);
            vm.expectRevert(TransitStation.ZeroAddress.selector);
            station.submitOrder(quote, signature);
        }

        function testSubmitOrder_RevertIf_ProtocolFeeTooHigh() external {
            TransitStation station = _deployDefaultStation();

            uint256 maxProtocolFee = (DEFAULT_OFFER_AMOUNT * station.MAX_PROTOCOL_FEE_BPS()) / 10_000;

            TransitStation.Quote memory quote = _defaultQuote();
            quote.protocolFee = maxProtocolFee + 1;
            bytes memory signature = _signQuote(station, quote);

            vm.prank(user);
            vm.expectRevert(
                abi.encodeWithSelector(TransitStation.ProtocolFeeTooHigh.selector, maxProtocolFee + 1, maxProtocolFee)
            );
            station.submitOrder(quote, signature);
        }

        function testSubmitOrder_RevertIf_IntegratorFeeTooHigh() external {
            TransitStation station = _deployDefaultStation();

            uint256 maxIntegratorFee = (DEFAULT_OFFER_AMOUNT * station.MAX_INTEGRATOR_FEE_BPS()) / 10_000;

            TransitStation.Quote memory quote = _defaultQuote();
            quote.integratorFee = maxIntegratorFee + 1;
            quote.integratorFeeReceiver = user;
            bytes memory signature = _signQuote(station, quote);

            vm.prank(user);
            vm.expectRevert(
                abi.encodeWithSelector(
                    TransitStation.IntegratorFeeTooHigh.selector, maxIntegratorFee + 1, maxIntegratorFee
                )
            );
            station.submitOrder(quote, signature);
        }

        function testSubmitOrder_RevertIf_FeesExceedOffer() external {
            TransitStation station = _deployDefaultStation();

            TransitStation.Quote memory quote = _defaultQuote();
            quote.offerAmount = 0;
            bytes memory signature = _signQuote(station, quote);

            vm.prank(user);
            vm.expectRevert(abi.encodeWithSelector(TransitStation.FeesExceedOrEqualOffer.selector, 0, 0, 0));
            station.submitOrder(quote, signature);
        }

        function testSubmitOrder_RevertIf_InsufficientAllowance() external {
            TransitStation station = _deployDefaultStation();

            TransitStation.Quote memory quote = _defaultQuote();
            bytes memory signature = _signQuote(station, quote);

            address brokeUser = makeAddr("brokeUser");
            deal(address(offerAsset), brokeUser, DEFAULT_OFFER_AMOUNT * 10);
            // No approval granted; `SafeTransferLib.safeTransferFrom` reverts with "TRANSFER_FROM_FAILED".
            // TODO: also test against an ERC20 that returns `false` instead of reverting.

            vm.prank(brokeUser);
            vm.expectRevert("TRANSFER_FROM_FAILED");
            station.submitOrder(quote, signature);
        }

        function testSubmitOrder_RevertIf_InsufficientBalance() external {
            TransitStation station = _deployDefaultStation();

            TransitStation.Quote memory quote = _defaultQuote();
            bytes memory signature = _signQuote(station, quote);

            address brokeUser = makeAddr("brokeUser");
            vm.prank(brokeUser);
            offerAsset.approve(address(station), type(uint256).max);
            // No balance granted; `SafeTransferLib.safeTransferFrom` reverts with "TRANSFER_FROM_FAILED".
            // TODO: also test against an ERC20 that returns `false` instead of reverting.

            vm.prank(brokeUser);
            vm.expectRevert("TRANSFER_FROM_FAILED");
            station.submitOrder(quote, signature);
        }

        // ========================================= CROSS-CHAIN DISPATCH REVERTS =========================================

        function testSubmitOrder_RevertIf_GasLimitNotSet() external {
            TransitStation station = _deployDefaultStationWithCrossChainRoute();

            // Peer is set, but gas limit is not.
            vm.prank(owner);
            station.setPeer(DEST_EID, bytes32(uint256(uint160(address(station)))));

            TransitStation.Quote memory quote = _defaultQuote();
            quote.route.destEID = DEST_EID;
            bytes memory signature = _signQuote(station, quote);

            vm.prank(user);
            vm.deal(user, LZ_QUOTE_FEE);
            vm.expectRevert(abi.encodeWithSelector(TransitStation.GasLimitNotSet.selector, DEST_EID));
            station.submitOrder{ value: LZ_QUOTE_FEE }(quote, signature);
        }

        function testSubmitOrder_RevertIf_NoPeer() external {
            TransitStation station = _deployDefaultStationWithCrossChainRoute();

            // Gas limit is set, but peer is not.
            vm.prank(owner);
            station.setMessageGasLimit(DEST_EID, 400_000);

            TransitStation.Quote memory quote = _defaultQuote();
            quote.route.destEID = DEST_EID;
            bytes memory signature = _signQuote(station, quote);

            vm.prank(user);
            vm.deal(user, LZ_QUOTE_FEE);
            vm.expectRevert(abi.encodeWithSelector(IOAppCore.NoPeer.selector, DEST_EID));
            station.submitOrder{ value: LZ_QUOTE_FEE }(quote, signature);
        }

        function testSubmitOrder_RevertIf_InsufficientMsgValue() external {
            TransitStation station = _deployDefaultStationWithCrossChainRoute();

            vm.startPrank(owner);
            station.setPeer(DEST_EID, bytes32(uint256(uint160(address(station)))));
            station.setMessageGasLimit(DEST_EID, 400_000);
            vm.stopPrank();

            TransitStation.Quote memory quote = _defaultQuote();
            quote.route.destEID = DEST_EID;
            bytes memory signature = _signQuote(station, quote);

            uint256 insufficientFee = LZ_QUOTE_FEE - 1;
            vm.prank(user);
            vm.deal(user, insufficientFee);
            vm.expectRevert("LZ fee insufficient");
            station.submitOrder{ value: insufficientFee }(quote, signature);
        }

        // ========================================= SIGNATURE REVERTS =========================================

        function testSubmitOrder_RevertIf_SignatureLengthInvalid() external {
            TransitStation station = _deployDefaultStation();

            TransitStation.Quote memory quote = _defaultQuote();
            bytes memory signature = new bytes(64);

            vm.prank(user);
            vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, 64));
            station.submitOrder(quote, signature);
        }

        function testSubmitOrder_RevertIf_SignatureSMalleable() external {
            TransitStation station = _deployDefaultStation();

            TransitStation.Quote memory quote = _defaultQuote();
            bytes32 r = bytes32(uint256(1));
            bytes32 s = bytes32(type(uint256).max);
            uint8 v = 27;
            bytes memory signature = abi.encodePacked(r, s, v);

            vm.prank(user);
            vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, s));
            station.submitOrder(quote, signature);
        }

        function testSubmitOrder_RevertIf_InvalidSigner() external {
            TransitStation station = _deployDefaultStation();

            TransitStation.Quote memory quote = _defaultQuote();
            (, uint256 attackerPk) = makeAddrAndKey("attacker");
            address attacker = vm.addr(attackerPk);

            bytes32 digest = keccak256(abi.encodePacked(hex"1901", _domainSeparator(station), _hashQuote(quote)));
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(attackerPk, digest);
            bytes memory signature = abi.encodePacked(r, s, v);

            vm.prank(user);
            vm.expectRevert(abi.encodeWithSelector(TransitStation.InvalidSigner.selector, attacker));
            station.submitOrder(quote, signature);
        }

        function testSubmitOrder_RevertIf_SignatureAlreadyUsed() external {
            TransitStation station = _deployDefaultStation();

            TransitStation.Quote memory quote = _defaultQuote();
            bytes memory signature = _signQuote(station, quote);
            bytes32 digest = keccak256(abi.encodePacked(hex"1901", _domainSeparator(station), _hashQuote(quote)));

            // First submission succeeds.
            vm.prank(user);
            station.submitOrder{ value: 0 }(quote, signature);

            // Replaying the same quote+signature reverts.
            vm.prank(user);
            vm.expectRevert(abi.encodeWithSelector(TransitStation.SignatureAlreadyUsed.selector, digest));
            station.submitOrder{ value: 0 }(quote, signature);
        }

        // ========================================= submitOrder EFFECTS =========================================

        function testSubmitOrder_MovesTokensCorrectly() external {
            TransitStation station = _deployDefaultStation();
            address integrator = makeAddr("integrator");

            TransitStation.Quote memory quote = _defaultQuote();
            quote.protocolFee = 0.5e6;
            quote.integratorFee = 2e6;
            quote.integratorFeeReceiver = integrator;
            bytes memory signature = _signQuote(station, quote);

            uint256 userBalanceBefore = offerAsset.balanceOf(user);
            uint256 protocolBalanceBefore = offerAsset.balanceOf(protocolFeeRecipient);
            uint256 integratorBalanceBefore = offerAsset.balanceOf(integrator);
            uint256 offerReceiverBalanceBefore = offerAsset.balanceOf(offerReceiver);

            vm.prank(user);
            station.submitOrder{ value: 0 }(quote, signature);

            assertEq(offerAsset.balanceOf(user), userBalanceBefore - DEFAULT_OFFER_AMOUNT);
            assertEq(offerAsset.balanceOf(protocolFeeRecipient), protocolBalanceBefore + 0.5e6);
            assertEq(offerAsset.balanceOf(integrator), integratorBalanceBefore + 2e6);
            assertEq(
                offerAsset.balanceOf(offerReceiver), offerReceiverBalanceBefore + (DEFAULT_OFFER_AMOUNT - 0.5e6 - 2e6)
            );
            assertEq(offerAsset.balanceOf(address(station)), 0);
        }

        function testSubmitOrder_LeavesZeroOfferTokenBalanceInStation() external {
            TransitStation station = _deployDefaultStation();

            TransitStation.Quote memory quote = _defaultQuote();
            bytes memory signature = _signQuote(station, quote);

            vm.prank(user);
            station.submitOrder{ value: 0 }(quote, signature);

            assertEq(offerAsset.balanceOf(address(station)), 0);
        }

        function testSubmitOrder_RoutesSameChainToPendingOrders() external {
            TransitStation station = _deployDefaultStation();

            TransitStation.Quote memory quote = _defaultQuote();
            bytes memory signature = _signQuote(station, quote);
            bytes32 digest = keccak256(abi.encodePacked(hex"1901", _domainSeparator(station), _hashQuote(quote)));

            vm.prank(user);
            station.submitOrder{ value: 0 }(quote, signature);

            assertEq(station.pendingOrderCount(), 1);

            TransitStation.Order[] memory orders = station.getPendingOrders();
            assertEq(orders.length, 1);
            TransitStation.Order memory order = orders[0];
            assertEq(order.terms.uuid, digest);
            assertEq(order.terms.wantAsset, address(wantAsset));
            assertEq(order.terms.receiver, user);
            assertEq(order.terms.offerAsset, address(offerAsset));
            assertEq(order.terms.offerAmountNormalized18AfterFees, DEFAULT_OFFER_AMOUNT_NORMALIZED);
            assertEq(order.amountDue, DEFAULT_OFFER_AMOUNT);
            assertEq(order.queuedAt, block.timestamp);
        }

        function testSubmitOrder_WithProtocolFee() external {
            TransitStation station = _deployDefaultStation();

            TransitStation.Quote memory quote = _defaultQuote();
            quote.protocolFee = 0.5e6;
            bytes memory signature = _signQuote(station, quote);

            uint256 userBalanceBefore = offerAsset.balanceOf(user);
            uint256 protocolBalanceBefore = offerAsset.balanceOf(protocolFeeRecipient);
            uint256 offerReceiverBalanceBefore = offerAsset.balanceOf(offerReceiver);

            vm.prank(user);
            station.submitOrder{ value: 0 }(quote, signature);

            assertEq(offerAsset.balanceOf(user), userBalanceBefore - DEFAULT_OFFER_AMOUNT);
            assertEq(offerAsset.balanceOf(protocolFeeRecipient), protocolBalanceBefore + 0.5e6);
            assertEq(offerAsset.balanceOf(offerReceiver), offerReceiverBalanceBefore + (DEFAULT_OFFER_AMOUNT - 0.5e6));
            assertEq(offerAsset.balanceOf(address(station)), 0);

            TransitStation.Order memory order = station.getPendingOrders()[0];
            assertEq(order.terms.offerAmountNormalized18AfterFees, DEFAULT_OFFER_AMOUNT_NORMALIZED - 0.5e18);
        }

        function testSubmitOrder_WithIntegratorFee() external {
            TransitStation station = _deployDefaultStation();
            address integrator = makeAddr("integrator");

            TransitStation.Quote memory quote = _defaultQuote();
            quote.integratorFee = 2e6;
            quote.integratorFeeReceiver = integrator;
            bytes memory signature = _signQuote(station, quote);

            uint256 userBalanceBefore = offerAsset.balanceOf(user);
            uint256 integratorBalanceBefore = offerAsset.balanceOf(integrator);
            uint256 offerReceiverBalanceBefore = offerAsset.balanceOf(offerReceiver);

            vm.prank(user);
            station.submitOrder{ value: 0 }(quote, signature);

            assertEq(offerAsset.balanceOf(user), userBalanceBefore - DEFAULT_OFFER_AMOUNT);
            assertEq(offerAsset.balanceOf(integrator), integratorBalanceBefore + 2e6);
            assertEq(offerAsset.balanceOf(offerReceiver), offerReceiverBalanceBefore + (DEFAULT_OFFER_AMOUNT - 2e6));
            assertEq(offerAsset.balanceOf(address(station)), 0);

            TransitStation.Order memory order = station.getPendingOrders()[0];
            assertEq(order.terms.offerAmountNormalized18AfterFees, DEFAULT_OFFER_AMOUNT_NORMALIZED - 2e18);
        }

        function testSubmitOrder_WithProtocolAndIntegratorFees() external {
            TransitStation station = _deployDefaultStation();
            address integrator = makeAddr("integrator");

            TransitStation.Quote memory quote = _defaultQuote();
            quote.protocolFee = 0.5e6;
            quote.integratorFee = 2e6;
            quote.integratorFeeReceiver = integrator;
            bytes memory signature = _signQuote(station, quote);

            uint256 userBalanceBefore = offerAsset.balanceOf(user);
            uint256 protocolBalanceBefore = offerAsset.balanceOf(protocolFeeRecipient);
            uint256 integratorBalanceBefore = offerAsset.balanceOf(integrator);
            uint256 offerReceiverBalanceBefore = offerAsset.balanceOf(offerReceiver);

            vm.prank(user);
            station.submitOrder{ value: 0 }(quote, signature);

            assertEq(offerAsset.balanceOf(user), userBalanceBefore - DEFAULT_OFFER_AMOUNT);
            assertEq(offerAsset.balanceOf(protocolFeeRecipient), protocolBalanceBefore + 0.5e6);
            assertEq(offerAsset.balanceOf(integrator), integratorBalanceBefore + 2e6);
            assertEq(
                offerAsset.balanceOf(offerReceiver), offerReceiverBalanceBefore + (DEFAULT_OFFER_AMOUNT - 0.5e6 - 2e6)
            );
            assertEq(offerAsset.balanceOf(address(station)), 0);

            TransitStation.Order memory order = station.getPendingOrders()[0];
            assertEq(order.terms.offerAmountNormalized18AfterFees, DEFAULT_OFFER_AMOUNT_NORMALIZED - 0.5e18 - 2e18);
        }

        function testSubmitOrder_SubmitterIsNotReceiver() external {
            TransitStation station = _deployDefaultStation();
            address receiver = makeAddr("receiver");
            address submitter = makeAddr("submitter");

            deal(address(offerAsset), submitter, DEFAULT_OFFER_AMOUNT * 10);
            vm.prank(submitter);
            offerAsset.approve(address(station), DEFAULT_OFFER_AMOUNT);

            TransitStation.Quote memory quote = _defaultQuote();
            quote.receiver = receiver;
            bytes memory signature = _signQuote(station, quote);

            uint256 submitterBalanceBefore = offerAsset.balanceOf(submitter);
            uint256 offerReceiverBalanceBefore = offerAsset.balanceOf(offerReceiver);

            vm.prank(submitter);
            bytes32 uuid = station.submitOrder{ value: 0 }(quote, signature);

            assertEq(offerAsset.balanceOf(submitter), submitterBalanceBefore - DEFAULT_OFFER_AMOUNT);
            assertEq(offerAsset.balanceOf(offerReceiver), offerReceiverBalanceBefore + DEFAULT_OFFER_AMOUNT);

            TransitStation.Order memory order = station.getPendingOrders()[0];
            assertEq(order.terms.uuid, uuid);
            assertEq(order.terms.receiver, receiver);
        }

        function testSubmitOrder_RoutesCrossChainWithoutPendingOrder() external {
            TransitStation station = _deployDefaultStationWithCrossChainRoute();
            vm.startPrank(owner);
            station.setPeer(DEST_EID, bytes32(uint256(uint160(address(station)))));
            station.setMessageGasLimit(DEST_EID, 400_000);
            vm.stopPrank();

            TransitStation.Quote memory quote = _defaultQuote();
            quote.route.destEID = DEST_EID;
            bytes memory signature = _signQuote(station, quote);

            vm.prank(user);
            vm.deal(user, LZ_QUOTE_FEE);
            station.submitOrder{ value: LZ_QUOTE_FEE }(quote, signature);

            assertEq(station.pendingOrderCount(), 0);

            TransitStation.Order[] memory orders = station.getPendingOrders();
            assertEq(orders.length, 0);
        }

        // ========================================= submitOrderWithPermit REVERTS =========================================

        function testSubmitOrderWithPermit_RevertIf_PermitFailedAndAllowanceTooLow() external {
            TransitStation station = _deployDefaultStation();

            TransitStation.Quote memory quote = _defaultQuote();
            bytes memory signature = _signQuote(station, quote);

            // `user` is already authorized and funded. Lower the allowance below the required offer
            // amount. The test token does not implement EIP-2612 `permit`, so the permit call will fail
            // and the station will fall back to an allowance check.
            vm.prank(user);
            offerAsset.approve(address(station), DEFAULT_OFFER_AMOUNT - 1);

            vm.prank(user);
            vm.expectRevert(TransitStation.PermitFailedAndAllowanceTooLow.selector);
            station.submitOrderWithPermit(quote, signature, block.timestamp + 1 hours, 27, bytes32(0), bytes32(0));
        }

        // ========================================= submitOrderWithPermit EFFECTS =========================================

        function testSubmitOrderWithPermit_PermitGrantsAllowanceWhenNoneExists() external {
            tERC20Permit offerPermit = new tERC20Permit(18);
            TransitStation station = _deployStationWithAssets(ERC20(address(offerPermit)), wantAsset);

            uint256 permitUserKey = 0xABCD;
            address permitUser = vm.addr(permitUserKey);
            deal(address(offerPermit), permitUser, DEFAULT_OFFER_AMOUNT_NORMALIZED * 10);

            TransitStation.Quote memory quote = TransitStation.Quote({
                route: TransitStation.Route({
                    destEID: endpoint.eid(), offerAsset: address(offerPermit), wantAsset: address(wantAsset)
                }),
                offerAmount: DEFAULT_OFFER_AMOUNT_NORMALIZED,
                receiver: permitUser,
                protocolFee: 0,
                integratorFee: 0,
                integratorFeeReceiver: address(0),
                distributorCode: bytes32(0),
                deadline: block.timestamp + 1 hours,
                salt: bytes32(0)
            });
            bytes memory signature = _signQuote(station, quote);

            uint256 deadline = block.timestamp + 1 hours;
            (uint8 v, bytes32 r, bytes32 s) =
                _getPermitSignature(offerPermit, permitUserKey, address(station), DEFAULT_OFFER_AMOUNT_NORMALIZED, deadline);

            assertEq(offerPermit.allowance(permitUser, address(station)), 0);

            vm.prank(permitUser);
            bytes32 uuid = station.submitOrderWithPermit{ value: 0 }(quote, signature, deadline, v, r, s);

            assertEq(uuid, keccak256(abi.encodePacked(hex"1901", _domainSeparator(station), _hashQuote(quote))));
            assertEq(station.pendingOrderCount(), 1);
            assertEq(offerPermit.allowance(permitUser, address(station)), 0);
            assertEq(offerPermit.balanceOf(offerReceiver), DEFAULT_OFFER_AMOUNT_NORMALIZED);
        }

        function testSubmitOrderWithPermit_FrontRunPermitLeavesAllowanceForOrder() external {
            tERC20Permit offerPermit = new tERC20Permit(18);
            TransitStation station = _deployStationWithAssets(ERC20(address(offerPermit)), wantAsset);

            uint256 permitUserKey = 0xBCDE;
            address permitUser = vm.addr(permitUserKey);
            deal(address(offerPermit), permitUser, DEFAULT_OFFER_AMOUNT_NORMALIZED * 10);

            TransitStation.Quote memory quote = TransitStation.Quote({
                route: TransitStation.Route({
                    destEID: endpoint.eid(), offerAsset: address(offerPermit), wantAsset: address(wantAsset)
                }),
                offerAmount: DEFAULT_OFFER_AMOUNT_NORMALIZED,
                receiver: permitUser,
                protocolFee: 0,
                integratorFee: 0,
                integratorFeeReceiver: address(0),
                distributorCode: bytes32(0),
                deadline: block.timestamp + 1 hours,
                salt: bytes32(0)
            });
            bytes memory signature = _signQuote(station, quote);

            uint256 deadline = block.timestamp + 1 hours;
            (uint8 v, bytes32 r, bytes32 s) =
                _getPermitSignature(offerPermit, permitUserKey, address(station), DEFAULT_OFFER_AMOUNT_NORMALIZED, deadline);

            assertEq(offerPermit.allowance(permitUser, address(station)), 0);

            // A front-runner executes the permit first, consuming the nonce and setting the allowance.
            address frontRunner = makeAddr("frontRunner");
            vm.prank(frontRunner);
            offerPermit.permit(permitUser, address(station), DEFAULT_OFFER_AMOUNT_NORMALIZED, deadline, v, r, s);

            assertEq(offerPermit.allowance(permitUser, address(station)), DEFAULT_OFFER_AMOUNT_NORMALIZED);

            // `submitOrderWithPermit` now sees an invalid/reused permit nonce, but the existing allowance
            // from the front-run is sufficient for the order to succeed.
            vm.prank(permitUser);
            bytes32 uuid = station.submitOrderWithPermit{ value: 0 }(quote, signature, deadline, v, r, s);

            assertEq(uuid, keccak256(abi.encodePacked(hex"1901", _domainSeparator(station), _hashQuote(quote))));
            assertEq(station.pendingOrderCount(), 1);
            assertEq(offerPermit.allowance(permitUser, address(station)), 0);
            assertEq(offerPermit.balanceOf(offerReceiver), DEFAULT_OFFER_AMOUNT_NORMALIZED);
        }

        // ========================================= lzReceive REVERTS =========================================

        function testLzReceive_RevertIf_OnlyEndpoint() external {
            TransitStation station = _deployDefaultStation();

            vm.prank(owner);
            station.setPeer(DEST_EID, bytes32(uint256(uint160(address(station)))));

            TransitStation.OrderTerms memory terms = _defaultOrderTerms();
            bytes memory payload = abi.encode(terms);
            Origin memory origin =
                Origin({ srcEid: DEST_EID, sender: bytes32(uint256(uint160(address(station)))), nonce: 1 });

            address notEndpoint = makeAddr("notEndpoint");
            vm.prank(notEndpoint);
            vm.expectRevert(abi.encodeWithSelector(OAppAuthReceiver.OnlyEndpoint.selector, notEndpoint));
            station.lzReceive(origin, bytes32(0), payload, address(0), "");
        }

        function testLzReceive_RevertIf_NoPeer() external {
            TransitStation station = _deployDefaultStation();
            // Peer is intentionally not set for DEST_EID.

            TransitStation.OrderTerms memory terms = _defaultOrderTerms();
            bytes memory payload = abi.encode(terms);
            Origin memory origin =
                Origin({ srcEid: DEST_EID, sender: bytes32(uint256(uint160(address(station)))), nonce: 1 });

            vm.prank(address(endpoint));
            vm.expectRevert(abi.encodeWithSelector(IOAppCore.NoPeer.selector, DEST_EID));
            station.lzReceive(origin, bytes32(0), payload, address(0), "");
        }

        function testLzReceive_RevertIf_OnlyPeer() external {
            TransitStation station = _deployDefaultStation();

            bytes32 registeredPeer = bytes32(uint256(uint160(address(station))));
            vm.prank(owner);
            station.setPeer(DEST_EID, registeredPeer);

            TransitStation.OrderTerms memory terms = _defaultOrderTerms();
            bytes memory payload = abi.encode(terms);
            bytes32 actualSender = bytes32(uint256(1));
            Origin memory origin = Origin({ srcEid: DEST_EID, sender: actualSender, nonce: 1 });

            vm.prank(address(endpoint));
            vm.expectRevert(abi.encodeWithSelector(IOAppCore.OnlyPeer.selector, DEST_EID, actualSender));
            station.lzReceive(origin, bytes32(0), payload, address(0), "");
        }

        function testLzReceive_IncrementsPendingOrderCount() external {
            TransitStation station = _deployDefaultStation();

            vm.prank(owner);
            station.setPeer(DEST_EID, bytes32(uint256(uint160(address(station)))));

            TransitStation.OrderTerms memory terms = _defaultOrderTerms();
            bytes memory payload = abi.encode(terms);
            Origin memory origin =
                Origin({ srcEid: DEST_EID, sender: bytes32(uint256(uint160(address(station)))), nonce: 1 });

            assertEq(station.pendingOrderCount(), 0);

            vm.prank(address(endpoint));
            station.lzReceive(origin, bytes32(0), payload, address(0), "");

            assertEq(station.pendingOrderCount(), 1);
        }

        // ========================================= executePendingOrders REVERTS =========================================

        function testExecutePendingOrders_RevertIf_CallerNotAuthorized() external {
            (TransitStation station, bytes32 uuid) = _deployStationWithPendingOrder();

            address unauthorized = makeAddr("unauthorized");
            vm.prank(unauthorized);
            vm.expectRevert("UNAUTHORIZED");
            station.executePendingOrders(_singleFillBatch(address(wantAsset), uuid, DEFAULT_OFFER_AMOUNT));
        }

        function testExecutePendingOrders_RevertIf_Paused() external {
            (TransitStation station, bytes32 uuid) = _deployStationWithPendingOrder();

            vm.prank(owner);
            station.pause();

            vm.prank(executor);
            vm.expectRevert(Pausable.EnforcedPause.selector);
            station.executePendingOrders(_singleFillBatch(address(wantAsset), uuid, DEFAULT_OFFER_AMOUNT));
        }

        function testExecutePendingOrders_RevertIf_LengthMismatch() external {
            (TransitStation station, bytes32 uuid) = _deployStationWithPendingOrder();

            TransitStation.FillBatch[] memory batches = new TransitStation.FillBatch[](1);
            bytes32[] memory uuids = new bytes32[](1);
            uuids[0] = uuid;
            uint256[] memory amounts = new uint256[](2);
            batches[0] = TransitStation.FillBatch({ wantAsset: address(wantAsset), uuids: uuids, amounts: amounts });

            vm.prank(executor);
            vm.expectRevert(abi.encodeWithSelector(TransitStation.LengthMismatch.selector, 1, 2));
            station.executePendingOrders(batches);
        }

        function testExecutePendingOrders_RevertIf_OrderNotFound() external {
            (TransitStation station,) = _deployStationWithPendingOrder();

            bytes32 unknownUuid = keccak256("unknown");

            vm.prank(executor);
            vm.expectRevert(abi.encodeWithSelector(TransitStation.OrderNotFound.selector, unknownUuid));
            station.executePendingOrders(_singleFillBatch(address(wantAsset), unknownUuid, DEFAULT_OFFER_AMOUNT));
        }

        function testExecutePendingOrders_RevertIf_WantAssetMismatch() external {
            (TransitStation station, bytes32 uuid) = _deployStationWithPendingOrder();

            ERC20 otherWantAsset = new tERC20(18);

            TransitStation.FillBatch[] memory batches = new TransitStation.FillBatch[](1);
            bytes32[] memory uuids = new bytes32[](1);
            uuids[0] = uuid;
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = DEFAULT_OFFER_AMOUNT;
            batches[0] = TransitStation.FillBatch({
                wantAsset: address(otherWantAsset), uuids: uuids, amounts: amounts
            });

            vm.prank(executor);
            vm.expectRevert(
                abi.encodeWithSelector(
                    TransitStation.WantAssetMismatch.selector, uuid, address(wantAsset), address(otherWantAsset)
                )
            );
            station.executePendingOrders(batches);
        }

        function testExecutePendingOrders_RevertIf_AmountExceedsDue() external {
            (TransitStation station, bytes32 uuid) = _deployStationWithPendingOrder();

            vm.prank(executor);
            vm.expectRevert(
                abi.encodeWithSelector(
                    TransitStation.AmountExceedsDue.selector, uuid, DEFAULT_OFFER_AMOUNT + 1, DEFAULT_OFFER_AMOUNT
                )
            );
            station.executePendingOrders(_singleFillBatch(address(wantAsset), uuid, DEFAULT_OFFER_AMOUNT + 1));
        }

        function testExecutePendingOrders_RevertIf_ResidualApproval() external {
            (TransitStation station, bytes32 uuid) = _deployStationWithPendingOrder();

            // Approve one token unit more than the fill amount so a residual allowance remains.
            vm.prank(wantAssetSource);
            wantAsset.approve(address(station), DEFAULT_OFFER_AMOUNT + 1);

            vm.prank(executor);
            vm.expectRevert(
                abi.encodeWithSelector(TransitStation.ResidualApproval.selector, address(wantAsset), wantAssetSource, 1)
            );
            station.executePendingOrders(_singleFillBatch(address(wantAsset), uuid, DEFAULT_OFFER_AMOUNT));
        }

        // ========================================= executePendingOrders EFFECTS =========================================

        function testExecutePendingOrders_FillsSingleOrder() external {
            (TransitStation station, bytes32 uuid) = _deployStationWithPendingOrder();

            uint256 userWantBefore = wantAsset.balanceOf(user);
            uint256 sourceWantBefore = wantAsset.balanceOf(wantAssetSource);

            vm.prank(executor);
            station.executePendingOrders(_singleFillBatch(address(wantAsset), uuid, DEFAULT_OFFER_AMOUNT));

            assertEq(station.pendingOrderCount(), 0);
            assertEq(wantAsset.balanceOf(user), userWantBefore + DEFAULT_OFFER_AMOUNT);
            assertEq(wantAsset.balanceOf(wantAssetSource), sourceWantBefore - DEFAULT_OFFER_AMOUNT);
            assertEq(wantAsset.allowance(wantAssetSource, address(station)), 0);
        }

        function testExecutePendingOrders_PartialFill() external {
            (TransitStation station, bytes32 uuid) = _deployStationWithPendingOrder();

            uint256 fillAmount = DEFAULT_OFFER_AMOUNT / 2;
            uint256 remaining = DEFAULT_OFFER_AMOUNT - fillAmount;

            // Approve only the partial fill amount so no residual allowance remains.
            vm.prank(wantAssetSource);
            wantAsset.approve(address(station), fillAmount);

            uint256 userWantBefore = wantAsset.balanceOf(user);

            vm.prank(executor);
            station.executePendingOrders(_singleFillBatch(address(wantAsset), uuid, fillAmount));

            assertEq(station.pendingOrderCount(), 1);
            TransitStation.Order memory order = station.getPendingOrders()[0];
            assertEq(order.amountDue, remaining);
            assertEq(wantAsset.balanceOf(user), userWantBefore + fillAmount);
            assertEq(wantAsset.allowance(wantAssetSource, address(station)), 0);
        }

        function testExecutePendingOrders_PartialFillThenFullFill() external {
            (TransitStation station, bytes32 uuid) = _deployStationWithPendingOrder();

            uint256 fillAmount = DEFAULT_OFFER_AMOUNT / 2;
            uint256 remaining = DEFAULT_OFFER_AMOUNT - fillAmount;

            // Approve only the partial fill amount so no residual allowance remains.
            vm.prank(wantAssetSource);
            wantAsset.approve(address(station), fillAmount);

            uint256 userWantBefore = wantAsset.balanceOf(user);

            vm.prank(executor);
            station.executePendingOrders(_singleFillBatch(address(wantAsset), uuid, fillAmount));

            assertEq(station.pendingOrderCount(), 1);
            TransitStation.Order memory order = station.getPendingOrders()[0];
            assertEq(order.amountDue, remaining);
            assertEq(wantAsset.balanceOf(user), userWantBefore + fillAmount);
            assertEq(wantAsset.allowance(wantAssetSource, address(station)), 0);

            // Approve the remaining amount and fully fill the order.
            vm.prank(wantAssetSource);
            wantAsset.approve(address(station), remaining);

            vm.prank(executor);
            station.executePendingOrders(_singleFillBatch(address(wantAsset), uuid, remaining));

            assertEq(station.pendingOrderCount(), 0);
            assertEq(station.getPendingOrders().length, 0);
            assertEq(wantAsset.balanceOf(user), userWantBefore + DEFAULT_OFFER_AMOUNT);
            assertEq(wantAsset.allowance(wantAssetSource, address(station)), 0);
        }

        function testExecutePendingOrders_RevertIf_ExecutedTwice() external {
            (TransitStation station, bytes32 uuid) = _deployStationWithPendingOrder();

            vm.prank(executor);
            station.executePendingOrders(_singleFillBatch(address(wantAsset), uuid, DEFAULT_OFFER_AMOUNT));

            assertEq(station.pendingOrderCount(), 0);

            vm.prank(executor);
            vm.expectRevert(abi.encodeWithSelector(TransitStation.OrderNotFound.selector, uuid));
            station.executePendingOrders(_singleFillBatch(address(wantAsset), uuid, DEFAULT_OFFER_AMOUNT));
        }

        function testExecutePendingOrders_RevertIf_DuplicateUuidInBatch() external {
            (TransitStation station, bytes32 uuid) = _deployStationWithPendingOrder();

            TransitStation.FillBatch[] memory batches = new TransitStation.FillBatch[](1);
            bytes32[] memory uuids = new bytes32[](2);
            uuids[0] = uuid;
            uuids[1] = uuid;
            uint256[] memory amounts = new uint256[](2);
            amounts[0] = DEFAULT_OFFER_AMOUNT;
            amounts[1] = DEFAULT_OFFER_AMOUNT;
            batches[0] = TransitStation.FillBatch({ wantAsset: address(wantAsset), uuids: uuids, amounts: amounts });

            vm.prank(executor);
            vm.expectRevert(abi.encodeWithSelector(TransitStation.OrderNotFound.selector, uuid));
            station.executePendingOrders(batches);
        }

        function testExecutePendingOrders_EmitsOrderExecuted() external {
            (TransitStation station, bytes32 uuid) = _deployStationWithPendingOrder();

            vm.expectEmit(true, false, false, true);
            emit OrderExecuted(uuid, DEFAULT_OFFER_AMOUNT, 0);

            vm.prank(executor);
            station.executePendingOrders(_singleFillBatch(address(wantAsset), uuid, DEFAULT_OFFER_AMOUNT));

            assertEq(wantAsset.allowance(wantAssetSource, address(station)), 0);
        }

        function testExecutePendingOrders_FillsMultipleBatches() external {
            ERC20 wantAsset18 = new tERC20(18);
            ERC20 wantAsset6 = new tERC20(6);
            TransitStation station = _deployStationWithAssets(offerAsset, wantAsset18);

            vm.startPrank(owner);
            rolesAuthority.setUserRole(executor, EXECUTOR_ROLE, true);
            rolesAuthority.setRoleCapability(
                EXECUTOR_ROLE, address(station), TransitStation.executePendingOrders.selector, true
            );

            TransitStation.Route[] memory routes = new TransitStation.Route[](2);
            routes[0] = TransitStation.Route({
                destEID: endpoint.eid(), offerAsset: address(offerAsset), wantAsset: address(wantAsset18)
            });
            routes[1] = TransitStation.Route({
                destEID: endpoint.eid(), offerAsset: address(offerAsset), wantAsset: address(wantAsset6)
            });
            bool[] memory approved = new bool[](2);
            approved[0] = true;
            approved[1] = true;
            station.setRouteApprovals(routes, approved);
            vm.stopPrank();

            TransitStation.Quote memory quote = _defaultQuote();
            quote.route.wantAsset = address(wantAsset18);
            bytes memory signature = _signQuote(station, quote);
            vm.prank(user);
            bytes32 uuid1 = station.submitOrder{ value: 0 }(quote, signature);

            quote.route.wantAsset = address(wantAsset6);
            quote.salt = bytes32(uint256(1));
            signature = _signQuote(station, quote);
            vm.prank(user);
            bytes32 uuid2 = station.submitOrder{ value: 0 }(quote, signature);

            uint256 amountDue18 = DEFAULT_OFFER_AMOUNT_NORMALIZED;
            uint256 amountDue6 = DEFAULT_OFFER_AMOUNT_NORMALIZED / 1e12;

            deal(address(wantAsset18), wantAssetSource, amountDue18 * 10);
            deal(address(wantAsset6), wantAssetSource, amountDue6 * 10);
            vm.startPrank(wantAssetSource);
            wantAsset18.approve(address(station), amountDue18);
            wantAsset6.approve(address(station), amountDue6);
            vm.stopPrank();

            TransitStation.FillBatch[] memory batches = new TransitStation.FillBatch[](2);
            batches[0] = _singleFillBatch(address(wantAsset18), uuid1, amountDue18)[0];
            batches[1] = _singleFillBatch(address(wantAsset6), uuid2, amountDue6)[0];

            uint256 userWant18Before = wantAsset18.balanceOf(user);

            vm.prank(executor);
            station.executePendingOrders(batches);

            assertEq(station.pendingOrderCount(), 0);
            assertEq(wantAsset18.balanceOf(user) - userWant18Before, amountDue18);
            assertEq(wantAsset6.balanceOf(user), amountDue6);
            assertEq(wantAsset18.allowance(wantAssetSource, address(station)), 0);
            assertEq(wantAsset6.allowance(wantAssetSource, address(station)), 0);
        }

        // ========================================= forceRemovePendingOrder REVERTS =========================================

        function testForceRemovePendingOrder_RevertIf_CallerNotAuthorized() external {
            (TransitStation station, bytes32 uuid) = _deployStationWithPendingOrder();

            // `executor` is only authorized for `executePendingOrders`, not `forceRemovePendingOrder`.
            vm.prank(executor);
            vm.expectRevert("UNAUTHORIZED");
            station.forceRemovePendingOrder(uuid);
        }

        function testForceRemovePendingOrder_RevertIf_OrderNotFound() external {
            (TransitStation station,) = _deployStationWithPendingOrder();

            bytes32 unknownUuid = keccak256("unknown");

            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(TransitStation.OrderNotFound.selector, unknownUuid));
            station.forceRemovePendingOrder(unknownUuid);
        }

        // ========================================= forceRemovePendingOrder EFFECTS =========================================

        function testForceRemovePendingOrder_RemovesOrder() external {
            (TransitStation station, bytes32 uuid) = _deployStationWithPendingOrder();

            assertEq(station.pendingOrderCount(), 1);

            vm.prank(owner);
            station.forceRemovePendingOrder(uuid);

            assertEq(station.pendingOrderCount(), 0);
            assertEq(station.getPendingOrders().length, 0);
        }

        function testForceRemovePendingOrder_AfterPartialFill() external {
            (TransitStation station, bytes32 uuid) = _deployStationWithPendingOrder();

            uint256 fillAmount = DEFAULT_OFFER_AMOUNT / 2;

            vm.prank(wantAssetSource);
            wantAsset.approve(address(station), fillAmount);

            vm.prank(executor);
            station.executePendingOrders(_singleFillBatch(address(wantAsset), uuid, fillAmount));

            assertEq(station.pendingOrderCount(), 1);
            assertEq(station.getPendingOrders()[0].amountDue, DEFAULT_OFFER_AMOUNT - fillAmount);

            vm.prank(owner);
            station.forceRemovePendingOrder(uuid);

            assertEq(station.pendingOrderCount(), 0);
            assertEq(station.getPendingOrders().length, 0);
        }

        // ========================================= ADMIN & UTILITY REVERTS =========================================

        function testRecoverETH_RevertIf_CallerNotAuthorized() external {
            TransitStation station = _deployDefaultStation();
            vm.deal(address(station), 1 ether);

            address unauthorized = makeAddr("unauthorized");
            vm.prank(unauthorized);
            vm.expectRevert("UNAUTHORIZED");
            station.recoverETH(1 ether);
        }

        function testRecoverETH_RevertIf_CallFailed() external {
            RevertingReceiver revertingOwner = new RevertingReceiver();
            TransitStation station = _deploy(
                address(revertingOwner),
                protocolFeeRecipient,
                quoteSigner,
                offerReceiver,
                wantAssetSource,
                address(endpoint)
            );

            vm.deal(address(station), 1 ether);

            vm.prank(address(revertingOwner));
            vm.expectRevert(TransitStation.CallFailed.selector);
            station.recoverETH(1 ether);
        }

        function testRecoverTokens_RevertIf_CallerNotAuthorized() external {
            TransitStation station = _deployDefaultStation();
            deal(address(offerAsset), address(station), 1e18);

            address unauthorized = makeAddr("unauthorized");
            vm.prank(unauthorized);
            vm.expectRevert("UNAUTHORIZED");
            station.recoverTokens(offerAsset, 1e18);
        }

        // ========================================= ADMIN & UTILITY EFFECTS =========================================

        function testRecoverETH_RecoversFunds() external {
            TransitStation station = _deployDefaultStation();
            vm.deal(address(station), 1 ether);

            uint256 ownerBalanceBefore = owner.balance;

            vm.prank(owner);
            station.recoverETH(1 ether);

            assertEq(address(station).balance, 0);
            assertEq(owner.balance, ownerBalanceBefore + 1 ether);
        }

        function testRecoverTokens_RecoversTokens() external {
            TransitStation station = _deployDefaultStation();
            deal(address(offerAsset), address(station), 1e18);

            uint256 ownerBalanceBefore = offerAsset.balanceOf(owner);

            vm.prank(owner);
            station.recoverTokens(offerAsset, 1e18);

            assertEq(offerAsset.balanceOf(address(station)), 0);
            assertEq(offerAsset.balanceOf(owner), ownerBalanceBefore + 1e18);
        }

        function testSetProtocolFeeRecipient_RevertIf_CallerNotAuthorized() external {
            TransitStation station = _deployDefaultStation();

            address unauthorized = makeAddr("unauthorized");
            vm.prank(unauthorized);
            vm.expectRevert("UNAUTHORIZED");
            station.setProtocolFeeRecipient(makeAddr("newRecipient"));
        }

        function testSetProtocolFeeRecipient_RevertIf_ZeroAddress() external {
            TransitStation station = _deployDefaultStation();

            vm.prank(owner);
            vm.expectRevert(TransitStation.ZeroAddress.selector);
            station.setProtocolFeeRecipient(address(0));
        }

        function testSetQuoteSigner_RevertIf_CallerNotAuthorized() external {
            TransitStation station = _deployDefaultStation();

            address unauthorized = makeAddr("unauthorized");
            vm.prank(unauthorized);
            vm.expectRevert("UNAUTHORIZED");
            station.setQuoteSigner(makeAddr("newSigner"));
        }

        function testSetQuoteSigner_RevertIf_ZeroAddress() external {
            TransitStation station = _deployDefaultStation();

            vm.prank(owner);
            vm.expectRevert(TransitStation.ZeroAddress.selector);
            station.setQuoteSigner(address(0));
        }

        function testSetOfferReceiver_RevertIf_CallerNotAuthorized() external {
            TransitStation station = _deployDefaultStation();

            address unauthorized = makeAddr("unauthorized");
            vm.prank(unauthorized);
            vm.expectRevert("UNAUTHORIZED");
            station.setOfferReceiver(makeAddr("newOfferReceiver"));
        }

        function testSetOfferReceiver_RevertIf_ZeroAddress() external {
            TransitStation station = _deployDefaultStation();

            vm.prank(owner);
            vm.expectRevert(TransitStation.ZeroAddress.selector);
            station.setOfferReceiver(address(0));
        }

        function testSetWantAssetSource_RevertIf_CallerNotAuthorized() external {
            TransitStation station = _deployDefaultStation();

            address unauthorized = makeAddr("unauthorized");
            vm.prank(unauthorized);
            vm.expectRevert("UNAUTHORIZED");
            station.setWantAssetSource(makeAddr("newWantAssetSource"));
        }

        function testSetWantAssetSource_RevertIf_ZeroAddress() external {
            TransitStation station = _deployDefaultStation();

            vm.prank(owner);
            vm.expectRevert(TransitStation.ZeroAddress.selector);
            station.setWantAssetSource(address(0));
        }

        function testSetRouteApprovals_RevertIf_CallerNotAuthorized() external {
            TransitStation station = _deployDefaultStation();

            TransitStation.Route[] memory routes = new TransitStation.Route[](1);
            routes[0] = TransitStation.Route({
                destEID: endpoint.eid(), offerAsset: address(offerAsset), wantAsset: address(wantAsset)
            });
            bool[] memory approved = new bool[](1);
            approved[0] = true;

            address unauthorized = makeAddr("unauthorized");
            vm.prank(unauthorized);
            vm.expectRevert("UNAUTHORIZED");
            station.setRouteApprovals(routes, approved);
        }

        function testSetRouteApprovals_RevertIf_LengthMismatch() external {
            TransitStation station = _deployDefaultStation();

            TransitStation.Route[] memory routes = new TransitStation.Route[](1);
            routes[0] = TransitStation.Route({
                destEID: endpoint.eid(), offerAsset: address(offerAsset), wantAsset: address(wantAsset)
            });
            bool[] memory approved = new bool[](0);

            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(TransitStation.LengthMismatch.selector, 1, 0));
            station.setRouteApprovals(routes, approved);
        }

        function testSetMessageGasLimit_RevertIf_CallerNotAuthorized() external {
            TransitStation station = _deployDefaultStation();

            address unauthorized = makeAddr("unauthorized");
            vm.prank(unauthorized);
            vm.expectRevert("UNAUTHORIZED");
            station.setMessageGasLimit(DEST_EID, 400_000);
        }

        // ========================================= OAppAuth REVERTS =========================================

        function testSetPeer_RevertIf_CallerNotAuthorized() external {
            TransitStation station = _deployDefaultStation();

            address unauthorized = makeAddr("unauthorized");
            vm.prank(unauthorized);
            vm.expectRevert("UNAUTHORIZED");
            station.setPeer(DEST_EID, bytes32(uint256(uint160(address(station)))));
        }

        function testSetDelegate_RevertIf_CallerNotAuthorized() external {
            TransitStation station = _deployDefaultStation();

            address unauthorized = makeAddr("unauthorized");
            vm.prank(unauthorized);
            vm.expectRevert("UNAUTHORIZED");
            station.setDelegate(makeAddr("newDelegate"));
        }

        // ========================================= GETTER TESTS =========================================

        function testProtocolFeeRecipient_GetterAfterSetter() external {
            TransitStation station = _deployDefaultStation();
            address newRecipient = makeAddr("newRecipient");

            vm.prank(owner);
            station.setProtocolFeeRecipient(newRecipient);

            assertEq(station.protocolFeeRecipient(), newRecipient);
        }

        function testQuoteSigner_GetterAfterSetter() external {
            TransitStation station = _deployDefaultStation();
            address newSigner = makeAddr("newSigner");

            vm.prank(owner);
            station.setQuoteSigner(newSigner);

            assertEq(station.quoteSigner(), newSigner);
        }

        function testOfferReceiver_GetterAfterSetter() external {
            TransitStation station = _deployDefaultStation();
            address newOfferReceiver = makeAddr("newOfferReceiver");

            vm.prank(owner);
            station.setOfferReceiver(newOfferReceiver);

            assertEq(station.offerReceiver(), newOfferReceiver);
        }

        function testWantAssetSource_GetterAfterSetter() external {
            TransitStation station = _deployDefaultStation();
            address newWantAssetSource = makeAddr("newWantAssetSource");

            vm.prank(owner);
            station.setWantAssetSource(newWantAssetSource);

            assertEq(station.wantAssetSource(), newWantAssetSource);
        }

        function testMessageGasLimit_GetterAfterSetter() external {
            TransitStation station = _deployDefaultStation();
            uint64 gasLimit = 400_000;

            vm.prank(owner);
            station.setMessageGasLimit(DEST_EID, gasLimit);

            assertEq(station.messageGasLimit(DEST_EID), gasLimit);
        }

        function testApprovedRoutes_GetterAfterSetter() external {
            TransitStation station = _deployDefaultStation();

            TransitStation.Route[] memory routes = new TransitStation.Route[](1);
            routes[0] = TransitStation.Route({
                destEID: endpoint.eid(), offerAsset: address(offerAsset), wantAsset: address(wantAsset)
            });
            bool[] memory approved = new bool[](1);
            approved[0] = true;

            vm.prank(owner);
            station.setRouteApprovals(routes, approved);

            assertTrue(station.approvedRoutes(endpoint.eid(), address(offerAsset), address(wantAsset)));
        }

        function testPeers_GetterAfterSetter() external {
            TransitStation station = _deployDefaultStation();
            bytes32 peer = bytes32(uint256(uint160(address(station))));

            vm.prank(owner);
            station.setPeer(DEST_EID, peer);

            assertEq(station.peers(DEST_EID), peer);
        }

        // ========================================= RETURN VALUE TESTS =========================================

        function testSubmitOrder_ReturnsUuid() external {
            TransitStation station = _deployDefaultStation();

            TransitStation.Quote memory quote = _defaultQuote();
            bytes memory signature = _signQuote(station, quote);
            bytes32 expectedUuid = keccak256(abi.encodePacked(hex"1901", _domainSeparator(station), _hashQuote(quote)));

            vm.prank(user);
            bytes32 uuid = station.submitOrder{ value: 0 }(quote, signature);

            assertEq(uuid, expectedUuid);
        }

        function testSubmitOrderWithPermit_ReturnsUuid() external {
            TransitStation station = _deployDefaultStation();

            TransitStation.Quote memory quote = _defaultQuote();
            bytes memory signature = _signQuote(station, quote);
            bytes32 expectedUuid = keccak256(abi.encodePacked(hex"1901", _domainSeparator(station), _hashQuote(quote)));

            vm.prank(user);
            bytes32 uuid =
                station.submitOrderWithPermit(quote, signature, block.timestamp + 1 hours, 27, bytes32(0), bytes32(0));

            assertEq(uuid, expectedUuid);
        }

        function testGetPendingOrders_ReturnsCorrectOrders() external {
            TransitStation station = _deployDefaultStation();
            TransitStation.Quote memory quote = _defaultQuote();

            // Empty case.
            assertEq(station.getPendingOrders().length, 0);

            // One order.
            quote.salt = bytes32(uint256(0));
            bytes memory signature0 = _signQuote(station, quote);
            bytes32 expectedUuid0 = keccak256(abi.encodePacked(hex"1901", _domainSeparator(station), _hashQuote(quote)));
            vm.prank(user);
            station.submitOrder{ value: 0 }(quote, signature0);

            TransitStation.Order[] memory orders = station.getPendingOrders();
            assertEq(orders.length, 1);
            assertEq(orders[0].terms.uuid, expectedUuid0);
            assertEq(orders[0].terms.wantAsset, address(wantAsset));
            assertEq(orders[0].terms.receiver, user);
            assertEq(orders[0].terms.offerAsset, address(offerAsset));
            assertEq(orders[0].terms.offerAmountNormalized18AfterFees, DEFAULT_OFFER_AMOUNT_NORMALIZED);
            assertEq(orders[0].amountDue, DEFAULT_OFFER_AMOUNT);
            assertEq(orders[0].queuedAt, block.timestamp);

            // Two orders.
            quote.salt = bytes32(uint256(1));
            bytes memory signature1 = _signQuote(station, quote);
            bytes32 expectedUuid1 = keccak256(abi.encodePacked(hex"1901", _domainSeparator(station), _hashQuote(quote)));
            vm.prank(user);
            station.submitOrder{ value: 0 }(quote, signature1);

            orders = station.getPendingOrders();
            assertEq(orders.length, 2);
            assertEq(orders[0].terms.uuid, expectedUuid0);
            assertEq(orders[1].terms.uuid, expectedUuid1);

            // Three orders.
            quote.salt = bytes32(uint256(2));
            bytes memory signature2 = _signQuote(station, quote);
            bytes32 expectedUuid2 = keccak256(abi.encodePacked(hex"1901", _domainSeparator(station), _hashQuote(quote)));
            vm.prank(user);
            station.submitOrder{ value: 0 }(quote, signature2);

            orders = station.getPendingOrders();
            assertEq(orders.length, 3);
            assertEq(orders[0].terms.uuid, expectedUuid0);
            assertEq(orders[1].terms.uuid, expectedUuid1);
            assertEq(orders[2].terms.uuid, expectedUuid2);
        }

        function testPendingOrderCount_ReturnsCorrectCount() external {
            TransitStation station = _deployDefaultStation();

            TransitStation.Quote memory quote = _defaultQuote();
            bytes memory signature = _signQuote(station, quote);

            assertEq(station.pendingOrderCount(), 0);

            vm.prank(user);
            station.submitOrder{ value: 0 }(quote, signature);
            assertEq(station.pendingOrderCount(), 1);

            quote.salt = bytes32(uint256(1));
            signature = _signQuote(station, quote);
            vm.prank(user);
            station.submitOrder{ value: 0 }(quote, signature);
            assertEq(station.pendingOrderCount(), 2);
        }

        function testQuoteSend_ReturnsNativeFee() external {
            TransitStation station = _deployDefaultStationWithCrossChainRoute();

            vm.startPrank(owner);
            station.setPeer(DEST_EID, bytes32(uint256(uint160(address(station)))));
            station.setMessageGasLimit(DEST_EID, 400_000);
            vm.stopPrank();

            TransitStation.OrderTerms memory terms = _defaultOrderTerms();

            uint256 fee = station.quoteSend(DEST_EID, terms);
            assertEq(fee, LZ_QUOTE_FEE);
        }

        // ========================================= EVENT TESTS =========================================

        function testSubmitOrder_EmitsOrderSubmitted_SameChain() external {
            TransitStation station = _deployDefaultStation();
            TransitStation.Quote memory quote = _defaultQuote();
            bytes memory signature = _signQuote(station, quote);
            bytes32 uuid = keccak256(abi.encodePacked(hex"1901", _domainSeparator(station), _hashQuote(quote)));

            TransitStation.OrderTerms memory expectedTerms = TransitStation.OrderTerms({
                uuid: uuid,
                wantAsset: address(wantAsset),
                receiver: user,
                offerAsset: address(offerAsset),
                offerAmountNormalized18AfterFees: DEFAULT_OFFER_AMOUNT_NORMALIZED
            });

            vm.expectEmit(true, true, true, true);
            emit OrderSubmitted(uuid, endpoint.eid(), quote.route, expectedTerms, user, bytes32(0));

            vm.prank(user);
            station.submitOrder{ value: 0 }(quote, signature);
        }

        function testSubmitOrder_EmitsOrderSubmitted_CrossChain() external {
            TransitStation station = _deployDefaultStationWithCrossChainRoute();

            vm.startPrank(owner);
            station.setPeer(DEST_EID, bytes32(uint256(uint160(address(station)))));
            station.setMessageGasLimit(DEST_EID, 400_000);
            vm.stopPrank();

            TransitStation.Quote memory quote = _defaultQuote();
            quote.route.destEID = DEST_EID;
            bytes memory signature = _signQuote(station, quote);
            bytes32 uuid = keccak256(abi.encodePacked(hex"1901", _domainSeparator(station), _hashQuote(quote)));

            TransitStation.OrderTerms memory expectedTerms = TransitStation.OrderTerms({
                uuid: uuid,
                wantAsset: address(wantAsset),
                receiver: user,
                offerAsset: address(offerAsset),
                offerAmountNormalized18AfterFees: DEFAULT_OFFER_AMOUNT_NORMALIZED
            });

            vm.deal(user, LZ_QUOTE_FEE);

            vm.expectEmit(true, true, true, true);
            emit OrderSubmitted(uuid, endpoint.eid(), quote.route, expectedTerms, user, bytes32(0));

            vm.prank(user);
            station.submitOrder{ value: LZ_QUOTE_FEE }(quote, signature);
        }

        function testSubmitOrder_EmitsOrderReceived() external {
            TransitStation station = _deployDefaultStation();
            TransitStation.Quote memory quote = _defaultQuote();
            bytes memory signature = _signQuote(station, quote);
            bytes32 uuid = keccak256(abi.encodePacked(hex"1901", _domainSeparator(station), _hashQuote(quote)));

            TransitStation.OrderTerms memory expectedTerms = TransitStation.OrderTerms({
                uuid: uuid,
                wantAsset: address(wantAsset),
                receiver: user,
                offerAsset: address(offerAsset),
                offerAmountNormalized18AfterFees: DEFAULT_OFFER_AMOUNT_NORMALIZED
            });
            TransitStation.Order memory expectedOrder = TransitStation.Order({
                terms: expectedTerms,
                amountDue: DEFAULT_OFFER_AMOUNT,
                queuedAt: uint64(block.timestamp)
            });

            vm.expectEmit(true, false, false, true);
            emit OrderReceived(uuid, expectedOrder);

            vm.prank(user);
            station.submitOrder{ value: 0 }(quote, signature);
        }

        function testSubmitOrder_EmitsOrderBridged() external {
            TransitStation station = _deployDefaultStationWithCrossChainRoute();

            vm.startPrank(owner);
            station.setPeer(DEST_EID, bytes32(uint256(uint160(address(station)))));
            station.setMessageGasLimit(DEST_EID, 400_000);
            vm.stopPrank();

            TransitStation.Quote memory quote = _defaultQuote();
            quote.route.destEID = DEST_EID;
            bytes memory signature = _signQuote(station, quote);
            bytes32 uuid = keccak256(abi.encodePacked(hex"1901", _domainSeparator(station), _hashQuote(quote)));

            TransitStation.OrderTerms memory expectedTerms = TransitStation.OrderTerms({
                uuid: uuid,
                wantAsset: address(wantAsset),
                receiver: user,
                offerAsset: address(offerAsset),
                offerAmountNormalized18AfterFees: DEFAULT_OFFER_AMOUNT_NORMALIZED
            });

            vm.deal(user, LZ_QUOTE_FEE);

            vm.expectEmit(true, true, false, true);
            emit OrderBridged(uuid, DEST_EID, bytes32(0), expectedTerms);

            vm.prank(user);
            station.submitOrder{ value: LZ_QUOTE_FEE }(quote, signature);
        }

        function testLzReceive_EmitsOrderBridgeReceived() external {
            TransitStation station = _deployDefaultStation();

            vm.prank(owner);
            station.setPeer(DEST_EID, bytes32(uint256(uint160(address(station)))));

            TransitStation.OrderTerms memory terms = TransitStation.OrderTerms({
                uuid: keccak256("test-uuid"),
                wantAsset: address(wantAsset),
                receiver: user,
                offerAsset: address(offerAsset),
                offerAmountNormalized18AfterFees: DEFAULT_OFFER_AMOUNT_NORMALIZED
            });
            bytes memory payload = abi.encode(terms);
            Origin memory origin = Origin({
                srcEid: DEST_EID,
                sender: bytes32(uint256(uint160(address(station)))),
                nonce: 1
            });
            bytes32 guid = bytes32(uint256(1));

            TransitStation.Order memory expectedOrder = TransitStation.Order({
                terms: terms,
                amountDue: DEFAULT_OFFER_AMOUNT,
                queuedAt: uint64(block.timestamp)
            });

            vm.expectEmit(true, true, false, true);
            emit OrderBridgeReceived(terms.uuid, DEST_EID, guid, expectedOrder);

            vm.prank(address(endpoint));
            station.lzReceive(origin, guid, payload, address(0), "");
        }

        function testForceRemovePendingOrder_EmitsOrderForceRemoved() external {
            (TransitStation station, bytes32 uuid) = _deployStationWithPendingOrder();

            TransitStation.Order memory order = station.getPendingOrders()[0];

            vm.expectEmit(true, false, false, true);
            emit OrderForceRemoved(uuid, order);

            vm.prank(owner);
            station.forceRemovePendingOrder(uuid);
        }

        function testSetProtocolFeeRecipient_EmitsProtocolFeeRecipientSet() external {
            TransitStation station = _deployDefaultStation();
            address newRecipient = makeAddr("newRecipient");

            vm.expectEmit(true, false, false, true);
            emit ProtocolFeeRecipientSet(newRecipient);

            vm.prank(owner);
            station.setProtocolFeeRecipient(newRecipient);
        }

        function testSetQuoteSigner_EmitsQuoteSignerSet() external {
            TransitStation station = _deployDefaultStation();
            address newSigner = makeAddr("newSigner");

            vm.expectEmit(true, false, false, true);
            emit QuoteSignerSet(newSigner);

            vm.prank(owner);
            station.setQuoteSigner(newSigner);
        }

        function testSetOfferReceiver_EmitsOfferReceiverSet() external {
            TransitStation station = _deployDefaultStation();
            address newOfferReceiver = makeAddr("newOfferReceiver");

            vm.expectEmit(true, false, false, true);
            emit OfferReceiverSet(newOfferReceiver);

            vm.prank(owner);
            station.setOfferReceiver(newOfferReceiver);
        }

        function testSetWantAssetSource_EmitsWantAssetSourceSet() external {
            TransitStation station = _deployDefaultStation();
            address newWantAssetSource = makeAddr("newWantAssetSource");

            vm.expectEmit(true, false, false, true);
            emit WantAssetSourceSet(newWantAssetSource);

            vm.prank(owner);
            station.setWantAssetSource(newWantAssetSource);
        }

        function testSetMessageGasLimit_EmitsMessageGasLimitSet() external {
            TransitStation station = _deployDefaultStation();
            uint64 gasLimit = 400_000;

            vm.expectEmit(true, false, false, true);
            emit MessageGasLimitSet(DEST_EID, gasLimit);

            vm.prank(owner);
            station.setMessageGasLimit(DEST_EID, gasLimit);
        }

        function testSetRouteApprovals_EmitsRouteApprovalSet() external {
            TransitStation station = _deployDefaultStation();

            TransitStation.Route[] memory routes = new TransitStation.Route[](1);
            routes[0] = TransitStation.Route({
                destEID: endpoint.eid(), offerAsset: address(offerAsset), wantAsset: address(wantAsset)
            });
            bool[] memory approved = new bool[](1);
            approved[0] = true;

            vm.expectEmit(true, false, false, true);
            emit RouteApprovalSet(routes[0], true);

            vm.prank(owner);
            station.setRouteApprovals(routes, approved);
        }

    }
