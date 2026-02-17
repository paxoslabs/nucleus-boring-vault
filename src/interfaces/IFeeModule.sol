// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IFeeModule
 * @notice Interface for modular fee calculation logic
 * @dev Allows different fee implementations to be plugged into the Queue contract
 */
interface IFeeModule {

    /**
     * @notice calculate fees on offer assets for a single order being submitted
     * @param amount deposited
     * @param offerAsset address
     * @param wantAsset address
     * @param receiver address of the want asset
     * @return feeAmount to take
     */
    function calculateOfferFees(
        uint256 amount,
        IERC20 offerAsset,
        IERC20 wantAsset,
        address receiver
    )
        external
        view
        returns (uint256 feeAmount);

}
