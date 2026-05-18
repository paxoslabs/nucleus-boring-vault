// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Test, stdStorage, StdStorage, stdError, console } from "@forge-std/Test.sol";
import { MockERC20 } from "@forge-std/mocks/MockERC20.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { SmartDepositAddress } from "src/smart-deposit/SmartDepositAddress.sol";
import { SmartDepositFactoryBeacon } from "src/smart-deposit/SmartDepositFactoryBeacon.sol";
import { ICreateX } from "src/interfaces/ICreateX.sol";
import { DistributorCodeDepositor } from "src/helper/DistributorCodeDepositor.sol";
import { BaseSmartDepositTest, MockDCD } from "test/smart-deposit/BaseSmartDepositTest.t.sol";

/// @notice Forked-mainnet so the real CreateX at
///         0x1077f8ea07EA34D9F23BC39256BF234665FB391f backs `deployBeaconProxy` / `computeSDAAddress`.
contract SmartDepositFactoryBeaconIntegrationTest is BaseSmartDepositTest {

    uint256 constant FORK_BLOCK_NUMBER = 24_321_829;

    function setUp() public override {
        // Select fork before any deployments so the CreateX predeploy at 0xba5Ed0… is live when
        // BaseSmartDepositTest's setUp deploys the SmartDepositFactoryBeacon used throughout the suite.
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

    function test_RevertWhen_ConstructorImplBoringVaultIsZero() public {
        MockDCD zeroVaultDCD = new MockDCD(address(0));
        vm.mockCall(address(impl), abi.encodeWithSelector(impl.DCD.selector), abi.encode(address(zeroVaultDCD)));

        vm.expectRevert(SmartDepositFactoryBeacon.ZeroAddress.selector);
        new SmartDepositFactoryBeacon(address(impl), beaconAdmin);
    }

    /*//////////////////////////////////////////////////////////////
                           DEPLOY BEACON PROXY
    //////////////////////////////////////////////////////////////*/

    function test_DeployBeaconProxyDeploysToComputedAddress() public {
        address expected = beacon.computeSDAAddress(ORG_ID, user, address(token));

        vm.prank(beaconAdmin);
        address sda = beacon.deployBeaconProxy(ORG_ID, user, address(token));

        assertEq(sda, expected, "deployed SDA must equal computeSDAAddress for identical inputs");
    }

    function test_DeployBeaconProxyEmitsBeaconProxyDeployed() public {
        address expected = beacon.computeSDAAddress(ORG_ID, user, address(token));

        _expectBeaconProxyDeployedEvent(user, ORG_ID, address(token), boringVault, expected);
        vm.prank(beaconAdmin);
        beacon.deployBeaconProxy(ORG_ID, user, address(token));
    }

    function test_DeployBeaconProxyInitializesUserDestinationAddressAndToken() public {
        vm.prank(beaconAdmin);
        address sdaAddr = beacon.deployBeaconProxy(ORG_ID, user, address(token));

        assertEq(
            SmartDepositAddress(sdaAddr).userDestinationAddress(),
            user,
            "factory-constructed initialize calldata must set userDestinationAddress in proxy storage"
        );
        assertEq(
            address(SmartDepositAddress(sdaAddr).token()),
            address(token),
            "factory-constructed initialize calldata must set token in proxy storage"
        );
    }

    function test_DeployBeaconProxyDifferentiatesByInputToken() public {
        MockERC20 otherToken = new MockERC20();
        otherToken.initialize("Other Token", "OTK", 6);

        vm.prank(beaconAdmin);
        address sdaA = beacon.deployBeaconProxy(ORG_ID, user, address(token));
        vm.prank(beaconAdmin);
        address sdaB = beacon.deployBeaconProxy(ORG_ID, user, address(otherToken));

        assertTrue(sdaA != sdaB, "varying inputToken must produce a distinct SDA address");
        assertEq(address(SmartDepositAddress(sdaA).token()), address(token));
        assertEq(address(SmartDepositAddress(sdaB).token()), address(otherToken));
    }

    function test_RevertWhen_DeployBeaconProxyZeroDestinationAddress() public {
        vm.expectRevert(SmartDepositFactoryBeacon.ZeroAddress.selector);
        vm.prank(beaconAdmin);
        beacon.deployBeaconProxy(ORG_ID, address(0), address(token));
    }

    function test_RevertWhen_DeployBeaconProxyZeroInputToken() public {
        vm.expectRevert(SmartDepositFactoryBeacon.ZeroAddress.selector);
        vm.prank(beaconAdmin);
        beacon.deployBeaconProxy(ORG_ID, user, address(0));
    }

    function test_RevertWhen_DeployBeaconProxyInputTokenHasNoCode() public {
        vm.expectRevert(SmartDepositFactoryBeacon.NoCode.selector);
        vm.prank(beaconAdmin);
        beacon.deployBeaconProxy(ORG_ID, user, address(0xCAFE));
    }

    function test_RevertWhen_DeployBeaconProxyReusedSalt() public {
        vm.prank(beaconAdmin);
        beacon.deployBeaconProxy(ORG_ID, user, address(token));

        // CREATEX collision: the CREATE3 proxy at the derived address already exists, so
        // CreateX's inner CREATE2 returns address(0) and reverts with FailedContractCreation.
        vm.expectRevert(abi.encodeWithSelector(ICreateX.FailedContractCreation.selector, address(beacon.CREATEX())));
        vm.prank(beaconAdmin);
        beacon.deployBeaconProxy(ORG_ID, user, address(token));
    }

    function test_DeployBeaconProxyIsCrossChainDeterministic() public {
        vm.chainId(1);
        uint256 snap = vm.snapshot();
        vm.prank(beaconAdmin);
        address sdaMainnet = beacon.deployBeaconProxy(ORG_ID, user, address(token));

        vm.revertTo(snap);
        vm.chainId(137);
        vm.prank(beaconAdmin);
        address sdaPolygon = beacon.deployBeaconProxy(ORG_ID, user, address(token));

        assertEq(
            sdaMainnet,
            sdaPolygon,
            "salt uses 0x00 crosschainProtectionFlag so identical inputs must produce identical addresses on every chain"
        );
    }

    /*//////////////////////////////////////////////////////////////
                           COMPUTE SDA ADDRESS
    //////////////////////////////////////////////////////////////*/

    function test_ComputeSDAAddressIsDeterministic() public view {
        address first = beacon.computeSDAAddress(ORG_ID, user, address(token));
        address second = beacon.computeSDAAddress(ORG_ID, user, address(token));

        assertEq(first, second, "computeSDAAddress must be pure in its inputs");
    }

    function test_ComputeSDAAddressDifferentiatesByOrganizationId() public view {
        bytes32 otherOrgId = bytes32(uint256(ORG_ID) + 1);

        address a = beacon.computeSDAAddress(ORG_ID, user, address(token));
        address b = beacon.computeSDAAddress(otherOrgId, user, address(token));

        assertTrue(a != b, "varying organizationId must change the computed SDA address");
    }

    function test_ComputeSDAAddressDifferentiatesByUserDestinationAddress() public view {
        address a = beacon.computeSDAAddress(ORG_ID, user, address(token));
        address b = beacon.computeSDAAddress(ORG_ID, user2, address(token));

        assertTrue(a != b, "varying userDestinationAddress must change the computed SDA address");
    }

    function test_ComputeSDAAddressDifferentiatesByInputToken() public {
        MockERC20 otherToken = new MockERC20();
        otherToken.initialize("Other Token", "OTK", 6);

        address a = beacon.computeSDAAddress(ORG_ID, user, address(token));
        address b = beacon.computeSDAAddress(ORG_ID, user, address(otherToken));

        assertTrue(a != b, "varying inputToken must change the computed SDA address");
    }

    /*//////////////////////////////////////////////////////////////
                                UPGRADE TO
    //////////////////////////////////////////////////////////////*/

    function test_UpgradeToSucceedsWhenBoringVaultMatches() public {
        // Fresh DCD pointing to the same boringVault — the guard checks values, not addresses.
        MockDCD sameVaultDCD = new MockDCD(boringVault);
        SmartDepositAddress upgradedImpl =
            new SmartDepositAddress(DistributorCodeDepositor(address(sameVaultDCD)), owner, recoveryAccount);

        address beforeUpgrade = beacon.computeSDAAddress(ORG_ID, user, address(token));

        vm.prank(beaconAdmin);
        beacon.upgradeTo(address(upgradedImpl));

        assertEq(beacon.implementation(), address(upgradedImpl), "implementation must be updated");
        assertEq(
            beacon.computeSDAAddress(ORG_ID, user, address(token)),
            beforeUpgrade,
            "computed SDA address must be stable across a matching upgrade"
        );
    }

    function test_RevertWhen_UpgradeToChangesBoringVault() public {
        MockDCD otherVaultDCD = new MockDCD(makeAddr("otherBoringVault"));
        SmartDepositAddress mismatchedImpl =
            new SmartDepositAddress(DistributorCodeDepositor(address(otherVaultDCD)), owner, recoveryAccount);

        vm.expectRevert(
            abi.encodeWithSelector(
                SmartDepositFactoryBeacon.BoringVaultMismatch.selector, boringVault, otherVaultDCD.boringVault()
            )
        );
        vm.prank(beaconAdmin);
        beacon.upgradeTo(address(mismatchedImpl));
    }

    function test_RevertWhen_UpgradeToCallerNotOwner() public {
        MockDCD sameVaultDCD = new MockDCD(boringVault);
        SmartDepositAddress upgradedImpl =
            new SmartDepositAddress(DistributorCodeDepositor(address(sameVaultDCD)), owner, recoveryAccount);
        address notOwner = makeAddr("notOwner");

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, notOwner));
        vm.prank(notOwner);
        beacon.upgradeTo(address(upgradedImpl));
    }

}
