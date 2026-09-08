// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { Auth, Authority } from "@solmate/auth/Auth.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";

/**
 * @custom:security-contact security@paxoslabs.com
 */
contract OracleRelay is Auth {

    address public implementation;
    bytes dataToCallWith = abi.encodeWithSignature("getRate()");

    event OracleRelay__ImplementationAddressSet(address newImplementation);
    event OracleRelay__DataToCallWithSet(bytes newDataToCallWith);

    error FailedCall(bytes b);
    error OracleRelay__ImplementationNotSet();
    error OracleRelay__ImplementationMustNotBeZero();
    error OracleRelay__ImplementationReturnedZero(address implementation, bytes data);

    constructor(address _owner) Auth(_owner, Authority(address(0))) { }

    function getRate() external view returns (uint256) {
        if (implementation == address(0)) {
            revert OracleRelay__ImplementationNotSet();
        }

        (bool success, bytes memory result) = implementation.staticcall(dataToCallWith);
        if (success) {
            uint256 val = abi.decode(result, (uint256));
            if (val == 0) {
                revert OracleRelay__ImplementationReturnedZero(implementation, dataToCallWith);
            }

            return val;
        } else {
            revert FailedCall(result);
        }
    }

    function setImplementation(address _implementation) external requiresAuth {
        if (_implementation == address(0)) {
            revert OracleRelay__ImplementationMustNotBeZero();
        }

        implementation = _implementation;
        emit OracleRelay__ImplementationAddressSet(_implementation);
    }

    function setDataToCallWith(bytes calldata data) external requiresAuth {
        dataToCallWith = data;
        emit OracleRelay__DataToCallWithSet(data);
    }

}
