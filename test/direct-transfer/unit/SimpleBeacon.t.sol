// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Test, stdStorage, StdStorage, stdError, console } from "@forge-std/Test.sol";
import { Vm } from "@forge-std/Vm.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { SimpleBeacon } from "src/direct-transfer/SimpleBeacon.sol";
import { BaseDirectTransferTest } from "test/direct-transfer/BaseDirectTransferTest.t.sol";

/// @notice Unit tests for SimpleBeacon.
/// @dev Adapted from OpenZeppelin's UpgradeableBeacon.test.js — see
///      https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/test/proxy/beacon/UpgradeableBeacon.test.js
///      SimpleBeacon intentionally diverges from OZ by not emitting Upgraded on construction
///      (see test_NoUpgradedEventOnConstruction).
contract SimpleBeaconUnitTest is BaseDirectTransferTest {

    DummyImplV1 v1;
    DummyImplV2 v2;
    SimpleBeacon localBeacon;

    function setUp() public override {
        super.setUp();
        v1 = new DummyImplV1();
        v2 = new DummyImplV2();
        localBeacon = new SimpleBeacon(address(v1), beaconAdmin);
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_ConstructorImplementationNotContract() public {
        address eoa = makeAddr("eoa");

        vm.expectRevert(abi.encodeWithSelector(SimpleBeacon.InvalidImplementation.selector, eoa));
        new SimpleBeacon(eoa, beaconAdmin);
    }

    function test_ReturnsImplementation() public view {
        assertEq(localBeacon.implementation(), address(v1), "implementation must equal ctor arg");
    }

    function test_OwnerIsSetByConstructor() public view {
        assertEq(localBeacon.owner(), beaconAdmin, "owner must equal ctor admin arg");
    }

    function test_NoUpgradedEventOnConstruction() public {
        vm.recordLogs();
        new SimpleBeacon(address(v1), beaconAdmin);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 upgradedTopic = keccak256("Upgraded(address)");
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics.length == 0 || logs[i].topics[0] != upgradedTopic,
                "constructor must not emit Upgraded (intentional divergence from OZ)"
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                               UPGRADE
    //////////////////////////////////////////////////////////////*/

    function test_CanBeUpgradedByOwner() public {
        vm.expectEmit(true, true, true, true, address(localBeacon));
        emit Upgraded(address(v2));
        vm.prank(beaconAdmin);
        localBeacon.upgradeTo(address(v2));

        assertEq(localBeacon.implementation(), address(v2), "implementation must be upgraded to v2");
    }

    function test_RevertWhen_UpgradeToNonContract() public {
        address eoa = makeAddr("eoa");

        vm.prank(beaconAdmin);
        vm.expectRevert(abi.encodeWithSelector(SimpleBeacon.InvalidImplementation.selector, eoa), address(localBeacon));
        localBeacon.upgradeTo(eoa);
    }

    function test_RevertWhen_UpgradeByNonOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user), address(localBeacon));
        localBeacon.upgradeTo(address(v2));
    }

}

/*//////////////////////////////////////////////////////////////
                           PER-FILE MOCKS
//////////////////////////////////////////////////////////////*/

contract DummyImplV1 {

    function version() external pure returns (string memory) {
        return "V1";
    }

}

contract DummyImplV2 {

    function version() external pure returns (string memory) {
        return "V2";
    }

}
