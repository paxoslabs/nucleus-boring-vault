// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { Attestation } from "@predicate/interfaces/IPredicateRegistry.sol";
import { Initializable } from "@openzeppelin-v5.0.1/contracts/proxy/utils/Initializable.sol";
import { DistributorCodeDepositor } from "src/helper/DistributorCodeDepositor.sol";

/**
 * @title DirectTransferAddress
 * @notice Implementation contract for DirectTransferAddress BeaconProxies. Receives one configured
 *         stablecoin and forwards balances into a DistributorCodeDepositor, minting BoringVault shares
 *         to a pre-configured userDestinationAddress.
 * @custom:security-contact security@molecularlabs.io
 * @custom:oz-upgrades
 */
contract DirectTransferAddress is Initializable {

    using SafeTransferLib for ERC20;

    // IMMUTABLES - stored in implementation bytecode and shared amongst proxies.

    /// @notice Authorized caller for depositAndForward(), refund(), and recover().
    address public immutable owner;

    /* @notice Wallet that receives token swept via recover() — used for sanctions reverts or when
    *          a prior refund() attempt fails (e.g. userDestinationAddress is on a token-level blacklist).
    */
    address public immutable recoveryAccount;

    /// @notice The DistributorCodeDepositor every proxy under this implementation forwards deposits to.
    DistributorCodeDepositor public immutable DCD;

    /// @notice The single token this implementation deposits into a DCD.
    ERC20 public immutable token;

    // STORAGE - unique, initializable, per-proxy values.

    /// @notice The recipient of vault shares from DCD deposits. Also the refund recipient.
    address public userDestinationAddress;

    /// @dev Reserved for future storage. Shrink this array by the number of slots any newly
    ///      appended variables consume, mindful of Solidity packing rules (a new array starts
    ///      at a fresh slot; an address packs with an adjacent uint96; etc.). Recognized as a
    ///      storage gap by OpenZeppelin's upgrade validator.
    uint256[49] private __gap;

    event Initialized(address indexed userDestinationAddress);
    event Forwarded(address indexed to, uint256 amount, uint256 shares);
    event Refunded(address indexed token, address indexed to, uint256 amount);
    event Recovered(address indexed token, address indexed to, uint256 amount);

    error OwnableUnauthorizedAccount(address account);
    error OwnableInvalidOwner(address owner);
    error ZeroAddress();
    error ZeroAmount();
    error NoCode();

    /**
     * @dev We replicate OZ Ownable's interface rather than inheriting it. OZ's Ownable would store owner in a
     * proxy storage slot, not as an `immutable` in the implementation contract. We want owner as an `immutable` in the
     * implementation's bytecode so a single impl upgrade rotates the owner across every proxy at once.
     */
    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    /**
     * @notice Deploy a new DirectTransferAddress. There should be one active implementation per (DCD, stablecoin) pair.
     * @dev All four arguments become shared immutables on the implementation's bytecode; none live in proxy storage.
     * @param _dcd The DistributorCodeDepositor every proxy under this implementation will forward to.
     * @param _owner The only address allowed to call depositAndForward(), refund(), and recover() on resulting proxies.
     * @param _recoveryAccount Recovery sink for recover().
     * @param _token The single stablecoin this implementation handles; FactoryBeacon derives this
     *               value from the implementation when computing deterministic deployment salts.
     */
    constructor(DistributorCodeDepositor _dcd, address _owner, address _recoveryAccount, ERC20 _token) {
        if (_owner == address(0)) revert OwnableInvalidOwner(address(0));

        if ((address(_dcd) == address(0)) || (_recoveryAccount == address(0)) || (address(_token) == address(0))) {
            revert ZeroAddress();
        }

        if ((address(_dcd).code.length == 0) || (address(_token).code.length == 0)) revert NoCode();

        DCD = _dcd;
        owner = _owner;
        recoveryAccount = _recoveryAccount;
        token = _token;

        _disableInitializers();
    }

    /**
     * @notice Initializes the proxy with the userDestinationAddress. Callable once per proxy.
     * @param _userDestinationAddress The address that will receive vault shares from deposits.
     */
    function initialize(address _userDestinationAddress) external initializer {
        if (_userDestinationAddress == address(0)) revert ZeroAddress();
        userDestinationAddress = _userDestinationAddress;
        emit Initialized(_userDestinationAddress);
    }

    /**
     * @notice Approves the configured token to the DCD and deposits on behalf of the userDestinationAddress.
     * @dev Propagates any DCD revert. Owner classifies the revert off-chain and then follows up
     *      with refund() or recover() to sweep the stranded token depending on the error.
     * @param amount The amount of token to forward.
     * @param minimumMint The minimum vault shares the userDestinationAddress must receive; deposit reverts otherwise.
     * @param distributorCode The DCD distributor code forwarded as-is into DCD.deposit.
     * @param attestation The Predicate attestation authorizing this deposit.
     * @return shares The vault shares minted to the userDestinationAddress.
     */
    function depositAndForward(
        uint256 amount,
        uint256 minimumMint,
        bytes calldata distributorCode,
        Attestation calldata attestation
    )
        external
        onlyOwner
        returns (uint256 shares)
    {
        // Reset to 0 first so USDT-like tokens (which reject non-zero → non-zero approve
        // transitions) don't brick subsequent depositAndForward() calls if any residual allowance remains.
        token.safeApprove(address(DCD), 0);
        token.safeApprove(address(DCD), amount);
        shares = DCD.deposit(token, amount, minimumMint, userDestinationAddress, distributorCode, attestation);
        emit Forwarded(userDestinationAddress, amount, shares);
    }

    /**
     * @notice Refund `amount` of `tokenToSweep` from this DTA to `userDestinationAddress`.
     * @dev Intended for non-sanctions depositAndForward() reverts. If the refund transfer reverts (e.g.
     *      `userDestinationAddress` is on a token-level blacklist), the owner should then call recover().
     *      `tokenToSweep` is a parameter (rather than the immutable `token`) so stray tokens of any
     *      kind accidentally sent to this proxy can be swept.
     * @param tokenToSweep The ERC20 to refund.
     * @param amount The amount of `tokenToSweep` to refund.
     */
    function refund(ERC20 tokenToSweep, uint256 amount) external onlyOwner {
        // slither-disable-next-line incorrect-equality
        if (amount == 0) revert ZeroAmount();
        tokenToSweep.safeTransfer(userDestinationAddress, amount);
        emit Refunded(address(tokenToSweep), userDestinationAddress, amount);
    }

    /**
     * @notice Sweep this DTA's full balance of `tokenToSweep` to `recoveryAccount`.
     * @dev Intended for sanctions-class `depositAndForward()` reverts or when a prior `refund()` attempt itself
     * reverted.
     *      `tokenToSweep` is a parameter (rather than the immutable `token`) so stray tokens of any kind accidentally
     *      sent to this proxy can be swept.
     * @param tokenToSweep The ERC20 to sweep.
     */
    function recover(ERC20 tokenToSweep) external onlyOwner {
        uint256 amount = tokenToSweep.balanceOf(address(this));
        // slither-disable-next-line incorrect-equality
        if (amount == 0) revert ZeroAmount();
        tokenToSweep.safeTransfer(recoveryAccount, amount);
        emit Recovered(address(tokenToSweep), recoveryAccount, amount);
    }

    /// @dev Throws if the sender is not the owner.
    function _checkOwner() internal view {
        if (msg.sender != owner) revert OwnableUnauthorizedAccount(msg.sender);
    }

}
