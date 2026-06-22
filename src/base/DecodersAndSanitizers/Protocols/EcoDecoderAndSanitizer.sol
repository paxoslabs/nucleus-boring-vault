// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import {
    BaseDecoderAndSanitizer,
    DecoderCustomTypes
} from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

/// @notice Decoder for the Eco Portal `publishAndFund` overload that takes the route as opaque bytes
///         (https://docs.eco.com/routes/architecture/portal). Pins the destination chain and the reward addresses
///         the vault funds. The encoded `route` (destination portal, tokens, calls) is not decoded, so it is not
///         constrained here.
abstract contract EcoDecoderAndSanitizer is BaseDecoderAndSanitizer {

    //============================== ECO ===============================

    // @desc Eco Portal publishAndFund — publish a cross-chain intent and fund its reward
    // @tag destination:uint64:the destination chain id
    // @tag creator:address:the reward creator (funding/refund authority)
    // @tag prover:address:the prover that must attest execution
    // @tag rewardToken:address:each reward token offered on the source chain
    function publishAndFund(
        uint64 destination,
        bytes calldata route,
        DecoderCustomTypes.EcoReward calldata reward,
        bool
    )
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        /// TODO: needs to decode the route...
        addressesFound = abi.encodePacked(destination, reward.creator, reward.prover);

        DecoderCustomTypes.EcoTokenAmount[] calldata rewardTokens = reward.tokens;
        for (uint256 i; i < rewardTokens.length; ++i) {
            addressesFound = abi.encodePacked(addressesFound, rewardTokens[i].token);
        }
    }

}
