// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { SimpleBeacon } from "src/direct-transfer/SimpleBeacon.sol";

/// @notice Minimal BeaconProxy compatible with Shanghai EVM.
///         Stores the beacon address as an immutable and delegates all calls to the beacon's implementation.
contract SimpleBeaconProxy {

    /// @dev ERC-1967 beacon slot (to let explorers know this is a beacon proxy):
    /// bytes32(uint256(keccak256("eip1967.proxy.beacon")) - 1)
    bytes32 private constant _ERC1967_BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;
    address private immutable _beacon;

    error InvalidBeacon(address beacon);
    error InvalidImplementation(address implementation);

    constructor(address beacon_, bytes memory data) {
        if (beacon_.code.length == 0) revert InvalidBeacon(beacon_);

        address impl = SimpleBeacon(beacon_).implementation();
        if (impl.code.length == 0) revert InvalidImplementation(impl);

        // Store beacon address in ERC-1967 slot for explorer tooling.
        assembly {
            sstore(_ERC1967_BEACON_SLOT, beacon_)
        }

        _beacon = beacon_;
        if (data.length > 0) {
            (bool success, bytes memory returndata) = impl.delegatecall(data);
            if (!success) {
                assembly {
                    revert(add(returndata, 32), mload(returndata))
                }
            }
        }
    }

    fallback() external payable {
        address impl = SimpleBeacon(_beacon).implementation();
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

}
