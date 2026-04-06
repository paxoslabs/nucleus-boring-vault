// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { SimpleBeacon } from "src/direct-transfer/SimpleBeacon.sol";

/// @notice Minimal BeaconProxy compatible with Shanghai EVM.
///         Stores the beacon address as an immutable and delegates all calls to the beacon's implementation.
contract SimpleBeaconProxy {

    address private immutable _beacon;

    constructor(address beacon_, bytes memory data) {
        _beacon = beacon_;
        if (data.length > 0) {
            address impl = SimpleBeacon(beacon_).implementation();
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
