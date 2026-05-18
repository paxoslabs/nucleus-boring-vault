// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { MainnetAddresses } from "test/resources/MainnetAddresses.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { VaultArchitectureSharedSetup, IPredicateRegistry } from "test/shared-setup/VaultArchitectureSharedSetup.t.sol";
import { DistributorCodeDepositor, INativeWrapper } from "src/helper/DistributorCodeDepositor.sol";
import { SmartDepositAddress } from "src/smart-deposit/SmartDepositAddress.sol";
import { SmartDepositFactoryBeacon } from "src/smart-deposit/SmartDepositFactoryBeacon.sol";
import { IFeeModule } from "src/interfaces/IFeeModule.sol";
import { Attestation } from "@predicate/interfaces/IPredicateRegistry.sol";
import { USDC } from "src/helper/Constants.sol";
import { stdStorage, StdStorage, stdError } from "@forge-std/Test.sol";
import { console } from "forge-std/console.sol";

/// @notice Minimal initial SDA implementation used only as the pre-upgrade impl in these tests.
/// @dev Exposes `DCD()` so SmartDepositFactoryBeacon can derive salt entropy from the DCD's boringVault. `token`
///      lives in proxy storage and is set by `initialize`, mirroring the production layout.
contract SmartDepositAddress1 {

    using SafeTransferLib for ERC20;

    address public userDestinationAddress;
    ERC20 public token;
    bool private _initialized;
    DistributorCodeDepositor public immutable DCD;

    error AlreadyInitialized();

    constructor(DistributorCodeDepositor _dcd) {
        DCD = _dcd;
    }

    function initialize(address _userDestinationAddress, ERC20 _token) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        userDestinationAddress = _userDestinationAddress;
        token = _token;
    }

    function forward(uint256 amount) external returns (uint256 shares) {
        Attestation memory emptyAttestation;

        token.safeApprove(address(DCD), amount);
        shares = DCD.deposit(token, amount, 0, userDestinationAddress, "", emptyAttestation);
    }

}

uint256 constant FORK_BLOCK_NUMBER = 24_321_829;

contract SmartDepositAddressTest is VaultArchitectureSharedSetup {

    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;
    using stdStorage for StdStorage;

    DistributorCodeDepositor public dcd;
    SmartDepositFactoryBeacon public beacon;
    address public owner = vm.addr(uint256(bytes32("owner")));
    address public recoveryAccount = vm.addr(uint256(bytes32("recoveryAccount")));

    address[5] public users;
    address[5] public sdas; // Smart Deposit Addresses (proxies)

    // Example UUID encoded as bytes 32
    bytes32 public constant ORGANIZATION_ID =
        bytes32(0x00000000000000000000000000000000700768aec71d42cc9ff913b777d6d379);
    uint256 public constant DEPOSIT_AMOUNT = 1000e6; // 1000 USDC

    function setUp() public {
        // Setup forked environment
        _startFork("MAINNET_RPC_URL", FORK_BLOCK_NUMBER);

        // Initialize predicate-related state
        (attesterOne, attesterOnePk) = makeAddrAndKey("attesterOne");
        policyOne = "policyOne";
        predicateRegistry = IPredicateRegistry(0xe15a8Ca5BD8464283818088c1760d8f23B6a216E);
        vm.prank(predicateRegistry.owner());
        predicateRegistry.registerAttester(attesterOne);

        // Set up USDC vault architecture
        address[] memory assets = new address[](1);
        assets[0] = address(USDC);
        (boringVault, teller, accountant) =
            _deployVaultArchitecture("Stablecoin Earn", "earnUSDC", 6, address(USDC), assets, 1e6);

        // Deploy DCD
        dcd = new DistributorCodeDepositor(
            teller,
            INativeWrapper(address(0)),
            rolesAuthority,
            false,
            type(uint256).max,
            IFeeModule(address(0)),
            owner,
            address(predicateRegistry),
            policyOne,
            owner
        );

        // Grant DCD public deposit capability
        vm.startPrank(rolesAuthority.owner());
        rolesAuthority.setPublicCapability(address(dcd), dcd.deposit.selector, true);
        vm.stopPrank();

        // Generate 5 user addresses
        for (uint256 i; i < 5; i++) {
            users[i] = vm.addr(uint256(keccak256(abi.encodePacked("user", i))));
        }
    }

    /*//////////////////////////////////////////////////////////////
                              TEST 1
        Deploy impl1 + beacon, create 5 SDA proxies via CREATEX,
        fund each with USDC, forward into vault, verify shares.
    //////////////////////////////////////////////////////////////*/

    function test_setup5Users() public {
        // Deploy implementation and beacon
        SmartDepositAddress1 impl = new SmartDepositAddress1(dcd);
        beacon = new SmartDepositFactoryBeacon(address(impl), address(this));

        // Deploy 5 SDA proxies via CREATEX
        for (uint256 i; i < 5; i++) {
            sdas[i] = beacon.deployBeaconProxy(ORGANIZATION_ID, users[i], address(USDC));

            // Verify the deployed address matches the deterministic computation
            address expected = beacon.computeSDAAddress(ORGANIZATION_ID, users[i], address(USDC));
            assertEq(sdas[i], expected, "SDA address must be deterministic");

            // Verify initialization
            assertEq(
                SmartDepositAddress1(sdas[i]).userDestinationAddress(), users[i], "userDestinationAddress must be user"
            );
            assertEq(address(SmartDepositAddress1(sdas[i]).DCD()), address(dcd), "DCD must match");
        }

        // Fund each SDA with USDC and forward
        for (uint256 i; i < 5; i++) {
            _setERC20Balance(address(USDC), sdas[i], DEPOSIT_AMOUNT);

            // Forward USDC through the SDA into the vault
            SmartDepositAddress1(sdas[i]).forward(DEPOSIT_AMOUNT);

            // Verify user received vault shares
            uint256 quoteRate = accountant.getRateInQuoteSafe(ERC20(address(USDC)));
            uint256 expectedShares = DEPOSIT_AMOUNT.mulDivDown(ONE_SHARE, quoteRate);
            assertEq(ERC20(address(boringVault)).balanceOf(users[i]), expectedShares, "user must have expected shares");

            console.log("User %s deposited %d USDC, received %d shares", i, DEPOSIT_AMOUNT, expectedShares);
        }
    }

    /*//////////////////////////////////////////////////////////////
                              TEST 2
        Deploy impl1 pointing to dcd1, create 5 proxies, then
        burn dcd1, deploy dcd2, upgrade beacon to new impl1
        pointing to dcd2, and verify deposits go through dcd2.
    //////////////////////////////////////////////////////////////*/

    function test_upgradeDCDFor5Users() public {
        // Deploy first DCD + implementation + beacon
        SmartDepositAddress1 impl1 = new SmartDepositAddress1(dcd);
        beacon = new SmartDepositFactoryBeacon(address(impl1), address(this));

        // Deploy 5 SDA proxies
        for (uint256 i; i < 5; i++) {
            sdas[i] = beacon.deployBeaconProxy(ORGANIZATION_ID, users[i], address(USDC));
        }

        // Verify initial DCD
        for (uint256 i; i < 5; i++) {
            assertEq(address(SmartDepositAddress1(sdas[i]).DCD()), address(dcd), "initial DCD must match");
        }

        // "Burn" the old DCD by revoking its public deposit capability
        vm.startPrank(rolesAuthority.owner());
        rolesAuthority.setPublicCapability(address(dcd), dcd.deposit.selector, false);
        vm.stopPrank();

        // Deploy a new DCD (same vault, fresh instance)
        DistributorCodeDepositor dcd2 = new DistributorCodeDepositor(
            teller,
            INativeWrapper(address(0)),
            rolesAuthority,
            false,
            type(uint256).max,
            IFeeModule(address(0)),
            owner,
            address(predicateRegistry),
            policyOne,
            owner
        );

        // Grant new DCD deposit capability + disable KYT
        vm.startPrank(rolesAuthority.owner());
        rolesAuthority.setPublicCapability(address(dcd2), dcd2.deposit.selector, true);
        vm.stopPrank();
        vm.prank(owner);
        dcd2.updateKytStatus(ERC20(address(USDC)), false);

        // Deploy new implementation pointing to dcd2 and upgrade beacon
        SmartDepositAddress1 impl2 = new SmartDepositAddress1(dcd2);
        beacon.upgradeTo(address(impl2));

        // Verify all proxies now use the new DCD (immutable is in the new implementation bytecode)
        for (uint256 i; i < 5; i++) {
            assertEq(address(SmartDepositAddress1(sdas[i]).DCD()), address(dcd2), "DCD must be upgraded to dcd2");
        }

        // Fund and forward through all 5 SDAs using the new DCD
        for (uint256 i; i < 5; i++) {
            _setERC20Balance(address(USDC), sdas[i], DEPOSIT_AMOUNT);

            SmartDepositAddress1(sdas[i]).forward(DEPOSIT_AMOUNT);

            uint256 quoteRate = accountant.getRateInQuoteSafe(ERC20(address(USDC)));
            uint256 expectedShares = DEPOSIT_AMOUNT.mulDivDown(ONE_SHARE, quoteRate);
            assertEq(
                ERC20(address(boringVault)).balanceOf(users[i]), expectedShares, "user must have shares from new DCD"
            );
            console.log("User %s forwarded via new DCD, received %d shares", i, expectedShares);
        }
    }

}
