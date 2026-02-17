// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { OneToOneQueue } from "src/helper/one-to-one-queue/OneToOneQueue.sol";
import { SimpleFeeModule } from "src/helper/SimpleFeeModule.sol";
import { OneToOneQueueTestBase, tERC20, ERC20 } from "../OneToOneQueueTestBase.t.sol";
import { Test, stdStorage, StdStorage, stdError, console } from "@forge-std/Test.sol";
import { AccessAuthority } from "src/helper/one-to-one-queue/access/AccessAuthority.sol";
import { VerboseAuth } from "src/helper/one-to-one-queue/access/VerboseAuth.sol";

contract OneToOneQueueTestManyOrders is OneToOneQueueTestBase {

    function testManyOrdersWithRefundsAndForceProcesses() external {
        // 12 orders (all User1)
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();

        // ensure queue has plenty of balance to refund and process orders
        deal(address(USDC), address(queue), 12e6);
        deal(address(USDG0), address(queue), 12e6);

        // Force refund and process a bunch of orders
        vm.startPrank(owner);
        _expectOrderProcessedEvent(3, OneToOneQueue.OrderType.PRE_FILLED, true, false);
        queue.forceProcess(3);
        _expectOrderProcessedEvent(4, OneToOneQueue.OrderType.PRE_FILLED, true, false);
        queue.forceProcess(4);
        _expectOrderProcessedEvent(7, OneToOneQueue.OrderType.PRE_FILLED, true, false);
        queue.forceProcess(7);
        queue.forceRefund(2);
        queue.forceRefund(5);
        queue.forceRefund(11);
        vm.stopPrank();

        // All valid orders
        assertEq(queue.ownerOf(1), user1, "User1 should own the first order");
        assertEq(queue.ownerOf(6), user1, "User1 should own the 6th order");
        assertEq(queue.ownerOf(8), user1, "User1 should own the 8th order");
        assertEq(queue.ownerOf(9), user1, "User1 should own the 9th order");
        assertEq(queue.ownerOf(10), user1, "User1 should own the 10th order");
        assertEq(queue.ownerOf(12), user1, "User1 should own the 12th order");

        uint256 totalUSDCForUser = 3e6; // 3 refunds return 3 USDC
        uint256 totalUSDG0ForUser = 3e6 - (3e6 * TEST_OFFER_FEE_PERCENTAGE / 10_000); // 3 USDG0 - fees. 3 from force
        // processing
        assertEq(USDC.balanceOf(user1), totalUSDCForUser, "User1 should have their USDC balance back");
        assertEq(
            USDG0.balanceOf(user1), totalUSDG0ForUser, "User1 should have their USDG0 balance from force processing"
        );

        // Process all the orders
        _expectOrderProcessedEvent(1, OneToOneQueue.OrderType.DEFAULT, false, false);
        _expectOrderProcessedEvent(6, OneToOneQueue.OrderType.DEFAULT, false, false);
        _expectOrderProcessedEvent(8, OneToOneQueue.OrderType.DEFAULT, false, false);
        _expectOrderProcessedEvent(9, OneToOneQueue.OrderType.DEFAULT, false, false);
        _expectOrderProcessedEvent(10, OneToOneQueue.OrderType.DEFAULT, false, false);
        _expectOrderProcessedEvent(12, OneToOneQueue.OrderType.DEFAULT, false, false);
        queue.processOrders(12);
        totalUSDG0ForUser += 6e6 - (6e6 * TEST_OFFER_FEE_PERCENTAGE / 10_000);
        // processing
        assertEq(USDC.balanceOf(user1), totalUSDCForUser, "User1 should have their USDC balance back");
        assertEq(USDG0.balanceOf(user1), totalUSDG0ForUser, "User1 should have their USDG0 balance");
    }

    function testOrdersRefundFirstAndLast() external {
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();

        // ensure queue has plenty of balance to refund and process orders
        deal(address(USDC), address(queue), 12e6);
        deal(address(USDG0), address(queue), 12e6);

        // Force refund and process a bunch of orders
        vm.startPrank(owner);
        queue.forceRefund(1);
        queue.forceRefund(2);
        queue.forceRefund(11);
        queue.forceRefund(12);
        vm.stopPrank();

        uint256 totalUSDCForUser = 4e6;
        uint256 totalUSDG0ForUser = 0;
        assertEq(USDC.balanceOf(user1), totalUSDCForUser, "User1 should have their USDC balance back");
        assertEq(
            USDG0.balanceOf(user1), totalUSDG0ForUser, "User1 should have their USDG0 balance from force processing"
        );

        // Process all the orders
        _expectOrderProcessedEvent(3, OneToOneQueue.OrderType.DEFAULT, false, false);
        _expectOrderProcessedEvent(4, OneToOneQueue.OrderType.DEFAULT, false, false);
        _expectOrderProcessedEvent(5, OneToOneQueue.OrderType.DEFAULT, false, false);
        _expectOrderProcessedEvent(6, OneToOneQueue.OrderType.DEFAULT, false, false);
        _expectOrderProcessedEvent(7, OneToOneQueue.OrderType.DEFAULT, false, false);
        _expectOrderProcessedEvent(8, OneToOneQueue.OrderType.DEFAULT, false, false);
        _expectOrderProcessedEvent(9, OneToOneQueue.OrderType.DEFAULT, false, false);
        _expectOrderProcessedEvent(10, OneToOneQueue.OrderType.DEFAULT, false, false);
        queue.processOrders(12);
        totalUSDG0ForUser += 8e6 - (8e6 * TEST_OFFER_FEE_PERCENTAGE / 10_000);
        // processing
        assertEq(USDC.balanceOf(user1), totalUSDCForUser, "User1 should have their USDC balance back");
        assertEq(USDG0.balanceOf(user1), totalUSDG0ForUser, "User1 should have their USDG0 balance");
    }

    function testOrdersForceProcessFirstAndLast() external {
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();

        // ensure queue has plenty of balance to refund and process orders
        deal(address(USDC), address(queue), 12e6);
        deal(address(USDG0), address(queue), 12e6);

        // Force refund and process a bunch of orders
        vm.startPrank(owner);
        _expectOrderProcessedEvent(1, OneToOneQueue.OrderType.PRE_FILLED, true, false);
        queue.forceProcess(1);
        _expectOrderProcessedEvent(2, OneToOneQueue.OrderType.PRE_FILLED, true, false);
        queue.forceProcess(2);
        _expectOrderProcessedEvent(11, OneToOneQueue.OrderType.PRE_FILLED, true, false);
        queue.forceProcess(11);
        _expectOrderProcessedEvent(12, OneToOneQueue.OrderType.PRE_FILLED, true, false);
        queue.forceProcess(12);
        vm.stopPrank();

        uint256 totalUSDCForUser = 0;
        uint256 totalUSDG0ForUser = 4e6 - (4e6 * TEST_OFFER_FEE_PERCENTAGE / 10_000);
        assertEq(USDC.balanceOf(user1), totalUSDCForUser, "User1 should have their USDC balance back");
        assertEq(
            USDG0.balanceOf(user1), totalUSDG0ForUser, "User1 should have their USDG0 balance from force processing"
        );

        // Process all the orders
        queue.processOrders(12);
        totalUSDG0ForUser += 8e6 - (8e6 * TEST_OFFER_FEE_PERCENTAGE / 10_000);
        // processing
        assertEq(USDC.balanceOf(user1), totalUSDCForUser, "User1 should have their USDC balance back");
        assertEq(USDG0.balanceOf(user1), totalUSDG0ForUser, "User1 should have their USDG0 balance");
    }

    function testManyOrdersAllForceRefund() external {
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();

        deal(address(USDC), address(queue), 12e6);

        vm.startPrank(owner);
        uint256[] memory orderIndices = new uint256[](12);
        orderIndices[0] = 1;
        orderIndices[1] = 2;
        orderIndices[2] = 3;
        orderIndices[3] = 4;
        orderIndices[4] = 5;
        orderIndices[5] = 6;
        orderIndices[6] = 7;
        orderIndices[7] = 8;
        orderIndices[8] = 9;
        orderIndices[9] = 10;
        orderIndices[10] = 11;
        orderIndices[11] = 12;
        queue.forceRefundOrders(orderIndices);
        vm.stopPrank();

        assertEq(USDC.balanceOf(user1), 12e6, "User1 should have their USDC balance from force processing");
        assertEq(USDG0.balanceOf(user1), 0, "User1 should have no USDG0");
        assertEq(queue.lastProcessedOrder(), 0, "Last processed order should be 0");
        queue.processOrders(12);
        assertEq(queue.lastProcessedOrder(), 12, "Last processed order should be the total number of orders");
    }

    function testManyOrdersAllForceProcess() external {
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();

        deal(address(USDG0), address(queue), 12e6);

        vm.startPrank(owner);
        uint256[] memory orderIndices = new uint256[](12);
        orderIndices[0] = 1;
        orderIndices[1] = 2;
        orderIndices[2] = 3;
        orderIndices[3] = 4;
        orderIndices[4] = 5;
        orderIndices[5] = 6;
        orderIndices[6] = 7;
        orderIndices[7] = 8;
        orderIndices[8] = 9;
        orderIndices[9] = 10;
        orderIndices[10] = 11;
        orderIndices[11] = 12;
        _expectOrderProcessedEvent(1, OneToOneQueue.OrderType.PRE_FILLED, true, false);
        _expectOrderProcessedEvent(2, OneToOneQueue.OrderType.PRE_FILLED, true, false);
        _expectOrderProcessedEvent(3, OneToOneQueue.OrderType.PRE_FILLED, true, false);
        _expectOrderProcessedEvent(4, OneToOneQueue.OrderType.PRE_FILLED, true, false);
        _expectOrderProcessedEvent(5, OneToOneQueue.OrderType.PRE_FILLED, true, false);
        _expectOrderProcessedEvent(6, OneToOneQueue.OrderType.PRE_FILLED, true, false);
        _expectOrderProcessedEvent(7, OneToOneQueue.OrderType.PRE_FILLED, true, false);
        _expectOrderProcessedEvent(8, OneToOneQueue.OrderType.PRE_FILLED, true, false);
        _expectOrderProcessedEvent(9, OneToOneQueue.OrderType.PRE_FILLED, true, false);
        _expectOrderProcessedEvent(10, OneToOneQueue.OrderType.PRE_FILLED, true, false);
        _expectOrderProcessedEvent(11, OneToOneQueue.OrderType.PRE_FILLED, true, false);
        _expectOrderProcessedEvent(12, OneToOneQueue.OrderType.PRE_FILLED, true, false);
        queue.forceProcessOrders(orderIndices);
        vm.stopPrank();

        assertEq(
            USDG0.balanceOf(user1),
            12e6 - (12e6 * TEST_OFFER_FEE_PERCENTAGE / 10_000),
            "User1 should have their USDG0 balance from force processing"
        );
        assertEq(queue.lastProcessedOrder(), 0, "Last processed order should be 0");
        queue.processOrders(12);
        assertEq(queue.lastProcessedOrder(), 12, "Last processed order should be the total number of orders");
    }

    /**
     * @dev orders to place refers to:
     * 0: normal order
     * 1: refund order
     * 2: force process order
     */
    function testManyOrdersFuzz(uint8[] memory ordersToPlace) external {
        if (ordersToPlace.length == 0) {
            vm.expectRevert(abi.encodeWithSelector(OneToOneQueue.InvalidOrdersCount.selector, 0));
            queue.processOrders(0);
            return;
        }
        // Deal massive amounts of tokens to the queue
        deal(address(USDC), address(queue), 100e18);
        deal(address(USDG0), address(queue), 100e18);

        uint256 refundCount;
        uint256 forceProcessCount;
        // Helps avoid deal override of USDC balance.
        address refundReceiver = makeAddr("refundReceiverTest");

        for (uint256 i; i < ordersToPlace.length; i++) {
            uint8 orderType = ordersToPlace[i] % 2;
            _submitAnOrder();
            if (orderType == 0) {
                vm.prank(owner);
                queue.forceRefund(i + 1);
                // do a transfer so we can keep using helper _submitAnOrder which just uses the user1 as the refund
                // receiver
                vm.prank(user1);
                USDC.transfer(refundReceiver, 1e6);
                refundCount++;
            } else if (orderType == 1) {
                vm.startPrank(owner);
                _expectOrderProcessedEvent(i + 1, OneToOneQueue.OrderType.PRE_FILLED, true, false);
                queue.forceProcess(i + 1);
                vm.stopPrank();
                forceProcessCount++;
            }
        }
        uint256 USDG0FromForceProcessing =
            forceProcessCount * 1e6 - forceProcessCount * 1e6 * TEST_OFFER_FEE_PERCENTAGE / 10_000;
        uint256 totalUSDCForUser = refundCount * 1e6;
        assertEq(
            USDG0.balanceOf(user1),
            USDG0FromForceProcessing,
            "User1 should have their USDG0 balance from force processing"
        );
        assertEq(USDC.balanceOf(refundReceiver), totalUSDCForUser, "User1 should have their USDC balance back");

        // Process all the orders
        queue.processOrders(ordersToPlace.length);
        assertEq(
            queue.lastProcessedOrder(),
            ordersToPlace.length,
            "Last processed order should be the total number of orders"
        );

        uint256 totalUSDG0ForUser = (ordersToPlace.length - refundCount) * 1e6 - (ordersToPlace.length - refundCount)
            * 1e6 * TEST_OFFER_FEE_PERCENTAGE / 10_000;
        assertEq(
            USDG0.balanceOf(user1), totalUSDG0ForUser, "User1 should have their total USDG0 balance after processing"
        );
    }

}

