// SPDX-License-Identifier: MIT

pragma solidity 0.8.21;

import {
    PendleRouterDecoderAndSanitizer,
    BaseDecoderAndSanitizer
} from "src/base/DecodersAndSanitizers/Protocols/PendleRouterDecoderAndSanitizer.sol";
import {
    UniswapUniversalStablecoinDecoderAndSanitizer
} from "src/base/DecodersAndSanitizers/Protocols/UniswapUniversalStablecoinDecoderAndSanitizer.sol";
import {
    UniswapV3DecoderAndSanitizer
} from "src/base/DecodersAndSanitizers/Protocols/UniswapV3DecoderAndSanitizer.sol";
import { OneInchDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/OneInchDecoderAndSanitizer.sol";
import {
    StablecoinCurveDecoderAndSanitizer
} from "src/base/DecodersAndSanitizers/Protocols/StablecoinCurveDecoderAndSanitizer.sol";
import {
    NativeWrapperDecoderAndSanitizer
} from "src/base/DecodersAndSanitizers/Protocols/NativeWrapperDecoderAndSanitizer.sol";
import { ERC4626DecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/ERC4626DecoderAndSanitizer.sol";
import { EigenpieDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/EigenpieDecoderAndSanitizer.sol";
import { PirexEthDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/PirexEthDecoderAndSanitizer.sol";
import { AaveV3DecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/AaveV3DecoderAndSanitizer.sol";
import {
    VelodromeV1DecoderAndSanitizer
} from "src/base/DecodersAndSanitizers/Protocols/VelodromeV1DecoderAndSanitizer.sol";
import {
    FlashHypeDecoderAndSanitizer
} from "src/base/DecodersAndSanitizers/Protocols/FlashHypeDecoderAndSanitizer.sol";
import { CircleDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/CircleDecoderAndSanitizer.sol";
import {
    BalancerV2DecoderAndSanitizer
} from "src/base/DecodersAndSanitizers/Protocols/BalancerV2DecoderAndSanitizer.sol";
import {
    MorphoBlueDecoderAndSanitizer
} from "src/base/DecodersAndSanitizers/Protocols/MorphoBlueDecoderAndSanitizer.sol";
import { EtherFiDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/EtherFiDecoderAndSanitizer.sol";
import {
    LayerZeroOFTDecoderAndSanitizer
} from "src/base/DecodersAndSanitizers/Protocols/LayerZeroOFTDecoderAndSanitizer.sol";
import { NucleusDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/NucleusDecoderAndSanitizer.sol";
import {
    CoreWriterDecoderAndSanitizer
} from "src/base/DecodersAndSanitizers/Protocols/CoreWriterDecoderAndSanitizer.sol";

/// @notice Same protocol set as `GenericDecoderAndSanitizer`, with Uniswap and Curve scoped to stablecoin swaps:
///         `UniswapUniversalStablecoinDecoderAndSanitizer` (the Universal Router `approve`/swap/`SWEEP` surface) and
///         `StablecoinCurveDecoderAndSanitizer` (Curve `exchange`) each commit the swap's minimum output so the
///         merkle leaf pins the worst price the strategist may accept. `UniswapV3DecoderAndSanitizer` covers direct
///         Uniswap V3 position management.
contract GenericStablecoinDecoderAndSanitizer is
    PendleRouterDecoderAndSanitizer,
    UniswapUniversalStablecoinDecoderAndSanitizer,
    UniswapV3DecoderAndSanitizer,
    OneInchDecoderAndSanitizer,
    StablecoinCurveDecoderAndSanitizer,
    NativeWrapperDecoderAndSanitizer,
    ERC4626DecoderAndSanitizer,
    EigenpieDecoderAndSanitizer,
    PirexEthDecoderAndSanitizer,
    AaveV3DecoderAndSanitizer,
    VelodromeV1DecoderAndSanitizer,
    FlashHypeDecoderAndSanitizer,
    CircleDecoderAndSanitizer,
    BalancerV2DecoderAndSanitizer,
    MorphoBlueDecoderAndSanitizer,
    EtherFiDecoderAndSanitizer,
    LayerZeroOFTDecoderAndSanitizer,
    NucleusDecoderAndSanitizer,
    CoreWriterDecoderAndSanitizer
{

    /// @param _boringVault The vault these decodings are sanitized for.
    /// @param _uniswapV3NonFungiblePositionManager V3 NFPM, for the direct Uniswap V3 position-management decoder.
    constructor(
        address _boringVault,
        address _uniswapV3NonFungiblePositionManager
    )
        BaseDecoderAndSanitizer(_boringVault)
        UniswapV3DecoderAndSanitizer(_uniswapV3NonFungiblePositionManager)
    { }

    function deposit(
        uint256,
        address receiver
    )
        external
        pure
        override(ERC4626DecoderAndSanitizer, BalancerV2DecoderAndSanitizer)
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(receiver);
    }

    function withdraw(uint256)
        external
        pure
        override(NativeWrapperDecoderAndSanitizer, BalancerV2DecoderAndSanitizer)
        returns (bytes memory addressesFound)
    {
        // Nothing to sanitize or return
        return addressesFound;
    }

    function deposit()
        external
        pure
        virtual
        override(NativeWrapperDecoderAndSanitizer, EtherFiDecoderAndSanitizer)
        returns (bytes memory addressesFound)
    {
        // Nothing to sanitize or return
        return addressesFound;
    }

}
