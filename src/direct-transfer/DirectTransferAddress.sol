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

    // IMMUTABLES - stored in implementation bytecode and shared amongst proxies.

    /// @notice Authorized caller for depositAndForward(), refund(), and recover().
    address public immutable owner;

    /// @notice Wallet that receives token swept via recover() — used for sanctions reverts or when
    ///         a prior refund() attempt fails (e.g. receiver is on a token-level blacklist).
    address public immutable recoveryAccount;

    /// @notice The DistributorCodeDepositor every proxy under this implementation forwards deposits to.
    DistributorCodeDepositor public immutable DCD;

    /// @notice The single stablecoin this implementation accepts, forwards, refunds, and recovers (e.g. USDC or USDT).
    ERC20 public immutable token;

    // STORAGE - unique, initializable, per-proxy values.

    /// @notice The receiver of vault shares from DCD deposits. Also the refund recipient.
    address public receiver;

    /// @notice Guard against re-initialization.
    bool public _initialized;

    event Forwarded(address indexed to, uint256 amount, uint256 shares);
    event Refunded(address indexed token, address indexed to, uint256 amount);
    event Recovered(address indexed token, address indexed to, uint256 amount);

    error AlreadyInitialized();
    error NotOwner();
    error ZeroAddress();
    error NoCode();

    /**
     * @notice Deploy a new DirectTransferAddress implementation, deployed once per (DCD, stablecoin) pair.
     * @dev All four arguments become shared immutables on the implementation's storage; none live in proxy storage.
     * @param _dcd The DistributorCodeDepositor every proxy under this implementation will forward to.
     * @param _owner The only address allowed to call depositAndForward(), refund(), and recover() on resulting proxies.
     * @param _recoveryAccount Recovery sink for recover().
     * @param _token The single stablecoin this implementation handles; must match the `inputToken` that
     *               FactoryBeacon.deployBeaconProxy() enforces.
     */
    constructor(DistributorCodeDepositor _dcd, address _owner, address _recoveryAccount, ERC20 _token) {
        if (
            (address(_dcd) == address(0)) || (_owner == address(0)) || (_recoveryAccount == address(0))
                || (address(_token) == address(0))
        ) revert ZeroAddress();
        if ((address(_dcd).code.length == 0) || (address(_token).code.length == 0)) revert NoCode();

        DCD = _dcd;
        owner = _owner;
        recoveryAccount = _recoveryAccount;
        token = _token;
    }

    /// @notice Initializes the proxy with the receiver address. Callable once.
    /// @param _receiver The address that will receive vault shares from deposits.
    function initialize(address _receiver) external {
        if (_initialized) revert AlreadyInitialized();
        if (_receiver == address(0)) revert ZeroAddress();
        _initialized = true;
        receiver = _receiver;
    }

    /// @notice Approves the configured token to the DCD and deposits on behalf of the receiver.
    /// @dev Propagates any DCD revert. Owner classifies the revert off-chain and then follows up
    ///      with refund() or recover() to sweep the stranded token depending on the error.
    /// @param amount The amount of token to forward.
    /// @param minimumMint The minimum vault shares the receiver must receive; deposit reverts otherwise.
    /// @param distributorCode The DCD distributor code forwarded as-is into DCD.deposit.
    /// @param attestation The Predicate attestation authorizing this deposit.
    /// @return shares The vault shares minted to the receiver.
    function depositAndForward(
        uint256 amount,
        uint256 minimumMint,
        bytes calldata distributorCode,
        Attestation calldata attestation
    )
        external
        returns (uint256 shares)
    {
        if (msg.sender != owner) revert NotOwner();

        // Reset to 0 first so USDT-class tokens (which reject non-zero → non-zero approve
        // transitions) don't brick subsequent depositAndForward() calls if any residual allowance remains.
        token.safeApprove(address(DCD), 0);
        token.safeApprove(address(DCD), amount);
        shares = DCD.deposit(token, amount, minimumMint, receiver, distributorCode, attestation);
        emit Forwarded(receiver, amount, shares);
    }

    /**
     * @notice Sweep this DTA's full `token` balance to `receiver`
     * @dev Intended for non-sanctions depositAndForward() reverts. If the refund transfer reverts (e.g. `receiver`
     *      is on a token-level blacklist), the owner should then call recover().
     */
    function refund(address tokenAddress) external {
        if (msg.sender != owner) revert NotOwner();
        uint256 amount = token.balanceOf(address(this));
        token.safeTransfer(receiver, amount);
        emit Refunded(tokenAddress, receiver, amount);
    }

    /**
     * @notice Sweep this DTA's full `token` balance to `recoveryAccount`. Only callable by `owner`.
     * @dev Intended for sanctions-class depositAndForward() reverts or when a prior refund() attempt itself reverted.
     */
    function recover(address tokenAddress) external {
        if (msg.sender != owner) revert NotOwner();
        uint256 amount = token.balanceOf(address(this));
        token.safeTransfer(recoveryAccount, amount);
        emit Recovered(tokenAddress, recoveryAccount, amount);
    }

}
