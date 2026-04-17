// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { Attestation } from "@predicate/interfaces/IPredicateRegistry.sol";
import { DistributorCodeDepositor } from "src/helper/DistributorCodeDepositor.sol";
import { FreezeListBeforeTransferHook } from "src/helper/FreezeListBeforeTransferHook.sol";
import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";
import { USDC } from "src/helper/Constants.sol";

/**
 * @title DirectTransferAddress
 * @notice Beacon proxy implementation that forwards USDC deposits into a DistributorCodeDepositor with
 *         sanctions-aware recovery and refund fallback paths.
 * @dev Intended to be deployed as a new implementation and set via UpgradeableBeacon.upgradeTo().
 *      - USDC is a compile-time constant.
 *      - DCD is immutable in the implementation (shared by all proxies under the same beacon).
 *      - receiver is stored in proxy storage via initialize().
 */
contract DirectTransferAddress {

    using SafeTransferLib for ERC20;

    /// @notice The receiver of vault shares from DCD deposits. Also the refund recipient.
    address public receiver;

    /// @notice Authorized forwarder allowed to call forward().
    /// @dev Also referred to as the owner in deployment/configuration docs.
    address public immutable owner;

    /// @notice Wallet that receives USDC swept from this DTA in response to sanctions failures
    ///         and refund-to-receiver failures.
    address public immutable recoveryAccount;

    /// @notice Deprecated storage slot kept for storage-layout compatibility with existing V2 proxies.
    /// @dev Not used by logic; `recoveryAccount` immutable is the active recovery destination.
    address public recoveryWallet;

    /// @notice Guard against re-initialization.
    bool private _initialized;

    /// @notice The DistributorCodeDepositor this implementation forwards deposits to.
    DistributorCodeDepositor public immutable DCD;

    /// @notice Emitted after a successful deposit: USDC moved from this DTA into DCD and `shares` were minted to `to`.
    event Forwarded(address indexed from, address indexed to, uint256 amount, uint256 shares);

    /// @notice Emitted after a refund: USDC moved from this DTA to `to` (the receiver) following a non-sanctions
    /// revert.
    /// @param reason Raw revert data from DCD.deposit. Decode offchain with the deposit-path error ABI catalog:
    ///        - selector `0x08c379a0` → `Error(string)`, decode as `(string)` for the message
    ///        - any other 4-byte selector → custom error, decode against known ABIs
    /// (Teller/Accountant/DCD/Freeze/Predicate) - empty bytes → out-of-gas or low-level failure
    event Refunded(address indexed from, address indexed to, uint256 amount, bytes reason);

    /// @notice Emitted after a recover: USDC moved from this DTA to `to` (receiver if Circle-clean, else
    /// recoveryAccount) following a sanctions revert.
    /// @param reason Raw revert data; decode as above. Sanctions path is
    /// triggered by Predicate require-strings, `UnauthorizedTransaction`, or `FrozenAddress(address)`.
    event Recovered(address indexed from, address indexed to, uint256 amount, bytes reason);

    /// @notice Emitted when a revert does not match any known refund or recover-class error. Funds remain in this
    ///         DTA; forward() returns 0. Should page louder than Recovered because this means the errors we look for
    /// are stale and the classifier needs a human to reclassify, followed by a beacon upgrade to extend the allowlists.
    /// @param reason Raw revert data; decode as above.
    event Failed(uint256 amount, bytes reason);

    error DirectTransferAddress__AlreadyInitialized();
    error DirectTransferAddress__NotForwarder();
    error DirectTransferAddress__ZeroAddress();

    /// @param _dcd The DistributorCodeDepositor contract for this beacon's proxies.
    /// @param _owner The only address allowed to call forward().
    /// @param _recoveryAccount Recovery sink for sanctions/refund-fallback paths.
    constructor(DistributorCodeDepositor _dcd, address _owner, address _recoveryAccount) {
        if (_owner == address(0) || _recoveryAccount == address(0)) {
            revert DirectTransferAddress__ZeroAddress();
        }
        DCD = _dcd;
        owner = _owner;
        recoveryAccount = _recoveryAccount;
    }

    /// @notice Initializes the proxy with the receiver address. Callable once.
    /// @param _receiver The address that will receive vault shares from deposits.
    function initialize(address _receiver) external {
        if (_initialized) revert DirectTransferAddress__AlreadyInitialized();
        _initialized = true;
        receiver = _receiver;
    }

    /// @notice Approves USDC to the DCD and deposits on behalf of the receiver.
    /// @dev Error handling policy (see Design_Notes/forward-error-handling.md) — three terminal actions:
    ///      - recover (sanctions): Predicate require-string prefix, UnauthorizedTransaction, FrozenAddress
    ///      - refund (everything else enumerated as reachable): solmate TRANSFER_*/APPROVE_FAILED/REENTRANCY
    ///        /UNAUTHORIZED + Teller/Accountant/DCD known customs + Panic(uint256) + empty revert data
    ///      - leave (default-deny for unknowns only): any revert whose selector/string matches none of
    ///        the above. Emits Failed and funds stay on the DTA. This is the safe failure mode for
    ///        upstream version drift (e.g. Predicate adds a new sanctions error we haven't learned) -
    ///        better to strand funds than auto-refund a sanctioned user.
    /// @param amount The amount of USDC to forward.
    /// @param minimumMint The minimum vault shares the receiver must receive; deposit reverts otherwise.
    /// @param attestation The Predicate attestation authorizing this deposit.
    /// @return shares The vault shares minted to the receiver, or 0 if we refunded/recovered/failed.
    function forward(
        uint256 amount,
        uint256 minimumMint,
        Attestation calldata attestation
    )
        external
        returns (uint256 shares)
    {
        if (msg.sender != owner) revert DirectTransferAddress__NotForwarder();

        ERC20 usdc = ERC20(USDC);

        usdc.safeApprove(address(DCD), amount);

        try DCD.deposit(usdc, amount, minimumMint, receiver, "", attestation) returns (uint256 _shares) {
            emit Forwarded(address(this), receiver, amount, _shares);
            return _shares;
        } catch Error(string memory reason) {
            // Re-encode with the Error(string) selector so emitted `reason` bytes match what the EVM
            // would have returned, letting offchain decode uniformly against a single ABI catalog.
            bytes memory raw = abi.encodeWithSignature("Error(string)", reason);
            if (_isPredicateRevert(reason)) {
                _recover(usdc, amount, raw);
                return 0;
            }
            bytes32 h = keccak256(bytes(reason));
            if (
                h == keccak256("TRANSFER_FAILED") || h == keccak256("TRANSFER_FROM_FAILED")
                    || h == keccak256("APPROVE_FAILED") || h == keccak256("REENTRANCY")
                    || h == keccak256("UNAUTHORIZED")
            ) {
                _refund(usdc, amount, raw);
                return 0;
            }

            // Unknown Error(string) - default-deny, funds stay on the DTA pending triage + upgrade.
            emit Failed(amount, raw);
            return 0;
        } catch (bytes memory rawData) {
            // Sanctions class: FrozenAddress (share-token freeze list) and UnauthorizedTransaction
            // (DCD's Predicate-rejected branch when the registry returns false instead of reverting).
            if (
                _isFrozenAddressRevert(rawData)
                    || _isRevertSelector(rawData, DistributorCodeDepositor.UnauthorizedTransaction.selector)
            ) {
                _recover(usdc, amount, rawData);
                return 0;
            }

            // Refund class: all other known-reachable reverts. Includes DCD/Teller/Accountant custom errors,
            // Panic(uint256), and empty revert data (OOG / low-level).
            if (
                rawData.length < 4 || _isRevertSelector(rawData, bytes4(0x4e487b71))
                    || _isRevertSelector(rawData, DistributorCodeDepositor.FeesExceedOrEqualAmount.selector)
                    || _isRevertSelector(rawData, DistributorCodeDepositor.SupplyCapInBaseError.selector)
                    || _isRevertSelector(
                        rawData, TellerWithMultiAssetSupport.TellerWithMultiAssetSupport__Paused.selector
                    )
                    || _isRevertSelector(
                        rawData, TellerWithMultiAssetSupport.TellerWithMultiAssetSupport__AssetNotSupported.selector
                    )
                    || _isRevertSelector(
                        rawData, TellerWithMultiAssetSupport.TellerWithMultiAssetSupport__ZeroAssets.selector
                    )
                    || _isRevertSelector(
                        rawData, TellerWithMultiAssetSupport.TellerWithMultiAssetSupport__MinimumMintNotMet.selector
                    )
                    || _isRevertSelector(
                        rawData, AccountantWithRateProviders.AccountantWithRateProviders__Paused.selector
                    )
            ) {
                _refund(usdc, amount, rawData);
                return 0;
            }

            // Unknown custom error - default-deny, funds stay on the DTA pending triage + upgrade.
            emit Failed(amount, rawData);
            return 0;
        }
    }

    /// @dev Refund path: attempt to return `amount` of `token` to `receiver`. If the transfer
    ///      itself reverts (e.g. receiver is on Circle's USDC blacklist or Tether's
    ///      isBlackListed list, which both revert on `transfer`), fall through to the recover
    ///      path so the tx doesn't revert as a whole. Uses `this._safeTransferExternal`,
    ///      because `try` can only be used with external function calls and contract creation calls.
    ///      by calling `safeTransfer` via `_safeTransferExternal`, the call happens in a separate external
    ///      context that try/catch can trap, while still handling non-standard ERC20s (USDT returns no data on
    ///      transfer) correctly.
    function _refund(ERC20 token, uint256 amount, bytes memory reason) private {
        try this._safeTransferExternal(token, receiver, amount) {
            emit Refunded(address(this), receiver, amount, reason);
        } catch {
            _recover(token, amount, reason);
        }
    }

    /// @dev Recover path: terminal sink for sanctions failures AND refund-to-user failures.
    ///      Sends `amount` of `token` to `recoveryAccount`. If this also reverts, the whole
    ///      forward() reverts — in that case `recoveryAccount` must be fixed operationally.
    function _recover(ERC20 token, uint256 amount, bytes memory reason) private {
        token.safeTransfer(recoveryAccount, amount);
        emit Recovered(address(this), recoveryAccount, amount, reason);
    }

    /// @notice Self-only wrapper so `_refund` can try/catch a safeTransfer (SafeTransferLib
    ///         is a library → internal call → can't be wrapped in try/catch directly). Handles
    ///         non-standard ERC20s like USDT that return no data on transfer.
    /// @dev Restricted to `msg.sender == address(this)` so external callers cannot abuse it.
    function _safeTransferExternal(ERC20 token, address to, uint256 amount) external {
        require(msg.sender == address(this));
        token.safeTransfer(to, amount);
    }

    /// @dev Returns true iff `reason` begins with the PredicateRegistry require-string prefix.
    function _isPredicateRevert(string memory reason) private pure returns (bool) {
        bytes memory r = bytes(reason);
        // The six PredicateRegistry require() messages all start with
        bytes memory prefix = bytes("Predicate.validateAttestation:");
        if (r.length < prefix.length) return false;
        for (uint256 i; i < prefix.length; ++i) {
            if (r[i] != prefix[i]) return false;
        }
        return true;
    }

    /// @dev Returns true iff `rawData` is an ABI-encoded `FrozenAddress(address)` revert.
    function _isFrozenAddressRevert(bytes memory rawData) private pure returns (bool) {
        return _isRevertSelector(rawData, FreezeListBeforeTransferHook.FrozenAddress.selector);
    }

    /// @dev Returns true iff `rawData` starts with the given 4-byte selector. `rawData` shorter
    ///      than 4 bytes (empty/OOG) returns false.
    function _isRevertSelector(bytes memory rawData, bytes4 selector) private pure returns (bool) {
        if (rawData.length < 4) return false;
        bytes4 sel;
        assembly {
            sel := mload(add(rawData, 0x20))
        }
        return sel == selector;
    }

}
