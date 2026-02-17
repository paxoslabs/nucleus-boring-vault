// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

import { Authority } from "@solmate/auth/Auth.sol";

interface IAuth {

    function setAuthority(Authority newAuthority) external;
    function transferOwnership(address newOwner) external;
    function owner() external view returns (address);
    function authority() external view returns (Authority);

}
