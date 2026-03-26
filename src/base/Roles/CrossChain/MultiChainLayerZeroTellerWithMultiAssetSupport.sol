// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { MultiChainTellerBase, MultiChainTellerBase_MessagesNotAllowedFrom } from "./MultiChainTellerBase.sol";
import { BridgeData, ERC20 } from "./CrossChainTellerBase.sol";
import { OAppAuth, MessagingFee, Origin, MessagingReceipt } from "./OAppAuth/OAppAuth.sol";

import { OptionsBuilder } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";

/**
 * @title MultiChainLayerZeroTellerWithMultiAssetSupport
 * @notice LayerZero implementation of MultiChainTeller
 */
contract MultiChainLayerZeroTellerWithMultiAssetSupport is MultiChainTellerBase, OAppAuth {

    using OptionsBuilder for bytes;

    error MultiChainLayerZeroTellerWithMultiAssetSupport_InvalidToken();

    constructor(
        address _owner,
        address _vault,
        address _accountant,
        address _endpoint
    )
        MultiChainTellerBase(_owner, _vault, _accountant)
        OAppAuth(_endpoint, _owner)
    { }

    /**
     * @notice function override to return the fee quote
     * @param shareAmount to be sent as a message
     * @param data Bridge data
     */
    function _quote(uint256 shareAmount, BridgeData calldata data) internal view override returns (uint256) {
        bytes memory _message = abi.encode(shareAmount, data.destinationChainReceiver);
        bytes memory _options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(data.messageGas, 0);

        if (address(data.bridgeFeeToken) != NATIVE) {
            revert MultiChainLayerZeroTellerWithMultiAssetSupport_InvalidToken();
        }

        MessagingFee memory fee = _quote(data.chainSelector, _message, _options, false);

        return fee.nativeFee;
    }

    /**
     * @notice Called when data is received from the protocol. It overrides the equivalent function in the parent
     * contract.
     * Protocol messages are defined as packets, comprised of the following parameters.
     * @param _origin A struct containing information about where the packet came from.
     * @param _guid A global unique identifier for tracking the packet.
     * @param payload Encoded message.
     */
    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata payload,
        address, // Executor address as specified by the OApp.
        bytes calldata // Any extra data or options to trigger on receipt.
    )
        internal
        override
    {
        if (!selectorToChains[_origin.srcEid].allowMessagesFrom) {
            revert MultiChainTellerBase_MessagesNotAllowedFrom(_origin.srcEid);
        }

        // Decode the payload to get the message
        (uint256 shareAmount, address receiver) = abi.decode(payload, (uint256, address));
        _beforeReceive(shareAmount, receiver);

        vault.enter(address(0), ERC20(address(0)), 0, receiver, shareAmount);

        _afterReceive(shareAmount, receiver, _guid);
    }

    /**
     * @notice bridge override to allow bridge logic to be done for bridge() and depositAndBridge()
     * @param shareAmount to be moved across chain
     * @param data BridgeData
     */
    function _bridge(uint256 shareAmount, BridgeData calldata data) internal override returns (bytes32) {
        if (address(data.bridgeFeeToken) != NATIVE) {
            revert MultiChainLayerZeroTellerWithMultiAssetSupport_InvalidToken();
        }

        bytes memory _payload = abi.encode(shareAmount, data.destinationChainReceiver);
        bytes memory _options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(data.messageGas, 0);

        MessagingReceipt memory receipt = _lzSend(
            data.chainSelector,
            _payload,
            _options,
            // Fee in native gas and ZRO token.
            MessagingFee(msg.value, 0),
            // Refund address in case of failed source message.
            payable(msg.sender)
        );

        return receipt.guid;
    }

}
