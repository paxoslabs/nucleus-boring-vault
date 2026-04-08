// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { Attestation } from "@predicate/interfaces/IPredicateRegistry.sol";
import { DistributorCodeDepositor } from "src/helper/DistributorCodeDepositor.sol";
import { USDC } from "src/helper/Constants.sol";

/**
 * @title DirectTransferAddress1
 * @notice Beacon proxy implementation that forwards USDC deposits into a DistributorCodeDepositor
 *         on behalf of a specific receiver. Each proxy instance serves one user/DCD combination.
 * @dev Intended to be used behind an UpgradeableBeacon (one beacon per DCD).
 *      - USDC is a compile-time constant.
 *      - DCD is immutable in the implementation (shared by all proxies under the same beacon).
 *      - receiver is stored in proxy storage via initialize().
 */
contract DirectTransferAddress1 {

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

}
