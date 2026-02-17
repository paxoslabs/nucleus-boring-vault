// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { BaseWithdrawQueueTest } from "../BaseWithdrawQueueTest.t.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { BaseWithdrawQueueTest, console } from "../BaseWithdrawQueueTest.t.sol";
import { WithdrawQueue } from "src/base/Roles/WithdrawQueue.sol";
import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";

contract WithdrawQueueIntegrationBaseTest is BaseWithdrawQueueTest {

    using FixedPointMathLib for uint256;

    function _forceProcessPath(uint256 depositAmount, uint96 r0, uint96 r1, uint96 r2) internal {
        _updateExchangeRate(r0);
        uint256 expectedShares = _convertUSDCToShares(depositAmount);

        deal(address(USDC), user, depositAmount);

        vm.startPrank(user);
        USDC.approve(address(boringVault), depositAmount);

        teller.deposit(ERC20(address(USDC)), depositAmount, 0);

        assertEq(boringVault.balanceOf(user), expectedShares, "user should have shares");

        boringVault.approve(address(withdrawQueue), expectedShares);
        withdrawQueue.submitOrder(
            WithdrawQueue.SubmitOrderParams({
                amountOffer: expectedShares,
                wantAsset: USDC,
                intendedDepositor: user,
                receiver: user,
                refundReceiver: user,
                signatureParams: defaultSignatureParams
            })
        );
        vm.stopPrank();
        _updateExchangeRate(r1);
        deal(address(USDC), address(boringVault), _convertSharesToUSDC(expectedShares));

        uint256 expectedValOfSharesAfterFees = _convertSharesToUSDC(_getAmountAfterFees(expectedShares));

        vm.startPrank(owner);
        withdrawQueue.forceProcess(withdrawQueue.latestOrder());
        vm.stopPrank();

        _updateExchangeRate(r2);
        withdrawQueue.processOrders(1);

        assertEq(USDC.balanceOf(user), expectedValOfSharesAfterFees, "user should have USDC - fees");
    }

    function _cancelPath(uint256 depositAmount, uint96 r0, uint96 r1, uint96 r2) internal {
        _updateExchangeRate(r0);
        uint256 expectedShares = _convertUSDCToShares(depositAmount);

        deal(address(USDC), user, depositAmount);

        vm.startPrank(user);
        USDC.approve(address(boringVault), depositAmount);

        teller.deposit(ERC20(address(USDC)), depositAmount, 0);

        assertEq(boringVault.balanceOf(user), expectedShares, "user should have shares");

        boringVault.approve(address(withdrawQueue), expectedShares);
        withdrawQueue.submitOrder(
            WithdrawQueue.SubmitOrderParams({
                amountOffer: expectedShares,
                wantAsset: USDC,
                intendedDepositor: user,
                receiver: user,
                refundReceiver: user,
                signatureParams: defaultSignatureParams
            })
        );
        vm.stopPrank();
        _updateExchangeRate(r1);

        vm.startPrank(user);
        withdrawQueue.cancelOrder(withdrawQueue.latestOrder());
        vm.stopPrank();

        _updateExchangeRate(r2);
        withdrawQueue.processOrders(1);

        assertEq(boringVault.balanceOf(user), expectedShares, "user should have all shares refunded");
        assertEq(USDC.balanceOf(user), 0, "user should have no USDC");
    }

    function _happySubmitAndProcessAllPath(uint256 depositAmount, uint96 r0) internal {
        uint256 shareBalanceOfQueueStart = boringVault.balanceOf(address(withdrawQueue));
        uint256 feeRecipientShareBalanceStart = boringVault.balanceOf(feeRecipient);
        uint256 vaultUSDCBalanceStart = USDC.balanceOf(address(boringVault));
        uint256 userShareBalanceStart = boringVault.balanceOf(user);
        uint256 totalSupplyStart = withdrawQueue.totalSupply();

        _updateExchangeRate(r0);

        uint256 expectedShares = _convertUSDCToShares(depositAmount);

        deal(address(USDC), user, depositAmount);

        vm.startPrank(user);
        USDC.approve(address(boringVault), depositAmount);

        teller.deposit(ERC20(address(USDC)), depositAmount, 0);

        assertEq(boringVault.balanceOf(user) - userShareBalanceStart, expectedShares, "user should have shares");

        boringVault.approve(address(withdrawQueue), expectedShares);
        console.log("vault USDC Balance", USDC.balanceOf(address(boringVault)));
        console.log("USDC expected before fees", _convertSharesToUSDC(expectedShares));

        withdrawQueue.submitOrderAndProcessAll(
            WithdrawQueue.SubmitOrderParams({
                amountOffer: expectedShares,
                wantAsset: USDC,
                intendedDepositor: user,
                receiver: user,
                refundReceiver: user,
                signatureParams: defaultSignatureParams
            })
        );

        vm.stopPrank();
        assertEq(boringVault.balanceOf(user) - userShareBalanceStart, 0, "user should have no shares");

        uint256 userSharesAfterFees = _getAmountAfterFees(expectedShares);
        uint256 expectedValOfSharesAfterFees = _convertSharesToUSDC(userSharesAfterFees);

        // If the value change is so drastic that the user withdraw amount is 0, expect InvalidAssetsOut error
        console.log("expectedValOfSharesAfterFees", expectedValOfSharesAfterFees);
        assertEq(USDC.balanceOf(user), expectedValOfSharesAfterFees, "User should have USDC - fees");
        assertEq(
            boringVault.balanceOf(feeRecipient) - feeRecipientShareBalanceStart,
            _getFees(expectedShares),
            "fee recipient should have fees"
        );
        assertEq(withdrawQueue.totalSupply(), 0, "total supply should be 0");
    }

    function _happyPath(uint256 depositAmount, uint96 r0, uint96 r2) internal {
        uint256 shareBalanceOfQueueStart = boringVault.balanceOf(address(withdrawQueue));
        uint256 feeRecipientShareBalanceStart = boringVault.balanceOf(feeRecipient);
        uint256 vaultUSDCBalanceStart = USDC.balanceOf(address(boringVault));
        uint256 userShareBalanceStart = boringVault.balanceOf(user);
        uint256 totalSupplyStart = withdrawQueue.totalSupply();

        _updateExchangeRate(r0);

        uint256 expectedShares = _convertUSDCToShares(depositAmount);

        deal(address(USDC), user, depositAmount);

        vm.startPrank(user);
        USDC.approve(address(boringVault), depositAmount);

        teller.deposit(ERC20(address(USDC)), depositAmount, 0);

        assertEq(boringVault.balanceOf(user) - userShareBalanceStart, expectedShares, "user should have shares");

        boringVault.approve(address(withdrawQueue), expectedShares);
        withdrawQueue.submitOrder(
            WithdrawQueue.SubmitOrderParams({
                amountOffer: expectedShares,
                wantAsset: USDC,
                intendedDepositor: user,
                receiver: user,
                refundReceiver: user,
                signatureParams: defaultSignatureParams
            })
        );

        vm.stopPrank();
        _updateExchangeRate(r2);
        assertEq(boringVault.balanceOf(user) - userShareBalanceStart, 0, "user should have no shares");
        assertEq(
            boringVault.balanceOf(address(withdrawQueue)),
            expectedShares + shareBalanceOfQueueStart,
            "queue should be holding shares"
        );
        assertEq(USDC.balanceOf(address(boringVault)), depositAmount + vaultUSDCBalanceStart, "vault should have USDC");
        assertEq(withdrawQueue.ownerOf(withdrawQueue.latestOrder()), user, "User should own order latestOrder");
        uint256 ordersCount = withdrawQueue.latestOrder() - withdrawQueue.lastProcessedOrder();

        // Reset the boring vault balance to reflect the new rate
        deal(address(USDC), address(boringVault), _convertSharesToUSDC(expectedShares));

        uint256 userSharesAfterFees = _getAmountAfterFees(expectedShares);
        uint256 expectedValOfSharesAfterFees = _convertSharesToUSDC(userSharesAfterFees);

        // If the value change is so drastic that the user withdraw amount is 0, expect InvalidAssetsOut error
        console.log("expectedValOfSharesAfterFees", expectedValOfSharesAfterFees);
        if (expectedValOfSharesAfterFees == 0) {
            console.log("expectedValOfSharesAfterFees is 0");
            vm.expectRevert(WithdrawQueue.InvalidAssetsOut.selector);
            withdrawQueue.processOrders(ordersCount);
        } else {
            withdrawQueue.processOrders(ordersCount);
            assertEq(USDC.balanceOf(user), expectedValOfSharesAfterFees, "User should have USDC - fees");
            assertEq(
                boringVault.balanceOf(feeRecipient) - feeRecipientShareBalanceStart,
                _getFees(expectedShares),
                "fee recipient should have fees"
            );
            assertEq(withdrawQueue.totalSupply(), 0, "total supply should be 0");
        }
    }

    function _convertUSDCToShares(uint256 usdc) internal view returns (uint256) {
        return usdc.mulDivDown(10 ** boringVault.decimals(), accountant.getRateInQuoteSafe(ERC20(address(USDC))));
    }

    function _convertSharesToUSDC(uint256 shares) internal view returns (uint256) {
        return shares.mulDivDown(accountant.getRateInQuoteSafe(ERC20(address(USDC))), 10 ** boringVault.decimals());
    }

    function _updateExchangeRate(uint96 r) internal {
        vm.startPrank(owner);
        accountant.updateExchangeRate(r);
        // in case the accountant pauses on the update, unpause it
        accountant.unpause();
        vm.stopPrank();
    }

}
