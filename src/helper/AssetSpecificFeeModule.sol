// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { IFeeModule, IERC20 } from "src/interfaces/IFeeModule.sol";
import { FixedPointMathLib } from "solmate/utils/FixedPointMathLib.sol";
import { Auth, Authority } from "solmate/auth/Auth.sol";

/**
 * @title AssetSpecificFeeModule
 * @notice A fee module allowing fees per asset
 */
contract AssetSpecificFeeModule is IFeeModule, Auth {

    using FixedPointMathLib for uint256;

    struct FeeData {
        uint256 feePercentage;
        uint256 flatFee;
    }

    mapping(IERC20 => FeeData) public depositTokenFeeData;

    uint256 public constant ONE_HUNDRED_PERCENT = 10_000;

    error FeePercentageTooHigh(uint256 feePercentage, uint256 maxAllowed);
    error ZeroAddress();

    event FeeDataUpdated(IERC20 indexed depositToken, uint256 feePercentage, uint256 flatFee);

    constructor(address _owner) Auth(_owner, Authority(address(0))) {
        if (_owner == address(0)) revert ZeroAddress();
    }

    function setFeeData(IERC20 depositToken, uint256 feePercentage, uint256 flatFee) external requiresAuth {
        if (feePercentage > ONE_HUNDRED_PERCENT) revert FeePercentageTooHigh(feePercentage, ONE_HUNDRED_PERCENT);
        depositTokenFeeData[depositToken] = FeeData(feePercentage, flatFee);
        emit FeeDataUpdated(depositToken, feePercentage, flatFee);
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
        FeeData memory feeData = depositTokenFeeData[offerAsset];
        uint256 percentageFee = amount.mulDivUp(feeData.feePercentage, ONE_HUNDRED_PERCENT);
        uint256 flatFee = feeData.flatFee;

        feeAmount = percentageFee + flatFee;
    }

}
