// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Test, stdStorage, StdStorage, stdError, console } from "@forge-std/Test.sol";
import { MockERC20 } from "@forge-std/mocks/MockERC20.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { Attestation } from "@predicate/interfaces/IPredicateRegistry.sol";
import { Initializable } from "@openzeppelin-v5.0.1/contracts/proxy/utils/Initializable.sol";
import { BeaconProxy } from "@openzeppelin-v5.0.1/contracts/proxy/beacon/BeaconProxy.sol";
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

    function test_RevertWhen_ConstructorHasZeroAddressArg() public {
        vm.expectRevert(DirectTransferAddress.ZeroAddress.selector);
        new DirectTransferAddress(DistributorCodeDepositor(address(0)), owner, recoveryAccount, ERC20(address(token)));

        vm.expectRevert(abi.encodeWithSelector(DirectTransferAddress.OwnableInvalidOwner.selector, address(0)));
        new DirectTransferAddress(
            DistributorCodeDepositor(address(mockDCD)), address(0), recoveryAccount, ERC20(address(token))
        );

        vm.expectRevert(DirectTransferAddress.ZeroAddress.selector);
        new DirectTransferAddress(DistributorCodeDepositor(address(mockDCD)), owner, address(0), ERC20(address(token)));

        vm.expectRevert(DirectTransferAddress.ZeroAddress.selector);
        new DirectTransferAddress(DistributorCodeDepositor(address(mockDCD)), owner, recoveryAccount, ERC20(address(0)));
    }

    function test_RevertWhen_ConstructorDcdOrTokenHasNoCode() public {
        vm.expectRevert(DirectTransferAddress.NoCode.selector);
        new DirectTransferAddress(
            DistributorCodeDepositor(address(0xBEEF)), owner, recoveryAccount, ERC20(address(token))
        );

        vm.expectRevert(DirectTransferAddress.NoCode.selector);
        new DirectTransferAddress(
            DistributorCodeDepositor(address(mockDCD)), owner, recoveryAccount, ERC20(address(0xCAFE))
        );
    }

    /*//////////////////////////////////////////////////////////////
                               INITIALIZE
    //////////////////////////////////////////////////////////////*/

    function test_InitializeSetsReceiver() public {
        DirectTransferAddress fresh = _deployUninitializedProxy();

        fresh.initialize(user);

        assertEq(fresh.receiver(), user, "receiver must equal initialize argument");
    }

    function test_RevertWhen_InitializeCalledTwice() public {
        DirectTransferAddress fresh = _deployUninitializedProxy();
        fresh.initialize(user);

        vm.expectRevert(Initializable.InvalidInitialization.selector, address(fresh));
        fresh.initialize(user2);
    }

    function test_RevertWhen_InitializeReceiverIsZeroAddress() public {
        DirectTransferAddress fresh = _deployUninitializedProxy();

        vm.expectRevert(DirectTransferAddress.ZeroAddress.selector, address(fresh));
        fresh.initialize(address(0));
    }

    function test_RevertWhen_InitializeCalledOnBareImpl() public {
        // The impl's constructor calls _disableInitializers(), so the bare impl must not be
        // initializable directly under any circumstances.
        vm.expectRevert(Initializable.InvalidInitialization.selector, address(impl));
        impl.initialize(user);
    }

    function test_ReceiverLivesAtSlotZero() public {
        // Pins the storage layout: `receiver` is the first declared storage variable and
        // therefore must occupy slot 0. Reads slot 0 directly with vm.load so that inserting
        // any new storage variable ahead of `receiver` (including a future base contract
        // that declares its own storage without a `__gap`) breaks this assertion immediately.
        DirectTransferAddress fresh = _deployUninitializedProxy();
        fresh.initialize(user);

        bytes32 slotZero = vm.load(address(fresh), bytes32(uint256(0)));
        assertEq(address(uint160(uint256(slotZero))), user, "receiver must occupy slot 0");
        assertEq(fresh.receiver(), user, "receiver getter must return initialized value");
    }

    /// @dev Deploy a BeaconProxy without initData so `initialize` can be called explicitly by the test.
    function _deployUninitializedProxy() internal returns (DirectTransferAddress) {
        BeaconProxy proxy = new BeaconProxy(address(beacon), "");
        return DirectTransferAddress(address(proxy));
    }

    /*//////////////////////////////////////////////////////////////
                                FORWARD
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_ForwardCallerNotOwner() public {
        Attestation memory emptyAttestation;

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(DirectTransferAddress.OwnableUnauthorizedAccount.selector, user), address(dta)
        );
        dta.depositAndForward(DEPOSIT_AMOUNT, 0, "", emptyAttestation);
    }

    function test_ForwardSucceeds() public {
        deal(address(token), address(dta), DEPOSIT_AMOUNT);
        // MockDCD settles shares 1:1 with depositAmount from its pre-funded share pool.
        uint256 expectedShares = DEPOSIT_AMOUNT;
        Attestation memory emptyAttestation;

        _expectForwardedEvent(address(dta), user, DEPOSIT_AMOUNT, expectedShares);
        vm.prank(owner);
        uint256 shares = dta.depositAndForward(DEPOSIT_AMOUNT, 0, "", emptyAttestation);

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

        _expectRefundedEvent(address(dta), address(token), user, DEPOSIT_AMOUNT);
        vm.prank(owner);
        dta.refund(address(token));

        assertEq(token.balanceOf(address(dta)), 0, "DTA token balance must be zero after refund");
        assertEq(token.balanceOf(user), DEPOSIT_AMOUNT, "receiver must hold swept balance");
    }

    function test_RefundSweepsStrayTokenAtTokenAddress() public {
        // A non-configured ERC20 accidentally sent to the DTA should be swept to `receiver`
        // using the tokenAddress argument, independent of the immutable `token`.
        MockERC20 strayToken = new MockERC20();
        strayToken.initialize("Stray", "STRAY", 18);
        uint256 strayAmount = 123e18;
        deal(address(strayToken), address(dta), strayAmount);

        _expectRefundedEvent(address(dta), address(strayToken), user, strayAmount);
        vm.prank(owner);
        dta.refund(address(strayToken));

        assertEq(strayToken.balanceOf(address(dta)), 0, "DTA stray-token balance must be zero after refund");
        assertEq(strayToken.balanceOf(user), strayAmount, "receiver must hold swept stray-token balance");
        assertEq(token.balanceOf(address(dta)), 0, "immutable token balance must be untouched");
    }

    function test_RevertWhen_RefundBalanceIsZero() public {
        assertEq(token.balanceOf(address(dta)), 0, "precondition: DTA balance is zero");

        vm.prank(owner);
        vm.expectRevert(DirectTransferAddress.ZeroAmount.selector, address(dta));
        dta.refund(address(token));
    }

    function test_RevertWhen_RefundCallerNotOwner() public {
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(DirectTransferAddress.OwnableUnauthorizedAccount.selector, user), address(dta)
        );
        dta.refund(address(token));
    }

    /*//////////////////////////////////////////////////////////////
                               RECOVER
    //////////////////////////////////////////////////////////////*/

    function test_RecoverSweepsFullBalanceToRecoveryAccount() public {
        deal(address(token), address(dta), DEPOSIT_AMOUNT);

        _expectRecoveredEvent(address(dta), address(token), recoveryAccount, DEPOSIT_AMOUNT);
        vm.prank(owner);
        dta.recover(address(token));

        assertEq(token.balanceOf(address(dta)), 0, "DTA token balance must be zero after recover");
        assertEq(token.balanceOf(recoveryAccount), DEPOSIT_AMOUNT, "recoveryAccount must hold swept balance");
    }

    function test_RecoverSweepsStrayTokenAtTokenAddress() public {
        // A non-configured ERC20 accidentally sent to the DTA should be swept to `recoveryAccount`
        // using the tokenAddress argument, independent of the immutable `token`.
        MockERC20 strayToken = new MockERC20();
        strayToken.initialize("Stray", "STRAY", 18);
        uint256 strayAmount = 456e18;
        deal(address(strayToken), address(dta), strayAmount);

        _expectRecoveredEvent(address(dta), address(strayToken), recoveryAccount, strayAmount);
        vm.prank(owner);
        dta.recover(address(strayToken));

        assertEq(strayToken.balanceOf(address(dta)), 0, "DTA stray-token balance must be zero after recover");
        assertEq(
            strayToken.balanceOf(recoveryAccount), strayAmount, "recoveryAccount must hold swept stray-token balance"
        );
        assertEq(token.balanceOf(address(dta)), 0, "immutable token balance must be untouched");
    }

    function test_RevertWhen_RecoverBalanceIsZero() public {
        assertEq(token.balanceOf(address(dta)), 0, "precondition: DTA balance is zero");

        vm.prank(owner);
        vm.expectRevert(DirectTransferAddress.ZeroAmount.selector, address(dta));
        dta.recover(address(token));
    }

    function test_RevertWhen_RecoverCallerNotOwner() public {
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(DirectTransferAddress.OwnableUnauthorizedAccount.selector, user), address(dta)
        );
        dta.recover(address(token));
    }

}
