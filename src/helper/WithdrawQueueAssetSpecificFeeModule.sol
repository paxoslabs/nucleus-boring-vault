// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { IFeeModule, IERC20 } from "src/interfaces/IFeeModule.sol";
import { FixedPointMathLib } from "solmate/utils/FixedPointMathLib.sol";
import { Auth, Authority } from "solmate/auth/Auth.sol";

/**
 * @title WithdrawQueueAssetSpecificFeeModule
 * @notice A fee module for withdrawals allowing per-asset percentage and flat fees.
 * @dev Fees are calculated on the withdraw (want) asset amount. The flat fee is stored directly in the withdraw
 * token's denomination (e.g., 2e6 = $2 for USDC, 1e15 = 0.001 ETH for WETH), so no exchange-rate conversion
 * is needed at calculation time.
 */
contract WithdrawQueueAssetSpecificFeeModule is IFeeModule, Auth {

    using FixedPointMathLib for uint256;

    struct FeeData {
        uint256 feePercentage;
        uint256 flatFee;
    }

    mapping(IERC20 => FeeData) public withdrawTokenFeeData;

    uint256 public constant ONE_HUNDRED_PERCENT = 10_000;

    error FeePercentageTooHigh(uint256 feePercentage, uint256 maxAllowed);
    error ZeroAddress();

    event FeeDataUpdated(IERC20 indexed withdrawToken, uint256 feePercentage, uint256 flatFee);

    constructor(address _owner) Auth(_owner, Authority(address(0))) {
        if (_owner == address(0)) revert ZeroAddress();
    }

    /**
     * @notice Set fee data for a specific withdraw token.
     * @dev flatFee is denominated in the withdraw token (e.g., 2e6 = $2 for USDC, 1e15 = 0.001 ETH for WETH).
     */
    function setFeeData(IERC20 withdrawToken, uint256 feePercentage, uint256 flatFee) external requiresAuth {
        if (feePercentage > ONE_HUNDRED_PERCENT) revert FeePercentageTooHigh(feePercentage, ONE_HUNDRED_PERCENT);
        withdrawTokenFeeData[withdrawToken] = FeeData(feePercentage, flatFee);
        emit FeeDataUpdated(withdrawToken, feePercentage, flatFee);
    }

    function calculateOfferFees(
        uint256 amount,
        IERC20 offerAsset,
        IERC20 wantAsset,
        address receiver
    )
        external
        view
        override
        returns (uint256 feeAmount)
    {
        FeeData memory feeData = withdrawTokenFeeData[wantAsset];
        uint256 percentageFee = amount.mulDivUp(feeData.feePercentage, ONE_HUNDRED_PERCENT);
        feeAmount = percentageFee + feeData.flatFee;
    }

}
