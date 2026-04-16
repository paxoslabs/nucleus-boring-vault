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
import { DirectTransferAddress1 } from "src/direct-transfer/DirectTransferAddress1.sol";
import { DirectTransferAddress2 } from "src/direct-transfer/DirectTransferAddress2.sol";
import { FactoryBeacon } from "src/direct-transfer/FactoryBeacon.sol";
import { IFeeModule } from "src/interfaces/IFeeModule.sol";
import { Attestation } from "@predicate/interfaces/IPredicateRegistry.sol";
import { stdStorage, StdStorage, stdError } from "@forge-std/Test.sol";
import { console } from "forge-std/console.sol";

/*//////////////////////////////////////////////////////////////
                    MINIMAL BEACON CONTRACTS
    OZ 5.x BeaconProxy requires Cancun (tload/tstore) which is
    incompatible with this project's Shanghai EVM target. These
    minimal versions provide the same beacon proxy pattern without
    ERC1967 storage slot overhead.
//////////////////////////////////////////////////////////////*/

uint256 constant FORK_BLOCK_NUMBER = 24_321_829;

contract DirectTransferAddressTest is VaultArchitectureSharedSetup {

    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;
    using stdStorage for StdStorage;

    DistributorCodeDepositor public dcd;
    FactoryBeacon public beacon;
    address public owner = vm.addr(uint256(bytes32("owner")));

    address[5] public users;
    address[5] public dtas; // Direct Transfer Addresses (proxies)

    // Example UUID -> bytes 32
    // Can be converted like:
    // const key = "0x" + uuid.replace(/-/g, "").padEnd(64, "0"); // preserves UUID
    bytes32 public constant ORGANIZATION_ID =
        bytes32(0x700768aec71d42cc9ff913b777d6d37900000000000000000000000000000000);
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
        Deploy impl1 + beacon, create 5 DTA proxies via CREATEX,
        fund each with USDC, forward into vault, verify shares.
    //////////////////////////////////////////////////////////////*/

    function test_setup5Users() public {
        // Deploy implementation and beacon
        DirectTransferAddress1 impl = new DirectTransferAddress1(dcd);
        beacon = new FactoryBeacon(address(impl), address(this));

        // Deploy 5 DTA proxies via CREATEX
        for (uint256 i; i < 5; i++) {
            dtas[i] = beacon.deployBeaconProxy(address(boringVault), ORGANIZATION_ID, users[i], address(USDC));

            // Verify the deployed address matches the deterministic computation
            address expected = beacon.computeDTAAddress(address(boringVault), ORGANIZATION_ID, users[i], address(USDC));
            assertEq(dtas[i], expected, "DTA address must be deterministic");

            // Verify initialization
            assertEq(DirectTransferAddress1(dtas[i]).receiver(), users[i], "receiver must be user");
            assertEq(address(DirectTransferAddress1(dtas[i]).DCD()), address(dcd), "DCD must match");
        }

        // Fund each DTA with USDC and forward
        for (uint256 i; i < 5; i++) {
            _setERC20Balance(address(USDC), dtas[i], DEPOSIT_AMOUNT);

            // Forward USDC through the DTA into the vault
            DirectTransferAddress1(dtas[i]).forward(DEPOSIT_AMOUNT);

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
        DirectTransferAddress1 impl1 = new DirectTransferAddress1(dcd);
        beacon = new FactoryBeacon(address(impl1), address(this));

        // Deploy 5 DTA proxies
        for (uint256 i; i < 5; i++) {
            dtas[i] = beacon.deployBeaconProxy(address(boringVault), ORGANIZATION_ID, users[i], address(USDC));
        }

        // Verify initial DCD
        for (uint256 i; i < 5; i++) {
            assertEq(address(DirectTransferAddress1(dtas[i]).DCD()), address(dcd), "initial DCD must match");
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
        DirectTransferAddress1 impl2 = new DirectTransferAddress1(dcd2);
        beacon.upgradeTo(address(impl2));

        // Verify all proxies now use the new DCD (immutable is in the new implementation bytecode)
        for (uint256 i; i < 5; i++) {
            assertEq(address(DirectTransferAddress1(dtas[i]).DCD()), address(dcd2), "DCD must be upgraded to dcd2");
        }

        // Fund and forward through all 5 DTAs using the new DCD
        for (uint256 i; i < 5; i++) {
            _setERC20Balance(address(USDC), dtas[i], DEPOSIT_AMOUNT);

            DirectTransferAddress1(dtas[i]).forward(DEPOSIT_AMOUNT);

            uint256 quoteRate = accountant.getRateInQuoteSafe(ERC20(address(USDC)));
            uint256 expectedShares = DEPOSIT_AMOUNT.mulDivDown(ONE_SHARE, quoteRate);
            assertEq(
                ERC20(address(boringVault)).balanceOf(users[i]), expectedShares, "user must have shares from new DCD"
            );
            console.log("User %s forwarded via new DCD, received %d shares", i, expectedShares);
        }
    }

    /*//////////////////////////////////////////////////////////////
                              TEST 3
        Deploy impl1 + beacon + 5 proxies, send stuck DAI to each,
        upgrade beacon to impl2 (DirectTransferAddress2), recover
        DAI for all users, then verify forward still works.
    //////////////////////////////////////////////////////////////*/

    function test_upgradeImplementationFor5Users() public {
        // Deploy impl1 + beacon + 5 proxies
        DirectTransferAddress1 impl1 = new DirectTransferAddress1(dcd);
        beacon = new FactoryBeacon(address(impl1), address(this));

        for (uint256 i; i < 5; i++) {
            dtas[i] = beacon.deployBeaconProxy(address(boringVault), ORGANIZATION_ID, users[i], address(USDC));
        }

        // Fund each DTA with some extra tokens (simulating stuck funds)
        ERC20 dai = ERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F); // DAI on mainnet
        for (uint256 i; i < 5; i++) {
            _setERC20Balance(address(dai), dtas[i], 500e18); // 500 DAI stuck
        }

        // Upgrade beacon to implementation2 (which has recover)
        DirectTransferAddress2 impl2 = new DirectTransferAddress2(dcd);
        beacon.upgradeTo(address(impl2));

        // Verify all proxies can now recover stuck DAI
        for (uint256 i; i < 5; i++) {
            address recoveryTarget = users[i];
            uint256 balBefore = dai.balanceOf(recoveryTarget);

            DirectTransferAddress2(dtas[i]).recover(dai, 500e18, recoveryTarget);

            assertEq(dai.balanceOf(recoveryTarget), balBefore + 500e18, "user must have recovered DAI");
            assertEq(dai.balanceOf(dtas[i]), 0, "DTA must have no DAI left");
            console.log("User %s recovered 500 DAI", i);
        }

        // Verify forward still works after upgrade
        // NOTE: Maybe something worth noting in this simple implementation. Is that if sanctioned and recovered, the
        // forward still works unless permanantly frozen. In the event a user is unsanctioned
        for (uint256 i; i < 5; i++) {
            _setERC20Balance(address(USDC), dtas[i], DEPOSIT_AMOUNT);

            Attestation memory emptyAttestation = Attestation({
                uuid: "0x0000000000000000000000000000000000000000000000000000000000000000",
                expiration: block.timestamp + 1000,
                attester: attesterOne,
                signature: new bytes(0)
            });

            DirectTransferAddress2(dtas[i]).forward(DEPOSIT_AMOUNT, emptyAttestation);

            uint256 quoteRate = accountant.getRateInQuoteSafe(ERC20(address(USDC)));
            uint256 expectedShares = DEPOSIT_AMOUNT.mulDivDown(ONE_SHARE, quoteRate);
            assertEq(
                ERC20(address(boringVault)).balanceOf(users[i]), expectedShares, "user must have shares after upgrade"
            );
            console.log("User %s forwarded after impl upgrade, received %d shares", i, expectedShares);
        }
    }

}
