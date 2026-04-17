// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Test, stdStorage, StdStorage, stdError, console } from "@forge-std/Test.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { Attestation } from "@predicate/interfaces/IPredicateRegistry.sol";
import { DistributorCodeDepositor } from "src/helper/DistributorCodeDepositor.sol";
import { DirectTransferAddress } from "src/direct-transfer/DirectTransferAddress.sol";
import { BaseDirectTransferTest, MockDCD } from "test/direct-transfer/BaseDirectTransferTest.t.sol";

contract DirectTransferAddressUnitTest is BaseDirectTransferTest {

    uint256 constant DEPOSIT_AMOUNT = 1000e6;

    DirectTransferAddress dta;

    function setUp() public override {
        super.setUp();
        dta = _deployDTA(user);
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_ConstructorSetsImmutables() public {
        DirectTransferAddress freshImpl = new DirectTransferAddress(
            DistributorCodeDepositor(address(mockDCD)), owner, recoveryAccount, ERC20(address(token))
        );

        assertEq(address(freshImpl.DCD()), address(mockDCD), "DCD immutable must match constructor arg");
        assertEq(freshImpl.owner(), owner, "owner immutable must match constructor arg");
        assertEq(freshImpl.recoveryAccount(), recoveryAccount, "recoveryAccount immutable must match constructor arg");
        assertEq(address(freshImpl.token()), address(token), "token immutable must match constructor arg");
    }

    /*//////////////////////////////////////////////////////////////
                               INITIALIZE
    //////////////////////////////////////////////////////////////*/

    function test_InitializeSetsReceiver() public {
        DirectTransferAddress freshImpl = new DirectTransferAddress(
            DistributorCodeDepositor(address(mockDCD)), owner, recoveryAccount, ERC20(address(token))
        );

        freshImpl.initialize(user);

        assertEq(freshImpl.receiver(), user, "receiver must equal initialize argument");
    }

    function test_RevertWhen_InitializeCalledTwice() public {
        DirectTransferAddress freshImpl = new DirectTransferAddress(
            DistributorCodeDepositor(address(mockDCD)), owner, recoveryAccount, ERC20(address(token))
        );
        freshImpl.initialize(user);

        vm.expectRevert(DirectTransferAddress.DirectTransferAddress__AlreadyInitialized.selector, address(freshImpl));
        freshImpl.initialize(user2);
    }

    /*//////////////////////////////////////////////////////////////
                                FORWARD
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_ForwardCallerNotOwner() public {
        Attestation memory emptyAttestation;

        vm.prank(user);
        vm.expectRevert(DirectTransferAddress.DirectTransferAddress__NotOwner.selector, address(dta));
        dta.forward(DEPOSIT_AMOUNT, 0, emptyAttestation);
    }

    function test_ForwardSucceeds() public {
        deal(address(token), address(dta), DEPOSIT_AMOUNT);
        // MockDCD settles shares 1:1 with depositAmount from its pre-funded share pool.
        uint256 expectedShares = DEPOSIT_AMOUNT;
        Attestation memory emptyAttestation;

        _expectForwardedEvent(address(dta), user, DEPOSIT_AMOUNT, expectedShares);
        vm.prank(owner);
        uint256 shares = dta.forward(DEPOSIT_AMOUNT, 0, emptyAttestation);

        assertEq(shares, expectedShares, "returned shares must match mock DCD rate");
        assertEq(token.balanceOf(address(dta)), 0, "DTA token balance must be zero after forward");
        assertEq(token.balanceOf(address(mockDCD)), DEPOSIT_AMOUNT, "DCD must hold the forwarded token");
        assertEq(shareToken.balanceOf(user), expectedShares, "receiver must hold settled shares");
    }

    /*//////////////////////////////////////////////////////////////
                                REFUND
    //////////////////////////////////////////////////////////////*/

    function test_RefundSweepsFullBalanceToReceiver() public {
        deal(address(token), address(dta), DEPOSIT_AMOUNT);

        _expectRefundedEvent(address(dta), user, DEPOSIT_AMOUNT);
        vm.prank(owner);
        dta.refund();

        assertEq(token.balanceOf(address(dta)), 0, "DTA token balance must be zero after refund");
        assertEq(token.balanceOf(user), DEPOSIT_AMOUNT, "receiver must hold swept balance");
    }

    function test_RefundWithZeroBalance() public {
        assertEq(token.balanceOf(address(dta)), 0, "precondition: DTA balance is zero");

        _expectRefundedEvent(address(dta), user, 0);
        vm.prank(owner);
        dta.refund();

        assertEq(token.balanceOf(user), 0, "receiver balance unchanged on zero-amount refund");
    }

    function test_RevertWhen_RefundCallerNotOwner() public {
        vm.prank(user);
        vm.expectRevert(DirectTransferAddress.DirectTransferAddress__NotOwner.selector, address(dta));
        dta.refund();
    }

    /*//////////////////////////////////////////////////////////////
                               RECOVER
    //////////////////////////////////////////////////////////////*/

    function test_RecoverSweepsFullBalanceToRecoveryAccount() public {
        deal(address(token), address(dta), DEPOSIT_AMOUNT);

        _expectRecoveredEvent(address(dta), recoveryAccount, DEPOSIT_AMOUNT);
        vm.prank(owner);
        dta.recover();

        assertEq(token.balanceOf(address(dta)), 0, "DTA token balance must be zero after recover");
        assertEq(token.balanceOf(recoveryAccount), DEPOSIT_AMOUNT, "recoveryAccount must hold swept balance");
    }

    function test_RecoverWithZeroBalance() public {
        assertEq(token.balanceOf(address(dta)), 0, "precondition: DTA balance is zero");

        _expectRecoveredEvent(address(dta), recoveryAccount, 0);
        vm.prank(owner);
        dta.recover();

        assertEq(token.balanceOf(recoveryAccount), 0, "recoveryAccount balance unchanged on zero-amount recover");
    }

    function test_RevertWhen_RecoverCallerNotOwner() public {
        vm.prank(user);
        vm.expectRevert(DirectTransferAddress.DirectTransferAddress__NotOwner.selector, address(dta));
        dta.recover();
    }

}
