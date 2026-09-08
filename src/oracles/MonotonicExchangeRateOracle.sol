// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { Auth, Authority } from "@solmate/auth/Auth.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";

/**
 * @custom:security-contact security@paxoslabs.com
 */
contract MonotonicExchangeRateOracle is Auth {

    AccountantWithRateProviders public accountant;
    uint8 public immutable accountantDecimals;

    // Stores in the Accountant Decimals, conversion to 18 decimals is done at the return step
    uint256 public highwaterMark;

    event MonotonicExchangeRateOracle__HighwaterMarkUpdated(uint256 newHighwaterMark);
    event MonotonicExchangeRateOracle__AccountantUpdated(AccountantWithRateProviders newAccountant);

    error MonotonicExchangeRateOracle__NewAccountantDecimalsMissmatch();
    error MonotonicExchangeRateOracle__NewAccountantReturnsZero();

    constructor(address _owner, AccountantWithRateProviders _accountant) Auth(_owner, Authority(address(0))) {
        accountant = _accountant;
        accountantDecimals = _accountant.decimals();

        uint256 rate = _accountant.getRate();
        if (rate == 0) {
            revert MonotonicExchangeRateOracle__NewAccountantReturnsZero();
        }
        highwaterMark = rate;
        emit MonotonicExchangeRateOracle__HighwaterMarkUpdated(highwaterMark);
    }

    /**
     * @dev setAccountant and the decimals as reported
     */
    function setAccountant(AccountantWithRateProviders _newAccountant) external requiresAuth {
        if (_newAccountant.decimals() != accountantDecimals) {
            revert MonotonicExchangeRateOracle__NewAccountantDecimalsMissmatch();
        }
        if (_newAccountant.getRate() == 0) {
            revert MonotonicExchangeRateOracle__NewAccountantReturnsZero();
        }
        accountant = _newAccountant;
        emit MonotonicExchangeRateOracle__AccountantUpdated(_newAccountant);
    }

    /**
     * @dev setHighwaterMark manually, must be done in accountantDecimals
     */
    function setHighwaterMark(uint256 _newHighwaterMark) external requiresAuth {
        highwaterMark = _newHighwaterMark;
        emit MonotonicExchangeRateOracle__HighwaterMarkUpdated(_newHighwaterMark);
    }

    /**
     * @dev function to update the highwater mark with the accountant's getRate if and only if it's the highest rate
     * yet.
     *  Also returns the new highwater mark in 18 decimals
     */
    function update() external returns (uint256) {
        uint256 rate = accountant.getRate();
        if (rate > highwaterMark) {
            highwaterMark = rate;
            emit MonotonicExchangeRateOracle__HighwaterMarkUpdated(highwaterMark);
        }
        return _convertTo18Decimals(highwaterMark);
    }

    /**
     * @dev function to return the highwater mark accountant rate with the following considerations
     *  1. The rate must never go down (excluding manual owner updates)
     *  2. The rate must be returned in 18 decimals
     */
    function getRate() external view returns (uint256) {
        return _convertTo18Decimals(highwaterMark);
    }

    /**
     * @dev convert a rate to 18 decimals before returning in getRate
     */
    function _convertTo18Decimals(uint256 _rate) internal view returns (uint256) {
        if (accountantDecimals == 18) {
            return _rate;
        } else if (accountantDecimals < 18) {
            uint8 diff = 18 - accountantDecimals;
            return _rate * 10 ** diff;
        } else {
            uint8 diff = accountantDecimals - 18;
            return _rate / 10 ** diff;
        }
    }

}
