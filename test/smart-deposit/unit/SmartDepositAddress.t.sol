// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Test, stdStorage, StdStorage, stdError, console } from "@forge-std/Test.sol";
import { MockERC20 } from "@forge-std/mocks/MockERC20.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { Attestation } from "@predicate/interfaces/IPredicateRegistry.sol";
import { Initializable } from "@openzeppelin-v5.0.1/contracts/proxy/utils/Initializable.sol";
import { BeaconProxy } from "@openzeppelin-v5.0.1/contracts/proxy/beacon/BeaconProxy.sol";
import { DistributorCodeDepositor } from "src/helper/DistributorCodeDepositor.sol";
import { SmartDepositAddress } from "src/smart-deposit/SmartDepositAddress.sol";
import { BaseSmartDepositTest, MockDCD } from "test/smart-deposit/BaseSmartDepositTest.t.sol";

contract SmartDepositAddressUnitTest is BaseSmartDepositTest {

    uint256 constant DEPOSIT_AMOUNT = 1000e6;

    SmartDepositAddress sda;

    function setUp() public override {
        super.setUp();
        sda = _deploySDA(user);
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_ConstructorSetsImmutables() public {
        SmartDepositAddress freshImpl =
            new SmartDepositAddress(DistributorCodeDepositor(address(mockDCD)), owner, recoveryAccount);

        assertEq(address(freshImpl.DCD()), address(mockDCD), "DCD immutable must match constructor arg");
        assertEq(freshImpl.owner(), owner, "owner immutable must match constructor arg");
        assertEq(freshImpl.recoveryAccount(), recoveryAccount, "recoveryAccount immutable must match constructor arg");
    }

    function test_RevertWhen_ConstructorHasZeroAddressArg() public {
        vm.expectRevert(SmartDepositAddress.ZeroAddress.selector);
        new SmartDepositAddress(DistributorCodeDepositor(address(0)), owner, recoveryAccount);

        vm.expectRevert(abi.encodeWithSelector(SmartDepositAddress.OwnableInvalidOwner.selector, address(0)));
        new SmartDepositAddress(DistributorCodeDepositor(address(mockDCD)), address(0), recoveryAccount);

        vm.expectRevert(SmartDepositAddress.ZeroAddress.selector);
        new SmartDepositAddress(DistributorCodeDepositor(address(mockDCD)), owner, address(0));
    }

    function test_RevertWhen_ConstructorDcdHasNoCode() public {
        vm.expectRevert(SmartDepositAddress.NoCode.selector);
        new SmartDepositAddress(DistributorCodeDepositor(address(0xBEEF)), owner, recoveryAccount);
    }

    /*//////////////////////////////////////////////////////////////
                               INITIALIZE
    //////////////////////////////////////////////////////////////*/

    function test_InitializeSetsUserDestinationAddressAndToken() public {
        SmartDepositAddress fresh = _deployUninitializedProxy();

        fresh.initialize(user, ERC20(address(token)));

        assertEq(fresh.userDestinationAddress(), user, "userDestinationAddress must equal initialize argument");
        assertEq(address(fresh.token()), address(token), "token must equal initialize argument");
    }

    function test_InitializeEmitsInitialized() public {
        SmartDepositAddress fresh = _deployUninitializedProxy();

        vm.expectEmit(true, true, true, true, address(fresh));
        emit Initialized(user, address(token));
        fresh.initialize(user, ERC20(address(token)));
    }

    function test_RevertWhen_InitializeCalledTwice() public {
        SmartDepositAddress fresh = _deployUninitializedProxy();
        fresh.initialize(user, ERC20(address(token)));

        vm.expectRevert(Initializable.InvalidInitialization.selector, address(fresh));
        fresh.initialize(user2, ERC20(address(token)));
    }

    function test_RevertWhen_InitializeUserDestinationAddressIsZeroAddress() public {
        SmartDepositAddress fresh = _deployUninitializedProxy();

        vm.expectRevert(SmartDepositAddress.ZeroAddress.selector, address(fresh));
        fresh.initialize(address(0), ERC20(address(token)));
    }

    function test_RevertWhen_InitializeTokenIsZeroAddress() public {
        SmartDepositAddress fresh = _deployUninitializedProxy();

        vm.expectRevert(SmartDepositAddress.ZeroAddress.selector, address(fresh));
        fresh.initialize(user, ERC20(address(0)));
    }

    function test_RevertWhen_InitializeTokenHasNoCode() public {
        SmartDepositAddress fresh = _deployUninitializedProxy();

        vm.expectRevert(SmartDepositAddress.NoCode.selector, address(fresh));
        fresh.initialize(user, ERC20(address(0xCAFE)));
    }

    function test_RevertWhen_InitializeCalledOnBareImpl() public {
        // The impl's constructor calls _disableInitializers(), so the bare impl must not be
        // initializable directly under any circumstances.
        vm.expectRevert(Initializable.InvalidInitialization.selector, address(impl));
        impl.initialize(user, ERC20(address(token)));
    }

    function test_UserDestinationAddressLivesAtSlotZero() public {
        // Pins the storage layout: `userDestinationAddress` is the first declared storage variable and
        // therefore must occupy slot 0. Reads slot 0 directly with vm.load so that inserting
        // any new storage variable ahead of `userDestinationAddress` (including a future base contract
        // that declares its own storage without a `__gap`) breaks this assertion immediately.
        SmartDepositAddress fresh = _deployUninitializedProxy();
        fresh.initialize(user, ERC20(address(token)));

        bytes32 slotZero = vm.load(address(fresh), bytes32(uint256(0)));
        assertEq(address(uint160(uint256(slotZero))), user, "userDestinationAddress must occupy slot 0");
        assertEq(fresh.userDestinationAddress(), user, "userDestinationAddress getter must return initialized value");

        bytes32 slotOne = vm.load(address(fresh), bytes32(uint256(1)));
        assertEq(address(uint160(uint256(slotOne))), address(token), "token must occupy slot 1");
        assertEq(address(fresh.token()), address(token), "token getter must return initialized value");
    }

    /// @dev Deploy a BeaconProxy without initData so `initialize` can be called explicitly by the test.
    function _deployUninitializedProxy() internal returns (SmartDepositAddress) {
        BeaconProxy proxy = new BeaconProxy(address(beacon), "");
        return SmartDepositAddress(address(proxy));
    }

    /*//////////////////////////////////////////////////////////////
                                FORWARD
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_ForwardCallerNotOwner() public {
        Attestation memory emptyAttestation;

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(SmartDepositAddress.OwnableUnauthorizedAccount.selector, user), address(sda)
        );
        sda.depositAndForward(DEPOSIT_AMOUNT, 0, "", emptyAttestation);
    }

    function test_ForwardSucceeds() public {
        deal(address(token), address(sda), DEPOSIT_AMOUNT);
        // MockDCD settles shares 1:1 with depositAmount from its pre-funded share pool.
        uint256 expectedShares = DEPOSIT_AMOUNT;
        Attestation memory emptyAttestation;

        _expectForwardedEvent(address(sda), user, DEPOSIT_AMOUNT, expectedShares);
        vm.prank(owner);
        uint256 shares = sda.depositAndForward(DEPOSIT_AMOUNT, 0, "", emptyAttestation);

        assertEq(shares, expectedShares, "returned shares must match mock DCD rate");
        assertEq(token.balanceOf(address(sda)), 0, "SDA token balance must be zero after forward");
        assertEq(token.balanceOf(address(mockDCD)), DEPOSIT_AMOUNT, "DCD must hold the forwarded token");
        assertEq(shareToken.balanceOf(user), expectedShares, "userDestinationAddress must hold settled shares");
    }

    /*//////////////////////////////////////////////////////////////
                                REFUND
    //////////////////////////////////////////////////////////////*/

    function test_RefundTransfersAmountToUserDestinationAddress() public {
        deal(address(token), address(sda), DEPOSIT_AMOUNT);

        _expectRefundedEvent(address(sda), address(token), user, DEPOSIT_AMOUNT);
        vm.prank(owner);
        sda.refund(ERC20(address(token)), DEPOSIT_AMOUNT);

        assertEq(token.balanceOf(address(sda)), 0, "SDA token balance must be zero after refund");
        assertEq(token.balanceOf(user), DEPOSIT_AMOUNT, "userDestinationAddress must hold refunded amount");
    }

    function test_RefundTransfersPartialAmount() public {
        uint256 firstDeposit = DEPOSIT_AMOUNT;
        uint256 secondDeposit = DEPOSIT_AMOUNT * 2;
        deal(address(token), address(sda), firstDeposit + secondDeposit);

        _expectRefundedEvent(address(sda), address(token), user, firstDeposit);
        vm.prank(owner);
        sda.refund(ERC20(address(token)), firstDeposit);

        assertEq(
            token.balanceOf(address(sda)), secondDeposit, "second deposit must remain on the SDA after partial refund"
        );
        assertEq(token.balanceOf(user), firstDeposit, "userDestinationAddress must hold only the first refund");
    }

    function test_RefundTransfersStrayTokenAtTokenAddress() public {
        // A non-configured ERC20 accidentally sent to the SDA should be refundable to `userDestinationAddress`
        // using the tokenAddress argument, independent of the configured `token`.
        MockERC20 strayToken = new MockERC20();
        strayToken.initialize("Stray", "STRAY", 18);
        uint256 strayAmount = 123e18;
        deal(address(strayToken), address(sda), strayAmount);

        _expectRefundedEvent(address(sda), address(strayToken), user, strayAmount);
        vm.prank(owner);
        sda.refund(ERC20(address(strayToken)), strayAmount);

        assertEq(strayToken.balanceOf(address(sda)), 0, "SDA stray-token balance must be zero after refund");
        assertEq(
            strayToken.balanceOf(user), strayAmount, "userDestinationAddress must hold refunded stray-token amount"
        );
        assertEq(token.balanceOf(address(sda)), 0, "configured token balance must be untouched");
    }

    function test_RevertWhen_RefundAmountIsZero() public {
        deal(address(token), address(sda), DEPOSIT_AMOUNT);

        vm.prank(owner);
        vm.expectRevert(SmartDepositAddress.ZeroAmount.selector, address(sda));
        sda.refund(ERC20(address(token)), 0);
    }

    function test_RevertWhen_RefundCallerNotOwner() public {
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(SmartDepositAddress.OwnableUnauthorizedAccount.selector, user), address(sda)
        );
        sda.refund(ERC20(address(token)), DEPOSIT_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                               RECOVER
    //////////////////////////////////////////////////////////////*/

    function test_RecoverSweepsFullBalanceToRecoveryAccount() public {
        deal(address(token), address(sda), DEPOSIT_AMOUNT);

        _expectRecoveredEvent(address(sda), address(token), recoveryAccount, DEPOSIT_AMOUNT);
        vm.prank(owner);
        sda.recover(ERC20(address(token)));

        assertEq(token.balanceOf(address(sda)), 0, "SDA token balance must be zero after recover");
        assertEq(token.balanceOf(recoveryAccount), DEPOSIT_AMOUNT, "recoveryAccount must hold swept balance");
    }

    function test_RecoverSweepsStrayTokenAtTokenAddress() public {
        // A non-configured ERC20 accidentally sent to the SDA should be swept to `recoveryAccount`
        // using the tokenAddress argument, independent of the configured `token`.
        MockERC20 strayToken = new MockERC20();
        strayToken.initialize("Stray", "STRAY", 18);
        uint256 strayAmount = 456e18;
        deal(address(strayToken), address(sda), strayAmount);

        _expectRecoveredEvent(address(sda), address(strayToken), recoveryAccount, strayAmount);
        vm.prank(owner);
        sda.recover(ERC20(address(strayToken)));

        assertEq(strayToken.balanceOf(address(sda)), 0, "SDA stray-token balance must be zero after recover");
        assertEq(
            strayToken.balanceOf(recoveryAccount), strayAmount, "recoveryAccount must hold swept stray-token balance"
        );
        assertEq(token.balanceOf(address(sda)), 0, "configured token balance must be untouched");
    }

    function test_RevertWhen_RecoverBalanceIsZero() public {
        assertEq(token.balanceOf(address(sda)), 0, "precondition: SDA balance is zero");

        vm.prank(owner);
        vm.expectRevert(SmartDepositAddress.ZeroAmount.selector, address(sda));
        sda.recover(ERC20(address(token)));
    }

    function test_RevertWhen_RecoverCallerNotOwner() public {
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(SmartDepositAddress.OwnableUnauthorizedAccount.selector, user), address(sda)
        );
        sda.recover(ERC20(address(token)));
    }

}
