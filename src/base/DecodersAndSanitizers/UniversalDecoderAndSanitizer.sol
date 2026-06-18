// SPDX-License-Identifier: MIT

pragma solidity 0.8.21;

import {
    PendleRouterDecoderAndSanitizer,
    BaseDecoderAndSanitizer
} from "src/base/DecodersAndSanitizers/Protocols/PendleRouterDecoderAndSanitizer.sol";
import {
    UniversalRouterDecoderAndSanitizer
} from "src/base/DecodersAndSanitizers/Protocols/UniversalRouterDecoderAndSanitizer.sol";
import {
    UniswapV3DecoderAndSanitizer
} from "src/base/DecodersAndSanitizers/Protocols/UniswapV3DecoderAndSanitizer.sol";
import { GranularityDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/GranularityDecoderAndSanitizer.sol";
import { OneInchDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/OneInchDecoderAndSanitizer.sol";
import { CurveDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/CurveDecoderAndSanitizer.sol";
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

/// @notice Same protocol set as `GenericDecoderAndSanitizer`, with Uniswap split across two mixins:
///         `UniversalRouterDecoderAndSanitizer` for swapping (the Permit2 `approve`, the V2/V3/V4 swap commands,
///         and the mandatory `SWEEP` of leftover funds) and `UniswapV3DecoderAndSanitizer` for direct Uniswap V3
///         position management (NonfungiblePositionManager `mint`/`increaseLiquidity`/`decreaseLiquidity`/etc.).
contract UniversalDecoderAndSanitizer is
    PendleRouterDecoderAndSanitizer,
    UniversalRouterDecoderAndSanitizer,
    UniswapV3DecoderAndSanitizer,
    OneInchDecoderAndSanitizer,
    CurveDecoderAndSanitizer,
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
    /// @param _granularity Resolution for the Universal Router decoder's slippage-bound commitment (0 = unconstrained).
    /// @param _uniswapV3NonFungiblePositionManager V3 NFPM, for the direct Uniswap V3 position-management decoder.
    constructor(
        address _boringVault,
        uint256 _granularity,
        address _uniswapV3NonFungiblePositionManager
    )
        BaseDecoderAndSanitizer(_boringVault)
        UniswapV3DecoderAndSanitizer(_uniswapV3NonFungiblePositionManager)
        UniversalRouterDecoderAndSanitizer(_granularity)
    { }

    /// @dev Both the granularity base default and the Universal Router decoder's override are in scope; defer to the
    ///      latter so every granular commitment (Uniswap swaps and Curve slippage bounds) shares one resolution.
    function _granularity()
        internal
        view
        override(GranularityDecoderAndSanitizer, UniversalRouterDecoderAndSanitizer)
        returns (uint256)
    {
        return UniversalRouterDecoderAndSanitizer._granularity();
    }

    function deposit(
        uint256,
        address receiver
    )
        external
        pure
        override(CurveDecoderAndSanitizer, ERC4626DecoderAndSanitizer, BalancerV2DecoderAndSanitizer)
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(receiver);
    }

    function withdraw(uint256)
        external
        pure
        override(CurveDecoderAndSanitizer, NativeWrapperDecoderAndSanitizer, BalancerV2DecoderAndSanitizer)
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
