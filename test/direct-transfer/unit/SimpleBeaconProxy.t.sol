// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Test, stdStorage, StdStorage, stdError, console } from "@forge-std/Test.sol";
import { SimpleBeacon } from "src/direct-transfer/SimpleBeacon.sol";
import { SimpleBeaconProxy } from "src/direct-transfer/SimpleBeaconProxy.sol";
import { BaseDirectTransferTest } from "test/direct-transfer/BaseDirectTransferTest.t.sol";

/// @notice Unit tests for SimpleBeaconProxy.
/// @dev Adapted from OpenZeppelin's BeaconProxy.test.js — see
///      https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/test/proxy/beacon/BeaconProxy.test.js
contract SimpleBeaconProxyUnitTest is BaseDirectTransferTest {

    /// @dev ERC-1967 beacon slot, mirrored from SimpleBeaconProxy.
    bytes32 constant _ERC1967_BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;

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

    function test_RevertWhen_BeaconIsNotContract() public {
        address eoa = makeAddr("eoaBeacon");

        vm.expectRevert(abi.encodeWithSelector(SimpleBeaconProxy.InvalidBeacon.selector, eoa));
        new SimpleBeaconProxy(eoa, "");
    }

    function test_RevertWhen_BeaconMissingImplementationSelector() public {
        NonCompliantBeacon nonCompliant = new NonCompliantBeacon();

        // The high-level SimpleBeacon(beacon_).implementation() call reverts when the target has
        // no matching selector; exact revert data is implementation-defined so we match any revert.
        vm.expectRevert();
        new SimpleBeaconProxy(address(nonCompliant), "");
    }

    function test_RevertWhen_ImplementationIsNotContract() public {
        address eoaImpl = makeAddr("eoaImpl");
        MockBeaconReturningAddress mockBeacon = new MockBeaconReturningAddress(eoaImpl);

        vm.expectRevert(abi.encodeWithSelector(SimpleBeaconProxy.InvalidImplementation.selector, eoaImpl));
        new SimpleBeaconProxy(address(mockBeacon), "");
    }

    /// @dev Mirrors OpenZeppelin BeaconProxy.test.js `assertInitialized({value, balance})`:
    ///      beacon slot == beacon, proxy `value()` == expected, proxy ETH balance == expected.
    function _assertInitialized(SimpleBeaconProxy proxy, uint256 expectedValue, uint256 expectedBalance) internal {
        bytes32 stored = vm.load(address(proxy), _ERC1967_BEACON_SLOT);
        assertEq(address(uint160(uint256(stored))), address(localBeacon), "beacon slot must equal beacon");
        assertEq(DummyImplV1(address(proxy)).value(), expectedValue, "proxy value must match expected");
        assertEq(address(proxy).balance, expectedBalance, "proxy balance must match expected");
    }

    function test_NoInitialization() public {
        SimpleBeaconProxy proxy = new SimpleBeaconProxy(address(localBeacon), "");

        _assertInitialized(proxy, 0, 0);
    }

    function test_InitializationRunsViaDelegatecall() public {
        uint256 seed = 55;
        bytes memory initData = abi.encodeCall(DummyImplV1.setValue, (seed));

        SimpleBeaconProxy proxy = new SimpleBeaconProxy(address(localBeacon), initData);

        _assertInitialized(proxy, seed, 0);
        assertEq(v1.value(), 0, "impl's own storage must be untouched by proxy initialization");
    }

    function test_RevertingInitializationBubblesReason() public {
        // OZ's BeaconProxy.test.js uses a `reverts()` function on DummyImplementation itself rather
        // than a separate contract; we mirror that by putting `reverts()` on DummyImplV1.
        bytes memory initData = abi.encodeCall(DummyImplV1.reverts, ());

        vm.expectRevert(bytes("DummyImplV1 reverted"));
        new SimpleBeaconProxy(address(localBeacon), initData);
    }

    function test_BeaconSlotIsSetToBeacon() public {
        SimpleBeaconProxy proxy = new SimpleBeaconProxy(address(localBeacon), "");

        bytes32 stored = vm.load(address(proxy), _ERC1967_BEACON_SLOT);
        assertEq(
            address(uint160(uint256(stored))),
            address(localBeacon),
            "ERC-1967 beacon slot must store the beacon address"
        );
    }

    /*//////////////////////////////////////////////////////////////
                               FALLBACK
    //////////////////////////////////////////////////////////////*/

    function test_FallbackDelegatesToImplementation() public {
        SimpleBeaconProxy proxy = new SimpleBeaconProxy(address(localBeacon), "");

        assertEq(DummyImplV1(address(proxy)).version(), "V1", "fallback must delegate to v1");
    }

    function test_FallbackReturnDataPassesThrough() public {
        SimpleBeaconProxy proxy = new SimpleBeaconProxy(address(localBeacon), "");

        (uint256 a, address b, string memory c, bytes memory d) = DummyImplV1(address(proxy)).returnTuple();

        assertEq(a, 42, "tuple uint matches");
        assertEq(b, address(0xBEEF), "tuple address matches");
        assertEq(c, "hello", "tuple string matches");
        assertEq(d, hex"deadbeef", "tuple bytes matches");
    }

    function test_FallbackBubblesRevertsFromImplementation() public {
        SimpleBeaconProxy proxy = new SimpleBeaconProxy(address(localBeacon), "");

        vm.expectRevert(abi.encodeWithSelector(DummyImplV1.CustomErr.selector, uint256(123)));
        DummyImplV1(address(proxy)).revertWithCustomError();
    }

    function test_FallbackIsPayableAndForwardsValue() public {
        SimpleBeaconProxy proxy = new SimpleBeaconProxy(address(localBeacon), "");
        vm.deal(address(this), 1 ether);

        uint256 reportedMsgValue = DummyImplV1(address(proxy)).getEthAndMsgValue{ value: 1 ether }();

        assertEq(reportedMsgValue, 1 ether, "impl must observe msg.value through fallback");
        assertEq(address(proxy).balance, 1 ether, "proxy must retain forwarded ETH (delegatecall preserves balance)");
    }

    /*//////////////////////////////////////////////////////////////
                           BEACON UPGRADE
    //////////////////////////////////////////////////////////////*/

    function test_UpgradingBeaconUpgradesProxyLogic() public {
        // Mirrors OZ BeaconProxy.test.js `upgrade a proxy by upgrading its beacon`: initialize with a
        // value, read it back, read V1 version, upgrade, read V2 version.
        uint256 value = 10;
        bytes memory initData = abi.encodeCall(DummyImplV1.setValue, (value));
        SimpleBeaconProxy proxy = new SimpleBeaconProxy(address(localBeacon), initData);

        assertEq(DummyImplV1(address(proxy)).value(), value, "initial value must be set");
        assertEq(DummyImplV1(address(proxy)).version(), "V1", "pre-upgrade: v1 logic");

        vm.prank(beaconAdmin);
        localBeacon.upgradeTo(address(v2));

        assertEq(DummyImplV2(address(proxy)).version(), "V2", "post-upgrade: v2 logic through same proxy");
    }

    function test_MultipleProxiesShareBeaconUpgrade() public {
        // Mirrors OZ BeaconProxy.test.js `upgrade 2 proxies by upgrading shared beacon`: each proxy
        // is initialized with a distinct value; both follow the shared beacon into V2.
        uint256 value1 = 10;
        uint256 value2 = 42;
        bytes memory data1 = abi.encodeCall(DummyImplV1.setValue, (value1));
        bytes memory data2 = abi.encodeCall(DummyImplV1.setValue, (value2));
        SimpleBeaconProxy proxyA = new SimpleBeaconProxy(address(localBeacon), data1);
        SimpleBeaconProxy proxyB = new SimpleBeaconProxy(address(localBeacon), data2);

        assertEq(DummyImplV1(address(proxyA)).value(), value1, "proxyA initial value");
        assertEq(DummyImplV1(address(proxyB)).value(), value2, "proxyB initial value");
        assertEq(DummyImplV1(address(proxyA)).version(), "V1", "proxyA pre-upgrade");
        assertEq(DummyImplV1(address(proxyB)).version(), "V1", "proxyB pre-upgrade");

        vm.prank(beaconAdmin);
        localBeacon.upgradeTo(address(v2));

        assertEq(DummyImplV2(address(proxyA)).version(), "V2", "proxyA follows shared beacon upgrade");
        assertEq(DummyImplV2(address(proxyB)).version(), "V2", "proxyB follows shared beacon upgrade");
    }

}

/*//////////////////////////////////////////////////////////////
                           PER-FILE MOCKS
//////////////////////////////////////////////////////////////*/

contract DummyImplV1 {

    uint256 public value;

    error CustomErr(uint256 code);

    function setValue(uint256 v) external {
        value = v;
    }

    function version() external pure returns (string memory) {
        return "V1";
    }

    function returnTuple() external pure returns (uint256, address, string memory, bytes memory) {
        return (42, address(0xBEEF), "hello", hex"deadbeef");
    }

    function revertWithCustomError() external pure {
        revert CustomErr(123);
    }

    function reverts() external pure {
        require(false, "DummyImplV1 reverted");
    }

    function getEthAndMsgValue() external payable returns (uint256) {
        return msg.value;
    }

}

contract DummyImplV2 {

    uint256 public value;

    function version() external pure returns (string memory) {
        return "V2";
    }

}

/// @notice Beacon-shaped contract with no `implementation()` selector, used to exercise the
///         SimpleBeaconProxy path where the external implementation() call fails.
contract NonCompliantBeacon { }

/// @notice Beacon that exposes `implementation()` returning a configurable address. Used to feed
///         SimpleBeaconProxy a beacon whose implementation is not a contract.
contract MockBeaconReturningAddress {

    address public implementation;

    constructor(address _impl) {
        implementation = _impl;
    }

}

