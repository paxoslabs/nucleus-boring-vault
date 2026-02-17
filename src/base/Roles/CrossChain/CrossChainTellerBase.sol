// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { TellerWithMultiAssetSupport } from "../TellerWithMultiAssetSupport.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";

struct BridgeData {
    uint32 chainSelector;
    address destinationChainReceiver;
    ERC20 bridgeFeeToken;
    uint64 messageGas;
    bytes data;
}

/**
 * @title CrossChainTellerBase
 * @notice Base contract for the CrossChainTeller, includes functions to overload with specific bridge method
 */
abstract contract CrossChainTellerBase is TellerWithMultiAssetSupport {

    event MessageSent(bytes32 messageId, uint256 shareAmount, address to);
    event MessageReceived(bytes32 messageId, uint256 shareAmount, address to);

    constructor(
        address _owner,
        address _vault,
        address _accountant
    )
        TellerWithMultiAssetSupport(_owner, _vault, _accountant)
    { }

    /**
     * @notice function to deposit into the vault AND bridge crosschain in 1 call
     * @param depositAsset ERC20 to deposit
     * @param depositAmount amount of deposit asset to deposit
     * @param minimumMint minimum required shares to receive
     * @param data Bridge Data
     */
    function depositAndBridge(
        ERC20 depositAsset,
        uint256 depositAmount,
        uint256 minimumMint,
        BridgeData calldata data
    )
        external
        payable
        requiresAuth
        nonReentrant
    {
        if (!isDepositSupported[depositAsset]) {
            revert TellerWithMultiAssetSupport__AssetNotSupported();
        }

        uint256 shareAmount = _erc20Deposit(depositAsset, depositAmount, minimumMint, msg.sender);
        _afterPublicDeposit(msg.sender, depositAsset, depositAmount, shareAmount, shareLockPeriod);
        bridge(shareAmount, data);
    }

    /**
     * @notice Preview fee required to bridge shares in a given feeToken.
     */
    function previewFee(uint256 shareAmount, BridgeData calldata data) external view returns (uint256 fee) {
        return _quote(shareAmount, data);
    }

    /**
     * @notice bridging code to be done without deposit, for users who already have vault tokens
     * @param shareAmount to bridge
     * @param data bridge data
     */
    function bridge(
        uint256 shareAmount,
        BridgeData calldata data
    )
        public
        payable
        requiresAuth
        returns (bytes32 messageId)
    {
        if (isPaused) revert TellerWithMultiAssetSupport__Paused();

        _beforeBridge(data);

        // Since shares are directly burned, call `beforeTransfer` to enforce before transfer hooks.
        beforeTransfer(msg.sender);

        // Burn shares from sender
        vault.exit(address(0), ERC20(address(0)), 0, msg.sender, shareAmount);

        messageId = _bridge(shareAmount, data);
        _afterBridge(shareAmount, data, messageId);
    }

    /**
     * @notice the virtual bridge function to be overridden
     * @param data bridge data
     * @return messageId
     */
    function _bridge(uint256 shareAmount, BridgeData calldata data) internal virtual returns (bytes32);

    /**
     * @notice the virtual function to override to get bridge fees
     * @param shareAmount to send
     * @param data bridge data
     */
    function _quote(uint256 shareAmount, BridgeData calldata data) internal view virtual returns (uint256);

    /**
     * @notice after bridge code, just an emit but can be overridden
     * @notice the before bridge hook to perform additional checks
     * @param data bridge data
     */
    function _beforeBridge(BridgeData calldata data) internal virtual;

    /**
     * @notice after bridge code, just an emit but can be overridden
     * @param shareAmount share amount burned
     * @param data bridge data
     * @param messageId message id returned when bridged
     */
    function _afterBridge(uint256 shareAmount, BridgeData calldata data, bytes32 messageId) internal virtual {
        emit MessageSent(messageId, shareAmount, data.destinationChainReceiver);
    }

    /**
     * @notice a before receive hook to call some logic before a receive is processed
     */
    function _beforeReceive() internal virtual {
        if (isPaused) revert TellerWithMultiAssetSupport__Paused();
    }

    /**
     * @notice a hook to execute after receiving
     * @param shareAmount the shareAmount that was minted
     * @param destinationChainReceiver the receiver of the shares
     * @param messageId the message ID
     */
    function _afterReceive(uint256 shareAmount, address destinationChainReceiver, bytes32 messageId) internal virtual {
        emit MessageReceived(messageId, shareAmount, destinationChainReceiver);
    }

}
