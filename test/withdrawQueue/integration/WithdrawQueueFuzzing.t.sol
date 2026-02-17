// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { WithdrawQueue } from "src/base/Roles/WithdrawQueue.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { WithdrawQueueIntegrationBaseTest } from "./WithdrawQueueIntegrationBaseTest.t.sol";

enum ChaosMonkeyAction {
    Submit,
    SubmitAndProcess,
    Process,
    Cancel,
    Refund,
    UpdateExchangeRate
}

contract WithdrawQueueScenarioPathsTest is WithdrawQueueIntegrationBaseTest {

    address[] public userRoundRobin =
        [makeAddr("user1"), makeAddr("user2"), makeAddr("user3"), makeAddr("user4"), makeAddr("user5")];

    function test_HappyPathsWithExchangeRateChanges(uint96 r0, uint96 r2) external {
        // r0 = rate at time of submission
        // r1 = rate at time of refund or force process
        // r2 = rate at time of process
        r0 = (r0 % uint96(10 * 10 ** accountant.decimals())) + 1;
        r2 = (r2 % uint96(10 * 10 ** accountant.decimals())) + 1;

        // happy path (normal process)
        _happySubmitAndProcessAllPath(1e6, r0);
        _happyPath(1e6, r0, r2);
    }

    function test_CancelPathWithExchangeRateChanges(uint96 r0, uint96 r1, uint96 r2) external {
        // r0 = rate at time of submission
        // r1 = rate at time of refund or force process
        // r2 = rate at time of process
        r0 = (r0 % uint96(10 * 10 ** accountant.decimals())) + 1;
        r1 = (r1 % uint96(10 * 10 ** accountant.decimals())) + 1;
        r2 = (r2 % uint96(10 * 10 ** accountant.decimals())) + 1;

        // cancel path (user cancels and then gets processed)
        _cancelPath(1e6, r0, r1, r2);
    }

    function test_ForceProcessPathWithExchangeRateChanges(uint96 r0, uint96 r1, uint96 r2) external {
        // r0 = rate at time of submission
        // r1 = rate at time of refund or force process
        // r2 = rate at time of process
        r0 = (r0 % uint96(10 * 10 ** accountant.decimals())) + 1;
        r1 = (r1 % uint96(10 * 10 ** accountant.decimals())) + 1;
        r2 = (r2 % uint96(10 * 10 ** accountant.decimals())) + 1;

        // force process path (user forces process and then gets processed)
        _forceProcessPath(1e6, r0, r1, r2);
    }

    /**
     * Chaos Monkey test that runs a sequential series of "actions" on the queue.
     * Chaos Monkey also uses random values and users in doing so based on the entropy provided. This value is
     * constantly hashed to generate new pseudo-random values for things like amounts or rate changes
     * Importantly to note is that this does not assert anything. The purpose here is to assert that the queue does not
     * "break" under any random conditions.
     * a "break" would consist of the queue attempting to transfer shares or assets it does not have. Or getting stuck
     * Chaos Monkey asserts there is always enough assets in the vault to cover orders by re-dealing on any
     * potential process including action based on the current exchange rate.
     */
    function test_ChaosMonkey(uint8[] calldata actions, bytes32 entropy) external {
        for (uint256 i; i < actions.length; i++) {
            entropy = keccak256(abi.encodePacked(entropy, i));
            ChaosMonkeyAction action = ChaosMonkeyAction(actions[i] % (uint8(type(ChaosMonkeyAction).max) + 1));

            uint256 userIndex = uint256(entropy) % userRoundRobin.length;
            entropy = keccak256(abi.encodePacked(entropy));
            address user = userRoundRobin[userIndex];

            uint256 supply = withdrawQueue.totalSupply();

            if (action == ChaosMonkeyAction.Submit) {
                uint256 shares = (uint256(entropy) % 100_000_000e6) + 1;
                // We deal the user shares as the vault will be dealt assets per it's rate later
                deal(address(boringVault), user, shares, true);

                vm.startPrank(user);
                boringVault.approve(address(withdrawQueue), shares);
                withdrawQueue.submitOrder(
                    WithdrawQueue.SubmitOrderParams({
                        amountOffer: shares,
                        wantAsset: USDC,
                        intendedDepositor: user,
                        receiver: user,
                        refundReceiver: user,
                        signatureParams: defaultSignatureParams
                    })
                );
                vm.stopPrank();
            } else if (action == ChaosMonkeyAction.SubmitAndProcess) {
                uint256 shares = (uint256(entropy) % 100_000_000e6) + 1;
                // We deal the user shares as the vault will be dealt assets per it's rate later
                deal(address(boringVault), user, shares, true);
                // Deal the vault the USDC balance as it should be at the current rate
                deal(address(USDC), address(boringVault), _convertSharesToUSDC(boringVault.totalSupply()), true);

                // We know this will always pass as the vault always has enough USDC on hand in this scenario
                vm.startPrank(user);
                boringVault.approve(address(withdrawQueue), shares);
                withdrawQueue.submitOrderAndProcessAll(
                    WithdrawQueue.SubmitOrderParams({
                        amountOffer: shares,
                        wantAsset: USDC,
                        intendedDepositor: user,
                        receiver: user,
                        refundReceiver: user,
                        signatureParams: defaultSignatureParams
                    })
                );
                vm.stopPrank();
            } else if (action == ChaosMonkeyAction.Process) {
                if (supply == 0) continue;
                // Deal the vault the USDC balance as it should be at the current rate
                deal(address(USDC), address(boringVault), _convertSharesToUSDC(boringVault.totalSupply()), true);
                // We add 1 to the order to process as orders start at index 1
                uint256 orderToProcess = (uint256(entropy) % supply) + 1;
                // Skip if the order is 0 or already processed/cancelled/refunded
                if (withdrawQueue.getOrderStatus(orderToProcess) != WithdrawQueue.OrderStatus.PENDING) continue;
                vm.startPrank(user);
                // We know this will always pass as the vault always has enough USDC on hand in this scenario
                withdrawQueue.processOrders(orderToProcess);
                vm.stopPrank();
            } else if (action == ChaosMonkeyAction.Cancel) {
                if (supply == 0) continue;
                uint256 orderToCancel = (uint256(entropy) % supply) + 1 + withdrawQueue.lastProcessedOrder();
                // Skip if the order is 0 or already processed/cancelled/refunded
                if (withdrawQueue.getOrderStatus(orderToCancel) != WithdrawQueue.OrderStatus.PENDING) continue;
                vm.startPrank(withdrawQueue.ownerOf(orderToCancel));
                withdrawQueue.cancelOrder(orderToCancel);
                vm.stopPrank();
            } else if (action == ChaosMonkeyAction.Refund) {
                if (supply == 0) continue;
                uint256 orderToRefund = (uint256(entropy) % supply) + 1 + withdrawQueue.lastProcessedOrder();
                // Skip if the order is 0 or already processed/cancelled/refunded
                if (withdrawQueue.getOrderStatus(orderToRefund) != WithdrawQueue.OrderStatus.PENDING) continue;
                vm.startPrank(owner);
                withdrawQueue.refundOrder(orderToRefund);
                vm.stopPrank();
            } else if (action == ChaosMonkeyAction.UpdateExchangeRate) {
                uint256 currentRate = accountant.getRate();
                uint256 minRate = currentRate * 9990 / 10_000; // 99.9% of current rate
                uint256 maxRate = currentRate * 10_010 / 10_000; // 100.1% of current rate
                uint256 rateRange = maxRate - minRate + 1;
                uint256 newRate = minRate + (uint256(entropy) % rateRange);
                _updateExchangeRate(uint96(newRate));
            }
        }
    }

}
