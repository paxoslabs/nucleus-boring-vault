// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { WithdrawQueue } from "src/base/Roles/WithdrawQueue.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { WithdrawQueueIntegrationBaseTest } from "./WithdrawQueueIntegrationBaseTest.t.sol";

contract WithdrawQueueScenarioPathsTest is WithdrawQueueIntegrationBaseTest {

    function testScenario_ExchangeRateToZero() external {
        // Scenario: Accountant exchange rate is 0
        // Users cannot deposit - revert - so we deal them some shares to mimic having deposited earlier
        // Users cannot withdraw via submitAndProcess
        // User can submit
        // User cannot process
        // User can cancel
        // User can process

        vm.startPrank(owner);
        accountant.updateLower(0);
        accountant.updateDelay(0);
        accountant.updateExchangeRate(0);
        vm.stopPrank();
        assertEq(accountant.getRate(), 0, "Exchange rate should be 0");
        vm.startPrank(user);
        USDC.approve(address(boringVault), 1e6);
        vm.expectRevert(address(teller));
        teller.deposit(ERC20(address(USDC)), 1e6, 0);

        deal(address(boringVault), user, 1e6);
        boringVault.approve(address(withdrawQueue), 1e6);

        vm.expectRevert(abi.encodeWithSelector(WithdrawQueue.InvalidAssetsOut.selector));
        withdrawQueue.submitOrderAndProcessAll(
            _createSubmitOrderParams(USDC, 1e6, user, user, user, defaultSignatureParams)
        );

        withdrawQueue.submitOrder(_createSubmitOrderParams(USDC, 1e6, user, user, user, defaultSignatureParams));

        vm.expectRevert(abi.encodeWithSelector(WithdrawQueue.InvalidAssetsOut.selector));
        withdrawQueue.processOrders(1);

        withdrawQueue.cancelOrder(1);
        withdrawQueue.processOrders(1);
        assertEq(boringVault.balanceOf(user), 1e6, "user should have 1e6 shares back");
        vm.stopPrank();
    }

    function testScenario_DifferentReceiver() external {
        // Scenario: User submits an order with a different receiver than themself
        deal(address(boringVault), user, 1e6);
        deal(address(USDC), address(boringVault), 1e6);

        vm.startPrank(user);
        boringVault.approve(address(withdrawQueue), 1e6);
        withdrawQueue.submitOrder(_createSubmitOrderParams(USDC, 1e6, user, user2, user, defaultSignatureParams));
        assertEq(withdrawQueue.ownerOf(1), user2, "user2 should be the owner of the order");
        assertEq(withdrawQueue.totalSupply(), 1, "total supply should be 1");
        vm.stopPrank();

        withdrawQueue.processOrders(1);
        assertEq(USDC.balanceOf(user2), _getAmountAfterFees(1e6), "user2 should have 1e6 USDC - fees");
    }

    function testScenario_DifferentRefundReceiver() external {
        // Scenario: User submits an order with a different refund receiver than themself and cancels
        deal(address(boringVault), user, 1e6);
        deal(address(USDC), address(boringVault), 1e6);
        vm.startPrank(user);
        boringVault.approve(address(withdrawQueue), 1e6);
        withdrawQueue.submitOrder(_createSubmitOrderParams(USDC, 1e6, user, user, user2, defaultSignatureParams));
        withdrawQueue.cancelOrder(1);
        vm.stopPrank();

        withdrawQueue.processOrders(1);
        assertEq(boringVault.balanceOf(user2), 1e6, "user2 should have 1e6 shares");
    }

    function testScenario_QueueFullOfRefunds() external {
        // Scenario: Queue has 5 orders, all refunded. Happy path is still possible from this state
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();

        // Not using the batch refund since it's easier for the test
        vm.startPrank(owner);
        withdrawQueue.refundOrder(1);
        withdrawQueue.refundOrder(2);
        withdrawQueue.refundOrder(3);
        withdrawQueue.refundOrder(4);
        withdrawQueue.refundOrder(5);
        vm.stopPrank();

        _happyPath(1e6, 1e6, 1e6);
        _happySubmitAndProcessAllPath(1e6, 1e6);
    }

    function testScenario_QueueFullOfPreFilledOrders() external {
        // Scenario: Queue has 5 orders, all pre-filled. Happy path is still possible from this state
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();
        _submitAnOrder();

        // Not using the batch force process since it's easier for the test
        vm.startPrank(owner);
        withdrawQueue.forceProcess(1);
        withdrawQueue.forceProcess(2);
        withdrawQueue.forceProcess(3);
        withdrawQueue.forceProcess(4);
        withdrawQueue.forceProcess(5);
        vm.stopPrank();

        _happyPath(1e6, 1e6, 1e6);
        _happySubmitAndProcessAllPath(1e6, 1e6);
    }

}

