// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Test, stdStorage, StdStorage, stdError, console } from "@forge-std/Test.sol";
import { DirectTransferAddress } from "src/direct-transfer/DirectTransferAddress.sol";
import { FactoryBeacon } from "src/direct-transfer/FactoryBeacon.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { BaseDirectTransferTest } from "test/direct-transfer/BaseDirectTransferTest.t.sol";

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
        address expected = beacon.computeDTAAddress(boringVault, ORG_ID, user, address(token));

        vm.prank(beaconAdmin);
        address dta = beacon.deployBeaconProxy(boringVault, ORG_ID, user, address(token));

        assertEq(dta, expected, "deployed DTA must equal computeDTAAddress for identical inputs");
    }

    function test_DeployBeaconProxyEmitsBeaconProxyDeployed() public {
        address expected = beacon.computeDTAAddress(boringVault, ORG_ID, user, address(token));

        _expectBeaconProxyDeployedEvent(expected, user, ORG_ID, address(token));
        vm.prank(beaconAdmin);
        beacon.deployBeaconProxy(boringVault, ORG_ID, user, address(token));
    }

    function test_DeployBeaconProxyInitializesReceiver() public {
        vm.prank(beaconAdmin);
        address dtaAddr = beacon.deployBeaconProxy(boringVault, ORG_ID, user, address(token));

        assertEq(
            DirectTransferAddress(dtaAddr).receiver(),
            user,
            "initialize data must have delegatecalled so receiver is set to userDestinationAddress"
        );
    }

    function test_RevertWhen_InputTokenMismatch() public {
        address wrongToken = makeAddr("wrongToken");

        vm.expectRevert(
            abi.encodeWithSelector(FactoryBeacon.InputTokenMismatch.selector, address(token), wrongToken),
            address(beacon)
        );
        vm.prank(beaconAdmin);
        beacon.deployBeaconProxy(boringVault, ORG_ID, user, wrongToken);
    }

    function test_RevertWhen_DeployBeaconProxyReusedSalt() public {
        vm.prank(beaconAdmin);
        beacon.deployBeaconProxy(boringVault, ORG_ID, user, address(token));

        // CREATEX collision: the CREATE3 proxy at the derived address already exists.
        vm.expectRevert();
        vm.prank(beaconAdmin);
        beacon.deployBeaconProxy(boringVault, ORG_ID, user, address(token));
    }

    function test_RevertWhen_DeployBeaconProxyCallerNotOwner() public {
        address notOwner = makeAddr("notOwner");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, notOwner));
        vm.prank(notOwner);
        beacon.deployBeaconProxy(boringVault, ORG_ID, user, address(token));
    }

    function test_DeployBeaconProxyIsCrossChainDeterministic() public {
        vm.chainId(1);
        uint256 snap = vm.snapshot();
        vm.prank(beaconAdmin);
        address dtaMainnet = beacon.deployBeaconProxy(boringVault, ORG_ID, user, address(token));

        vm.revertTo(snap);
        vm.chainId(137);
        vm.prank(beaconAdmin);
        address dtaPolygon = beacon.deployBeaconProxy(boringVault, ORG_ID, user, address(token));

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
        address first = beacon.computeDTAAddress(boringVault, ORG_ID, user, address(token));
        address second = beacon.computeDTAAddress(boringVault, ORG_ID, user, address(token));

        assertEq(first, second, "computeDTAAddress must be pure in its inputs");
    }

    function test_ComputeDTAAddressDifferentiatesByBoringVault() public {
        address otherBoringVault = makeAddr("otherBoringVault");

        address a = beacon.computeDTAAddress(boringVault, ORG_ID, user, address(token));
        address b = beacon.computeDTAAddress(otherBoringVault, ORG_ID, user, address(token));

        assertTrue(a != b, "varying boringVault must change the computed DTA address");
    }

    function test_ComputeDTAAddressDifferentiatesByOrganizationId() public view {
        bytes32 otherOrgId = bytes32(uint256(ORG_ID) + 1);

        address a = beacon.computeDTAAddress(boringVault, ORG_ID, user, address(token));
        address b = beacon.computeDTAAddress(boringVault, otherOrgId, user, address(token));

        assertTrue(a != b, "varying organizationId must change the computed DTA address");
    }

    function test_ComputeDTAAddressDifferentiatesByUserDestinationAddress() public view {
        address a = beacon.computeDTAAddress(boringVault, ORG_ID, user, address(token));
        address b = beacon.computeDTAAddress(boringVault, ORG_ID, user2, address(token));

        assertTrue(a != b, "varying userDestinationAddress must change the computed DTA address");
    }

    function test_ComputeDTAAddressDifferentiatesByInputToken() public {
        address otherToken = makeAddr("otherToken");

        address a = beacon.computeDTAAddress(boringVault, ORG_ID, user, address(token));
        address b = beacon.computeDTAAddress(boringVault, ORG_ID, user, otherToken);

        assertTrue(a != b, "varying inputToken must change the computed DTA address");
    }

}
