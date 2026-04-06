// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { Attestation } from "@predicate/interfaces/IPredicateRegistry.sol";
import { DistributorCodeDepositor } from "src/helper/DistributorCodeDepositor.sol";
import { USDC } from "src/helper/Constants.sol";

/**
 * @title DirectTransferAddress2
 * @notice Upgraded beacon proxy implementation that adds token recovery on top of DirectTransferAddress1.
 * @dev Intended to be deployed as a new implementation and set via UpgradeableBeacon.upgradeTo().
 *      - USDC is a compile-time constant.
 *      - DCD is immutable in the implementation (shared by all proxies under the same beacon).
 *      - receiver is stored in proxy storage via initialize().
 */
contract DirectTransferAddress2 {

    using SafeTransferLib for ERC20;

    /// @notice The receiver of vault shares from DCD deposits.
    address public receiver;

    /// @notice Guard against re-initialization.
    bool private _initialized;

    /// @notice The DistributorCodeDepositor this implementation forwards deposits to.
    DistributorCodeDepositor public immutable DCD;

    error DirectTransferAddress__AlreadyInitialized();

    /// @param _dcd The DistributorCodeDepositor contract for this beacon's proxies.
    constructor(DistributorCodeDepositor _dcd) {
        DCD = _dcd;
    }

    /// @notice Initializes the proxy with the receiver address. Callable once.
    /// @param _receiver The address that will receive vault shares from deposits.
    function initialize(address _receiver) external {
        if (_initialized) revert DirectTransferAddress__AlreadyInitialized();
        _initialized = true;
        receiver = _receiver;
    }

    /// @notice Approves USDC to the DCD and deposits on behalf of the receiver.
    /// @param amount The amount of USDC to forward.
    /// @return shares The vault shares minted to the receiver.
    function forward(uint256 amount) external returns (uint256 shares) {
        ERC20 usdc = ERC20(USDC);
        Attestation memory emptyAttestation;

        usdc.safeApprove(address(DCD), amount);
        shares = DCD.deposit(usdc, amount, 0, receiver, "", emptyAttestation);
    }

    /// @notice Recovers tokens stuck in this proxy by transferring them to a specified address.
    /// @dev POC only — no access control is enforced. Production usage would require auth (e.g. requiresAuth).
    /// @param token The ERC20 token to recover.
    /// @param amount The amount to transfer.
    /// @param to The recipient of the recovered tokens.
    function recover(ERC20 token, uint256 amount, address to) external {
        token.safeTransfer(to, amount);
    }

}
