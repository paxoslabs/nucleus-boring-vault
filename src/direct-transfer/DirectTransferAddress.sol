// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { Attestation } from "@predicate/interfaces/IPredicateRegistry.sol";
import { DistributorCodeDepositor } from "src/helper/DistributorCodeDepositor.sol";

/**
 * @title DirectTransferAddress
 * @notice Beacon proxy implementation that forwards a single configured stablecoin into a
 *         DistributorCodeDepositor. When forward() reverts, an off-chain classifier inspects the
 *         revert and decides whether to route stranded funds back to the receiver via refund() or
 *         to recoveryAccount via recover().
 * @dev Intended to be deployed as a new implementation and set via UpgradeableBeacon.upgradeTo().
 *      - `token` is an immutable of the implementation: one implementation (and therefore one
 *        beacon) supports exactly one stablecoin. Supporting USDC and USDT simultaneously means
 *        deploying two implementations and two beacons; the factory picks the right beacon for
 *        the requested token. The CREATE2 salt already binds address↔token (inputToken), so
 *        making `token` immutable mirrors that invariant in the type system rather than storage.
 *      - DCD is immutable in the implementation (shared by all proxies under the same beacon).
 *      - receiver is stored in proxy storage via initialize().
 */
contract DirectTransferAddress {

    using SafeTransferLib for ERC20;

    /// @notice Authorized caller for forward(), refund(), and recover().
    /// @dev Also referred to as the owner in deployment/configuration docs.
    address public immutable owner;

    /// @notice Wallet that receives token swept via recover() — used for sanctions reverts or when
    ///         a prior refund() attempt fails (e.g. receiver is on a token-level blacklist).
    address public immutable recoveryAccount;

    /// @notice The receiver of vault shares from DCD deposits. Also the refund recipient.
    address public receiver;

    /// @notice Guard against re-initialization.
    bool private _initialized;

    /// @notice The DistributorCodeDepositor this implementation forwards deposits to.
    DistributorCodeDepositor public immutable DCD;

    /// @notice The stablecoin this implementation forwards, refunds, and recovers.
    /// @dev Immutable so every proxy under the beacon is pinned to a single token. Support a new
    ///      stablecoin by deploying a fresh implementation + beacon with that token.
    ERC20 public immutable token;

    /// @notice Emitted after a successful deposit: token moved from this DTA into DCD and `shares`
    ///         were minted to `to`.
    event Forwarded(address indexed from, address indexed to, uint256 amount, uint256 shares);

    /// @notice Emitted after refund(): the DTA's token balance was swept to `to` (the receiver).
    event Refunded(address indexed from, address indexed to, uint256 amount);

    /// @notice Emitted after recover(): the DTA's token balance was swept to `to` (recoveryAccount).
    event Recovered(address indexed from, address indexed to, uint256 amount);

    error DirectTransferAddress__AlreadyInitialized();
    error DirectTransferAddress__NotOwner();

    /// @param _dcd The DistributorCodeDepositor contract for this beacon's proxies.
    /// @param _owner The only address allowed to call forward(), refund(), and recover().
    /// @param _recoveryAccount Recovery sink for recover().
    /// @param _token The stablecoin this implementation handles (e.g. USDC, USDT).
    constructor(DistributorCodeDepositor _dcd, address _owner, address _recoveryAccount, ERC20 _token) {
        DCD = _dcd;
        owner = _owner;
        recoveryAccount = _recoveryAccount;
        token = _token;
    }

    /// @notice Initializes the proxy with the receiver address. Callable once.
    /// @param _receiver The address that will receive vault shares from deposits.
    function initialize(address _receiver) external {
        if (_initialized) revert DirectTransferAddress__AlreadyInitialized();
        _initialized = true;
        receiver = _receiver;
    }

    /// @notice Approves the configured token to the DCD and deposits on behalf of the receiver.
    /// @dev Propagates any DCD revert. Operators classify the revert off-chain and then follow up
    ///      with refund() or recover() to sweep the stranded token — see
    ///      Design_Notes/forward-error-handling.md for the classification taxonomy.
    /// @param amount The amount of token to forward.
    /// @param minimumMint The minimum vault shares the receiver must receive; deposit reverts otherwise.
    /// @param attestation The Predicate attestation authorizing this deposit.
    /// @return shares The vault shares minted to the receiver.
    function forward(
        uint256 amount,
        uint256 minimumMint,
        Attestation calldata attestation
    )
        external
        returns (uint256 shares)
    {
        if (msg.sender != owner) revert DirectTransferAddress__NotOwner();

        token.safeApprove(address(DCD), amount);
        shares = DCD.deposit(token, amount, minimumMint, receiver, "", attestation);
        emit Forwarded(address(this), receiver, amount, shares);
    }

    /// @notice Sweeps the DTA's full token balance to `receiver`.
    /// @dev Intended use: call after a non-sanctions revert from forward(). Reverts if the transfer
    ///      itself fails (e.g. receiver is on a token-level blacklist); operators must then call
    ///      recover() to route funds to recoveryAccount instead.
    function refund() external {
        if (msg.sender != owner) revert DirectTransferAddress__NotOwner();
        uint256 amount = token.balanceOf(address(this));
        token.safeTransfer(receiver, amount);
        emit Refunded(address(this), receiver, amount);
    }

    /// @notice Sweeps the DTA's full token balance to `recoveryAccount`.
    /// @dev Intended use: call after a sanctions revert from forward(), or when refund() itself
    ///      fails. If this transfer also reverts, `recoveryAccount` must be fixed operationally.
    function recover() external {
        if (msg.sender != owner) revert DirectTransferAddress__NotOwner();
        uint256 amount = token.balanceOf(address(this));
        token.safeTransfer(recoveryAccount, amount);
        emit Recovered(address(this), recoveryAccount, amount);
    }

}
