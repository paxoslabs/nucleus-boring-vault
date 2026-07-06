// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { UManager } from "src/micro-managers/UManager.sol";

abstract contract RateLimitUManager is UManager {

    // ========================================= STATE =========================================

    /**
     * @notice The period in seconds for the rate limit.
     */
    uint16 public period;

    /**
     * @notice The number of calls allowed per period.
     */
    uint16 public allowedCallsPerPeriod;

    /**
     * @notice The number of calls made in the current period.
     */
    mapping(uint256 => uint256) public callCountPerPeriod;

    //============================== ERRORS ===============================

    error RateLimitUManager__CallCountExceeded();

    //============================== EVENTS ===============================

    event PeriodUpdated(uint16 oldPeriod, uint16 newPeriod);
    event AllowedCallsPeriodUpdated(uint16 oldAllowance, uint16 newAllowance);

    //============================== MODIFIERS ===============================

    modifier enforceRateLimit() {
        // Use parenthesis to avoid stack too deep error.
        {
            // We include this call in the current call count for period.
            uint256 currentCallCountForPeriod = callCountPerPeriod[block.timestamp % period] + 1;
            if (currentCallCountForPeriod > allowedCallsPerPeriod) {
                revert RateLimitUManager__CallCountExceeded();
            }
            callCountPerPeriod[block.timestamp % period] = currentCallCountForPeriod;
        }
        _;
    }

    constructor(address _owner, address _manager, address _boringVault) UManager(_owner, _manager, _boringVault) { }

    // ========================================= ADMIN FUNCTIONS =========================================

    /**
     * @notice Sets the duration of the period.
     * @dev Callable by MULTISIG_ROLE.
     */
    function setPeriod(uint16 _period) external requiresAuth {
        emit PeriodUpdated(period, _period);
        period = _period;
    }

    /**
     * @notice Sets the number of calls allowed per period.
     * @dev Callable by MULTISIG_ROLE.
     */
    function setAllowedCallsPerPeriod(uint16 _allowedCallsPerPeriod) external requiresAuth {
        emit AllowedCallsPeriodUpdated(allowedCallsPerPeriod, _allowedCallsPerPeriod);
        allowedCallsPerPeriod = _allowedCallsPerPeriod;
    }

}
