// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Minimal UpgradeableBeacon compatible with Shanghai EVM.
contract SimpleBeacon is Ownable {

    address public implementation;

    error InvalidImplementation(address impl);

    event Upgraded(address indexed implementation);

    constructor(address _implementation, address _owner) Ownable(_owner) {
        if (_implementation.code.length == 0) revert InvalidImplementation(_implementation);
        implementation = _implementation;
    }

    function upgradeTo(address newImplementation) external onlyOwner {
        if (newImplementation.code.length == 0) revert InvalidImplementation(newImplementation);
        implementation = newImplementation;
        emit Upgraded(newImplementation);
    }

}
