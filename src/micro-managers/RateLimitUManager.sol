// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { UManager } from "src/micro-managers/UManager.sol";

/**
 * @title Rate Limit UManager
 * @notice Abstract UManager that enforces a maximum number of manage calls within a rolling time window.
 */
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

    /// @notice Thrown when the number of calls in the current period exceeds the allowed limit.
    error RateLimitUManager__CallCountExceeded();

    //============================== EVENTS ===============================

    /// @notice Emitted when the rate limit period is updated.
    event PeriodUpdated(uint16 oldPeriod, uint16 newPeriod);
    /// @notice Emitted when the number of allowed calls per period is updated.
    event AllowedCallsPeriodUpdated(uint16 oldAllowance, uint16 newAllowance);

    //============================== MODIFIERS ===============================

    /**
     * @notice Enforces the configured rate limit on the function it modifies.
     * @dev Increments the call count for the current period and reverts if the limit is exceeded.
     */
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

    /**
     * @notice Constructor for the RateLimitUManager.
     * @param _owner The address that will own this contract.
     * @param _manager The ManagerWithMerkleVerification this uManager works with.
     * @param _boringVault The BoringVault this uManager works with.
     */
    constructor(address _owner, address _manager, address _boringVault) UManager(_owner, _manager, _boringVault) { }

    // ========================================= ADMIN FUNCTIONS =========================================

    /**
     * @notice Sets the duration of the period.
     * @param _period The new period duration in seconds.
     * @dev Callable by MULTISIG_ROLE.
     */
    function setPeriod(uint16 _period) external requiresAuth {
        emit PeriodUpdated(period, _period);
        period = _period;
    }

    /**
     * @notice Sets the number of calls allowed per period.
     * @param _allowedCallsPerPeriod The new number of calls allowed per period.
     * @dev Callable by MULTISIG_ROLE.
     */
    function setAllowedCallsPerPeriod(uint16 _allowedCallsPerPeriod) external requiresAuth {
        emit AllowedCallsPeriodUpdated(allowedCallsPerPeriod, _allowedCallsPerPeriod);
        allowedCallsPerPeriod = _allowedCallsPerPeriod;
    }

}
