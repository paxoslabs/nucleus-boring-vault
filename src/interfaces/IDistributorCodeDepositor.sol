// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { TellerWithMultiAssetSupport } from "../base/Roles/TellerWithMultiAssetSupport.sol";
import { IAuth } from "src/interfaces/IAuth.sol";

interface INativeWrapper {

    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function deposit() external payable;
    function withdraw(uint256 wad) external;
    function decimals() external view returns (uint8);

}

interface IDistributorCodeDepositor is IAuth {

    function depositNative(
        uint256 depositAmount,
        uint256 minimumMint,
        address to,
        bytes calldata distributorCode
    )
        external
        payable
        returns (uint256 shares);
    function deposit(
        ERC20 depositAsset,
        uint256 depositAmount,
        uint256 minimumMint,
        address to,
        bytes calldata distributorCode
    )
        external
        returns (uint256 shares);
    function depositWithPermit(
        ERC20 depositAsset,
        uint256 depositAmount,
        uint256 minimumMint,
        address to,
        bytes calldata distributorCode,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
        returns (uint256 shares);
    function nativeWrapper() external view returns (INativeWrapper);
    function teller() external view returns (TellerWithMultiAssetSupport);
    function boringVault() external view returns (address);
    function isNativeDepositSupported() external view returns (bool);
    function depositNonce() external view returns (uint256);

}
