// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { IRateProvider } from "src/interfaces/IRateProvider.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { IAuth } from "src/interfaces/IAuth.sol";

interface IAccountantWithRateProviders is IAuth {

    function pause() external;
    function unpause() external;
    function updateDelay(uint32 minimumUpdateDelayInSeconds) external;
    function updateUpper(uint16 allowedExchangeRateChangeUpper) external;
    function updateLower(uint16 allowedExchangeRateChangeLower) external;
    function updateManagementFee(uint16 managementFee) external;
    function updatePerformanceFee(uint16 performanceFee) external;
    function updatePayoutAddress(address payoutAddress) external;
    function setRateProviderData(ERC20 asset, bool isPeggedToBase, address rateProvider) external;
    function resetHighestExchangeRate() external;
    function updateExchangeRate(uint96 newExchangeRate) external;
    function claimFees(ERC20 feeAsset) external;
    function getRate() external view returns (uint256 rate);
    function getRateSafe() external view returns (uint256 rate);
    function getRateInQuote(ERC20 quote) external view returns (uint256 rateInQuote);
    function getRateInQuoteSafe(ERC20 quote) external view returns (uint256 rateInQuote);
    function accountantState()
        external
        view
        returns (
            address payoutAddress,
            uint128 feesOwedInBase,
            uint128 totalSharesLastUpdate,
            uint96 exchangeRate,
            uint96 highestExchangeRate,
            uint16 allowedExchangeRateChangeUpper,
            uint16 allowedExchangeRateChangeLower,
            uint64 lastUpdateTimestamp,
            bool isPaused,
            uint32 minimumUpdateDelayInSeconds,
            uint16 managementFee,
            uint16 performanceFee
        );
    function rateProviderData(ERC20 asset) external view returns (bool isPeggedToBase, IRateProvider rateProvider);
    function base() external view returns (ERC20);
    function decimals() external view returns (uint8);
    function vault() external view returns (BoringVault);

}
