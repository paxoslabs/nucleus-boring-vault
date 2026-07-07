// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import {
    ILayerZeroEndpointV2,
    MessagingParams,
    MessagingFee,
    MessagingReceipt,
    Origin
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { SetConfigParam } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";

/// @notice LayerZero endpoint mock sufficient for construction and cross-chain dispatch tests.
/// @dev Implements the minimal subset of `ILayerZeroEndpointV2` used by `TransitStation`:
///      `eid()`, `setDelegate(address)`, `quote(...)`, and `send{value}(...)`. All other
///      interface methods are stubbed out with empty or reverting implementations.
contract MockEndpoint is ILayerZeroEndpointV2 {

    uint32 public immutable override eid;
    uint256 public quoteFee;

    constructor(uint32 _eid) {
        eid = _eid;
    }

    function setQuoteFee(uint256 _quoteFee) external {
        quoteFee = _quoteFee;
    }

    // ---- Methods actually exercised by TransitStation ----

    function setDelegate(address) external pure override { }

    function quote(MessagingParams calldata, address) external view override returns (MessagingFee memory) {
        return MessagingFee(quoteFee, 0);
    }

    function send(MessagingParams calldata, address) external payable override returns (MessagingReceipt memory) {
        require(msg.value >= quoteFee, "LZ fee insufficient");
        return MessagingReceipt(bytes32(0), 0, MessagingFee(msg.value, 0));
    }

    // ---- ILayerZeroEndpointV2 stubs ----

    function clear(address, Origin calldata, bytes32, bytes calldata) external pure override {
        revert("unsupported");
    }

    function setLzToken(address) external pure override {
        revert("unsupported");
    }

    function nativeToken() external pure override returns (address) {
        return address(0);
    }

    function lzToken() external pure override returns (address) {
        return address(0);
    }

    function verify(Origin calldata, address, bytes32) external pure override {
        revert("unsupported");
    }

    function verifiable(Origin calldata, address) external pure override returns (bool) {
        return false;
    }

    function initializable(Origin calldata, address) external pure override returns (bool) {
        return false;
    }

    function lzReceive(Origin calldata, address, bytes32, bytes calldata, bytes calldata) external payable override {
        revert("unsupported");
    }

    // ---- IMessagingChannel stubs ----

    function skip(address, uint32, bytes32, uint64) external pure override {
        revert("unsupported");
    }

    function nilify(address, uint32, bytes32, uint64, bytes32) external pure override {
        revert("unsupported");
    }

    function burn(address, uint32, bytes32, uint64, bytes32) external pure override {
        revert("unsupported");
    }

    function nextGuid(address, uint32, bytes32) external pure override returns (bytes32) {
        return bytes32(0);
    }

    function inboundNonce(address, uint32, bytes32) external pure override returns (uint64) {
        return 0;
    }

    function outboundNonce(address, uint32, bytes32) external pure override returns (uint64) {
        return 0;
    }

    function inboundPayloadHash(address, uint32, bytes32, uint64) external pure override returns (bytes32) {
        return bytes32(0);
    }

    function lazyInboundNonce(address, uint32, bytes32) external pure override returns (uint64) {
        return 0;
    }

    // ---- IMessagingComposer stubs ----

    function composeQueue(address, address, bytes32, uint16) external pure override returns (bytes32) {
        return bytes32(0);
    }

    function sendCompose(address, bytes32, uint16, bytes calldata) external pure override {
        revert("unsupported");
    }

    function lzCompose(address, address, bytes32, uint16, bytes calldata, bytes calldata) external payable override {
        revert("unsupported");
    }

    // ---- IMessagingContext stubs ----

    function isSendingMessage() external pure override returns (bool) {
        return false;
    }

    function getSendContext() external pure override returns (uint32, address) {
        return (0, address(0));
    }

    // ---- IMessageLibManager stubs ----

    function registerLibrary(address) external pure override {
        revert("unsupported");
    }

    function isRegisteredLibrary(address) external pure override returns (bool) {
        return false;
    }

    function getRegisteredLibraries() external pure override returns (address[] memory) {
        return new address[](0);
    }

    function setDefaultSendLibrary(uint32, address) external pure override {
        revert("unsupported");
    }

    function defaultSendLibrary(uint32) external pure override returns (address) {
        return address(0);
    }

    function setDefaultReceiveLibrary(uint32, address, uint256) external pure override {
        revert("unsupported");
    }

    function defaultReceiveLibrary(uint32) external pure override returns (address) {
        return address(0);
    }

    function setDefaultReceiveLibraryTimeout(uint32, address, uint256) external pure override {
        revert("unsupported");
    }

    function defaultReceiveLibraryTimeout(uint32) external pure override returns (address, uint256) {
        return (address(0), 0);
    }

    function isSupportedEid(uint32) external pure override returns (bool) {
        return true;
    }

    function isValidReceiveLibrary(address, uint32, address) external pure override returns (bool) {
        return false;
    }

    function setSendLibrary(address, uint32, address) external pure override {
        revert("unsupported");
    }

    function getSendLibrary(address, uint32) external pure override returns (address) {
        return address(0);
    }

    function isDefaultSendLibrary(address, uint32) external pure override returns (bool) {
        return false;
    }

    function setReceiveLibrary(address, uint32, address, uint256) external pure override {
        revert("unsupported");
    }

    function getReceiveLibrary(address, uint32) external pure override returns (address, bool) {
        return (address(0), false);
    }

    function setReceiveLibraryTimeout(address, uint32, address, uint256) external pure override {
        revert("unsupported");
    }

    function receiveLibraryTimeout(address, uint32) external pure override returns (address, uint256) {
        return (address(0), 0);
    }

    function setConfig(address, address, SetConfigParam[] calldata) external pure override {
        revert("unsupported");
    }

    function getConfig(address, address, uint32, uint32) external pure override returns (bytes memory) {
        return "";
    }

    receive() external payable { }

    }
