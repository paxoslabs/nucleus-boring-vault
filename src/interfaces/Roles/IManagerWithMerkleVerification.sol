// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { BoringVault } from "src/base/BoringVault.sol";
import { BalancerVault } from "src/interfaces/BalancerVault.sol";
import { IAuth } from "src/interfaces/IAuth.sol";

interface IManagerWithMerkleVerification is IAuth {

    function setManageRoot(address strategist, bytes32 _manageRoot) external;
    function pause() external;
    function unpause() external;
    function manageVaultWithMerkleVerification(
        bytes32[][] calldata manageProofs,
        address[] calldata decodersAndSanitizers,
        address[] calldata targets,
        bytes[] calldata targetData,
        uint256[] calldata values
    )
        external;
    function flashLoan(
        address recipient,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes calldata userData
    )
        external;
    function receiveFlashLoan(
        address[] calldata tokens,
        uint256[] calldata amounts,
        uint256[] calldata feeAmounts,
        bytes calldata userData
    )
        external;
    function manageRoot(address strategist) external view returns (bytes32);
    function isPaused() external view returns (bool);
    function vault() external view returns (BoringVault);
    function balancerVault() external view returns (BalancerVault);

}
