// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { DistributorCodeDepositor } from "./DistributorCodeDepositor.sol";
import { Attestation } from "@predicate/interfaces/IPredicateRegistry.sol";

interface WarpRoute {

    function transferRemote(
        uint32 _destination,
        bytes32 _recipient,
        uint256 _amountOrId
    )
        external
        payable
        returns (bytes32);

}

/**
 * @notice A simple wrapper to call `deposit` on a DistributorCodeDepositor(DCD) and
 * `transferRemote` on a WarpRoute in one transaction.
 *
 * This contract can only be used with a defined DCD. If a new DCD is deployed,
 * a new Wrapper must be deployed.
 *
 * @custom:security-contact security@molecularlabs.io
 */
contract WarpRouteWrapper {

    using SafeTransferLib for ERC20;

    error ZeroAddress();

    DistributorCodeDepositor public immutable dcd;
    BoringVault public immutable boringVault;
    WarpRoute public immutable warpRoute;
    uint32 public immutable destination;

    constructor(DistributorCodeDepositor _dcd, WarpRoute _warpRoute, uint32 _destination, address _owner) {
        if (_owner == address(0)) revert ZeroAddress();
        if (address(_dcd) == address(0)) revert ZeroAddress();
        if (address(_warpRoute) == address(0)) revert ZeroAddress();

        dcd = _dcd;
        warpRoute = _warpRoute;
        destination = _destination;

        boringVault = _dcd.teller().vault();

        // Infinite approvals to the warpRoute okay because this contract will
        // never hold any balance aside from donations.
        boringVault.approve(address(warpRoute), type(uint256).max);
    }

    /**
     * @notice Calls `deposit` on the DCD and `transferRemote` on the WarpRoute
     * in one transaction.
     *
     * @dev Two approvals are required: the caller must approve this contract for
     * `depositAsset`, and this contract approves the DCD for `depositAsset` on
     * each call. The warpRoute approval for boringVault shares is set once in
     * the constructor.
     *
     * @param depositAsset The ERC20 token to deposit
     * @param depositAmount The amount to deposit
     * @param minimumMint Minimum amount of shares (post-fee) to mint. Reverts otherwise.
     * @param recipient The bridge recipient on the destination chain (as bytes32)
     * @param distributorCode Indicator for which operator the token gets staked to
     * @param _attestation Predicate KYT attestation forwarded to the DCD
     */
    function depositAndBridge(
        ERC20 depositAsset,
        uint256 depositAmount,
        uint256 minimumMint,
        bytes32 recipient,
        bytes calldata distributorCode,
        Attestation calldata _attestation
    )
        external
        payable
        returns (uint256 sharesMinted, bytes32 messageId)
    {
        depositAsset.safeTransferFrom(msg.sender, address(this), depositAmount);

        if (depositAsset.allowance(address(this), address(dcd)) < depositAmount) {
            depositAsset.approve(address(dcd), type(uint256).max);
        }

        sharesMinted =
            dcd.deposit(depositAsset, depositAmount, minimumMint, address(this), distributorCode, _attestation);

        messageId = warpRoute.transferRemote{ value: msg.value }(destination, recipient, sharesMinted);
    }

}
