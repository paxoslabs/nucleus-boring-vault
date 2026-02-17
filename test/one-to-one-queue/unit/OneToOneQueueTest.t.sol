// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { OneToOneQueue } from "src/helper/one-to-one-queue/OneToOneQueue.sol";
import { SimpleFeeModule } from "src/helper/SimpleFeeModule.sol";
import { Test, stdStorage, StdStorage, stdError, console } from "@forge-std/Test.sol";
import { OneToOneQueueTestBase, tERC20, IERC20 } from "../OneToOneQueueTestBase.t.sol";
import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { VerboseAuth } from "src/helper/one-to-one-queue/access/VerboseAuth.sol";

contract OneToOneQueueTest is OneToOneQueueTestBase {

    function test_SetFeeModule() external {
        address oldFeeModule = address(queue.feeModule());
        assertEq(oldFeeModule, address(feeModule));

        SimpleFeeModule newFeeModule = new SimpleFeeModule(TEST_OFFER_FEE_PERCENTAGE);
        vm.expectPartialRevert(VerboseAuth.Unauthorized.selector);
        queue.setFeeModule(newFeeModule);

        vm.startPrank(owner);
        vm.expectRevert(OneToOneQueue.ZeroAddress.selector);
        queue.setFeeModule(SimpleFeeModule(address(0)));

        vm.expectEmit();
        emit OneToOneQueue.FeeModuleUpdated(SimpleFeeModule(oldFeeModule), newFeeModule);
        queue.setFeeModule(newFeeModule);
        assertEq(address(queue.feeModule()), address(newFeeModule));
        vm.stopPrank();
    }

    function test_SetFeeRecipient() external {
        address oldFeeRecipient = queue.feeRecipient();
        address newFeeRecipient = makeAddr("new fee recipient");
        assertEq(oldFeeRecipient, feeRecipient);

        vm.expectPartialRevert(VerboseAuth.Unauthorized.selector);
        queue.setFeeRecipient(address(newFeeRecipient));

        vm.startPrank(owner);
        vm.expectRevert(OneToOneQueue.ZeroAddress.selector);
        queue.setFeeRecipient(address(0));

        vm.expectEmit(true, true, true, true);
        emit OneToOneQueue.FeeRecipientUpdated(oldFeeRecipient, address(newFeeRecipient));
        queue.setFeeRecipient(address(newFeeRecipient));
        assertEq(queue.feeRecipient(), address(newFeeRecipient));
        vm.stopPrank();
    }

    function test_SetRecoveryAddress() external {
        address oldRecoveryAddress = queue.recoveryAddress();
        address newRecoveryAddress = makeAddr("new recovery address");
        assertEq(oldRecoveryAddress, recoveryAddress);

        vm.expectPartialRevert(VerboseAuth.Unauthorized.selector);
        queue.setRecoveryAddress(address(newRecoveryAddress));

        vm.startPrank(owner);
        vm.expectRevert(OneToOneQueue.ZeroAddress.selector);
        queue.setRecoveryAddress(address(0));

        vm.expectEmit(true, true, true, true);
        emit OneToOneQueue.RecoveryAddressUpdated(oldRecoveryAddress, address(newRecoveryAddress));
        queue.setRecoveryAddress(address(newRecoveryAddress));
        assertEq(queue.recoveryAddress(), address(newRecoveryAddress));
        vm.stopPrank();

        assertEq(queue.recoveryAddress(), address(newRecoveryAddress), "recovery address should be set");
    }

    function test_AddOfferAsset() external {
        address oldOfferAsset = address(USDC);
        address newOfferAsset = address(new tERC20(6));
        assertEq(queue.supportedOfferAssets(address(USDC)), true);

        vm.expectPartialRevert(VerboseAuth.Unauthorized.selector);
        queue.addOfferAsset(newOfferAsset, 12);

        vm.startPrank(owner);
        vm.expectRevert(OneToOneQueue.ZeroAddress.selector);
        queue.addOfferAsset(address(0), 0);

        vm.expectEmit(true, true, true, true);
        emit OneToOneQueue.OfferAssetAdded(newOfferAsset, 12);
        queue.addOfferAsset(newOfferAsset, 12);
        assertEq(queue.supportedOfferAssets(newOfferAsset), true);
        assertEq(queue.minimumOrderSizePerAsset(newOfferAsset), 12);

        vm.expectRevert(abi.encodeWithSelector(OneToOneQueue.AssetAlreadySupported.selector, newOfferAsset));
        queue.addOfferAsset(newOfferAsset, 12);
        vm.stopPrank();
    }

    function test_UpdateAssetMinimumOrderSize() external {
        uint256 oldMinimum = queue.minimumOrderSizePerAsset(address(USDC));
        uint256 newMinimum = 12;

        vm.expectPartialRevert(VerboseAuth.Unauthorized.selector);
        queue.updateAssetMinimumOrderSize(address(USDC), newMinimum);

        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(OneToOneQueue.AssetNotSupported.selector, address(0)));
        queue.updateAssetMinimumOrderSize(address(0), 12);

        vm.expectEmit(true, true, true, true);
        emit OneToOneQueue.MinimumOrderSizeUpdated(address(USDC), 0, 12);
        queue.updateAssetMinimumOrderSize(address(USDC), newMinimum);
        assertEq(queue.minimumOrderSizePerAsset(address(USDC)), newMinimum);
        vm.stopPrank();
    }

    function test_RemoveOfferAsset() external {
        address oldOfferAsset = address(USDC);
        assertEq(queue.supportedOfferAssets(address(USDC)), true);

        vm.expectPartialRevert(VerboseAuth.Unauthorized.selector);
        queue.removeOfferAsset(address(USDC));

        vm.startPrank(owner);
        vm.expectEmit(true, true, true, true);
        emit OneToOneQueue.OfferAssetRemoved(address(USDC));
        queue.removeOfferAsset(address(USDC));
        assertFalse(queue.supportedOfferAssets(address(USDC)));
        vm.stopPrank();
    }

    function test_AddWantAsset() external {
        address oldWantAsset = address(USDG0);
        address newWantAsset = address(new tERC20(6));
        assertEq(queue.supportedWantAssets(address(USDG0)), true);

        vm.expectPartialRevert(VerboseAuth.Unauthorized.selector);
        queue.addWantAsset(newWantAsset);

        vm.startPrank(owner);
        vm.expectRevert(OneToOneQueue.ZeroAddress.selector);
        queue.addWantAsset(address(0));

        vm.expectEmit(true, true, true, true);
        emit OneToOneQueue.WantAssetAdded(newWantAsset);
        queue.addWantAsset(newWantAsset);
        assertEq(queue.supportedWantAssets(newWantAsset), true);

        vm.expectRevert(abi.encodeWithSelector(OneToOneQueue.AssetAlreadySupported.selector, newWantAsset));
        queue.addWantAsset(newWantAsset);
        vm.stopPrank();
    }

    function test_RemoveWantAsset() external {
        address oldWantAsset = address(USDG0);
        assertEq(queue.supportedWantAssets(address(USDG0)), true);

        vm.expectPartialRevert(VerboseAuth.Unauthorized.selector);
        queue.removeWantAsset(address(USDG0));

        vm.startPrank(owner);
        vm.expectEmit(true, true, true, true);
        emit OneToOneQueue.WantAssetRemoved(address(USDG0));
        queue.removeWantAsset(address(USDG0));
        assertFalse(queue.supportedWantAssets(address(USDG0)));
        vm.stopPrank();
    }

    function test_UpdateOfferAssetRecipient() external {
        address oldOfferAssetRecipient = queue.offerAssetRecipient();
        address newOfferAssetRecipient = makeAddr("new offer asset recipient");
        assertEq(oldOfferAssetRecipient, mockBoringVaultAddress);

        vm.expectPartialRevert(VerboseAuth.Unauthorized.selector);
        queue.updateOfferAssetRecipient(address(newOfferAssetRecipient));

        vm.startPrank(owner);
        vm.expectRevert(OneToOneQueue.ZeroAddress.selector);
        queue.updateOfferAssetRecipient(address(0));

        vm.expectEmit(true, true, true, true);
        emit OneToOneQueue.OfferAssetRecipientUpdated(oldOfferAssetRecipient, address(newOfferAssetRecipient));
        queue.updateOfferAssetRecipient(address(newOfferAssetRecipient));
        assertEq(queue.offerAssetRecipient(), address(newOfferAssetRecipient));
        vm.stopPrank();
    }

    function test_ForceRefundOrders() external {
        vm.expectPartialRevert(VerboseAuth.Unauthorized.selector);
        queue.forceRefundOrders(new uint256[](0));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OneToOneQueue.InvalidOrderIndex.selector, 0));
        queue.forceRefundOrders(new uint256[](1));

        _submitAnOrder();
        _submitAnOrder();
        vm.startPrank(owner);

        uint256[] memory orderIndices = new uint256[](2);
        orderIndices[0] = 1;
        orderIndices[1] = 2;

        (
            uint128 amountOffer,
            uint128 amountWant,
            IERC20 offerAsset,
            IERC20 wantAsset,
            address refundReceiver,
            OneToOneQueue.OrderType orderType,
            // did order fail transfer
        ) = queue.queue(1);

        OneToOneQueue.Order memory order = OneToOneQueue.Order({
            offerAsset: offerAsset,
            wantAsset: wantAsset,
            amountOffer: amountOffer,
            amountWant: amountWant,
            refundReceiver: refundReceiver,
            orderType: OneToOneQueue.OrderType.REFUND, // order event should emit with refund not with old status
            didOrderFailTransfer: false
        });

        vm.expectEmit(true, true, true, true);
        emit OneToOneQueue.OrderRefunded(1, order);
        emit OneToOneQueue.OrderRefunded(2, order);
        deal(address(USDC), address(queue), 2e6);
        queue.forceRefundOrders(orderIndices);
        assertEq(uint8(queue.getOrderStatus(1)), uint8(OneToOneQueue.OrderStatus.COMPLETE_REFUNDED));
        assertEq(uint8(queue.getOrderStatus(2)), uint8(OneToOneQueue.OrderStatus.COMPLETE_REFUNDED));
        vm.stopPrank();
    }

    function test_ForceProcessOrders() external {
        vm.expectPartialRevert(VerboseAuth.Unauthorized.selector);
        queue.forceProcessOrders(new uint256[](0));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OneToOneQueue.InvalidOrderIndex.selector, 0));
        queue.forceProcessOrders(new uint256[](1));

        _submitAnOrder();
        _submitAnOrder();
        vm.startPrank(owner);

        uint256[] memory orderIndices = new uint256[](2);
        orderIndices[0] = 1;
        orderIndices[1] = 2;

        deal(address(USDG0), address(queue), 2e6);

        _expectOrderProcessedEvent(1, OneToOneQueue.OrderType.PRE_FILLED, true, false);
        _expectOrderProcessedEvent(2, OneToOneQueue.OrderType.PRE_FILLED, true, false);
        queue.forceProcessOrders(orderIndices);

        assertEq(uint8(queue.getOrderStatus(1)), uint8(OneToOneQueue.OrderStatus.COMPLETE_PRE_FILLED));
        assertEq(uint8(queue.getOrderStatus(2)), uint8(OneToOneQueue.OrderStatus.COMPLETE_PRE_FILLED));
        vm.stopPrank();
    }

    function test_ForceRefund() external {
        vm.expectPartialRevert(VerboseAuth.Unauthorized.selector);
        queue.forceRefund(0);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OneToOneQueue.InvalidOrderIndex.selector, 0));
        queue.forceRefund(0);

        _submitAnOrder();
        assertEq(uint8(queue.getOrderStatus(queue.latestOrder())), uint8(OneToOneQueue.OrderStatus.PENDING));

        vm.startPrank(owner);

        vm.expectRevert(abi.encodeWithSelector(OneToOneQueue.InvalidOrderIndex.selector, 2));
        queue.forceProcess(2);

        (
            uint128 amountOffer,
            uint128 amountWant,
            IERC20 offerAsset,
            IERC20 wantAsset,
            address refundReceiver,
            OneToOneQueue.OrderType orderType,
            // did order fail transfer
        ) = queue.queue(1);
        OneToOneQueue.Order memory order = OneToOneQueue.Order({
            offerAsset: offerAsset,
            wantAsset: wantAsset,
            amountOffer: amountOffer,
            amountWant: amountWant,
            refundReceiver: refundReceiver,
            orderType: OneToOneQueue.OrderType.REFUND, // order event should emit with refund not with old status
            didOrderFailTransfer: false
        });

        vm.expectRevert(
            abi.encodeWithSelector(OneToOneQueue.InsufficientBalanceInQueue.selector, 1, address(USDC), 1e6, 0)
        );
        queue.forceRefund(1);

        deal(address(USDC), address(queue), 1e6); // give the queue extra USDC to make up fees

        vm.expectEmit(true, true, true, true);
        emit OneToOneQueue.OrderRefunded(1, order);
        queue.forceRefund(1);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        queue.ownerOf(1);

        (,,,,, orderType,) = queue.queue(1);
        assertEq(uint8(orderType), uint8(OneToOneQueue.OrderType.REFUND), "order should be marked for refund");
        assertEq(uint8(queue.getOrderStatus(1)), uint8(OneToOneQueue.OrderStatus.COMPLETE_REFUNDED));
        assertEq(USDC.balanceOf(user1), 1e6, "user1 should have their USDC balance back");
        vm.stopPrank();
    }

    function test_ForceProcess() external {
        vm.expectPartialRevert(VerboseAuth.Unauthorized.selector);
        queue.forceProcess(0);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OneToOneQueue.InvalidOrderIndex.selector, 0));
        queue.forceProcess(0);

        _submitAnOrder();

        assertEq(uint8(queue.getOrderStatus(queue.latestOrder())), uint8(OneToOneQueue.OrderStatus.PENDING));

        vm.startPrank(owner);

        vm.expectRevert(
            abi.encodeWithSelector(
                OneToOneQueue.InsufficientBalanceInQueue.selector,
                1,
                address(USDG0),
                1e6 - (1e6 * TEST_OFFER_FEE_PERCENTAGE / 10_000),
                0
            )
        );
        queue.forceProcess(1);

        deal(address(USDG0), address(queue), 1e6);

        vm.expectRevert(abi.encodeWithSelector(OneToOneQueue.InvalidOrderIndex.selector, 2));
        queue.forceProcess(2);

        queue.forceProcess(1);
        assertEq(uint8(queue.getOrderStatus(1)), uint8(OneToOneQueue.OrderStatus.COMPLETE_PRE_FILLED));
        assertEq(
            USDG0.balanceOf(user1),
            1e6 - (1e6 * TEST_OFFER_FEE_PERCENTAGE / 10_000),
            "user1 should have their USDG0 balance - fees"
        );

        vm.stopPrank();
    }

    function test_SubmitOrderBasicErrors() external {
        vm.prank(owner);
        queue.updateAssetMinimumOrderSize(address(USDC), 1e6);

        deal(address(USDC), alice, 1e6);
        vm.startPrank(alice);

        vm.expectRevert(abi.encodeWithSelector(OneToOneQueue.ZeroAddress.selector));
        queue.submitOrder(_createSubmitOrderParams(1e6, USDC, USDG0, address(0), address(0), address(0), defaultParams));

        vm.expectRevert(abi.encodeWithSelector(OneToOneQueue.ZeroAddress.selector));
        queue.submitOrder(_createSubmitOrderParams(1e6, USDC, USDG0, user1, address(0), address(0), defaultParams));

        vm.expectRevert(abi.encodeWithSelector(OneToOneQueue.ZeroAddress.selector));
        queue.submitOrder(_createSubmitOrderParams(1e6, USDC, USDG0, address(0), alice, address(0), defaultParams));

        vm.expectRevert(abi.encodeWithSelector(OneToOneQueue.AssetNotSupported.selector, address(DAI)));
        queue.submitOrder(_createSubmitOrderParams(1e6, DAI, USDG0, alice, alice, alice, defaultParams));

        vm.expectRevert(abi.encodeWithSelector(OneToOneQueue.AssetNotSupported.selector, address(DAI)));
        queue.submitOrder(_createSubmitOrderParams(1e6, USDC, DAI, alice, alice, alice, defaultParams));

        vm.expectRevert(abi.encodeWithSelector(OneToOneQueue.AssetNotSupported.selector, address(DAI)));
        queue.submitOrder(_createSubmitOrderParams(1e6, DAI, DAI, alice, alice, alice, defaultParams));

        vm.expectRevert(abi.encodeWithSelector(OneToOneQueue.AmountBelowMinimum.selector, 1e6 - 1, 1e6));
        queue.submitOrder(_createSubmitOrderParams(1e6 - 1, USDC, USDG0, alice, alice, alice, defaultParams));

        vm.stopPrank();
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(OneToOneQueue.InvalidDepositor.selector, alice, user1));
        queue.submitOrder(_createSubmitOrderParams(1e6, USDC, USDG0, alice, alice, alice, defaultParams));

        vm.stopPrank();
    }

    function test_submitOrderERC20PermitNoSignature() external {
        (address alice, uint256 alicePk) = makeAddrAndKey("alice");
        deal(address(USDC), alice, 1e6);
        vm.startPrank(alice);

        (uint8 approvalV, bytes32 approvalR, bytes32 approvalS) =
            _getPermitSignature(USDC, alice, alicePk, address(queue), 1e6, block.timestamp + 1000);

        OneToOneQueue.SignatureParams memory params = OneToOneQueue.SignatureParams({
            approvalMethod: OneToOneQueue.ApprovalMethod.EIP2612_PERMIT,
            approvalV: approvalV,
            approvalR: approvalR,
            approvalS: approvalS,
            submitWithSignature: false,
            deadline: block.timestamp + 1000,
            eip2612Signature: "",
            nonce: 0
        });

        _expectOrderSubmittedEvent(1e6, USDC, USDG0, alice, alice, alice, params, alice, false);
        queue.submitOrder(_createSubmitOrderParams(1e6, USDC, USDG0, alice, alice, alice, params));
        assertTrue(queue.ownerOf(queue.latestOrder()) == alice, "alice should be the owner of the order");
    }

    function test_submitOrderERC20ApproveEIP2612Signature() external {
        deal(address(USDC), alice, 2e6);
        vm.startPrank(alice);

        // Create the base submit order params that will be used throughout the test
        OneToOneQueue.SubmitOrderParams memory submitParams = _createSubmitOrderParams(
            1e6,
            USDC,
            USDG0,
            alice,
            alice,
            alice,
            OneToOneQueue.SignatureParams({
                approvalMethod: OneToOneQueue.ApprovalMethod.EIP20_APROVE,
                approvalV: 0,
                approvalR: bytes32(0),
                approvalS: bytes32(0),
                submitWithSignature: true,
                deadline: block.timestamp + 1000,
                eip2612Signature: "",
                nonce: 0
            })
        );

        bytes32 hash = keccak256(
            abi.encode(
                submitParams.amountOffer,
                submitParams.offerAsset,
                submitParams.wantAsset,
                submitParams.receiver,
                submitParams.refundReceiver,
                submitParams.signatureParams.deadline,
                OneToOneQueue.ApprovalMethod.EIP20_APROVE,
                submitParams.signatureParams.nonce,
                queue.feeModule(),
                block.chainid,
                address(queue)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, hash);
        submitParams.signatureParams.eip2612Signature = abi.encodePacked(r, s, v);

        {
            submitParams.offerAsset.approve(address(queue), submitParams.amountOffer * 2);
            _expectOrderSubmittedEvent(1e6, USDC, USDG0, alice, alice, alice, submitParams.signatureParams, alice, true);
            queue.submitOrder(submitParams);
            assertTrue(queue.ownerOf(queue.latestOrder()) == alice, "alice should be the owner of the order");

            vm.expectRevert(abi.encodeWithSelector(OneToOneQueue.SignatureHashAlreadyUsed.selector, hash));
            queue.submitOrder(submitParams);

            vm.stopPrank();
            vm.startPrank(user1);

            vm.expectRevert(abi.encodeWithSelector(OneToOneQueue.SignatureHashAlreadyUsed.selector, hash));
            queue.submitOrder(submitParams);
        }
        {
            // Update for second test with different nonce
            // Calculate hash with new nonce
            hash = keccak256(
                abi.encode(
                    submitParams.amountOffer,
                    submitParams.offerAsset,
                    submitParams.wantAsset,
                    alice,
                    submitParams.refundReceiver,
                    submitParams.signatureParams.deadline,
                    OneToOneQueue.ApprovalMethod.EIP20_APROVE,
                    1,
                    queue.feeModule(),
                    block.chainid,
                    address(queue)
                )
            );
            (v, r, s) = vm.sign(alicePk, hash);
            bytes memory newSig = abi.encodePacked(r, s, v);

            // Update nonce but keep old signature - should fail
            submitParams.signatureParams.nonce = 1;
            vm.expectPartialRevert(OneToOneQueue.InvalidEip2612Signature.selector);
            queue.submitOrder(submitParams);

            // Now update signature and it should succeed
            submitParams.signatureParams.eip2612Signature = newSig;
            _expectOrderSubmittedEvent(
                1e6, USDC, USDG0, alice, alice, submitParams.refundReceiver, submitParams.signatureParams, alice, true
            );
            queue.submitOrder(submitParams);
            assertTrue(queue.ownerOf(queue.latestOrder()) == alice, "alice should be the owner of the new order");
        }
    }

    function test_submitOrderERC20PermitWithEIP2612Signature() external {
        {
            deal(address(USDC), alice, 2e6);
            vm.startPrank(alice);
        }

        IERC20 offerAsset = USDC;
        IERC20 wantAsset = USDG0;
        uint256 deadline = block.timestamp + 1000;

        (uint8 approvalV, bytes32 approvalR, bytes32 approvalS) =
            _getPermitSignature(USDC, alice, alicePk, address(queue), 1e6, deadline);

        bytes32 sigHash;
        OneToOneQueue.SignatureParams memory params;
        {
            sigHash = keccak256(
                abi.encode(
                    1e6,
                    offerAsset,
                    wantAsset,
                    alice,
                    alice,
                    deadline,
                    OneToOneQueue.ApprovalMethod.EIP2612_PERMIT,
                    0,
                    queue.feeModule(),
                    block.chainid,
                    address(queue)
                )
            );
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, sigHash);

            bytes memory sig = abi.encodePacked(r, s, v);

            params = OneToOneQueue.SignatureParams({
                approvalMethod: OneToOneQueue.ApprovalMethod.EIP2612_PERMIT,
                approvalV: approvalV,
                approvalR: approvalR,
                approvalS: approvalS,
                submitWithSignature: true,
                deadline: deadline,
                eip2612Signature: sig,
                nonce: 0
            });
        }

        _expectOrderSubmittedEvent(1e6, USDC, USDG0, alice, alice, alice, params, alice, true);
        queue.submitOrder(_createSubmitOrderParams(1e6, offerAsset, wantAsset, alice, alice, alice, params));
        assertTrue(queue.ownerOf(queue.latestOrder()) == alice, "alice should be the owner of the order");

        vm.expectRevert(abi.encodeWithSelector(OneToOneQueue.SignatureHashAlreadyUsed.selector, sigHash));
        queue.submitOrder(_createSubmitOrderParams(1e6, offerAsset, wantAsset, alice, alice, alice, params));

        vm.stopPrank();
        vm.startPrank(user1);

        vm.expectRevert(abi.encodeWithSelector(OneToOneQueue.SignatureHashAlreadyUsed.selector, sigHash));
        queue.submitOrder(_createSubmitOrderParams(1e6, offerAsset, wantAsset, alice, alice, alice, params));

        {

            sigHash = keccak256(
                abi.encode(
                    1e6,
                    offerAsset,
                    wantAsset,
                    alice,
                    alice,
                    deadline,
                    OneToOneQueue.ApprovalMethod.EIP2612_PERMIT,
                    1,
                    queue.feeModule(),
                    block.chainid,
                    address(queue)
                )
            );
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, sigHash);

            bytes memory sig = abi.encodePacked(r, s, v);

            // need to re-sign the permit
            (approvalV, approvalR, approvalS) = _getPermitSignature(USDC, alice, alicePk, address(queue), 1e6, deadline);
            params.approvalV = approvalV;
            params.approvalR = approvalR;
            params.approvalS = approvalS;
            params.nonce = 1;

            vm.expectPartialRevert(OneToOneQueue.InvalidEip2612Signature.selector);
            queue.submitOrder(_createSubmitOrderParams(1e6, offerAsset, wantAsset, alice, alice, alice, params));

            params.eip2612Signature = sig;
            _expectOrderSubmittedEvent(1e6, USDC, USDG0, alice, alice, alice, params, alice, true);
            queue.submitOrder(_createSubmitOrderParams(1e6, offerAsset, wantAsset, alice, alice, alice, params));
            assertTrue(queue.ownerOf(queue.latestOrder()) == alice, "alice should be the owner of the new order");
        }
    }

    function test_submitOrderWithoutApproval() external {
        deal(address(USDC), alice, 2e6);
        vm.startPrank(alice);

        address receiver = user1;
        address refundReceiver = alice;

        OneToOneQueue.SignatureParams memory params = OneToOneQueue.SignatureParams({
            approvalMethod: OneToOneQueue.ApprovalMethod.EIP20_APROVE,
            approvalV: 0,
            approvalR: bytes32(0),
            approvalS: bytes32(0),
            submitWithSignature: false,
            deadline: block.timestamp + 1000,
            eip2612Signature: "",
            nonce: 0
        });

        vm.expectRevert(address(USDC));
        queue.submitOrder(_createSubmitOrderParams(1e6, USDC, USDG0, alice, receiver, refundReceiver, params));
        vm.stopPrank();
    }

    function test_submitOrderDifferentReceiver() external {
        deal(address(USDC), alice, 2e6);
        vm.startPrank(alice);

        address receiver = user1;
        address refundReceiver = alice;

        OneToOneQueue.SignatureParams memory params = OneToOneQueue.SignatureParams({
            approvalMethod: OneToOneQueue.ApprovalMethod.EIP20_APROVE,
            approvalV: 0,
            approvalR: bytes32(0),
            approvalS: bytes32(0),
            submitWithSignature: false,
            deadline: block.timestamp + 1000,
            eip2612Signature: "",
            nonce: 0
        });

        USDC.approve(address(queue), 1e6);
        _expectOrderSubmittedEvent(1e6, USDC, USDG0, alice, receiver, refundReceiver, params, alice, false);
        queue.submitOrder(_createSubmitOrderParams(1e6, USDC, USDG0, alice, receiver, refundReceiver, params));
        assertTrue(queue.ownerOf(queue.latestOrder()) == receiver, "receiver should be the owner of the order");
        vm.stopPrank();
    }

    function test_processOrders() external {
        deal(address(USDG0), address(queue), 1e6);
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(OneToOneQueue.InvalidOrdersCount.selector, 0));
        queue.processOrders(0);

        _submitAnOrder();
        vm.expectRevert(abi.encodeWithSelector(OneToOneQueue.NotEnoughOrdersToProcess.selector, 2, 1));
        queue.processOrders(2);

        vm.expectEmit(true, true, true, true);
        emit OneToOneQueue.OrdersProcessedInRange(1, 1);
        queue.processOrders(1);

        assertEq(uint8(queue.getOrderStatus(1)), uint8(OneToOneQueue.OrderStatus.COMPLETE));
        assertEq(
            USDG0.balanceOf(user1),
            1e6 - (1e6 * TEST_OFFER_FEE_PERCENTAGE / 10_000),
            "user1 should have their USDG0 balance - fees"
        );
        vm.stopPrank();
    }

    function test_submitOrderAndProcess() external {
        deal(address(USDG0), address(queue), 1e6);
        deal(address(USDC), user1, 1e6);
        vm.startPrank(user1);
        USDC.approve(address(queue), 1e6);

        vm.expectEmit(true, true, true, true);
        emit OneToOneQueue.OrdersProcessedInRange(1, 1);
        uint256 numberOfOrders = queue.latestOrder() + 1 - queue.lastProcessedOrder();
        queue.submitOrderAndProcess(
            _createSubmitOrderParams(1e6, USDC, USDG0, user1, user1, user1, defaultParams), numberOfOrders
        );
        assertEq(uint8(queue.getOrderStatus(queue.latestOrder())), uint8(OneToOneQueue.OrderStatus.COMPLETE));
        assertEq(
            USDG0.balanceOf(user1),
            1e6 - (1e6 * TEST_OFFER_FEE_PERCENTAGE / 10_000),
            "user1 should have their USDG0 balance - fees"
        );
        vm.stopPrank();
    }

    function test_submitOrderAndProcessAll() external {
        deal(address(USDG0), address(queue), 1e6);
        deal(address(USDC), user1, 1e6);
        vm.startPrank(user1);
        USDC.approve(address(queue), 1e6);

        vm.expectEmit(true, true, true, true);
        emit OneToOneQueue.OrdersProcessedInRange(1, 1);
        queue.submitOrderAndProcessAll(_createSubmitOrderParams(1e6, USDC, USDG0, user1, user1, user1, defaultParams));
        assertEq(uint8(queue.getOrderStatus(queue.latestOrder())), uint8(OneToOneQueue.OrderStatus.COMPLETE));
        assertEq(
            USDG0.balanceOf(user1),
            1e6 - (1e6 * TEST_OFFER_FEE_PERCENTAGE / 10_000),
            "user1 should have their USDG0 balance - fees"
        );
        vm.stopPrank();
    }

    function test_statusNotFound(uint256 aNumber) external {
        aNumber = bound(aNumber, 1, 1000);
        assertEq(uint8(queue.getOrderStatus(aNumber)), uint8(OneToOneQueue.OrderStatus.NOT_FOUND));
        assertEq(uint8(queue.getOrderStatus(0)), uint8(OneToOneQueue.OrderStatus.NOT_FOUND));
    }

    function test_submitOrderAndProcessLessThanTotal() external {
        deal(address(USDG0), address(queue), 1e6);

        _submitAnOrder();

        deal(address(USDC), user1, 1e6);
        vm.startPrank(user1);
        USDC.approve(address(queue), 1e6);

        vm.expectEmit(true, true, true, true);
        emit OrdersProcessedInRange(1, 1);
        queue.submitOrderAndProcess(_createSubmitOrderParams(1e6, USDC, USDG0, user1, user1, user1, defaultParams), 1);
        assertEq(uint8(queue.getOrderStatus(1)), uint8(OneToOneQueue.OrderStatus.COMPLETE));
        assertEq(
            USDG0.balanceOf(user1),
            1e6 - (1e6 * TEST_OFFER_FEE_PERCENTAGE / 10_000),
            "user1 should have their USDG0 balance - fees"
        );
        assertEq(uint8(queue.getOrderStatus(2)), uint8(OneToOneQueue.OrderStatus.PENDING));
    }

}
