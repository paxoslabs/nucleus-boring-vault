// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { IFeeModule, IERC20 } from "src/interfaces/IFeeModule.sol";
import { FixedPointMathLib } from "solmate/utils/FixedPointMathLib.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/**
 * @title SimpleFeeModule
 * @notice A simple fee module implementation that charges a percentage fee
 * @dev Fees are sent to a designated fee recipient
 * @custom:security-contact security@molecularlabs.io
 */
contract SimpleFeeModule is IFeeModule {

    using FixedPointMathLib for uint256;

    uint256 constant ONE_HUNDRED_PERCENT = 10_000;
    uint256 public immutable offerFeePercentage;

    error FeePercentageTooHigh(uint256 feePercentage, uint256 maxAllowed);

    /**
     * @notice Initialize the SimpleFeeModule
     * @param _offerFeePercentage Fee percentage on offer assets in basis points
     */
    constructor(uint256 _offerFeePercentage) {
        if (_offerFeePercentage > ONE_HUNDRED_PERCENT) {
            revert FeePercentageTooHigh(_offerFeePercentage, ONE_HUNDRED_PERCENT);
        }

        offerFeePercentage = _offerFeePercentage;
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
        feeAmount = amount.mulDivUp(offerFeePercentage, ONE_HUNDRED_PERCENT);
    }

}
