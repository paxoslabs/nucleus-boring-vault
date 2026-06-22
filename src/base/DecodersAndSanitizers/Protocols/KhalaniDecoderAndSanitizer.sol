// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

abstract contract KhalaniDecoderAndSanitizer is BaseDecoderAndSanitizer {

    //============================== KHALANI ===============================

    // @desc Khalani AssetReserves deposit
    // @tag token:address:the source spoke token deposited
    // @tag payloadType:bytes32:the Gateway conversion-deposit type hash
    // @tag integratorId:bytes32:the integrator identifier
    // @tag dstMToken:address:the destination spoke token
    // @tag payoutAddr:address:where the converted token is paid out
    // @tag refundAddr:address:where refunds go if the order fails
    function deposit(
        address token,
        uint256,
        bytes calldata conversionPayload,
        uint256
    )
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        // conversionPayload = abi.encode(payloadType, integratorId, dstMToken, payoutAddr, refundAddr, nonce, feeBps,
        // totalMarginBps, deadline, operatorSig)
        (bytes32 payloadType, bytes32 integratorId, address dstMToken, address payoutAddr, address refundAddr,,,,,) = abi.decode(
            conversionPayload, (bytes32, bytes32, address, address, address, uint256, uint16, uint16, uint256, bytes)
        );
        addressesFound = abi.encodePacked(token, payloadType, integratorId, dstMToken, payoutAddr, refundAddr);
    }

}
