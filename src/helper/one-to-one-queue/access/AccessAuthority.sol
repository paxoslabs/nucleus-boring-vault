// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Pausable } from "./Pausable.sol";
import { VerboseAuth, Authority } from "./VerboseAuth.sol";
import { IAccessAuthorityHook } from "src/interfaces/IAccessAuthorityHook.sol";

/**
 * @title AccessAuthority
 * @notice Abstract contract for managing access to all of a system's external functions. Examples include:
 * pausing
 * roles/ownership
 * deprecation
 * whitelist/blacklist
 * @author Based on Solmate
 * (https://github.com/transmissions11/solmate/blob/main/src/auth/authorities/RolesAuthority.sol)
 * @dev This contract contains code almost identical to Solmate's RolesAuhtority but features more verbose error
 * messages and some helpers
 * for capability setting without role checks internally.
 */
abstract contract AccessAuthority is Pausable, VerboseAuth, Authority {

    /// @notice Current deprecation step (0 = not deprecated)
    uint8 public deprecationStep;

    /// @notice Bool flag if deprecation is complete
    bool public isFullyDeprecated;

    /// @notice Hook contract for additional logic to be added to the canCallVerbose function.
    IAccessAuthorityHook public accessAuthorityHook;

    /// @notice Mapping of accepted pausers
    /// @dev We implement this instead of using Roles to eliminate the need for an AccessAuthority for your
    /// AccessAuthority to configure a pause role
    mapping(address => bool) public pausers;

    mapping(address => bytes32) public getUserRoles;

    mapping(address => mapping(bytes4 => bool)) public isCapabilityPublic;

    mapping(address => mapping(bytes4 => bytes32)) public getRolesWithCapability;

    event DeprecationContinued(uint8 newStep);
    event DeprecationFinished(uint8 newStep);
    event PauserStatusSet(address indexed pauser, bool indexed canPause);
    event UserRoleUpdated(address indexed user, uint8 indexed role, bool enabled);
    event PublicCapabilityUpdated(address indexed target, bytes4 indexed functionSig, bool enabled);
    event RoleCapabilityUpdated(uint8 indexed role, address indexed target, bytes4 indexed functionSig, bool enabled);
    event AccessAuthorityHookUpdated(address indexed oldHook, address indexed newHook);

    error DeprecationComplete();
    error NoDeprecationDefined();

    constructor(
        address _owner,
        Authority _authority,
        IAccessAuthorityHook _accessAuthorityHook,
        address[] memory _defaultPausers
    )
        VerboseAuth(_owner, _authority)
    {
        uint256 length = _defaultPausers.length;
        for (uint256 i; i < length; ++i) {
            pausers[_defaultPausers[i]] = true;
            emit PauserStatusSet(_defaultPausers[i], true);
        }

        accessAuthorityHook = _accessAuthorityHook;
        emit AccessAuthorityHookUpdated(address(0), address(_accessAuthorityHook));
    }

    /// @notice only OWNER can set the new access authority hook
    /// @dev Hook address may be 0 in order to disable it
    function setAccessAuthorityHook(IAccessAuthorityHook newHook) external virtual requiresAuthVerbose {
        address oldHook = address(accessAuthorityHook);
        accessAuthorityHook = newHook;
        emit AccessAuthorityHookUpdated(oldHook, address(newHook));
    }

    /// @notice only OWNER can set new pauser status
    function setPauserStatus(address pauser, bool canPause) external virtual requiresAuthVerbose {
        pausers[pauser] = canPause;
        emit PauserStatusSet(pauser, canPause);
    }

    /// @notice only PAUSER and OWNER can pause
    function pause() external virtual {
        if (!pausers[msg.sender] && msg.sender != owner) {
            revert VerboseAuth.Unauthorized(msg.sender, msg.data, "- Not a pauser or owner ");
        }
        _pause();
    }

    /// @notice only OWNER can unpause
    function unpause() external virtual requiresAuthVerbose {
        _unpause();
    }

    /// @notice only OWNER role
    /// @dev solmate RolesAuthority function to set public capability
    function setPublicCapability(address target, bytes4 functionSig, bool enabled) public virtual requiresAuthVerbose {
        _setPublicCapability(target, functionSig, enabled);
    }

    /// @notice only OWNER role
    /// @dev solmate RolesAuthority function to set a role's capability
    function setRoleCapability(
        uint8 role,
        address target,
        bytes4 functionSig,
        bool enabled
    )
        public
        virtual
        requiresAuthVerbose
    {
        _setRoleCapability(role, target, functionSig, enabled);
    }

    /// @notice only OWNER role
    /// @dev solmate RolesAuthority function to set a user's role
    function setUserRole(address user, uint8 role, bool enabled) public virtual requiresAuthVerbose {
        _setUserRole(user, role, enabled);
    }

    /**
     * @notice Continue deprecation to next step.
     */
    function continueDeprecation() external virtual requiresAuthVerbose {
        if (totalDeprecationSteps() == 0) revert NoDeprecationDefined();
        if (deprecationStep == totalDeprecationSteps()) revert DeprecationComplete();

        unchecked {
            ++deprecationStep;
        }
        _onDeprecationContinue(deprecationStep);
        emit DeprecationContinued(deprecationStep);
        if (deprecationStep == totalDeprecationSteps()) {
            isFullyDeprecated = true;
            emit DeprecationFinished(deprecationStep);
        }
    }

    /**
     * @dev Verbose version of solmate's RolesAuthority canCall. Provides detailed reasons for a calls failure with
     * strings.
     * Overriding the hook in this function allows you to include more logic such as a whitelist.
     */
    function canCallVerbose(
        address user,
        address target,
        bytes calldata data
    )
        public
        view
        virtual
        returns (bool canCall, string memory reasons)
    {
        // If the contract is paused, canCall is false
        if (paused()) {
            reasons = "- Paused ";
            // canCall is false by default
        } else {
            // canCall is false by default so set true if not paused
            canCall = true;
        }

        bytes4 functionSelector = bytes4(data[:4]);
        // The following is identical to the RolesAuthority canCall logic, but negated for identifying if canCall is
        // False
        if (!(isCapabilityPublic[target][functionSelector]
                    || bytes32(0) != getUserRoles[user] & getRolesWithCapability[target][functionSelector])) {
            canCall = false;
            reasons = string(abi.encodePacked(reasons, "- Unauthorized "));
        }

        // If a contract is in deprecation/deprecated, the deprecation contract should enforce the logic of the
        // deprecation uing roles. IE disabling public authority of deposit() function. However, some functions may
        // still be callable such as withdraw() at that step of deprecation. It's for this reason we do not set canCall
        // to false if a contract is deprecating, but we do provide the reason of "deprecated" in the event a call is
        // failing
        if (deprecationStep > 0 && !canCall) {
            reasons = string(abi.encodePacked(reasons, "- Deprecated "));
        }

        (bool canCallExtensions, string memory reasonsExtensions) = _canCallVerboseExtensionHook(user, target, data);

        // The extension may not set canCall true if it is currently false to override the pause or role checks. The
        // extension may only add more strict checks.
        canCall = canCall && canCallExtensions;
        reasons = string(abi.encodePacked(reasons, reasonsExtensions));
    }

    /// @notice return if a user has a role
    function doesUserHaveRole(address user, uint8 role) public view virtual returns (bool) {
        return (uint256(getUserRoles[user]) >> role) & 1 != 0;
    }

    /// @notice return if a role has a capability to call a function
    function doesRoleHaveCapability(uint8 role, address target, bytes4 functionSig) public view virtual returns (bool) {
        return (uint256(getRolesWithCapability[target][functionSig]) >> role) & 1 != 0;
    }

    /**
     * @dev required override to return number of the total deprecation steps
     */
    function totalDeprecationSteps() public view virtual returns (uint8);

    /**
     * @dev Hook to allow for additional logic to be added to the canCallVerbose function.
     * Returns true by default to enforce no additional checks.
     * May be overridden in the derived contract or logic may be provided via an AccessAuthorityHook contract.
     */
    function _canCallVerboseExtensionHook(
        address user,
        address target,
        bytes calldata data
    )
        internal
        view
        virtual
        returns (bool canCall, string memory reasons)
    {
        if (address(accessAuthorityHook) != address(0)) {
            (canCall, reasons) = accessAuthorityHook.canCallVerbose(user, target, data);
        } else {
            canCall = true;
        }
    }

    /**
     * @dev Internal and no-auth version of setUserRole
     */
    function _setUserRole(address user, uint8 role, bool enabled) internal virtual {
        if (enabled) {
            getUserRoles[user] |= bytes32(1 << role);
        } else {
            getUserRoles[user] &= ~bytes32(1 << role);
        }

        emit UserRoleUpdated(user, role, enabled);
    }

    /**
     * @dev Internal and no-auth version of setPublicCapability
     */
    function _setPublicCapability(address target, bytes4 functionSig, bool enabled) internal virtual {
        isCapabilityPublic[target][functionSig] = enabled;

        emit PublicCapabilityUpdated(target, functionSig, enabled);
    }

    /**
     * @dev Internal and no-auth version of setRoleCapability
     */
    function _setRoleCapability(uint8 role, address target, bytes4 functionSig, bool enabled) internal virtual {
        if (enabled) {
            getRolesWithCapability[target][functionSig] |= bytes32(1 << role);
        } else {
            getRolesWithCapability[target][functionSig] &= ~bytes32(1 << role);
        }

        emit RoleCapabilityUpdated(role, target, functionSig, enabled);
    }

    /**
     * @notice Hook called when deprecation continues to next step
     * @param newStep The new deprecation step
     * @dev Override to implement step-specific logic
     */
    function _onDeprecationContinue(uint8 newStep) internal virtual;

}
