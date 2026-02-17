// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { BaseWithdrawQueueTest } from "../BaseWithdrawQueueTest.t.sol";
import { WithdrawQueueHandler } from "./WithdrawQueueHandler.t.sol";
import { WithdrawQueue } from "src/base/Roles/WithdrawQueue.sol";
import { console } from "forge-std/console.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";

/**
 * @title WithdrawQueueInvariantTest
 * @notice Invariant tests for the WithdrawQueue using coverage-guided fuzzing
 * @dev This test maintains "perfect solvency" - the vault always has exactly
 *      what the exchange rate says it should have. Any revert indicates incorrect
 *      accounting in the WithdrawQueue.
 */
contract WithdrawQueueInvariantTest is BaseWithdrawQueueTest {

    WithdrawQueueHandler public handler;

    // Create multiple actors for realistic multi-user testing
    address[] public actors;

    function setUp() public override {
        super.setUp();

        // Initialize actors
        actors = new address[](5);
        actors[0] = makeAddr("actor1");
        actors[1] = makeAddr("actor2");
        actors[2] = makeAddr("actor3");
        actors[3] = makeAddr("actor4");
        actors[4] = makeAddr("actor5");

        // Deploy handler
        handler = new WithdrawQueueHandler(
            withdrawQueue, boringVault, accountant, ERC20(address(USDC)), owner, feeRecipient, actors
        );

        // Target only the handler for invariant testing
        targetContract(address(handler));
    }

    // ========================================
    // Core Invariants
    // ========================================

    /**
     * @notice The primary invariant: shares accounting must balance
     * @dev Total submitted = processed + refunded + pending + fees
     */
    function invariant_shareAccountingBalance() public view {
        uint256 pendingShares = handler.getPendingShares();

        uint256 leftSide = handler.ghost_sumSharesSubmitted();
        uint256 rightSide = handler.ghost_sumSharesProcessed() + handler.ghost_sumSharesRefunded()
            + handler.ghost_sumSharesFees() + pendingShares;

        assertEq(leftSide, rightSide, "Share accounting must balance");
    }

    /**
     * @notice Queue share balance: queue should hold exactly the pending shares
     * @dev This ensures no shares are lost or stuck in the queue
     */
    function invariant_queueShareBalance() public view {
        uint256 queueShareBalance = boringVault.balanceOf(address(withdrawQueue));
        uint256 pendingShares = handler.getPendingShares();

        assertEq(queueShareBalance, pendingShares, "Queue should hold exactly pending shares");
    }

    /**
     * @notice Order status integrity: All orders <= lastProcessed should not be pending
     */
    function invariant_orderStatusIntegrity() public view {
        uint256 lastProcessed = withdrawQueue.lastProcessedOrder();
        uint256 latest = withdrawQueue.latestOrder();

        // All orders <= lastProcessed should not be pending
        for (uint256 i = 1; i <= lastProcessed && i <= latest; i++) {
            WithdrawQueue.OrderStatus status = withdrawQueue.getOrderStatus(i);
            assertTrue(status != WithdrawQueue.OrderStatus.PENDING, "Processed orders should not be pending");
        }
    }

    /**
     * @notice Fee recipient accumulation: fees should accumulate correctly
     * @dev Fee recipient should have received all fees as shares (transferred, not burned)
     */
    function invariant_feeAccumulation() public view {
        uint256 feeRecipientBalance = boringVault.balanceOf(feeRecipient);
        uint256 totalFees = handler.ghost_sumSharesFees();

        // Fee recipient should have exactly the tracked fees
        assertEq(feeRecipientBalance, totalFees, "Fee recipient should accumulate fees");
        console.log("feeRecipientBalance", feeRecipientBalance);
        console.log("totalFees", totalFees);
    }

    /**
     * @notice Total supply conservation: vault total supply should equal all shares
     * @dev Sum of all user shares + queue shares + fee shares = total supply
     */
    function invariant_totalSupplyConservation() public view {
        uint256 totalSupply = boringVault.totalSupply();

        // Calculate sum of all actor balances + queue + fee recipient
        uint256 sumBalances = boringVault.balanceOf(address(withdrawQueue)) + boringVault.balanceOf(feeRecipient);

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            sumBalances += boringVault.balanceOf(handler.actors(i));
        }

        assertEq(totalSupply, sumBalances, "Total supply should equal sum of balances");
    }

    /**
     * @notice Order monotonicity: latest order should always be >= last processed
     * @dev This ensures the queue processes orders in sequence
     */
    function invariant_orderMonotonicity() public view {
        uint256 lastProcessed = withdrawQueue.lastProcessedOrder();
        uint256 latest = withdrawQueue.latestOrder();

        assertGe(latest, lastProcessed, "Latest order should be >= last processed");
    }

    // ========================================
    // Logging & Metrics
    // ========================================

    /**
     * @notice Log handler metrics after each run
     * @dev Useful for understanding fuzzer behavior and coverage
     */
    function afterInvariant() public view {
        console.log("=== Invariant Test Metrics ===");
        console.log("Submit calls:", handler.ghost_submitCalls());
        console.log("Submit+Process calls:", handler.ghost_submitAndProcessCalls());
        console.log("Process calls:", handler.ghost_processCalls());
        console.log("Cancel calls:", handler.ghost_cancelCalls());
        console.log("Refund calls:", handler.ghost_refundCalls());
        console.log("Update rate calls:", handler.ghost_updateRateCalls());
        console.log("");
        console.log("Total shares submitted:", handler.ghost_sumSharesSubmitted());
        console.log("Total shares processed:", handler.ghost_sumSharesProcessed());
        console.log("Total shares refunded (incl cancelled):", handler.ghost_sumSharesRefunded());
        console.log("Total shares taken as fees:", handler.ghost_sumSharesFees());
        console.log("Pending shares:", handler.getPendingShares());
        console.log("==============================");
    }

}

