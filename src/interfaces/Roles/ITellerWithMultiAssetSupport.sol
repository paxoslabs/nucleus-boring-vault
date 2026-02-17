// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";
import { IAuth } from "src/interfaces/IAuth.sol";

interface ITellerWithMultiAssetSupport is IAuth {

    function pause() external;
    function unpause() external;
    function addDepositAsset(ERC20 asset) external;
    function addWithdrawAsset(ERC20 asset) external;
    function removeDepositAsset(ERC20 asset) external;
    function removeWithdrawAsset(ERC20 asset) external;
    function setShareLockPeriod(uint64 _shareLockPeriod) external;
    function beforeTransfer(address from) external view;
    function refundDeposit(
        uint256 nonce,
        address receiver,
        address depositAsset,
        uint256 depositAmount,
        uint256 shareAmount,
        uint256 depositTimestamp,
        uint256 shareLockUpPeriodAtTimeOfDeposit
    )
        external;
    function deposit(ERC20 depositAsset, uint256 depositAmount, uint256 minimumMint) external returns (uint256 shares);
    function depositWithPermit(
        ERC20 depositAsset,
        uint256 depositAmount,
        uint256 minimumMint,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
        returns (uint256 shares);
    function bulkWithdraw(
        ERC20 withdrawAsset,
        uint256 shareAmount,
        uint256 minimumAssets,
        address to
    )
        external
        returns (uint256 assetsOut);
    function isDepositSupported(ERC20 asset) external view returns (bool);
    function isWithdrawSupported(ERC20 asset) external view returns (bool);
    function depositNonce() external view returns (uint96);
    function shareLockPeriod() external view returns (uint64);
    function isPaused() external view returns (bool);
    function publicDepositHistory(uint256 nonce) external view returns (bytes32);
    function shareUnlockTime(address user) external view returns (uint256);
    function vault() external view returns (BoringVault);
    function accountant() external view returns (AccountantWithRateProviders);

}
