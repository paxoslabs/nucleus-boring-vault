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
        bytes memory initData = abi.encodeWithSelector(DirectTransferAddress.initialize.selector, user);
        address expected = beacon.computeDTAAddress(ORG_ID, user, initData);

        vm.prank(beaconAdmin);
        address dta = beacon.deployBeaconProxy(ORG_ID, user, initData);

        assertEq(dta, expected, "deployed DTA must equal computeDTAAddress for identical inputs");
    }

    function test_DeployBeaconProxyEmitsBeaconProxyDeployed() public {
        bytes memory initData = abi.encodeWithSelector(DirectTransferAddress.initialize.selector, user);
        address expected = beacon.computeDTAAddress(ORG_ID, user, initData);

        _expectBeaconProxyDeployedEvent(expected, user, ORG_ID, address(token));
        vm.prank(beaconAdmin);
        beacon.deployBeaconProxy(ORG_ID, user, initData);
    }

    function test_DeployBeaconProxyInitializesReceiver() public {
        bytes memory initData = abi.encodeWithSelector(DirectTransferAddress.initialize.selector, user);

        vm.prank(beaconAdmin);
        address dtaAddr = beacon.deployBeaconProxy(ORG_ID, user, initData);

        assertEq(
            DirectTransferAddress(dtaAddr).receiver(), user, "initialize calldata must set receiver in proxy storage"
        );
    }

    function test_RevertWhen_DeployBeaconProxyZeroDestinationAddress() public {
        bytes memory initData = abi.encodeWithSelector(DirectTransferAddress.initialize.selector, user);

        vm.expectRevert(FactoryBeacon.ZeroAddress.selector);
        vm.prank(beaconAdmin);
        beacon.deployBeaconProxy(ORG_ID, address(0), initData);
    }

    function test_RevertWhen_DeployBeaconProxyEmptyInitData() public {
        vm.expectRevert(FactoryBeacon.EmptyInitData.selector);
        vm.prank(beaconAdmin);
        beacon.deployBeaconProxy(ORG_ID, user, "");
    }

    function test_RevertWhen_DeployBeaconProxyReusedSalt() public {
        bytes memory initData = abi.encodeWithSelector(DirectTransferAddress.initialize.selector, user);

        vm.prank(beaconAdmin);
        beacon.deployBeaconProxy(ORG_ID, user, initData);

        // CREATEX collision: the CREATE3 proxy at the derived address already exists.
        vm.expectRevert();
        vm.prank(beaconAdmin);
        beacon.deployBeaconProxy(ORG_ID, user, initData);
    }

    function test_RevertWhen_DeployBeaconProxyCallerNotOwner() public {
        bytes memory initData = abi.encodeWithSelector(DirectTransferAddress.initialize.selector, user);
        address notOwner = makeAddr("notOwner");

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, notOwner));
        vm.prank(notOwner);
        beacon.deployBeaconProxy(ORG_ID, user, initData);
    }

    function test_DeployBeaconProxyIsCrossChainDeterministic() public {
        bytes memory initData = abi.encodeWithSelector(DirectTransferAddress.initialize.selector, user);

        vm.chainId(1);
        uint256 snap = vm.snapshot();
        vm.prank(beaconAdmin);
        address dtaMainnet = beacon.deployBeaconProxy(ORG_ID, user, initData);

        vm.revertTo(snap);
        vm.chainId(137);
        vm.prank(beaconAdmin);
        address dtaPolygon = beacon.deployBeaconProxy(ORG_ID, user, initData);

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
        bytes memory initData = abi.encodeWithSelector(DirectTransferAddress.initialize.selector, user);

        address first = beacon.computeDTAAddress(ORG_ID, user, initData);
        address second = beacon.computeDTAAddress(ORG_ID, user, initData);

        assertEq(first, second, "computeDTAAddress must be pure in its inputs");
    }

    function test_ComputeDTAAddressDifferentiatesByOrganizationId() public view {
        bytes memory initData = abi.encodeWithSelector(DirectTransferAddress.initialize.selector, user);
        bytes32 otherOrgId = bytes32(uint256(ORG_ID) + 1);

        address a = beacon.computeDTAAddress(ORG_ID, user, initData);
        address b = beacon.computeDTAAddress(otherOrgId, user, initData);

        assertTrue(a != b, "varying organizationId must change the computed DTA address");
    }

    function test_ComputeDTAAddressDifferentiatesByUserDestinationAddress() public view {
        bytes memory initData = abi.encodeWithSelector(DirectTransferAddress.initialize.selector, user);

        address a = beacon.computeDTAAddress(ORG_ID, user, initData);
        address b = beacon.computeDTAAddress(ORG_ID, user2, initData);

        assertTrue(a != b, "varying userDestinationAddress must change the computed DTA address");
    }

    function test_ComputeDTAAddressDifferentiatesByInitData() public view {
        bytes memory initDataA = abi.encodeWithSelector(DirectTransferAddress.initialize.selector, user);
        bytes memory initDataB = abi.encodeWithSelector(DirectTransferAddress.initialize.selector, user2);

        address a = beacon.computeDTAAddress(ORG_ID, user, initDataA);
        address b = beacon.computeDTAAddress(ORG_ID, user, initDataB);

        assertTrue(a != b, "varying initData must change the computed DTA address");
    }

    function test_ComputeDTAAddressDependsOnImplementationImmutables() public {
        bytes memory initData = abi.encodeWithSelector(DirectTransferAddress.initialize.selector, user);
        address beforeUpgrade = beacon.computeDTAAddress(ORG_ID, user, initData);

        MockDCD otherMockDCD = new MockDCD(makeAddr("otherBoringVault"));
        MockERC20 otherToken = new MockERC20();
        otherToken.initialize("Other Token", "OTK", 6);

        DirectTransferAddress upgradedImpl = new DirectTransferAddress(
            DistributorCodeDepositor(address(otherMockDCD)), owner, recoveryAccount, ERC20(address(otherToken))
        );
        vm.prank(beaconAdmin);
        beacon.upgradeTo(address(upgradedImpl));

        address afterUpgrade = beacon.computeDTAAddress(ORG_ID, user, initData);
        assertTrue(beforeUpgrade != afterUpgrade, "implementation immutables must influence computed DTA address");
    }

}
