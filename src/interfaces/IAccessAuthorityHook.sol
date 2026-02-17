// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

/**
 * @dev Interface for an upgradeable hook contract that can provide more logic for canCallVerbose
 */
interface IAccessAuthorityHook {

    function canCallVerbose(
        address user,
        address target,
        bytes calldata data
    )
        external
        view
        returns (bool, string memory);

}
