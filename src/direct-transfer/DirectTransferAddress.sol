// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { Attestation } from "@predicate/interfaces/IPredicateRegistry.sol";
import { DistributorCodeDepositor } from "src/helper/DistributorCodeDepositor.sol";

/**
 * @title DirectTransferAddress
 * @notice Implementation contract for DirectTransferAddress BeaconProxies. Receives one configured
 *         stablecoin and forwards balances into a DistributorCodeDepositor, minting BoringVault shares
 *         to a pre-configured receiver.
 * @custom:security-contact security@molecularlabs.io
 */
contract DirectTransferAddress {

    using SafeTransferLib for ERC20;

    /// @notice Authorized caller for forward(), refund(), and recover().
    address public immutable owner;

    /// @notice Wallet that receives token swept via recover() — used for sanctions reverts or when
    ///         a prior refund() attempt fails (e.g. receiver is on a token-level blacklist).
    address public immutable recoveryAccount;

    /// @notice The DistributorCodeDepositor every proxy under this implementation forwards deposits to.
    DistributorCodeDepositor public immutable DCD;

    /// @notice The single stablecoin this implementation accepts, forwards, refunds, and recovers (e.g. USDC or USDT).
    ERC20 public immutable token;

    /// @notice The receiver of vault shares from DCD deposits. Also the refund recipient.
    address public receiver;

    /// @notice Guard against re-initialization.
    bool private _initialized;

    event Forwarded(address indexed from, address indexed to, uint256 amount, uint256 shares);
    event Refunded(address indexed from, address indexed to, uint256 amount);
    event Recovered(address indexed from, address indexed to, uint256 amount);

    error DirectTransferAddress__AlreadyInitialized();
    error DirectTransferAddress__NotOwner();

    /**
     * @notice Deploy a new DirectTransferAddress implementation, deployed once per (DCD, stablecoin) pair.
     * @dev All four arguments become shared immutables on the implementation; none live in proxy storage.
     * @param _dcd The DistributorCodeDepositor every proxy under this implementation will forward to.
     * @param _owner The only address allowed to call forward(), refund(), and recover() on resulting proxies.
     * @param _recoveryAccount Recovery sink for recover().
     * @param _token The single stablecoin this implementation handles; must match the `inputToken` that
     *               FactoryBeacon.deployBeaconProxy() enforces.
     */
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

    /**
     * @notice Sweep this DTA's full `token` balance to `receiver`
     * @dev Intended for non-sanctions forward() reverts. If the refund transfer reverts (e.g. `receiver`
     *      is on a token-level blacklist), the owner should then call recover().
     */
    function refund() external {
        if (msg.sender != owner) revert DirectTransferAddress__NotOwner();
        uint256 amount = token.balanceOf(address(this));
        token.safeTransfer(receiver, amount);
        emit Refunded(address(this), receiver, amount);
    }

    /**
     * @notice Sweep this DTA's full `token` balance to `recoveryAccount`. Only callable by `owner`.
     * @dev Intended for sanctions-class forward() reverts or when a prior refund() attempt itself reverted.
     */
    function recover() external {
        if (msg.sender != owner) revert DirectTransferAddress__NotOwner();
        uint256 amount = token.balanceOf(address(this));
        token.safeTransfer(recoveryAccount, amount);
        emit Recovered(address(this), recoveryAccount, amount);
    }

}
