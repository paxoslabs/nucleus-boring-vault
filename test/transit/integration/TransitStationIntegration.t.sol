// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { TransitStation } from "src/transit/TransitStation.sol";
import { Authority } from "@solmate/auth/Auth.sol";
import { RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {
    ILayerZeroEndpointV2,
    MessagingParams,
    MessagingFee,
    MessagingReceipt,
    Origin
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { SetConfigParam } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";

/// @notice LayerZero endpoint mock sufficient for `TransitStation` construction.
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

    contract TransitStationIntegrationTest is Test {

        RolesAuthority rolesAuthority;
        MockEndpoint endpoint;
        MockEndpoint endpoint2;

        address owner = makeAddr("owner");
        address protocolFeeRecipient = makeAddr("protocolFeeRecipient");
        address quoteSigner;
        uint256 quoteSignerPk;
        address offerReceiver = makeAddr("offerReceiver");
        address wantAssetSource = makeAddr("wantAssetSource");
        address user = makeAddr("user");
        address executor = makeAddr("executor");

        tERC20 offerToken;
        tERC20 wantToken;
        tERC20 offerToken18;
        tERC20 wantToken18;

        TransitStation station;
        TransitStation dstStation;

        uint256 constant OFFER_AMOUNT = 100e6; // 100 tokens, 6 decimals
        uint256 constant OFFER_AMOUNT_18 = 100e18; // 100 tokens, 18 decimals
        uint256 constant OFFER_AMOUNT_NORMALIZED = 100e18;
        uint256 constant LZ_FEE = 0.01 ether;
        uint32 constant DST_EID = 2;
        uint8 constant EXECUTOR_ROLE = 1;

        address integratorFeeRecipient = makeAddr("integratorFeeRecipient");


        function setUp() public {
            (quoteSigner, quoteSignerPk) = makeAddrAndKey("quoteSigner");

            endpoint = new MockEndpoint(1);
            endpoint.setQuoteFee(LZ_FEE);
            endpoint2 = new MockEndpoint(DST_EID);

            rolesAuthority = new RolesAuthority(owner, Authority(address(0)));

            offerToken = new tERC20(6);
            wantToken = new tERC20(6);
            offerToken18 = new tERC20(18);
            wantToken18 = new tERC20(18);

            station = new TransitStation(
                owner,
                Authority(address(rolesAuthority)),
                address(endpoint),
                protocolFeeRecipient,
                quoteSigner,
                offerReceiver,
                wantAssetSource
            );

            dstStation = new TransitStation(
                owner,
                Authority(address(rolesAuthority)),
                address(endpoint2),
                protocolFeeRecipient,
                quoteSigner,
                offerReceiver,
                wantAssetSource
            );

            // Authorize public submission and executor fulfillment.
            vm.startPrank(owner);
            rolesAuthority.setPublicCapability(address(station), TransitStation.submitOrder.selector, true);
            rolesAuthority.setPublicCapability(address(station), TransitStation.submitOrderWithPermit.selector, true);
            rolesAuthority.setUserRole(executor, EXECUTOR_ROLE, true);
            rolesAuthority.setRoleCapability(
                EXECUTOR_ROLE, address(station), TransitStation.executePendingOrders.selector, true
            );
            rolesAuthority.setRoleCapability(
                EXECUTOR_ROLE, address(dstStation), TransitStation.executePendingOrders.selector, true
            );

            // Wire the two stations as LayerZero peers.
            station.setPeer(DST_EID, bytes32(uint256(uint160(address(dstStation)))));
            dstStation.setPeer(uint32(endpoint.eid()), bytes32(uint256(uint160(address(station)))));
            station.setMessageGasLimit(DST_EID, 400_000);

            // Approve same-chain and cross-chain routes for 6/6, 6/18, and 18/6 decimal pairs.
            TransitStation.Route[] memory routes = new TransitStation.Route[](6);
            routes[0] = TransitStation.Route({
                destEID: endpoint.eid(), offerAsset: address(offerToken), wantAsset: address(wantToken)
            });
            routes[1] = TransitStation.Route({
                destEID: endpoint.eid(), offerAsset: address(offerToken), wantAsset: address(wantToken18)
            });
            routes[2] = TransitStation.Route({
                destEID: endpoint.eid(), offerAsset: address(offerToken18), wantAsset: address(wantToken)
            });
            routes[3] = TransitStation.Route({
                destEID: DST_EID, offerAsset: address(offerToken), wantAsset: address(wantToken)
            });
            routes[4] = TransitStation.Route({
                destEID: DST_EID, offerAsset: address(offerToken), wantAsset: address(wantToken18)
            });
            routes[5] = TransitStation.Route({
                destEID: DST_EID, offerAsset: address(offerToken18), wantAsset: address(wantToken)
            });
            bool[] memory approved = new bool[](6);
            approved[0] = true;
            approved[1] = true;
            approved[2] = true;
            approved[3] = true;
            approved[4] = true;
            approved[5] = true;
            station.setRouteApprovals(routes, approved);
            vm.stopPrank();
        }

        function _domainSeparator(TransitStation _station) internal view returns (bytes32) {
            return keccak256(
                abi.encode(
                    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                    keccak256(bytes("TransitStation")),
                    keccak256(bytes("1")),
                    block.chainid,
                    address(_station)
                )
            );
        }

        function _signQuote(TransitStation.Quote memory quote) internal view returns (bytes memory) {
            bytes32 digest = keccak256(abi.encodePacked(hex"1901", _domainSeparator(station), station.hashQuote(quote)));
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(quoteSignerPk, digest);
            return abi.encodePacked(r, s, v);
        }

        function _defaultQuote() internal view returns (TransitStation.Quote memory) {
            return TransitStation.Quote({
                route: TransitStation.Route({
                    destEID: endpoint.eid(), offerAsset: address(offerToken), wantAsset: address(wantToken)
                }),
                offerAmount: OFFER_AMOUNT,
                receiver: user,
                protocolFee: 0,
                integratorFee: 0,
                integratorFeeReceiver: address(0),
                distributorCode: bytes32(0),
                deadline: block.timestamp + 1 hours,
                salt: bytes32(0)
            });
        }

        /// @dev Manually deliver the bridged `OrderTerms` to the destination station as its local endpoint would.
        function _simulateLzReceive(TransitStation.OrderTerms memory terms) internal {
            bytes memory payload = abi.encode(terms);
            Origin memory origin = Origin({
                srcEid: uint32(endpoint.eid()),
                sender: bytes32(uint256(uint160(address(station)))),
                nonce: 0
            });

            vm.prank(address(endpoint2));
            dstStation.lzReceive(origin, bytes32(0), payload, address(0), "");
        }

        /// @dev Submit a cross-chain quote on the source station and extract the bridged `OrderTerms` from the
        ///      `OrderBridged` event so tests do not have to reconstruct it.
        function _submitCrossChainAndGetTerms(TransitStation.Quote memory quote)
            internal
            returns (bytes32 uuid, TransitStation.OrderTerms memory terms)
        {
            bytes memory signature = _signQuote(quote);

            vm.recordLogs();
            vm.startPrank(user);
            uuid = station.submitOrder{ value: LZ_FEE }(quote, signature);
            vm.stopPrank();

            bytes32 eventSig =
                keccak256("OrderBridged(bytes32,uint32,bytes32,(bytes32,address,address,address,uint256))");
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 i; i < logs.length;) {
                if (logs[i].topics[0] == eventSig) {
                    (, terms) = abi.decode(logs[i].data, (bytes32, TransitStation.OrderTerms));
                    return (uuid, terms);
                }
                unchecked {
                    ++i;
                }
            }
            revert("OrderBridged event not found");
        }

        function testFullSameChainOrder_6DecimalsTo6Decimals() external {
            // Fund the user and approve the station for the full offer amount.
            deal(address(offerToken), user, OFFER_AMOUNT * 10);
            vm.prank(user);
            offerToken.approve(address(station), OFFER_AMOUNT);

            // Build a quote with a 0.5% protocol fee and a 1% integrator fee.
            uint256 protocolFeeNormalized18 = (OFFER_AMOUNT_NORMALIZED * 50) / 10_000;
            uint256 integratorFeeNormalized18 = (OFFER_AMOUNT_NORMALIZED * 100) / 10_000;
            uint256 protocolFeeTokenUnits = protocolFeeNormalized18 / 10 ** (18 - 6);
            uint256 integratorFeeTokenUnits = integratorFeeNormalized18 / 10 ** (18 - 6);
            uint256 netTokenUnits = OFFER_AMOUNT - protocolFeeTokenUnits - integratorFeeTokenUnits;

            TransitStation.Quote memory quote = _defaultQuote();
            quote.protocolFee = protocolFeeTokenUnits;
            quote.integratorFee = integratorFeeTokenUnits;
            quote.integratorFeeReceiver = integratorFeeRecipient;

            bytes memory signature = _signQuote(quote);

            uint256 offererBalanceBefore = offerToken.balanceOf(user);
            uint256 offerReceiverBalanceBefore = offerToken.balanceOf(offerReceiver);

            vm.prank(user);
            bytes32 uuid = station.submitOrder{ value: 0 }(quote, signature);

            bytes32 expectedUuid = keccak256(abi.encodePacked(hex"1901", _domainSeparator(station), station.hashQuote(quote)));
            assertEq(uuid, expectedUuid);

            // Offer tokens should have been partitioned between fees and the offer receiver.
            assertEq(offerToken.balanceOf(user), offererBalanceBefore - OFFER_AMOUNT);
            assertEq(offerToken.balanceOf(protocolFeeRecipient), protocolFeeTokenUnits);
            assertEq(offerToken.balanceOf(integratorFeeRecipient), integratorFeeTokenUnits);
            assertEq(offerToken.balanceOf(offerReceiver), offerReceiverBalanceBefore + netTokenUnits);

            // Order should be pending locally.
            assertEq(station.pendingOrderCount(), 1);
            TransitStation.Order[] memory orders = station.getPendingOrders();
            assertEq(orders.length, 1);
            assertEq(orders[0].terms.uuid, uuid);
            assertEq(orders[0].terms.wantAsset, address(wantToken));
            assertEq(orders[0].terms.receiver, user);
            assertEq(orders[0].terms.offerAsset, address(offerToken));
            assertEq(
                orders[0].terms.offerAmountNormalized18AfterFees,
                OFFER_AMOUNT_NORMALIZED - protocolFeeNormalized18 - integratorFeeNormalized18
            );
            assertEq(orders[0].amountDue, netTokenUnits); // 6-decimal want token

            // Fund the want-asset source and fulfill the order for the post-fee amount.
            deal(address(wantToken), wantAssetSource, netTokenUnits * 10);
            vm.prank(wantAssetSource);
            wantToken.approve(address(station), netTokenUnits);

            uint256 userWantBalanceBefore = wantToken.balanceOf(user);
            uint256 wantSourceBalanceBefore = wantToken.balanceOf(wantAssetSource);

            TransitStation.FillBatch[] memory batches = new TransitStation.FillBatch[](1);
            bytes32[] memory uuids = new bytes32[](1);
            uuids[0] = uuid;
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = netTokenUnits;
            batches[0] = TransitStation.FillBatch({ wantAsset: address(wantToken), uuids: uuids, amounts: amounts });

            vm.prank(executor);
            station.executePendingOrders(batches);

            // Want tokens should have moved from source to receiver.
            assertEq(wantToken.balanceOf(user), userWantBalanceBefore + netTokenUnits);
            assertEq(wantToken.balanceOf(wantAssetSource), wantSourceBalanceBefore - netTokenUnits);

            // Order should no longer be pending.
            assertEq(station.pendingOrderCount(), 0);
            assertEq(station.getPendingOrders().length, 0);
        }

        function testFullSameChainOrder_6DecimalsTo18Decimals() external {
            // Fund the user and approve the station for the full 6-decimal offer amount.
            deal(address(offerToken), user, OFFER_AMOUNT * 10);
            vm.prank(user);
            offerToken.approve(address(station), OFFER_AMOUNT);

            // Build a quote with a 0.5% protocol fee and a 1% integrator fee.
            uint256 protocolFeeNormalized18 = (OFFER_AMOUNT_NORMALIZED * 50) / 10_000;
            uint256 integratorFeeNormalized18 = (OFFER_AMOUNT_NORMALIZED * 100) / 10_000;
            uint256 protocolFeeTokenUnits = protocolFeeNormalized18 / 10 ** (18 - 6);
            uint256 integratorFeeTokenUnits = integratorFeeNormalized18 / 10 ** (18 - 6);
            uint256 netOfferTokenUnits = OFFER_AMOUNT - protocolFeeTokenUnits - integratorFeeTokenUnits;
            uint256 netNormalized18 = OFFER_AMOUNT_NORMALIZED - protocolFeeNormalized18 - integratorFeeNormalized18;

            TransitStation.Quote memory quote = _defaultQuote();
            quote.route.wantAsset = address(wantToken18);
            quote.protocolFee = protocolFeeTokenUnits;
            quote.integratorFee = integratorFeeTokenUnits;
            quote.integratorFeeReceiver = integratorFeeRecipient;

            bytes memory signature = _signQuote(quote);

            uint256 offererBalanceBefore = offerToken.balanceOf(user);
            uint256 offerReceiverBalanceBefore = offerToken.balanceOf(offerReceiver);

            vm.prank(user);
            bytes32 uuid = station.submitOrder{ value: 0 }(quote, signature);

            bytes32 expectedUuid = keccak256(abi.encodePacked(hex"1901", _domainSeparator(station), station.hashQuote(quote)));
            assertEq(uuid, expectedUuid);

            // Offer tokens should have been partitioned between fees and the offer receiver.
            assertEq(offerToken.balanceOf(user), offererBalanceBefore - OFFER_AMOUNT);
            assertEq(offerToken.balanceOf(protocolFeeRecipient), protocolFeeTokenUnits);
            assertEq(offerToken.balanceOf(integratorFeeRecipient), integratorFeeTokenUnits);
            assertEq(offerToken.balanceOf(offerReceiver), offerReceiverBalanceBefore + netOfferTokenUnits);

            // Order should be pending locally; amountDue is in 18-decimal want units.
            assertEq(station.pendingOrderCount(), 1);
            TransitStation.Order[] memory orders = station.getPendingOrders();
            assertEq(orders.length, 1);
            assertEq(orders[0].terms.uuid, uuid);
            assertEq(orders[0].terms.wantAsset, address(wantToken18));
            assertEq(orders[0].terms.receiver, user);
            assertEq(orders[0].terms.offerAsset, address(offerToken));
            assertEq(orders[0].terms.offerAmountNormalized18AfterFees, netNormalized18);
            assertEq(orders[0].amountDue, netNormalized18);

            // Fund the 18-decimal want-asset source and fulfill the order.
            deal(address(wantToken18), wantAssetSource, netNormalized18 * 10);
            vm.prank(wantAssetSource);
            wantToken18.approve(address(station), netNormalized18);

            uint256 userWantBalanceBefore = wantToken18.balanceOf(user);
            uint256 wantSourceBalanceBefore = wantToken18.balanceOf(wantAssetSource);

            TransitStation.FillBatch[] memory batches = new TransitStation.FillBatch[](1);
            bytes32[] memory uuids = new bytes32[](1);
            uuids[0] = uuid;
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = netNormalized18;
            batches[0] = TransitStation.FillBatch({ wantAsset: address(wantToken18), uuids: uuids, amounts: amounts });

            vm.prank(executor);
            station.executePendingOrders(batches);

            // Want tokens should have moved from source to receiver.
            assertEq(wantToken18.balanceOf(user), userWantBalanceBefore + netNormalized18);
            assertEq(wantToken18.balanceOf(wantAssetSource), wantSourceBalanceBefore - netNormalized18);

            // Order should no longer be pending.
            assertEq(station.pendingOrderCount(), 0);
            assertEq(station.getPendingOrders().length, 0);
        }

        function testFullSameChainOrder_18DecimalsTo6Decimals() external {
            // Fund the user and approve the station for the full 18-decimal offer amount.
            deal(address(offerToken18), user, OFFER_AMOUNT_18 * 10);
            vm.prank(user);
            offerToken18.approve(address(station), OFFER_AMOUNT_18);

            // Build a quote with a 0.5% protocol fee and a 1% integrator fee.
            uint256 protocolFeeNormalized18 = (OFFER_AMOUNT_NORMALIZED * 50) / 10_000;
            uint256 integratorFeeNormalized18 = (OFFER_AMOUNT_NORMALIZED * 100) / 10_000;
            uint256 netOfferTokenUnits = OFFER_AMOUNT_18 - protocolFeeNormalized18 - integratorFeeNormalized18;
            uint256 netWantTokenUnits = netOfferTokenUnits / 10 ** (18 - 6);

            TransitStation.Quote memory quote = _defaultQuote();
            quote.route.offerAsset = address(offerToken18);
            quote.offerAmount = OFFER_AMOUNT_18;
            quote.protocolFee = protocolFeeNormalized18;
            quote.integratorFee = integratorFeeNormalized18;
            quote.integratorFeeReceiver = integratorFeeRecipient;

            bytes memory signature = _signQuote(quote);

            uint256 offererBalanceBefore = offerToken18.balanceOf(user);
            uint256 offerReceiverBalanceBefore = offerToken18.balanceOf(offerReceiver);

            vm.prank(user);
            bytes32 uuid = station.submitOrder{ value: 0 }(quote, signature);

            bytes32 expectedUuid = keccak256(abi.encodePacked(hex"1901", _domainSeparator(station), station.hashQuote(quote)));
            assertEq(uuid, expectedUuid);

            // Offer tokens should have been partitioned between fees and the offer receiver.
            assertEq(offerToken18.balanceOf(user), offererBalanceBefore - OFFER_AMOUNT_18);
            assertEq(offerToken18.balanceOf(protocolFeeRecipient), protocolFeeNormalized18);
            assertEq(offerToken18.balanceOf(integratorFeeRecipient), integratorFeeNormalized18);
            assertEq(offerToken18.balanceOf(offerReceiver), offerReceiverBalanceBefore + netOfferTokenUnits);

            // Order should be pending locally; amountDue is truncated into 6-decimal want units.
            assertEq(station.pendingOrderCount(), 1);
            TransitStation.Order[] memory orders = station.getPendingOrders();
            assertEq(orders.length, 1);
            assertEq(orders[0].terms.uuid, uuid);
            assertEq(orders[0].terms.wantAsset, address(wantToken));
            assertEq(orders[0].terms.receiver, user);
            assertEq(orders[0].terms.offerAsset, address(offerToken18));
            assertEq(orders[0].terms.offerAmountNormalized18AfterFees, netOfferTokenUnits);
            assertEq(orders[0].amountDue, netWantTokenUnits);

            // Fund the 6-decimal want-asset source and fulfill the order.
            deal(address(wantToken), wantAssetSource, netWantTokenUnits * 10);
            vm.prank(wantAssetSource);
            wantToken.approve(address(station), netWantTokenUnits);

            uint256 userWantBalanceBefore = wantToken.balanceOf(user);
            uint256 wantSourceBalanceBefore = wantToken.balanceOf(wantAssetSource);

            TransitStation.FillBatch[] memory batches = new TransitStation.FillBatch[](1);
            bytes32[] memory uuids = new bytes32[](1);
            uuids[0] = uuid;
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = netWantTokenUnits;
            batches[0] = TransitStation.FillBatch({ wantAsset: address(wantToken), uuids: uuids, amounts: amounts });

            vm.prank(executor);
            station.executePendingOrders(batches);

            // Want tokens should have moved from source to receiver.
            assertEq(wantToken.balanceOf(user), userWantBalanceBefore + netWantTokenUnits);
            assertEq(wantToken.balanceOf(wantAssetSource), wantSourceBalanceBefore - netWantTokenUnits);

            // Order should no longer be pending.
            assertEq(station.pendingOrderCount(), 0);
            assertEq(station.getPendingOrders().length, 0);
        }

        function testFullCrossChainOrder_6DecimalsTo6Decimals() external {
            deal(address(offerToken), user, OFFER_AMOUNT * 10);
            vm.deal(user, 1 ether);
            vm.prank(user);
            offerToken.approve(address(station), OFFER_AMOUNT);

            uint256 protocolFeeNormalized18 = (OFFER_AMOUNT_NORMALIZED * 50) / 10_000;
            uint256 integratorFeeNormalized18 = (OFFER_AMOUNT_NORMALIZED * 100) / 10_000;
            uint256 protocolFeeTokenUnits = protocolFeeNormalized18 / 10 ** (18 - 6);
            uint256 integratorFeeTokenUnits = integratorFeeNormalized18 / 10 ** (18 - 6);
            uint256 netTokenUnits = OFFER_AMOUNT - protocolFeeTokenUnits - integratorFeeTokenUnits;
            uint256 netNormalized18 = OFFER_AMOUNT_NORMALIZED - protocolFeeNormalized18 - integratorFeeNormalized18;

            TransitStation.Quote memory quote = _defaultQuote();
            quote.route.destEID = DST_EID;
            quote.protocolFee = protocolFeeTokenUnits;
            quote.integratorFee = integratorFeeTokenUnits;
            quote.integratorFeeReceiver = integratorFeeRecipient;

            vm.prank(user);
            (bytes32 uuid, TransitStation.OrderTerms memory terms) = _submitCrossChainAndGetTerms(quote);

            assertEq(uuid, keccak256(abi.encodePacked(hex"1901", _domainSeparator(station), station.hashQuote(quote))));
            assertEq(offerToken.balanceOf(user), OFFER_AMOUNT * 9);
            assertEq(offerToken.balanceOf(protocolFeeRecipient), protocolFeeTokenUnits);
            assertEq(offerToken.balanceOf(integratorFeeRecipient), integratorFeeTokenUnits);
            assertEq(offerToken.balanceOf(offerReceiver), netTokenUnits);
            assertEq(station.pendingOrderCount(), 0);
            assertEq(terms.offerAmountNormalized18AfterFees, netNormalized18);

            _simulateLzReceive(terms);

            assertEq(dstStation.pendingOrderCount(), 1);
            assertEq(dstStation.getPendingOrders()[0].terms.uuid, uuid);
            assertEq(dstStation.getPendingOrders()[0].terms.wantAsset, address(wantToken));
            assertEq(dstStation.getPendingOrders()[0].terms.receiver, user);
            assertEq(dstStation.getPendingOrders()[0].terms.offerAsset, address(offerToken));
            assertEq(dstStation.getPendingOrders()[0].terms.offerAmountNormalized18AfterFees, netNormalized18);
            assertEq(dstStation.getPendingOrders()[0].amountDue, netTokenUnits);

            deal(address(wantToken), wantAssetSource, netTokenUnits * 10);
            vm.prank(wantAssetSource);
            wantToken.approve(address(dstStation), netTokenUnits);

            TransitStation.FillBatch[] memory batches = new TransitStation.FillBatch[](1);
            bytes32[] memory uuids = new bytes32[](1);
            uuids[0] = uuid;
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = netTokenUnits;
            batches[0] = TransitStation.FillBatch({ wantAsset: address(wantToken), uuids: uuids, amounts: amounts });

            vm.prank(executor);
            dstStation.executePendingOrders(batches);

            assertEq(wantToken.balanceOf(user), netTokenUnits);
            assertEq(wantToken.balanceOf(wantAssetSource), netTokenUnits * 9);
            assertEq(dstStation.pendingOrderCount(), 0);
            assertEq(dstStation.getPendingOrders().length, 0);
        }

        function testFullCrossChainOrder_6DecimalsTo18Decimals() external {
            deal(address(offerToken), user, OFFER_AMOUNT * 10);
            vm.deal(user, 1 ether);
            vm.prank(user);
            offerToken.approve(address(station), OFFER_AMOUNT);

            uint256 protocolFeeNormalized18 = (OFFER_AMOUNT_NORMALIZED * 50) / 10_000;
            uint256 integratorFeeNormalized18 = (OFFER_AMOUNT_NORMALIZED * 100) / 10_000;
            uint256 protocolFeeTokenUnits = protocolFeeNormalized18 / 10 ** (18 - 6);
            uint256 integratorFeeTokenUnits = integratorFeeNormalized18 / 10 ** (18 - 6);
            uint256 netOfferTokenUnits = OFFER_AMOUNT - protocolFeeTokenUnits - integratorFeeTokenUnits;
            uint256 netNormalized18 = OFFER_AMOUNT_NORMALIZED - protocolFeeNormalized18 - integratorFeeNormalized18;

            TransitStation.Quote memory quote = _defaultQuote();
            quote.route.destEID = DST_EID;
            quote.route.wantAsset = address(wantToken18);
            quote.protocolFee = protocolFeeTokenUnits;
            quote.integratorFee = integratorFeeTokenUnits;
            quote.integratorFeeReceiver = integratorFeeRecipient;

            vm.prank(user);
            (bytes32 uuid, TransitStation.OrderTerms memory terms) = _submitCrossChainAndGetTerms(quote);

            assertEq(uuid, keccak256(abi.encodePacked(hex"1901", _domainSeparator(station), station.hashQuote(quote))));
            assertEq(offerToken.balanceOf(user), OFFER_AMOUNT * 9);
            assertEq(offerToken.balanceOf(protocolFeeRecipient), protocolFeeTokenUnits);
            assertEq(offerToken.balanceOf(integratorFeeRecipient), integratorFeeTokenUnits);
            assertEq(offerToken.balanceOf(offerReceiver), netOfferTokenUnits);
            assertEq(station.pendingOrderCount(), 0);
            assertEq(terms.offerAmountNormalized18AfterFees, netNormalized18);

            _simulateLzReceive(terms);

            assertEq(dstStation.pendingOrderCount(), 1);
            assertEq(dstStation.getPendingOrders()[0].terms.uuid, uuid);
            assertEq(dstStation.getPendingOrders()[0].terms.wantAsset, address(wantToken18));
            assertEq(dstStation.getPendingOrders()[0].terms.receiver, user);
            assertEq(dstStation.getPendingOrders()[0].terms.offerAsset, address(offerToken));
            assertEq(dstStation.getPendingOrders()[0].terms.offerAmountNormalized18AfterFees, netNormalized18);
            assertEq(dstStation.getPendingOrders()[0].amountDue, netNormalized18);

            deal(address(wantToken18), wantAssetSource, netNormalized18 * 10);
            vm.prank(wantAssetSource);
            wantToken18.approve(address(dstStation), netNormalized18);

            TransitStation.FillBatch[] memory batches = new TransitStation.FillBatch[](1);
            bytes32[] memory uuids = new bytes32[](1);
            uuids[0] = uuid;
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = netNormalized18;
            batches[0] = TransitStation.FillBatch({ wantAsset: address(wantToken18), uuids: uuids, amounts: amounts });

            vm.prank(executor);
            dstStation.executePendingOrders(batches);

            assertEq(wantToken18.balanceOf(user), netNormalized18);
            assertEq(wantToken18.balanceOf(wantAssetSource), netNormalized18 * 9);
            assertEq(dstStation.pendingOrderCount(), 0);
            assertEq(dstStation.getPendingOrders().length, 0);
        }

        function testFullCrossChainOrder_18DecimalsTo6Decimals() external {
            deal(address(offerToken18), user, OFFER_AMOUNT_18 * 10);
            vm.deal(user, 1 ether);
            vm.prank(user);
            offerToken18.approve(address(station), OFFER_AMOUNT_18);

            uint256 protocolFeeNormalized18 = (OFFER_AMOUNT_NORMALIZED * 50) / 10_000;
            uint256 integratorFeeNormalized18 = (OFFER_AMOUNT_NORMALIZED * 100) / 10_000;
            uint256 netOfferTokenUnits = OFFER_AMOUNT_18 - protocolFeeNormalized18 - integratorFeeNormalized18;
            uint256 netWantTokenUnits = netOfferTokenUnits / 10 ** (18 - 6);

            TransitStation.Quote memory quote = _defaultQuote();
            quote.route.destEID = DST_EID;
            quote.route.offerAsset = address(offerToken18);
            quote.offerAmount = OFFER_AMOUNT_18;
            quote.protocolFee = protocolFeeNormalized18;
            quote.integratorFee = integratorFeeNormalized18;
            quote.integratorFeeReceiver = integratorFeeRecipient;

            vm.prank(user);
            (bytes32 uuid, TransitStation.OrderTerms memory terms) = _submitCrossChainAndGetTerms(quote);

            assertEq(uuid, keccak256(abi.encodePacked(hex"1901", _domainSeparator(station), station.hashQuote(quote))));
            assertEq(offerToken18.balanceOf(user), OFFER_AMOUNT_18 * 9);
            assertEq(offerToken18.balanceOf(protocolFeeRecipient), protocolFeeNormalized18);
            assertEq(offerToken18.balanceOf(integratorFeeRecipient), integratorFeeNormalized18);
            assertEq(offerToken18.balanceOf(offerReceiver), netOfferTokenUnits);
            assertEq(station.pendingOrderCount(), 0);
            assertEq(terms.offerAmountNormalized18AfterFees, netOfferTokenUnits);

            _simulateLzReceive(terms);

            assertEq(dstStation.pendingOrderCount(), 1);
            assertEq(dstStation.getPendingOrders()[0].terms.uuid, uuid);
            assertEq(dstStation.getPendingOrders()[0].terms.wantAsset, address(wantToken));
            assertEq(dstStation.getPendingOrders()[0].terms.receiver, user);
            assertEq(dstStation.getPendingOrders()[0].terms.offerAsset, address(offerToken18));
            assertEq(dstStation.getPendingOrders()[0].terms.offerAmountNormalized18AfterFees, netOfferTokenUnits);
            assertEq(dstStation.getPendingOrders()[0].amountDue, netWantTokenUnits);

            deal(address(wantToken), wantAssetSource, netWantTokenUnits * 10);
            vm.prank(wantAssetSource);
            wantToken.approve(address(dstStation), netWantTokenUnits);

            TransitStation.FillBatch[] memory batches = new TransitStation.FillBatch[](1);
            bytes32[] memory uuids = new bytes32[](1);
            uuids[0] = uuid;
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = netWantTokenUnits;
            batches[0] = TransitStation.FillBatch({ wantAsset: address(wantToken), uuids: uuids, amounts: amounts });

            vm.prank(executor);
            dstStation.executePendingOrders(batches);

            assertEq(wantToken.balanceOf(user), netWantTokenUnits);
            assertEq(wantToken.balanceOf(wantAssetSource), netWantTokenUnits * 9);
            assertEq(dstStation.pendingOrderCount(), 0);
            assertEq(dstStation.getPendingOrders().length, 0);
        }

    }
