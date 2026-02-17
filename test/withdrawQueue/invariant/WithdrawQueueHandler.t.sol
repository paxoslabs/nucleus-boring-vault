// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Test } from "@forge-std/Test.sol";
import { WithdrawQueue } from "src/base/Roles/WithdrawQueue.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";

contract WithdrawQueueHandler is Test {

    using FixedPointMathLib for uint256;

    // Core contracts
    WithdrawQueue public withdrawQueue;
    BoringVault public boringVault;
    AccountantWithRateProviders public accountant;
    ERC20 public USDC;
    address public owner;
    address public feeRecipient;

    // Actor management
    address[] public actors;
    address internal currentActor;
    uint256 public actorCount;

    // Default signature params
    WithdrawQueue.SignatureParams internal defaultSignatureParams;

    // Ghost variables for tracking cumulative state
    uint256 public ghost_sumSharesSubmitted;
    uint256 public ghost_sumSharesProcessed;
    uint256 public ghost_sumSharesRefunded; // Includes both cancelled and refunded orders
    uint256 public ghost_sumSharesFees; // Shares taken as fees

    // Call tracking
    uint256 public ghost_submitCalls;
    uint256 public ghost_processCalls;
    uint256 public ghost_cancelCalls;
    uint256 public ghost_refundCalls;
    uint256 public ghost_submitAndProcessCalls;
    uint256 public ghost_updateRateCalls;
    uint256 public ghost_failedTransferCount; // Count of orders that failed during processing

    modifier useActor(uint256 actorIndexSeed) {
        currentActor = actors[bound(actorIndexSeed, 0, actors.length - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    constructor(
        WithdrawQueue _withdrawQueue,
        BoringVault _boringVault,
        AccountantWithRateProviders _accountant,
        ERC20 _USDC,
        address _owner,
        address _feeRecipient,
        address[] memory _actors
    ) {
        withdrawQueue = _withdrawQueue;
        boringVault = _boringVault;
        accountant = _accountant;
        USDC = _USDC;
        owner = _owner;
        feeRecipient = _feeRecipient;
        actors = _actors;
        // included since we can't query the length of the array externally
        actorCount = _actors.length;

        defaultSignatureParams = WithdrawQueue.SignatureParams({
            approvalMethod: WithdrawQueue.ApprovalMethod.EIP20_APPROVE,
            approvalV: 0,
            approvalR: bytes32(0),
            approvalS: bytes32(0),
            submitWithSignature: false,
            deadline: block.timestamp + 1000,
            eip2612Signature: ""
        });
    }

    // ========================================
    // Handler Functions
    // ========================================

    /**
     * @notice Submit a withdraw order
     * @dev Deals shares to the actor and submits an order
     */
    function submit(uint256 sharesSeed, uint256 actorSeed) public useActor(actorSeed) {
        uint256 shares = bound(sharesSeed, 1, 100_000_000e6);

        // Deal shares to user (simulating they have them)
        deal(address(boringVault), currentActor, shares, true);

        // Approve and submit
        boringVault.approve(address(withdrawQueue), shares);

        try withdrawQueue.submitOrder(
            WithdrawQueue.SubmitOrderParams({
                amountOffer: shares,
                wantAsset: IERC20(address(USDC)),
                intendedDepositor: currentActor,
                receiver: currentActor,
                refundReceiver: currentActor,
                signatureParams: defaultSignatureParams
            })
        ) {
            ghost_sumSharesSubmitted += shares;
            ghost_submitCalls++;
        } catch {
            // If it reverts, that's ok but don't increment the submit calls or shares
        }
    }

    /**
     * @notice Submit and process all orders
     * @dev Maintains perfect solvency by dealing exact USDC before processing
     */
    function submitAndProcess(uint256 sharesSeed, uint256 actorSeed) public useActor(actorSeed) {
        uint256 shares = bound(sharesSeed, 1, 100_000_000e6);

        // Deal shares to user
        deal(address(boringVault), currentActor, shares, true);

        // Deal vault perfect solvency BEFORE processing
        // This ensures vault has exactly what the rate says it should have
        uint256 totalShares = boringVault.totalSupply();
        uint256 expectedUSDC = _convertSharesToUSDC(totalShares);
        deal(address(USDC), address(boringVault), expectedUSDC, true);

        // Track pending orders BEFORE submit to know what gets processed
        uint256 lastProcessed = withdrawQueue.lastProcessedOrder();
        uint256 latestBefore = withdrawQueue.latestOrder();

        // Approve and submit+process
        boringVault.approve(address(withdrawQueue), shares);

        try withdrawQueue.submitOrderAndProcessAll(
            WithdrawQueue.SubmitOrderParams({
                amountOffer: shares,
                wantAsset: IERC20(address(USDC)),
                intendedDepositor: currentActor,
                receiver: currentActor,
                refundReceiver: currentActor,
                signatureParams: defaultSignatureParams
            })
        ) {
            // Track the newly submitted shares
            ghost_sumSharesSubmitted += shares;

            // submitOrderAndProcessAll processes ALL pending orders including the new one
            // We need to track ALL processed orders, not just the new one
            uint256 newLastProcessed = withdrawQueue.lastProcessedOrder();

            // Process all orders that were processed (from lastProcessed to newLastProcessed)
            for (uint256 i = lastProcessed + 1; i <= newLastProcessed; i++) {
                WithdrawQueue.Order memory order = _getOrder(i);
                _trackProcessedOrder(order);
            }

            ghost_submitAndProcessCalls++;
        } catch { }
    }

    /**
     * @notice Process pending orders
     * @dev Maintains perfect solvency by dealing exact USDC before processing
     */
    function process(uint256 orderSeed) public {
        uint256 supply = withdrawQueue.totalSupply();
        if (supply == 0) return;

        // Deal vault perfect solvency BEFORE processing
        uint256 totalShares = boringVault.totalSupply();
        uint256 expectedUSDC = _convertSharesToUSDC(totalShares);
        deal(address(USDC), address(boringVault), expectedUSDC, true);

        uint256 lastProcessed = withdrawQueue.lastProcessedOrder();
        uint256 latest = withdrawQueue.latestOrder();

        if (lastProcessed >= latest) return;

        uint256 orderToProcess = bound(orderSeed, lastProcessed + 1, latest);

        // Calculate how many orders will be processed (from lastProcessed+1 to orderToProcess)
        uint256 ordersToProcess = orderToProcess - lastProcessed;

        try withdrawQueue.processOrders(ordersToProcess) {
            // Track all orders that were processed
            for (uint256 i = lastProcessed + 1; i <= orderToProcess; i++) {
                WithdrawQueue.Order memory order = _getOrder(i);
                _trackProcessedOrder(order);
            }
            ghost_processCalls++;
        } catch {
            // Revert is ok in fuzzing mode
        }
    }

    /**
     * @notice Cancel a pending order
     * @dev Marks the order as REFUND. Shares are tracked when the order is processed.
     */
    function cancel(uint256 orderSeed, uint256 actorSeed) public useActor(actorSeed) {
        uint256 supply = withdrawQueue.totalSupply();
        if (supply == 0) return;

        uint256 lastProcessed = withdrawQueue.lastProcessedOrder();
        uint256 latest = withdrawQueue.latestOrder();

        if (lastProcessed >= latest) return;

        uint256 orderToCancel = bound(orderSeed, lastProcessed + 1, latest);

        // Skip if not pending (like if it's already been cancelled or refunded)
        if (withdrawQueue.getOrderStatus(orderToCancel) != WithdrawQueue.OrderStatus.PENDING) {
            return;
        }

        try withdrawQueue.cancelOrder(orderToCancel) {
            // Order is now marked as REFUND - shares will be tracked when processed
            ghost_cancelCalls++;
        } catch { }
    }

    /**
     * @notice Refund an order (owner action)
     * @dev Marks the order as REFUND. Shares are tracked when the order is processed.
     */
    function refund(uint256 orderSeed) public {
        uint256 supply = withdrawQueue.totalSupply();
        if (supply == 0) return;

        uint256 lastProcessed = withdrawQueue.lastProcessedOrder();
        uint256 latest = withdrawQueue.latestOrder();

        if (lastProcessed >= latest) return;

        uint256 orderToRefund = bound(orderSeed, lastProcessed + 1, latest);

        // Skip if not pending (like if it's already been refunded)
        if (withdrawQueue.getOrderStatus(orderToRefund) != WithdrawQueue.OrderStatus.PENDING) {
            return;
        }

        vm.startPrank(owner);
        try withdrawQueue.refundOrder(orderToRefund) {
            // Order is now marked as REFUND - shares will be tracked when processed
            ghost_refundCalls++;
        } catch { }
        vm.stopPrank();
    }

    /**
     * @notice Update the exchange rate
     * @dev Constrains rate changes to ±0.1% of current rate for realistic testing
     */
    function updateExchangeRate(uint256 rateSeed) public {
        uint256 currentRate = accountant.getRate();

        // Bound to ±0.1% of current rate for rate changes within bounds
        uint256 minRate = currentRate * 9990 / 10_000;
        uint256 maxRate = currentRate * 10_010 / 10_000;
        uint256 rateRange = maxRate - minRate + 1;
        uint256 newRate = minRate + (rateSeed % rateRange);

        vm.startPrank(owner);
        try accountant.updateExchangeRate(uint96(newRate)) {
            // In case the accountant pauses on update, unpause it
            try accountant.unpause() { } catch { }
            ghost_updateRateCalls++;
        } catch {
            // Rate update can fail if bounds are exceeded
        }
        vm.stopPrank();
    }

    // ========================================
    // Helper Functions
    // ========================================

    /**
     * @notice Helper to get Order struct from orderAtQueueIndex mapping
     * @dev Solidity returns tuples from public mappings, not structs
     */
    function _getOrder(uint256 orderIndex) internal view returns (WithdrawQueue.Order memory order) {
        (
            uint256 amountOffer,
            IERC20 wantAsset,
            address refundReceiver,
            WithdrawQueue.OrderType orderType,
            bool didOrderFailTransfer
        ) = withdrawQueue.orderAtQueueIndex(orderIndex);

        order = WithdrawQueue.Order({
            amountOffer: amountOffer,
            wantAsset: wantAsset,
            refundReceiver: refundReceiver,
            orderType: orderType,
            didOrderFailTransfer: didOrderFailTransfer
        });
    }

    function _convertSharesToUSDC(uint256 shares) internal view returns (uint256) {
        return shares.mulDivDown(accountant.getRateInQuoteSafe(USDC), 10 ** boringVault.decimals());
    }

    function _calculateFees(uint256 shares) internal pure returns (uint256) {
        // Fee is 0.1% (10 basis points out of 10000)
        return shares.mulDivUp(10, 10_000);
    }

    /**
     * @notice Track accounting for a processed order
     * @dev Handles ghost variable updates for all order types
     */
    function _trackProcessedOrder(WithdrawQueue.Order memory order) internal {
        // Track based on order type
        if (order.orderType == WithdrawQueue.OrderType.DEFAULT) {
            // Only count fees if the transfer didn't fail
            if (!order.didOrderFailTransfer) {
                uint256 fees = _calculateFees(order.amountOffer);
                uint256 sharesAfterFees = order.amountOffer - fees;
                ghost_sumSharesProcessed += sharesAfterFees;
                ghost_sumSharesFees += fees;
            } else {
                // Failed transfers are accounted in tests like a refund (no fees taken)
                ghost_sumSharesRefunded += order.amountOffer;
                ghost_failedTransferCount++;
            }
        } else if (order.orderType == WithdrawQueue.OrderType.REFUND) {
            // REFUND orders return shares (both cancelled and refunded end up here)
            ghost_sumSharesRefunded += order.amountOffer;
        }
    }

    // ========================================
    // View Functions for Invariant Checks
    // ========================================

    function getPendingShares() public view returns (uint256 pending) {
        uint256 lastProcessed = withdrawQueue.lastProcessedOrder();
        uint256 latest = withdrawQueue.latestOrder();

        for (uint256 i = lastProcessed + 1; i <= latest; i++) {
            WithdrawQueue.OrderStatus status = withdrawQueue.getOrderStatus(i);
            // Count both PENDING and PENDING_REFUND because shares are still in queue
            if (status == WithdrawQueue.OrderStatus.PENDING || status == WithdrawQueue.OrderStatus.PENDING_REFUND) {
                pending += _getOrder(i).amountOffer;
            }
        }
    }

}

