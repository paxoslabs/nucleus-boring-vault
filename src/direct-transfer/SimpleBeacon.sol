// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

/// @notice Minimal UpgradeableBeacon compatible with Shanghai EVM.
contract SimpleBeacon {

    address public implementation;
    address public owner;

    error NotOwner();
    error InvalidImplementation(address impl);

    event Upgraded(address indexed implementation);

    constructor(address _implementation, address _owner) {
        if (_implementation.code.length == 0) revert InvalidImplementation(_implementation);
        implementation = _implementation;
        owner = _owner;
    }

    function upgradeTo(address newImplementation) external {
        if (msg.sender != owner) revert NotOwner();
        if (newImplementation.code.length == 0) revert InvalidImplementation(newImplementation);
        implementation = newImplementation;
        emit Upgraded(newImplementation);
    }

}
