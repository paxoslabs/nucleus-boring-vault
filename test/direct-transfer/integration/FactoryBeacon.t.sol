// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Test, stdStorage, StdStorage, stdError, console } from "@forge-std/Test.sol";
import { MockERC20 } from "@forge-std/mocks/MockERC20.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { DirectTransferAddress } from "src/direct-transfer/DirectTransferAddress.sol";
import { FactoryBeacon } from "src/direct-transfer/FactoryBeacon.sol";
import { DistributorCodeDepositor } from "src/helper/DistributorCodeDepositor.sol";
import { BaseDirectTransferTest, MockDCD } from "test/direct-transfer/BaseDirectTransferTest.t.sol";

/// @notice Forked-mainnet so the real CreateX at
///         0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed backs `deployBeaconProxy` / `computeDTAAddress`.
contract FactoryBeaconIntegrationTest is BaseDirectTransferTest {

    uint256 constant FORK_BLOCK_NUMBER = 24_321_829;

    function setUp() public override {
        // Select fork before any deployments so the CreateX predeploy at 0xba5Ed0… is live when
        // BaseDirectTransferTest's setUp deploys the FactoryBeacon used throughout the suite.
        vm.selectFork(vm.createFork(vm.envString("MAINNET_RPC_URL"), FORK_BLOCK_NUMBER));
        super.setUp();
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_ConstructorSetsImplementationAndOwner() public {
        assertEq(beacon.implementation(), address(impl), "implementation must match constructor arg");
        assertEq(beacon.owner(), beaconAdmin, "owner must match constructor arg");
    }

    /*//////////////////////////////////////////////////////////////
                           DEPLOY BEACON PROXY
    //////////////////////////////////////////////////////////////*/

    function test_DeployBeaconProxyDeploysToComputedAddress() public {
        address expected = beacon.computeDTAAddress(ORG_ID, user);

        vm.prank(beaconAdmin);
        address dta = beacon.deployBeaconProxy(ORG_ID, user);

        assertEq(dta, expected, "deployed DTA must equal computeDTAAddress for identical inputs");
    }

    function test_DeployBeaconProxyEmitsBeaconProxyDeployed() public {
        address expected = beacon.computeDTAAddress(ORG_ID, user);

        _expectBeaconProxyDeployedEvent(expected, user, ORG_ID, address(token));
        vm.prank(beaconAdmin);
        beacon.deployBeaconProxy(ORG_ID, user);
    }

    function test_DeployBeaconProxyInitializesReceiver() public {
        vm.prank(beaconAdmin);
        address dtaAddr = beacon.deployBeaconProxy(ORG_ID, user);

        assertEq(
            DirectTransferAddress(dtaAddr).receiver(),
            user,
            "factory-constructed initialize calldata must set receiver in proxy storage"
        );
    }

    function test_RevertWhen_DeployBeaconProxyZeroDestinationAddress() public {
        vm.expectRevert(FactoryBeacon.ZeroAddress.selector);
        vm.prank(beaconAdmin);
        beacon.deployBeaconProxy(ORG_ID, address(0));
    }

    function test_RevertWhen_DeployBeaconProxyReusedSalt() public {
        vm.prank(beaconAdmin);
        beacon.deployBeaconProxy(ORG_ID, user);

        // CREATEX collision: the CREATE3 proxy at the derived address already exists.
        vm.expectRevert();
        vm.prank(beaconAdmin);
        beacon.deployBeaconProxy(ORG_ID, user);
    }

    function test_RevertWhen_DeployBeaconProxyCallerNotOwner() public {
        address notOwner = makeAddr("notOwner");

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, notOwner));
        vm.prank(notOwner);
        beacon.deployBeaconProxy(ORG_ID, user);
    }

    function test_DeployBeaconProxyIsCrossChainDeterministic() public {
        vm.chainId(1);
        uint256 snap = vm.snapshot();
        vm.prank(beaconAdmin);
        address dtaMainnet = beacon.deployBeaconProxy(ORG_ID, user);

        vm.revertTo(snap);
        vm.chainId(137);
        vm.prank(beaconAdmin);
        address dtaPolygon = beacon.deployBeaconProxy(ORG_ID, user);

        assertEq(
            dtaMainnet,
            dtaPolygon,
            "salt uses 0x00 crosschainProtectionFlag so identical inputs must produce identical addresses on every chain"
        );
    }

    /*//////////////////////////////////////////////////////////////
                           COMPUTE DTA ADDRESS
    //////////////////////////////////////////////////////////////*/

    function test_ComputeDTAAddressIsDeterministic() public view {
        address first = beacon.computeDTAAddress(ORG_ID, user);
        address second = beacon.computeDTAAddress(ORG_ID, user);

        assertEq(first, second, "computeDTAAddress must be pure in its inputs");
    }

    function test_ComputeDTAAddressDifferentiatesByOrganizationId() public view {
        bytes32 otherOrgId = bytes32(uint256(ORG_ID) + 1);

        address a = beacon.computeDTAAddress(ORG_ID, user);
        address b = beacon.computeDTAAddress(otherOrgId, user);

        assertTrue(a != b, "varying organizationId must change the computed DTA address");
    }

    function test_ComputeDTAAddressDifferentiatesByUserDestinationAddress() public view {
        address a = beacon.computeDTAAddress(ORG_ID, user);
        address b = beacon.computeDTAAddress(ORG_ID, user2);

        assertTrue(a != b, "varying userDestinationAddress must change the computed DTA address");
    }

    /*//////////////////////////////////////////////////////////////
                                UPGRADE TO
    //////////////////////////////////////////////////////////////*/

    function test_UpgradeToSucceedsWhenBoringVaultAndTokenMatch() public {
        // Fresh DCD pointing to the same boringVault and same token — the guard checks values, not addresses.
        MockDCD sameVaultDCD = new MockDCD(boringVault);
        DirectTransferAddress upgradedImpl = new DirectTransferAddress(
            DistributorCodeDepositor(address(sameVaultDCD)), owner, recoveryAccount, ERC20(address(token))
        );

        address beforeUpgrade = beacon.computeDTAAddress(ORG_ID, user);

        vm.prank(beaconAdmin);
        beacon.upgradeTo(address(upgradedImpl));

        assertEq(beacon.implementation(), address(upgradedImpl), "implementation must be updated");
        assertEq(
            beacon.computeDTAAddress(ORG_ID, user),
            beforeUpgrade,
            "computed DTA address must be stable across a matching upgrade"
        );
    }

    function test_RevertWhen_UpgradeToChangesBoringVault() public {
        MockDCD otherVaultDCD = new MockDCD(makeAddr("otherBoringVault"));
        DirectTransferAddress mismatchedImpl = new DirectTransferAddress(
            DistributorCodeDepositor(address(otherVaultDCD)), owner, recoveryAccount, ERC20(address(token))
        );

        vm.expectRevert(
            abi.encodeWithSelector(FactoryBeacon.BoringVaultMismatch.selector, boringVault, otherVaultDCD.boringVault())
        );
        vm.prank(beaconAdmin);
        beacon.upgradeTo(address(mismatchedImpl));
    }

    function test_RevertWhen_UpgradeToChangesToken() public {
        MockERC20 otherToken = new MockERC20();
        otherToken.initialize("Other Token", "OTK", 6);

        DirectTransferAddress mismatchedImpl = new DirectTransferAddress(
            DistributorCodeDepositor(address(mockDCD)), owner, recoveryAccount, ERC20(address(otherToken))
        );

        vm.expectRevert(
            abi.encodeWithSelector(FactoryBeacon.TokenMismatch.selector, address(token), address(otherToken))
        );
        vm.prank(beaconAdmin);
        beacon.upgradeTo(address(mismatchedImpl));
    }

    function test_RevertWhen_UpgradeToCallerNotOwner() public {
        MockDCD sameVaultDCD = new MockDCD(boringVault);
        DirectTransferAddress upgradedImpl = new DirectTransferAddress(
            DistributorCodeDepositor(address(sameVaultDCD)), owner, recoveryAccount, ERC20(address(token))
        );
        address notOwner = makeAddr("notOwner");

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, notOwner));
        vm.prank(notOwner);
        beacon.upgradeTo(address(upgradedImpl));
    }

}
