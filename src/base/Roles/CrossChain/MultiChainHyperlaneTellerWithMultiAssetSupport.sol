// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import {
    MultiChainTellerBase,
    MultiChainTellerBase_MessagesNotAllowedFrom,
    MultiChainTellerBase_MessagesNotAllowedFromSender,
    Chain
} from "./MultiChainTellerBase.sol";
import { BridgeData, ERC20 } from "./CrossChainTellerBase.sol";
import { StandardHookMetadata } from "../../../helper/StandardHookMetadata.sol";
import { IMailbox } from "../../../interfaces/hyperlane/IMailbox.sol";
import { IInterchainSecurityModule } from "../../../interfaces/hyperlane/IInterchainSecurityModule.sol";
import { IPostDispatchHook } from "../../../interfaces/hyperlane/IPostDispatchHook.sol";

/**
 * @title MultiChainHyperlaneTellerWithMultiAssetSupport
 * @notice Hyperlane implementation of MultiChainTeller
 * @custom:security-contact security@molecularlabs.io
 */
contract MultiChainHyperlaneTellerWithMultiAssetSupport is MultiChainTellerBase {

    // ========================================= STATE =========================================

    /**
     * @notice The Hyperlane mailbox contract.
     */
    IMailbox public immutable mailbox;

    /**
     * @notice The Hyperlane interchain security module.
     * @dev If `address(0)`, uses the mailbox's default ISM.
     */
    IInterchainSecurityModule public interchainSecurityModule;

    /**
     * @notice The hook invoked after `dispatch`.
     */
    IPostDispatchHook public hook;

    /**
     * @notice A nonce used to generate unique message IDs.
     */
    uint128 public nonce;

    //============================== EVENTS ===============================

    event SetInterChainSecurityModule(address _interchainSecurityModule);
    event SetPostDispatchHook(address _hook);

    //============================== ERRORS ===============================

    error MultiChainHyperlaneTellerWithMultiAssetSupport_InvalidBridgeFeeToken();
    error MultiChainHyperlaneTellerWithMultiAssetSupport_CallerMustBeMailbox(address caller);
    error MultiChainHyperlaneTellerWithMultiAssetSupport_InvalidBytes32Address(bytes32 _address);
    error MultiChainHyperlaneTellerWithMultiAssetSupport_ZeroAddressDestinationReceiver();

    constructor(
        address _owner,
        address _vault,
        address _accountant,
        IMailbox _mailbox
    )
        MultiChainTellerBase(_owner, _vault, _accountant)
    {
        mailbox = _mailbox;
    }

    /**
     * @notice Sets the post dispatch hook for Hyperlane mailbox.
     */
    function setHook(IPostDispatchHook _hook) external requiresAuth {
        hook = _hook;
        emit SetPostDispatchHook(address(_hook));
    }

    /**
     * @notice Sets a custom interchain security module for Hyperlane.
     */
    function setInterchainSecurityModule(IInterchainSecurityModule _interchainSecurityModule) external requiresAuth {
        interchainSecurityModule = _interchainSecurityModule;
        emit SetInterChainSecurityModule(address(_interchainSecurityModule));
    }

    /**
     * @notice function override to return the fee quote
     * @param shareAmount to be sent as a message
     * @param data Bridge data
     */
    function _quote(uint256 shareAmount, BridgeData calldata data) internal view override returns (uint256) {
        uint256 nextNonce = nonce + 1;
        bytes32 messageId = keccak256(abi.encodePacked(nextNonce, address(this), block.chainid));

        bytes memory _payload = abi.encode(shareAmount, data.destinationChainReceiver, messageId);

        bytes32 msgRecipient = _addressToBytes32(selectorToChains[data.chainSelector].targetTeller);

        return mailbox.quoteDispatch(
            data.chainSelector, msgRecipient, _payload, StandardHookMetadata.overrideGasLimit(data.messageGas), hook
        );
    }

    /**
     * @notice Called when data is received from the protocol. It overrides the equivalent function in the parent
     * contract.
     * Protocol messages are defined as packets, comprised of the following parameters.
     * @param origin A struct containing information about where the packet came from.
     * @param sender The contract that sent this message.
     * @param payload Encoded message.
     */
    function handle(uint32 origin, bytes32 sender, bytes calldata payload) external payable {
        Chain memory chain = selectorToChains[origin];

        // Three things must be checked.
        // 1. This function must only be called by the mailbox
        // 2. The sender must be the teller from the source chain
        // 3. The origin aka chainSelector must be allowed to send message to this
        // contract through the `Chain` config.
        if (msg.sender != address(mailbox)) {
            revert MultiChainHyperlaneTellerWithMultiAssetSupport_CallerMustBeMailbox(msg.sender);
        }

        if (sender != _addressToBytes32(chain.targetTeller)) {
            revert MultiChainTellerBase_MessagesNotAllowedFromSender(uint256(origin), _bytes32ToAddress(sender));
        }

        if (!chain.allowMessagesFrom) {
            revert MultiChainTellerBase_MessagesNotAllowedFrom(origin);
        }

        (uint256 shareAmount, address receiver, bytes32 messageId) = abi.decode(payload, (uint256, address, bytes32));
        // We perform the before receive hook here and not first because the above error handling will result in more
        // verbose errors, while still avoiding any writes. As an example, passing in an invalid bytes32 should fail
        // with MultiChainHyperlaneTellerWithMultiAssetSupport_InvalidBytes32Address but would instead error with no
        // data if we tried to parse it and pass in the hook first
        _beforeReceive(shareAmount, receiver);

        // This should never be the case since zero address
        // `destinationChainReceiver` in `_bridge` is not allowed, but we have
        // this as a sanity check.
        if (receiver == address(0)) {
            revert MultiChainHyperlaneTellerWithMultiAssetSupport_ZeroAddressDestinationReceiver();
        }

        vault.enter(address(0), ERC20(address(0)), 0, receiver, shareAmount);

        _afterReceive(shareAmount, receiver, messageId);
    }

    /**
     * @notice bridge override to allow bridge logic to be done for bridge() and depositAndBridge()
     * @param shareAmount to be moved across chain
     * @param data BridgeData
     * @return messageId a unique hash for the message
     */
    function _bridge(uint256 shareAmount, BridgeData calldata data) internal override returns (bytes32 messageId) {
        // We create our own guid and pass it into the payload for it to be
        // parsed in `handle`. There is no way to pass the return `messageId`
        // from `dispatch` to `handle`.
        unchecked {
            messageId = keccak256(abi.encodePacked(++nonce, address(this), block.chainid));
        }

        if (address(data.bridgeFeeToken) != NATIVE) {
            revert MultiChainHyperlaneTellerWithMultiAssetSupport_InvalidBridgeFeeToken();
        }

        if (data.destinationChainReceiver == address(0)) {
            revert MultiChainHyperlaneTellerWithMultiAssetSupport_ZeroAddressDestinationReceiver();
        }

        bytes memory _payload = abi.encode(shareAmount, data.destinationChainReceiver, messageId);

        // Unlike L0 that has a built in peer check, this contract must
        // constrain the message recipient itself. We do this by our own
        // configuration.
        bytes32 msgRecipient = _addressToBytes32(selectorToChains[data.chainSelector].targetTeller);

        mailbox.dispatch{ value: msg.value }(
            data.chainSelector, // must be `destinationDomain` on hyperlane
            msgRecipient, // must be the teller address left-padded to bytes32
            _payload,
            StandardHookMetadata.overrideGasLimit(data.messageGas), // Sets the refund address to msg.sender, sets
            // `_msgValue` to zero
            hook
        );
    }

    function _addressToBytes32(address _address) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_address)));
    }

    function _bytes32ToAddress(bytes32 _address) internal pure returns (address) {
        if (uint256(_address) > uint256(type(uint160).max)) {
            revert MultiChainHyperlaneTellerWithMultiAssetSupport_InvalidBytes32Address(_address);
        }

        return address(uint160(uint256(_address)));
    }

}
