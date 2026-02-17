// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import {
    BaseWithdrawQueueTest,
    SimpleFeeModule,
    WithdrawQueue,
    BoringVault,
    TellerWithMultiAssetSupport,
    IERC20,
    tERC20
} from "../BaseWithdrawQueueTest.t.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";

contract WithdrawQueueUnitTests is BaseWithdrawQueueTest {

    function test_setFeeModule() external {
        // Test only the owner can set the fee module
        // The fee module can not be zero
        // And the correct event is emitted
        // Also test that if an order exists in the queue, the fee module can not be updated until the order is
        // processed NOTE: we don't enforce that a new fee module is != old fee module

        assertEq(address(withdrawQueue.feeModule()), address(feeModule));
        SimpleFeeModule newFeeModule = new SimpleFeeModule(TEST_OFFER_FEE_PERCENTAGE);

        vm.expectRevert("UNAUTHORIZED");
        withdrawQueue.setFeeModule(newFeeModule);

        vm.startPrank(owner);
        vm.expectRevert(WithdrawQueue.ZeroAddress.selector, address(withdrawQueue));
        withdrawQueue.setFeeModule(SimpleFeeModule(address(0)));

        vm.expectEmit(true, true, true, true);
        emit WithdrawQueue.FeeModuleUpdated(feeModule, newFeeModule);
        withdrawQueue.setFeeModule(newFeeModule);
        vm.stopPrank();
        assertEq(address(withdrawQueue.feeModule()), address(newFeeModule));

        _submitAnOrder();

        vm.startPrank(owner);
        vm.expectRevert(WithdrawQueue.QueueMustBeEmpty.selector, address(withdrawQueue));
        withdrawQueue.setFeeModule(feeModule);

        withdrawQueue.processOrders(1);

        withdrawQueue.setFeeModule(feeModule);

        assertEq(address(withdrawQueue.feeModule()), address(feeModule));

        vm.stopPrank();
    }

    function test_setFeeRecipient() external {
        // Test only the owner can set the fee recipient
        // The fee recipient can not be zero address and should not start as the zero address
        // Test the correct event is emitted

        assertNotEq(address(withdrawQueue.feeRecipient()), address(0), "fee recipient should not start as zero address");

        address newFeeRecipient = makeAddr("new fee recipient");

        vm.expectRevert("UNAUTHORIZED");
        withdrawQueue.setFeeRecipient(address(newFeeRecipient));

        vm.startPrank(owner);
        vm.expectRevert(WithdrawQueue.ZeroAddress.selector, address(withdrawQueue));
        withdrawQueue.setFeeRecipient(address(0));

        vm.expectEmit(true, true, true, true);
        emit WithdrawQueue.FeeRecipientUpdated(address(withdrawQueue.feeRecipient()), address(newFeeRecipient));
        withdrawQueue.setFeeRecipient(address(newFeeRecipient));
        assertEq(address(withdrawQueue.feeRecipient()), address(newFeeRecipient));
        vm.stopPrank();
    }

    function test_setTellerWithMultiAssetSupport() external {
        // Test only the owner can set the teller
        // The teller can not be zero address
        // A teller with a different vault can not be set
        // The queue must be empty (no active orders) to be set
        // Test the correct event is emitted

        BoringVault badVault = new BoringVault(owner, "Vault With 18 Decimals", "BADVAULT", 18);
        TellerWithMultiAssetSupport newBadTeller =
            new TellerWithMultiAssetSupport(owner, address(badVault), address(accountant));
        TellerWithMultiAssetSupport newTeller =
            new TellerWithMultiAssetSupport(owner, address(boringVault), address(accountant));

        vm.expectRevert("UNAUTHORIZED");
        withdrawQueue.setTellerWithMultiAssetSupport(newTeller);

        vm.startPrank(owner);
        vm.expectRevert(WithdrawQueue.ZeroAddress.selector, address(withdrawQueue));
        withdrawQueue.setTellerWithMultiAssetSupport(TellerWithMultiAssetSupport(address(0)));
        vm.stopPrank();

        _submitAnOrder();

        vm.startPrank(owner);
        vm.expectRevert(WithdrawQueue.QueueMustBeEmpty.selector, address(withdrawQueue));
        withdrawQueue.setTellerWithMultiAssetSupport(newTeller);

        withdrawQueue.processOrders(1);

        vm.expectEmit(true, true, true, true);
        emit WithdrawQueue.TellerUpdated(teller, newTeller);
        withdrawQueue.setTellerWithMultiAssetSupport(newTeller);
        assertEq(address(withdrawQueue.tellerWithMultiAssetSupport()), address(newTeller), "teller should be set");

        vm.expectRevert(WithdrawQueue.TellerVaultMissmatch.selector, address(withdrawQueue));
        withdrawQueue.setTellerWithMultiAssetSupport(newBadTeller);
        vm.stopPrank();
    }

    function test_updateAssetMinimumOrderSize() external {
        // Test only the owner can update the minimum order size
        // Test the minimum is updated and the event is emitted
        vm.expectRevert("UNAUTHORIZED");
        withdrawQueue.updateAssetMinimumOrderSize(111);

        vm.startPrank(owner);
        vm.expectEmit(true, true, true, true);
        emit WithdrawQueue.MinimumOrderSizeUpdated(withdrawQueue.minimumOrderSize(), 111);
        withdrawQueue.updateAssetMinimumOrderSize(111);
        vm.stopPrank();
        assertEq(withdrawQueue.minimumOrderSize(), 111);
    }

    function test_manageERC20() external {
        // Test only the owner can call this
        // The token must not be zero
        // The receiver must not be zero
        // NOTE: There is no event emitted
        deal(address(USDC), address(withdrawQueue), 100);

        vm.expectRevert("UNAUTHORIZED");
        withdrawQueue.manageERC20(USDC, 100, owner);

        vm.startPrank(owner);
        vm.expectRevert(WithdrawQueue.ZeroAddress.selector, address(withdrawQueue));
        withdrawQueue.manageERC20(IERC20(address(0)), 100, owner);

        vm.expectRevert(WithdrawQueue.ZeroAddress.selector, address(withdrawQueue));
        withdrawQueue.manageERC20(USDC, 100, address(0));

        withdrawQueue.manageERC20(USDC, 100, owner);
        assertEq(USDC.balanceOf(address(withdrawQueue)), 0);
        assertEq(USDC.balanceOf(owner), 100);

        vm.stopPrank();
    }

    function test_forceProcessOrders() external {
        // Test only the owner can call
        // The array must not be empty
        // With 3 orders in the queue test that if 2 are force processed, that 2 events are emitted, one for each
        // NOTE: there are more errors to test here but that are applied to individual _forceProcess calls and are
        // better tested in the singular test_forceProcess test
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();

        uint256[] memory orderIndices = new uint256[](2);
        orderIndices[0] = 2;
        orderIndices[1] = 3;

        vm.expectRevert("UNAUTHORIZED");
        withdrawQueue.forceProcessOrders(orderIndices);

        vm.startPrank(owner);
        vm.expectRevert(WithdrawQueue.EmptyArray.selector);
        withdrawQueue.forceProcessOrders(new uint256[](0));
        assertEq(USDC.balanceOf(address(boringVault)), 3e6);

        _expectOrderProcessedEvent(2, USDC, user, 1e6, WithdrawQueue.OrderType.PRE_FILLED, true);
        _expectOrderProcessedEvent(3, USDC, user, 1e6, WithdrawQueue.OrderType.PRE_FILLED, true);
        withdrawQueue.forceProcessOrders(orderIndices);
        vm.stopPrank();

        assertEq(uint8(withdrawQueue.getOrderStatus(1)), uint8(WithdrawQueue.OrderStatus.PENDING));
        assertEq(uint8(withdrawQueue.getOrderStatus(2)), uint8(WithdrawQueue.OrderStatus.COMPLETE_PRE_FILLED));
        assertEq(uint8(withdrawQueue.getOrderStatus(3)), uint8(WithdrawQueue.OrderStatus.COMPLETE_PRE_FILLED));
    }

    function test_forceProcess() external {
        // Perform same test as with forceProcessOrders, 3 orders placed, but force process only the last one
        // Test only the owner can call
        // An index must not be 0 (will revert with InvalidOrderIndex)
        // An index must not be greater than the latest order (will revert with InvalidOrderIndex)
        // If orders are already processed normally, it should revert with OrderAlreadyProcessed
        // Orders must not be pre-filled or refunded (will revert with InvalidOrderType)
        // Test the correct event is emitted
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();

        vm.expectRevert("UNAUTHORIZED");
        withdrawQueue.forceProcess(3);

        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(WithdrawQueue.InvalidOrderIndex.selector, 0));
        withdrawQueue.forceProcess(0);

        vm.expectRevert(abi.encodeWithSelector(WithdrawQueue.InvalidOrderIndex.selector, 4));
        withdrawQueue.forceProcess(4);

        // Successfully force process the last order
        _expectOrderProcessedEvent(3, USDC, user, 1e6, WithdrawQueue.OrderType.PRE_FILLED, true);
        withdrawQueue.forceProcess(3);
        assertEq(
            uint8(withdrawQueue.getOrderStatus(1)),
            uint8(WithdrawQueue.OrderStatus.PENDING),
            "pre-process: 1 should be pending"
        );
        assertEq(
            uint8(withdrawQueue.getOrderStatus(2)),
            uint8(WithdrawQueue.OrderStatus.PENDING),
            "pre-process: 2 should be pending"
        );
        assertEq(
            uint8(withdrawQueue.getOrderStatus(3)),
            uint8(WithdrawQueue.OrderStatus.COMPLETE_PRE_FILLED),
            "pre-process: 3 should be complete pre-filled"
        );
        assertEq(
            USDC.balanceOf(user), _getAmountAfterFees(1e6), "after force process, user should have 1e6 USDC - fees"
        );
        assertEq(
            boringVault.balanceOf(address(withdrawQueue.feeRecipient())),
            _getFees(1e6),
            "after force process, fee recipient should have fees in shares"
        );

        // Try to force process an already force processed order
        vm.expectRevert(
            abi.encodeWithSelector(WithdrawQueue.InvalidOrderType.selector, 3, WithdrawQueue.OrderType.PRE_FILLED)
        );
        withdrawQueue.forceProcess(3);

        // mark order 2 for refund
        withdrawQueue.refundOrder(2);

        vm.expectRevert(
            abi.encodeWithSelector(WithdrawQueue.InvalidOrderType.selector, 2, WithdrawQueue.OrderType.REFUND)
        );
        withdrawQueue.forceProcess(2);

        // Now process orders. 1 should be complete, 2 refunded and 3 pre-filled
        _expectOrderProcessedEvent(1, USDC, user, 1e6, WithdrawQueue.OrderType.DEFAULT, false);
        _expectOrderRefundedEvent(2, USDC, user, 1e6);
        withdrawQueue.processOrders(3);

        assertEq(
            USDC.balanceOf(user), _getAmountAfterFees(2e6), "after force process, user should have 1e6 USDC - fees"
        );
        assertEq(
            boringVault.balanceOf(address(withdrawQueue.feeRecipient())),
            _getFees(2e6),
            "after force process, fee recipient should have fees in shares"
        );
        assertEq(withdrawQueue.lastProcessedOrder(), 3, "post-process: last processed order should be 3");
        assertEq(
            uint8(withdrawQueue.getOrderStatus(1)),
            uint8(WithdrawQueue.OrderStatus.COMPLETE),
            "post-process: 1 should be complete"
        );
        assertEq(
            uint8(withdrawQueue.getOrderStatus(2)),
            uint8(WithdrawQueue.OrderStatus.COMPLETE_REFUNDED),
            "post-process: 2 should be complete refunded"
        );
        assertEq(
            uint8(withdrawQueue.getOrderStatus(3)),
            uint8(WithdrawQueue.OrderStatus.COMPLETE_PRE_FILLED),
            "post-process: 3 should be complete pre-filled"
        );

        // Try to force process an order that is refunded
        vm.expectRevert(abi.encodeWithSelector(WithdrawQueue.OrderAlreadyProcessed.selector, 2));
        withdrawQueue.forceProcess(2);

        // Try to force process an order that is complete
        vm.expectRevert(abi.encodeWithSelector(WithdrawQueue.OrderAlreadyProcessed.selector, 1));
        withdrawQueue.forceProcess(1);

        vm.stopPrank();
    }

    function test_cancelOrder() external {
        // Test a user must own the order they're canceling
        // NOTE: because the user must own the order it's impossible to revert with InvalidOrderIndex
        // Should fail with InvalidOrderType if order is already marked for refund
        // Should emit OrderMarkedForRefund

        _submitAnOrder();

        vm.expectRevert(abi.encodeWithSelector(WithdrawQueue.OnlyOrderOwnerCanCancel.selector, address(this), user));
        withdrawQueue.cancelOrder(1);

        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(WithdrawQueue.OnlyOrderOwnerCanCancel.selector, owner, user));
        withdrawQueue.cancelOrder(1);
        vm.stopPrank();

        vm.startPrank(user);
        vm.expectEmit(true, true, true, true);
        emit WithdrawQueue.OrderMarkedForRefund(1, true);
        withdrawQueue.cancelOrder(1);
        assertEq(
            uint8(withdrawQueue.getOrderStatus(1)),
            uint8(WithdrawQueue.OrderStatus.PENDING_REFUND),
            "order 1 should be marked for refund"
        );

        vm.expectRevert(
            abi.encodeWithSelector(WithdrawQueue.InvalidOrderType.selector, 1, WithdrawQueue.OrderType.REFUND)
        );
        withdrawQueue.cancelOrder(1);

        vm.stopPrank();
    }

    function test_cancelOrderWithSignature() external {
        // Test a valid signature may cancel an order
        // Test an invalid signature may not cancel an order
        // Test a signature may not be used past it's deadline
        // Test a signature may not be reused (as the order is already marked for refund)
        WithdrawQueue.SubmitOrderParams memory params =
            _createSubmitOrderParams(USDC, 1e6, alice, alice, alice, defaultSignatureParams);
        deal(address(boringVault), alice, 2e6);
        vm.startPrank(alice);
        boringVault.approve(address(withdrawQueue), 2e6);
        // submit 2 orders
        withdrawQueue.submitOrder(params);
        withdrawQueue.submitOrder(params);

        uint256 deadline = block.timestamp + 1000;
        bytes32 hash = keccak256(
            abi.encode(withdrawQueue.CANCEL_ORDER_TYPEHASH(), 1, deadline, address(withdrawQueue), block.chainid)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, hash);
        bytes memory signature = abi.encodePacked(r, s, v);
        vm.stopPrank();

        vm.expectEmit(true, true, true, true);
        emit WithdrawQueue.OrderMarkedForRefund(1, true);
        withdrawQueue.cancelOrderWithSignature(1, deadline, signature);

        // attempt to double sign fails
        vm.expectRevert(
            abi.encodeWithSelector(WithdrawQueue.InvalidOrderType.selector, 1, WithdrawQueue.OrderType.REFUND)
        );
        withdrawQueue.cancelOrderWithSignature(1, deadline, signature);

        vm.startPrank(bob);
        // sign a second cancellation as bob
        hash = keccak256(
            abi.encode(withdrawQueue.CANCEL_ORDER_TYPEHASH(), 2, deadline, address(withdrawQueue), block.chainid)
        );
        (v, r, s) = vm.sign(bobPk, hash);
        signature = abi.encodePacked(r, s, v);

        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(WithdrawQueue.OnlyOrderOwnerCanCancel.selector, bob, alice));
        withdrawQueue.cancelOrderWithSignature(2, deadline, signature);

        vm.expectRevert(abi.encodeWithSelector(WithdrawQueue.OnlyOrderOwnerCanCancel.selector, bob, alice));
        withdrawQueue.cancelOrderWithSignature(2, deadline, signature);

        vm.startPrank(alice);
        // alice signs a cancellation for order 2
        hash = keccak256(
            abi.encode(withdrawQueue.CANCEL_ORDER_TYPEHASH(), 2, deadline, address(withdrawQueue), block.chainid)
        );
        (v, r, s) = vm.sign(alicePk, hash);
        signature = abi.encodePacked(r, s, v);
        vm.stopPrank();

        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(WithdrawQueue.SignatureExpired.selector, deadline, block.timestamp));
        withdrawQueue.cancelOrderWithSignature(2, deadline, signature);
    }

    function test_refundOrder() external {
        // Test only the owner can call
        // The order should be of status PENDING_REFUND
        // Should emit OrderMarkedForRefund
        // Should fail for index 0 or greater than latest order
        // Should fail if order is already marked for refund or pre-processed

        _submitAnOrder();
        _submitAnOrder();

        vm.expectRevert("UNAUTHORIZED");
        withdrawQueue.refundOrder(1);

        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(WithdrawQueue.InvalidOrderIndex.selector, 0));
        withdrawQueue.refundOrder(0);

        vm.expectRevert(abi.encodeWithSelector(WithdrawQueue.InvalidOrderIndex.selector, 4));
        withdrawQueue.refundOrder(4);

        vm.expectEmit(true, true, true, true);
        emit WithdrawQueue.OrderMarkedForRefund(1, false);
        withdrawQueue.refundOrder(1);
        assertEq(
            uint8(withdrawQueue.getOrderStatus(1)),
            uint8(WithdrawQueue.OrderStatus.PENDING_REFUND),
            "order 1 should be marked for refund"
        );

        vm.expectRevert(
            abi.encodeWithSelector(WithdrawQueue.InvalidOrderType.selector, 1, WithdrawQueue.OrderType.REFUND)
        );
        withdrawQueue.refundOrder(1);

        withdrawQueue.forceProcess(2);

        vm.expectRevert(
            abi.encodeWithSelector(WithdrawQueue.InvalidOrderType.selector, 2, WithdrawQueue.OrderType.PRE_FILLED)
        );
        withdrawQueue.refundOrder(2);

        vm.stopPrank();
    }

    function test_refundOrders() external {
        // Test only the owner can call
        // The array must not be empty
        // With 3 orders in the queue test that if 2 are marked for refund, that 2 events are emitted, one for each
        // NOTE: there are more errors to test here but that are applied to individual _markForRefund calls and are
        // better tested in the singular test_refundOrder test
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();

        vm.expectRevert("UNAUTHORIZED");
        withdrawQueue.refundOrders(new uint256[](0));

        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(WithdrawQueue.EmptyArray.selector));
        withdrawQueue.refundOrders(new uint256[](0));

        uint256[] memory orderIndices = new uint256[](2);
        orderIndices[0] = 2;
        orderIndices[1] = 3;

        vm.expectEmit(true, true, true, true);
        emit WithdrawQueue.OrderMarkedForRefund(2, false);
        vm.expectEmit(true, true, true, true);
        emit WithdrawQueue.OrderMarkedForRefund(3, false);
        withdrawQueue.refundOrders(orderIndices);
        assertEq(
            uint8(withdrawQueue.getOrderStatus(1)),
            uint8(WithdrawQueue.OrderStatus.PENDING),
            "order 1 should be pending"
        );
        assertEq(
            uint8(withdrawQueue.getOrderStatus(2)),
            uint8(WithdrawQueue.OrderStatus.PENDING_REFUND),
            "order 2 should be marked for refund"
        );
        assertEq(
            uint8(withdrawQueue.getOrderStatus(3)),
            uint8(WithdrawQueue.OrderStatus.PENDING_REFUND),
            "order 3 should be marked for refund"
        );
    }

    function test_submitOrderAndProcess() external {
        // Test fails if the boring vault doesn't have enough balance
        // Test fails if attempting to process more orders than are in the queue
        // Test fails if attempting to process 0 orders
        // Can process orders not including user's order
        // Can process a user's order atomically
        // Should emit OrderSubmitted and OrderProcessed and OrdersProcessedInRange

        // start with 2 orders
        _submitAnOrder();
        _submitAnOrder();
        // reset boring vault balance to 0 as _submitAnOrder deals
        deal(address(USDC), address(boringVault), 0);

        // ensure user has balance for 2 orders
        deal(address(boringVault), address(user), 2e6);
        WithdrawQueue.SubmitOrderParams memory params =
            _createSubmitOrderParams(USDC, 1e6, user, user, user, defaultSignatureParams);
        vm.startPrank(user);
        boringVault.approve(address(withdrawQueue), 2e6);

        assertEq(USDC.balanceOf(address(boringVault)), 0, "vault should have 0 balance");
        vm.expectRevert(
            abi.encodeWithSelector(WithdrawQueue.VaultInsufficientBalance.selector, USDC, _getAmountAfterFees(1e6), 0)
        );
        withdrawQueue.submitOrderAndProcess(params, 1);

        // same test with just not enough balance for 2 orders
        // NOTE: We deal 1e6 - fees since the vault only transfers out the amount - fees on process. The fees are kept
        // in shares. To make testing easy for the event, we have a round amount where only 0 is left by the second
        // process
        deal(address(USDC), address(boringVault), _getAmountAfterFees(1e6));

        vm.expectRevert(
            abi.encodeWithSelector(WithdrawQueue.VaultInsufficientBalance.selector, USDC, _getAmountAfterFees(1e6), 0)
        );
        withdrawQueue.submitOrderAndProcess(params, 2);

        // now deal enough for all coming orders
        deal(address(USDC), address(boringVault), 4e6);

        vm.expectRevert(abi.encodeWithSelector(WithdrawQueue.InvalidOrdersCount.selector, 0));
        withdrawQueue.submitOrderAndProcess(params, 0);

        vm.expectRevert(abi.encodeWithSelector(WithdrawQueue.NotEnoughOrdersToProcess.selector, 4, 3));
        withdrawQueue.submitOrderAndProcess(params, 4);

        // submit and process 2 orders (not including user's order)
        _expectOrderSubmittedEvent(1e6, USDC, user, user, false);
        _expectOrderProcessedEvent(1, USDC, user, 1e6, WithdrawQueue.OrderType.DEFAULT, false);
        _expectOrderProcessedEvent(2, USDC, user, 1e6, WithdrawQueue.OrderType.DEFAULT, false);
        vm.expectEmit(true, true, true, true);
        emit WithdrawQueue.OrdersProcessedInRange(1, 2);
        withdrawQueue.submitOrderAndProcess(params, 2);

        assertEq(
            uint8(withdrawQueue.getOrderStatus(1)),
            uint8(WithdrawQueue.OrderStatus.COMPLETE),
            "first-submitAndProcess: order 1 should be complete"
        );
        assertEq(
            uint8(withdrawQueue.getOrderStatus(2)),
            uint8(WithdrawQueue.OrderStatus.COMPLETE),
            "first-submitAndProcess: order 2 should be complete"
        );
        assertEq(
            uint8(withdrawQueue.getOrderStatus(3)),
            uint8(WithdrawQueue.OrderStatus.PENDING),
            "first-submitAndProcess: order 3 should be pending"
        );

        // now submit and process a user's order atomically
        _expectOrderSubmittedEvent(1e6, USDC, user, user, false);
        _expectOrderProcessedEvent(3, USDC, user, 1e6, WithdrawQueue.OrderType.DEFAULT, false);
        _expectOrderProcessedEvent(4, USDC, user, 1e6, WithdrawQueue.OrderType.DEFAULT, false);
        vm.expectEmit(true, true, true, true);
        emit WithdrawQueue.OrdersProcessedInRange(3, 4);
        withdrawQueue.submitOrderAndProcess(params, 2);
        assertEq(
            uint8(withdrawQueue.getOrderStatus(3)),
            uint8(WithdrawQueue.OrderStatus.COMPLETE),
            "second-submitAndProcess: order 3 should be complete"
        );
        assertEq(
            uint8(withdrawQueue.getOrderStatus(4)),
            uint8(WithdrawQueue.OrderStatus.COMPLETE),
            "second-submitAndProcess: order 4 should be complete"
        );
        vm.stopPrank();
    }

    function test_submitOrderAndProcessAll() external {
        // Test fails if the boring vault doesn't have enough balance
        // Can process a user's order atomically with orders already in the queue
        // Can process a user's order atomically with no orders in the queue
        // Should emit OrderSubmitted and OrderProcessed and OrdersProcessedInRange

        // start with 2 orders
        _submitAnOrder();
        _submitAnOrder();
        // reset boring vault balance to 0 as _submitAnOrder deals
        deal(address(USDC), address(boringVault), 0);

        // ensure user has balance for 2 orders
        deal(address(boringVault), address(user), 2e6);
        WithdrawQueue.SubmitOrderParams memory params =
            _createSubmitOrderParams(USDC, 1e6, user, user, user, defaultSignatureParams);
        vm.startPrank(user);
        boringVault.approve(address(withdrawQueue), 2e6);

        assertEq(USDC.balanceOf(address(boringVault)), 0, "vault should have 0 balance");
        vm.expectRevert(
            abi.encodeWithSelector(WithdrawQueue.VaultInsufficientBalance.selector, USDC, _getAmountAfterFees(1e6), 0)
        );
        withdrawQueue.submitOrderAndProcessAll(params);

        deal(address(USDC), address(boringVault), 3e6);
        _expectOrderSubmittedEvent(1e6, USDC, user, user, false);
        _expectOrderProcessedEvent(1, USDC, user, 1e6, WithdrawQueue.OrderType.DEFAULT, false);
        _expectOrderProcessedEvent(2, USDC, user, 1e6, WithdrawQueue.OrderType.DEFAULT, false);
        _expectOrderProcessedEvent(3, USDC, user, 1e6, WithdrawQueue.OrderType.DEFAULT, false);
        vm.expectEmit(true, true, true, true);
        emit WithdrawQueue.OrdersProcessedInRange(1, 3);
        withdrawQueue.submitOrderAndProcessAll(params);
        assertEq(
            uint8(withdrawQueue.getOrderStatus(1)),
            uint8(WithdrawQueue.OrderStatus.COMPLETE),
            "first-submitAndProcessAll: order 1 should be complete"
        );
        assertEq(
            uint8(withdrawQueue.getOrderStatus(2)),
            uint8(WithdrawQueue.OrderStatus.COMPLETE),
            "first-submitAndProcessAll: order 2 should be complete"
        );
        assertEq(
            uint8(withdrawQueue.getOrderStatus(3)),
            uint8(WithdrawQueue.OrderStatus.COMPLETE),
            "first-submitAndProcessAll: order 3 should be complete"
        );

        // now submit and process a user's order atomically with no orders in the queue
        deal(address(USDC), address(boringVault), 1e6);
        _expectOrderSubmittedEvent(1e6, USDC, user, user, false);
        _expectOrderProcessedEvent(4, USDC, user, 1e6, WithdrawQueue.OrderType.DEFAULT, false);
        vm.expectEmit(true, true, true, true);
        emit WithdrawQueue.OrdersProcessedInRange(4, 4);
        withdrawQueue.submitOrderAndProcessAll(params);
        assertEq(
            uint8(withdrawQueue.getOrderStatus(4)),
            uint8(WithdrawQueue.OrderStatus.COMPLETE),
            "second-submitAndProcessAll: order 4 should be complete"
        );

        vm.stopPrank();
    }

    function test_getOrderStatus() external {
        // returns NOT_FOUND for order index 0 or index greater than latest order
        // returns PRE_FILLED for PRE_FILLED
        // returns FAILED_TRANSFER_REFUNDED for orders that fail on transfer
        // if the order index > lastProcessedOrder the order is PENDING. Otherwise it is COMPLETE. The order may be
        // postfixed with _REFUND/_REFUNDED if a refund order

        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();

        assertEq(
            uint8(withdrawQueue.getOrderStatus(0)),
            uint8(WithdrawQueue.OrderStatus.NOT_FOUND),
            "order 0 should be NOT_FOUND"
        );
        assertEq(
            uint8(withdrawQueue.getOrderStatus(5)),
            uint8(WithdrawQueue.OrderStatus.NOT_FOUND),
            "order 5 should be NOT_FOUND"
        );
        assertEq(
            uint8(withdrawQueue.getOrderStatus(1)),
            uint8(WithdrawQueue.OrderStatus.PENDING),
            "order 1 should be PENDING"
        );
        vm.startPrank(owner);
        withdrawQueue.forceProcess(1);
        withdrawQueue.refundOrder(2);
        assertEq(
            uint8(withdrawQueue.getOrderStatus(1)),
            uint8(WithdrawQueue.OrderStatus.COMPLETE_PRE_FILLED),
            "order 1 now should be COMPLETE_PRE_FILLED"
        );
        assertEq(
            uint8(withdrawQueue.getOrderStatus(2)),
            uint8(WithdrawQueue.OrderStatus.PENDING_REFUND),
            "order 2 now should be PENDING_REFUND"
        );

        tERC20(address(USDC)).setFailSwitch(true);
        // What happens here:
        // 1. force processed, gets skipped
        // 2. refund order, gets refunded and skipped
        // 3. goes to process, fails on transfer and is refunded due to failed transfer
        withdrawQueue.processOrders(3);
        assertEq(
            uint8(withdrawQueue.getOrderStatus(2)),
            uint8(WithdrawQueue.OrderStatus.COMPLETE_REFUNDED),
            "order 2 now should be COMPLETE_REFUNDED"
        );
        assertEq(
            uint8(withdrawQueue.getOrderStatus(3)),
            uint8(WithdrawQueue.OrderStatus.FAILED_TRANSFER_REFUNDED),
            "order 3 now should be FAILED_TRANSFER_REFUNDED"
        );

        // Set fail switch false and get a complete order
        tERC20(address(USDC)).setFailSwitch(false);
        withdrawQueue.processOrders(1);
        assertEq(
            uint8(withdrawQueue.getOrderStatus(4)),
            uint8(WithdrawQueue.OrderStatus.COMPLETE),
            "order 4 now should be COMPLETE"
        );
    }

    function test_submitOrder_approval_noSignature() external {
        // Test flow with ERC20 approve and no signature. Also test the basic input validation in this test
        // Set a minimum order size. Order must be greater than it
        // receiver must not be zero address
        // refund receiver must not be zero address
        // want asset must be supported on the teller
        // msg.sender must be the intended depositor
        // orderSubmitted event should be emitted
        vm.startPrank(owner);
        withdrawQueue.updateAssetMinimumOrderSize(1e6);
        vm.stopPrank();

        IERC20 badERC20 = IERC20(address(new tERC20(8)));
        WithdrawQueue.SubmitOrderParams memory params =
            _createSubmitOrderParams(badERC20, 0.5e6, user2, address(0), address(0), defaultSignatureParams);
        deal(address(boringVault), user, 1e6);

        vm.startPrank(user);
        boringVault.approve(address(withdrawQueue), 1e6);

        vm.expectRevert(abi.encodeWithSelector(WithdrawQueue.AmountBelowMinimum.selector, 0.5e6, 1e6));
        withdrawQueue.submitOrder(params);
        params.amountOffer = 1e6;

        vm.expectRevert(abi.encodeWithSelector(WithdrawQueue.ZeroAddress.selector));
        withdrawQueue.submitOrder(params);
        params.receiver = user;

        vm.expectRevert(abi.encodeWithSelector(WithdrawQueue.ZeroAddress.selector));
        withdrawQueue.submitOrder(params);
        params.refundReceiver = user;

        assertFalse(teller.isWithdrawSupported(ERC20(address(badERC20))), "badERC20 should not be withdraw supported");
        assertEq(address(params.wantAsset), address(badERC20), "want asset should be badERC20");
        vm.expectRevert(abi.encodeWithSelector(WithdrawQueue.AssetNotSupported.selector, badERC20));
        withdrawQueue.submitOrder(params);
        params.wantAsset = USDC;

        vm.expectRevert(abi.encodeWithSelector(WithdrawQueue.InvalidDepositor.selector, user2, user));
        withdrawQueue.submitOrder(params);
        params.intendedDepositor = user;

        _expectOrderSubmittedEvent(1e6, USDC, user, user, false);
        withdrawQueue.submitOrder(params);
        vm.stopPrank();
    }

    function test_submitOrder_approval_withSignature() external {
        // Sign with vm.sign
        // Signature must match the intended depositor
        // Signature may not be reused
        // Signature may not be used after the deadline
        WithdrawQueue.SignatureParams memory signatureParams = WithdrawQueue.SignatureParams({
            approvalMethod: WithdrawQueue.ApprovalMethod.EIP20_APPROVE,
            approvalV: 0,
            approvalR: bytes32(0),
            approvalS: bytes32(0),
            submitWithSignature: true,
            deadline: block.timestamp + 1000,
            eip2612Signature: ""
        });
        WithdrawQueue.SubmitOrderParams memory params =
            _createSubmitOrderParams(USDC, 1e6, user, alice, alice, signatureParams);

        bytes32 hash = keccak256(
            abi.encode(
                params.amountOffer,
                params.wantAsset,
                params.receiver,
                params.refundReceiver,
                params.signatureParams.deadline,
                params.signatureParams.approvalMethod,
                withdrawQueue.nonces(alice),
                address(withdrawQueue.feeModule()),
                alice,
                block.chainid,
                address(withdrawQueue)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, hash);
        signatureParams.eip2612Signature = abi.encodePacked(r, s, v);
        params.signatureParams = signatureParams;
        deal(address(boringVault), alice, 1e6);

        vm.startPrank(alice);
        boringVault.approve(address(withdrawQueue), 1e6);

        vm.expectPartialRevert(WithdrawQueue.InvalidEip2612Signature.selector);
        withdrawQueue.submitOrder(params);
        params.intendedDepositor = alice;

        _expectOrderSubmittedEvent(1e6, USDC, alice, alice, true);
        withdrawQueue.submitOrder(params);

        vm.expectPartialRevert(WithdrawQueue.InvalidEip2612Signature.selector);
        withdrawQueue.submitOrder(params);

        vm.warp(block.timestamp + 1001);
        // This is also already used but the expired revert should be checked first
        vm.expectRevert(
            abi.encodeWithSelector(
                WithdrawQueue.SignatureExpired.selector, params.signatureParams.deadline, block.timestamp
            )
        );
        withdrawQueue.submitOrder(params);
        vm.stopPrank();
    }

    function test_submitOrder_permit_noSignature() external {
        // Test a valid flow with the permit and event is emitted
        // No new tests needed for permit as it's in the scope of the ERC20 implementation
        assertEq(address(withdrawQueue.offerAsset()), address(boringVault), "offer asset should be boring vault");
        (uint8 v, bytes32 r, bytes32 s) = _getPermitSignature(
            IERC20(address(boringVault)), alice, alicePk, address(withdrawQueue), 1e6, block.timestamp + 1000
        );
        WithdrawQueue.SignatureParams memory signatureParams = WithdrawQueue.SignatureParams({
            approvalMethod: WithdrawQueue.ApprovalMethod.EIP2612_PERMIT,
            approvalV: v,
            approvalR: r,
            approvalS: s,
            submitWithSignature: false,
            deadline: block.timestamp + 1000,
            eip2612Signature: ""
        });
        WithdrawQueue.SubmitOrderParams memory params =
            _createSubmitOrderParams(USDC, 1e6, alice, alice, alice, signatureParams);

        deal(address(boringVault), alice, 1e6);
        vm.startPrank(alice);
        // Note no approval here
        _expectOrderSubmittedEvent(1e6, USDC, alice, alice, false);
        withdrawQueue.submitOrder(params);
        vm.stopPrank();
    }

    function test_submitOrder_permit_withSignature() external {
        // Conduct the same signature tests just using permit for approval
        // No new tests needed for permit as it's in the scope of the ERC20 implementation
        (uint8 _v, bytes32 _r, bytes32 _s) = _getPermitSignature(
            IERC20(address(boringVault)), alice, alicePk, address(withdrawQueue), 1e6, block.timestamp + 1000
        );
        WithdrawQueue.SignatureParams memory signatureParams = WithdrawQueue.SignatureParams({
            approvalMethod: WithdrawQueue.ApprovalMethod.EIP2612_PERMIT,
            approvalV: _v,
            approvalR: _r,
            approvalS: _s,
            submitWithSignature: true,
            deadline: block.timestamp + 1000,
            eip2612Signature: ""
        });
        WithdrawQueue.SubmitOrderParams memory params =
            _createSubmitOrderParams(USDC, 1e6, user, alice, alice, signatureParams);

        bytes32 hash = keccak256(
            abi.encode(
                params.amountOffer,
                params.wantAsset,
                params.receiver,
                params.refundReceiver,
                params.signatureParams.deadline,
                params.signatureParams.approvalMethod,
                withdrawQueue.nonces(alice),
                address(withdrawQueue.feeModule()),
                alice,
                block.chainid,
                address(withdrawQueue)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, hash);
        signatureParams.eip2612Signature = abi.encodePacked(r, s, v);
        params.signatureParams = signatureParams;
        deal(address(boringVault), alice, 1e6);

        vm.startPrank(alice);

        vm.expectPartialRevert(WithdrawQueue.InvalidEip2612Signature.selector);
        withdrawQueue.submitOrder(params);
        params.intendedDepositor = alice;

        _expectOrderSubmittedEvent(1e6, USDC, alice, alice, true);
        withdrawQueue.submitOrder(params);

        vm.expectPartialRevert(WithdrawQueue.InvalidEip2612Signature.selector);
        withdrawQueue.submitOrder(params);

        vm.warp(block.timestamp + 1001);
        // This is also already used but the expired revert should be checked first
        vm.expectRevert(
            abi.encodeWithSelector(
                WithdrawQueue.SignatureExpired.selector, params.signatureParams.deadline, block.timestamp
            )
        );
        withdrawQueue.submitOrder(params);
        vm.stopPrank();
    }

    function test_processOrders() external {
        // Orders to process cannot be 0
        // Cannot process more orders than are in the queue
        // Orders marked for refund are not processed and instead refunded in their entirety (no fees taken)
        // Orders pre-processed are not processed and no balances are transferred
        // Orders that fail on transfer are refunded in their entirety (no fees taken)
        // Normal orders are processed and the fees are taken in shares
        // Events are emitted for orders processed and refunds
        // NOTE: Focus here is on the appropriate balance changes and less on state updates and order statuses. As these
        // are already covered in above tests for submitAndProcess which directly call this function
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        assertEq(withdrawQueue.ownerOf(1), user, "user should own order 1");
        assertEq(withdrawQueue.ownerOf(2), user, "user should own order 2");
        assertEq(withdrawQueue.ownerOf(3), user, "user should own order 3");
        assertEq(withdrawQueue.ownerOf(4), user, "user should own order 4");
        assertEq(withdrawQueue.totalSupply(), 4, "total supply should be 4");

        vm.expectRevert(abi.encodeWithSelector(WithdrawQueue.InvalidOrdersCount.selector, 0));
        withdrawQueue.processOrders(0);

        vm.expectRevert(abi.encodeWithSelector(WithdrawQueue.NotEnoughOrdersToProcess.selector, 5, 4));
        withdrawQueue.processOrders(5);

        uint256 userUSDCBalance1 = USDC.balanceOf(user);
        uint256 userShareBalance1 = boringVault.balanceOf(user);

        vm.startPrank(user);
        withdrawQueue.cancelOrder(4);
        vm.stopPrank();

        vm.startPrank(owner);
        withdrawQueue.refundOrder(2);
        withdrawQueue.forceProcess(3);

        assertEq(withdrawQueue.ownerOf(1), user, "user should own order 1 still");
        assertEq(withdrawQueue.ownerOf(2), user, "user should own order 2 still");
        assertEq(withdrawQueue.ownerOf(4), user, "user should own order 4 still");
        assertEq(withdrawQueue.totalSupply(), 3, "total supply should be 3 after force process");

        _expectOrderProcessedEvent(1, USDC, user, 1e6, WithdrawQueue.OrderType.DEFAULT, false);
        _expectOrderRefundedEvent(2, USDC, user, 1e6);
        _expectOrderRefundedEvent(4, USDC, user, 1e6);
        vm.expectEmit(true, true, true, true);
        emit WithdrawQueue.OrdersProcessedInRange(1, 4);
        withdrawQueue.processOrders(4);
        assertEq(withdrawQueue.totalSupply(), 0, "total supply should be 0 after process");

        uint256 userUSDCBalance2 = USDC.balanceOf(user);
        uint256 userShareBalance2 = boringVault.balanceOf(user);

        assertEq(
            userUSDCBalance2 - userUSDCBalance1,
            _getAmountAfterFees(2e6),
            "after first process, user should have 2e6 USDC - fees"
        );
        assertEq(
            userShareBalance2 - userShareBalance1,
            2e6,
            "after first process, user should have 1e6 shares from 1 refund and 1 cancel"
        );
        vm.stopPrank();

        _submitAnOrder();
        assertEq(withdrawQueue.ownerOf(5), user, "user should own order 5");
        assertEq(withdrawQueue.totalSupply(), 1, "total supply should be 1 after submit");
        tERC20(address(USDC)).setFailSwitch(true);
        withdrawQueue.processOrders(1);
        tERC20(address(USDC)).setFailSwitch(false);
        assertEq(withdrawQueue.totalSupply(), 0, "total supply should be 0 after process fail order");

        uint256 userUSDCBalance3 = USDC.balanceOf(user);
        uint256 userShareBalance3 = boringVault.balanceOf(user);

        assertEq(userUSDCBalance3 - userUSDCBalance2, 0, "after second failing process, user should have no more USDC");
        assertEq(
            userShareBalance3 - userShareBalance2,
            1e6,
            "after second process, user should have 1e6 shares from 1 refund"
        );
    }

}
