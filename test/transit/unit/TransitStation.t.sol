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
        ERC20 offerAsset;
        ERC20 wantAsset;

        uint256 constant DEFAULT_OFFER_AMOUNT = 100e18;
        uint32 constant DEST_EID = 2;
        uint256 constant LZ_QUOTE_FEE = 0.01 ether;

        bytes32 constant DOMAIN_TYPEHASH =
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        bytes32 constant ROUTE_TYPEHASH = keccak256("Route(uint32 destEID,address offerAsset,address wantAsset)");
        bytes32 constant QUOTE_TYPEHASH = keccak256(
            "Quote(Route route,uint256 offerAmountNormalized18,address receiver,uint256 protocolFeeNormalized18,uint256 integratorFeeNormalized18,address integratorFeeReceiver,bytes32 distributorCode,uint256 deadline,bytes32 salt)Route(uint32 destEID,address offerAsset,address wantAsset)"
        );

        function setUp() public {
            rolesAuthority = new RolesAuthority(owner, Authority(address(0)));
            endpoint = new MockEndpoint(1);
            endpoint.setQuoteFee(LZ_QUOTE_FEE);
            (quoteSigner, quoteSignerPk) = makeAddrAndKey("quoteSigner");
            offerAsset = new tERC20(18);
            wantAsset = new tERC20(18);
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
        ///      - Offer and want assets are the 18-decimal test tokens deployed in `setUp`.
        ///      - `offerAmountNormalized18` is `DEFAULT_OFFER_AMOUNT` (100e18), large enough to avoid
        ///        truncation-to-zero issues.
        ///      - Both fees are zero and `integratorFeeReceiver` is `address(0)`.
        ///      - `receiver` is the test `user`.
        ///      - `deadline` is `block.timestamp + 1 hours`.
        ///      - `distributorCode` and `salt` are empty.
        function _defaultQuote() internal view returns (TransitStation.Quote memory) {
            return TransitStation.Quote({
                route: TransitStation.Route({
                    destEID: endpoint.eid(), offerAsset: address(offerAsset), wantAsset: address(wantAsset)
                }),
                offerAmountNormalized18: DEFAULT_OFFER_AMOUNT,
                receiver: user,
                protocolFeeNormalized18: 0,
                integratorFeeNormalized18: 0,
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
                offerAmountNormalized18AfterFees: DEFAULT_OFFER_AMOUNT
            });
        }

        function _hashRoute(TransitStation.Route memory route) internal pure returns (bytes32) {
            return keccak256(abi.encode(ROUTE_TYPEHASH, route.destEID, route.offerAsset, route.wantAsset));
        }

        function _hashQuote(TransitStation.Quote memory quote) internal pure returns (bytes32) {
            return keccak256(
                abi.encode(
                    QUOTE_TYPEHASH,
                    _hashRoute(quote.route),
                    quote.offerAmountNormalized18,
                    quote.receiver,
                    quote.protocolFeeNormalized18,
                    quote.integratorFeeNormalized18,
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
            // TODO: ...
            vm.skip(true);
        }

        function testSubmitOrder_RevertIf_Paused() external {
            TransitStation station = _deployDefaultStation();

            vm.prank(owner);
            station.pause();
            assertTrue(station.paused());

            TransitStation.Quote memory quote = _defaultQuote();
            bytes memory signature = _signQuote(station, quote);

            // `whenNotPaused` is checked after `requiresAuth`; the owner is always authorized, so the
            // pause modifier is what reverts.
            vm.prank(owner);
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
            quote.integratorFeeNormalized18 = 1e18;
            bytes memory signature = _signQuote(station, quote);

            vm.prank(user);
            vm.expectRevert(TransitStation.ZeroAddress.selector);
            station.submitOrder(quote, signature);
        }

        function testSubmitOrder_RevertIf_ProtocolFeeTooHigh() external {
            TransitStation station = _deployDefaultStation();

            uint256 maxProtocolFee = (DEFAULT_OFFER_AMOUNT * station.MAX_PROTOCOL_FEE_BPS()) / 10_000;

            TransitStation.Quote memory quote = _defaultQuote();
            quote.protocolFeeNormalized18 = maxProtocolFee + 1;
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
            quote.integratorFeeNormalized18 = maxIntegratorFee + 1;
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
            quote.offerAmountNormalized18 = 0;
            bytes memory signature = _signQuote(station, quote);

            vm.prank(user);
            vm.expectRevert(abi.encodeWithSelector(TransitStation.FeesExceedOffer.selector, 0, 0, 0));
            station.submitOrder(quote, signature);
        }

        function testSubmitOrder_RevertIf_NetTruncatesToZero() external {
            ERC20 offerAsset6 = new tERC20(6);
            TransitStation station = _deployStationWithAssets(offerAsset6, wantAsset);

            TransitStation.Quote memory quote = _defaultQuote();
            quote.route.offerAsset = address(offerAsset6);
            quote.offerAmountNormalized18 = 1e11;
            bytes memory signature = _signQuote(station, quote);

            vm.prank(user);
            vm.expectRevert(abi.encodeWithSelector(TransitStation.NetTruncatesToZero.selector, 1e11, 6));
            station.submitOrder(quote, signature);
        }

        function testSubmitOrder_RevertIf_ZeroAmountDue() external {
            ERC20 wantAsset6 = new tERC20(6);
            TransitStation station = _deployStationWithAssets(offerAsset, wantAsset6);

            TransitStation.Quote memory quote = _defaultQuote();
            quote.route.wantAsset = address(wantAsset6);
            quote.offerAmountNormalized18 = 1e11;
            bytes memory signature = _signQuote(station, quote);

            vm.prank(user);
            vm.expectRevert(TransitStation.ZeroAmountDue.selector);
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

        // ========================================= CROSS-CHAIN DISPATCH REVERTS
        // =========================================

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
            quote.protocolFeeNormalized18 = 0.5e18;
            quote.integratorFeeNormalized18 = 2e18;
            quote.integratorFeeReceiver = integrator;
            bytes memory signature = _signQuote(station, quote);

            uint256 userBalanceBefore = offerAsset.balanceOf(user);
            uint256 protocolBalanceBefore = offerAsset.balanceOf(protocolFeeRecipient);
            uint256 integratorBalanceBefore = offerAsset.balanceOf(integrator);
            uint256 offerReceiverBalanceBefore = offerAsset.balanceOf(offerReceiver);

            vm.prank(user);
            station.submitOrder{ value: 0 }(quote, signature);

            assertEq(offerAsset.balanceOf(user), userBalanceBefore - DEFAULT_OFFER_AMOUNT);
            assertEq(offerAsset.balanceOf(protocolFeeRecipient), protocolBalanceBefore + 0.5e18);
            assertEq(offerAsset.balanceOf(integrator), integratorBalanceBefore + 2e18);
            assertEq(
                offerAsset.balanceOf(offerReceiver), offerReceiverBalanceBefore + (DEFAULT_OFFER_AMOUNT - 0.5e18 - 2e18)
            );
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
            assertEq(order.terms.offerAmountNormalized18AfterFees, DEFAULT_OFFER_AMOUNT);
            assertEq(order.amountDue, DEFAULT_OFFER_AMOUNT);
            assertEq(order.queuedAt, block.timestamp);
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

        // ========================================= lzReceive REVERTS =========================================

        function testLzReceive_RevertIf_OnlyEndpoint() external {
            TransitStation station = _deployDefaultStation();

            vm.prank(owner);
            station.setPeer(DEST_EID, bytes32(uint256(uint160(address(station)))));

            TransitStation.OrderTerms memory terms = _defaultOrderTerms();
            bytes memory payload = abi.encode(terms);
            Origin memory origin = Origin({
                srcEid: DEST_EID,
                sender: bytes32(uint256(uint160(address(station)))),
                nonce: 1
            });

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
            Origin memory origin = Origin({
                srcEid: DEST_EID,
                sender: bytes32(uint256(uint160(address(station)))),
                nonce: 1
            });

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

        function testLzReceive_RevertIf_ZeroAmountDue() external {
            ERC20 wantAsset6 = new tERC20(6);
            TransitStation station = _deployStationWithAssets(offerAsset, wantAsset6);

            vm.prank(owner);
            station.setPeer(DEST_EID, bytes32(uint256(uint160(address(station)))));

            TransitStation.OrderTerms memory terms = TransitStation.OrderTerms({
                uuid: keccak256("test-uuid"),
                wantAsset: address(wantAsset6),
                receiver: user,
                offerAsset: address(offerAsset),
                offerAmountNormalized18AfterFees: 1e11
            });

            bytes memory payload = abi.encode(terms);
            Origin memory origin = Origin({
                srcEid: DEST_EID,
                sender: bytes32(uint256(uint160(address(station)))),
                nonce: 1
            });

            vm.prank(address(endpoint));
            vm.expectRevert(TransitStation.ZeroAmountDue.selector);
            station.lzReceive(origin, bytes32(0), payload, address(0), "");
        }

    }
