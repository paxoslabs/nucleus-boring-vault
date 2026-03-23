// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { IFeeModule, IERC20 } from "src/interfaces/IFeeModule.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";
import { FixedPointMathLib } from "solmate/utils/FixedPointMathLib.sol";
import { Auth, Authority } from "solmate/auth/Auth.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";

/**
 * @title WithdrawQueueAssetSpecificFeeModule
 * @notice A fee module for the WithdrawQueue allowing per-asset percentage and flat fees.
 * @dev This module is scoped to a single accountant (and therefore a single vault). The accountant's exchange rate
 * for the withdraw asset is used to convert flat fees from withdraw-asset denomination to share denomination at
 * calculation time so that flat fees remain stable in withdraw-asset terms regardless of vault appreciation.
 */
contract WithdrawQueueAssetSpecificFeeModule is IFeeModule, Auth {

    using FixedPointMathLib for uint256;

    struct FeeData {
        uint256 feePercentage;
        uint256 flatFee;
    }

    mapping(IERC20 => FeeData) public withdrawTokenFeeData;

    uint256 public constant ONE_HUNDRED_PERCENT = 10_000;

    /**
     * @notice The accountant used to convert flat fees from withdraw-asset denomination to shares.
     */
    AccountantWithRateProviders public immutable accountant;

    error FeePercentageTooHigh(uint256 feePercentage, uint256 maxAllowed);
    error ZeroAddress();
    error VaultMismatch();
    error RateInQuoteZero();

    event FeeDataUpdated(IERC20 indexed withdrawToken, uint256 feePercentage, uint256 flatFee);

    constructor(address _owner, address _accountant) Auth(_owner, Authority(address(0))) {
        if (_owner == address(0)) revert ZeroAddress();
        if (_accountant == address(0)) revert ZeroAddress();
        accountant = AccountantWithRateProviders(_accountant);
    }

    /**
     * @notice Set fee data for a specific withdraw token.
     * @dev flatFee is denominated in the withdraw token. At fee calculation time, the flat fee is converted to share
     * denomination using the accountant's exchange rate
     * for that withdraw token.
     * @param withdrawToken to configure fees for
     * @param feePercentage in bps (10_000)
     * @param flatFee IMPORTANT must be in terms of asset decimals and not the base asset/vault
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
        // As this is used for withdrawals, the offerAsset MUST equal the boring vault assigned to our accountant
        if (address(offerAsset) != address(accountant.vault())) revert VaultMismatch();

        // Fee data is mapped to wantAssets (what the user is withdrawing)
        FeeData memory feeData = withdrawTokenFeeData[wantAsset];
        // mulDivUp, round in protocols favor
        uint256 percentageFee = amount.mulDivUp(feeData.feePercentage, ONE_HUNDRED_PERCENT);

        uint256 rateInQuote = accountant.getRateInQuoteSafe(ERC20(address(wantAsset)));

        if (rateInQuote == 0) revert RateInQuoteZero();

        // DECIMALS MATH:
        // QUOTE_ASSET * BASE_ASSET / QUOTE_ASSET = Flat Fee In Quote Assets
        // NOTE: This is why it's important that flat fees are provided per asset and in terms of that asset's decimals.
        uint256 flatFeeInShares =
            feeData.flatFee > 0 ? feeData.flatFee.mulDivUp(10 ** accountant.decimals(), rateInQuote) : 0;

        feeAmount = percentageFee + flatFeeInShares;
    }

}
