// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";
import { PirexEthDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/PirexEthDecoderAndSanitizer.sol";
import { CurveDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/CurveDecoderAndSanitizer.sol";
import {
    UniswapV3DecoderAndSanitizer
} from "src/base/DecodersAndSanitizers/Protocols/UniswapV3DecoderAndSanitizer.sol";
import { ERC4626DecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/ERC4626DecoderAndSanitizer.sol";
import {
    LayerZeroOFTDecoderAndSanitizer
} from "src/base/DecodersAndSanitizers/Protocols/LayerZeroOFTDecoderAndSanitizer.sol";
import {
    PendleRouterDecoderAndSanitizer
} from "src/base/DecodersAndSanitizers/Protocols/PendleRouterDecoderAndSanitizer.sol";
import {
    NativeWrapperDecoderAndSanitizer
} from "src/base/DecodersAndSanitizers/Protocols/NativeWrapperDecoderAndSanitizer.sol";
import {
    BalancerV2DecoderAndSanitizer
} from "src/base/DecodersAndSanitizers/Protocols/BalancerV2DecoderAndSanitizer.sol";
import { EigenpieDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/EigenpieDecoderAndSanitizer.sol";
import { PxlDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/PxlDecoderAndSanitizer.sol";

contract ssETHDecoderAndSanitizer is
    BaseDecoderAndSanitizer,
    PirexEthDecoderAndSanitizer,
    CurveDecoderAndSanitizer,
    UniswapV3DecoderAndSanitizer,
    ERC4626DecoderAndSanitizer,
    LayerZeroOFTDecoderAndSanitizer,
    PendleRouterDecoderAndSanitizer,
    NativeWrapperDecoderAndSanitizer,
    BalancerV2DecoderAndSanitizer,
    EigenpieDecoderAndSanitizer,
    PxlDecoderAndSanitizer
{

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
        override(ERC4626DecoderAndSanitizer, CurveDecoderAndSanitizer, BalancerV2DecoderAndSanitizer)
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(receiver);
    }

    function withdraw(uint256)
        external
        pure
        override(CurveDecoderAndSanitizer, BalancerV2DecoderAndSanitizer, NativeWrapperDecoderAndSanitizer)
        returns (bytes memory addressesFound)
    {
        // Nothing to sanitize or return
        return addressesFound;
    }

}
