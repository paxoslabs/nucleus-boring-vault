// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import {
    PendleRouterDecoderAndSanitizer,
    BaseDecoderAndSanitizer
} from "src/base/DecodersAndSanitizers/Protocols/PendleRouterDecoderAndSanitizer.sol";
import {
    UniswapV3DecoderAndSanitizer
} from "src/base/DecodersAndSanitizers/Protocols/UniswapV3DecoderAndSanitizer.sol";
import { OneInchDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/OneInchDecoderAndSanitizer.sol";
import { CurveDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/CurveDecoderAndSanitizer.sol";
import {
    NativeWrapperDecoderAndSanitizer
} from "src/base/DecodersAndSanitizers/Protocols/NativeWrapperDecoderAndSanitizer.sol";
import { ERC4626DecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/ERC4626DecoderAndSanitizer.sol";
import { EigenpieDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/EigenpieDecoderAndSanitizer.sol";
import { PirexEthDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/PirexEthDecoderAndSanitizer.sol";
import {
    ThunderheadDecoderAndSanitizer
} from "src/base/DecodersAndSanitizers/Protocols/ThunderheadDecoderAndSanitizer.sol";
import { AaveV3DecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/AaveV3DecoderAndSanitizer.sol";
import {
    VelodromeV1DecoderAndSanitizer
} from "src/base/DecodersAndSanitizers/Protocols/VelodromeV1DecoderAndSanitizer.sol";
import {
    FlashHypeDecoderAndSanitizer
} from "src/base/DecodersAndSanitizers/Protocols/FlashHypeDecoderAndSanitizer.sol";
import {
    CoreWriterDecoderAndSanitizer
} from "src/base/DecodersAndSanitizers/Protocols/CoreWriterDecoderAndSanitizer.sol";
import { FraxLendDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/FraxLendDecoderAndSanitizer.sol";
import {
    VelodromeBuybackDecoderAndSanitizer
} from "src/base/DecodersAndSanitizers/Protocols/VelodromeBuybackDecoderAndSanitizer.sol";
import {
    HyperliquidForwarderDecoderAndSanitizer
} from "src/base/DecodersAndSanitizers/Protocols/HyperliquidForwarderDecoderAndSanitizer.sol";
import { PumpBTCDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/PumpBTCDecoderAndSanitizer.sol";
import { PxlDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/PxlDecoderAndSanitizer.sol";

contract WHLPDecoderAndSanitizer is
    PendleRouterDecoderAndSanitizer,
    UniswapV3DecoderAndSanitizer,
    OneInchDecoderAndSanitizer,
    CurveDecoderAndSanitizer,
    NativeWrapperDecoderAndSanitizer,
    PxlDecoderAndSanitizer,
    ERC4626DecoderAndSanitizer,
    EigenpieDecoderAndSanitizer,
    PirexEthDecoderAndSanitizer,
    ThunderheadDecoderAndSanitizer,
    AaveV3DecoderAndSanitizer,
    VelodromeV1DecoderAndSanitizer,
    CoreWriterDecoderAndSanitizer,
    FlashHypeDecoderAndSanitizer,
    FraxLendDecoderAndSanitizer,
    VelodromeBuybackDecoderAndSanitizer,
    HyperliquidForwarderDecoderAndSanitizer,
    PumpBTCDecoderAndSanitizer
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
        override(CurveDecoderAndSanitizer, ERC4626DecoderAndSanitizer)
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(receiver);
    }

    function withdraw(uint256)
        external
        pure
        override(CurveDecoderAndSanitizer, NativeWrapperDecoderAndSanitizer)
        returns (bytes memory addressesFound)
    {
        // Nothing to sanitize or return
        return addressesFound;
    }

    function sendToVault(address, uint64) external view virtual returns (bytes memory addressesFound) { }

    function transferHLP(address, uint64, bool) external view virtual returns (bytes memory addressesfound) { }

    function USDClassTransfer(address, uint64, bool) external view virtual returns (bytes memory addressesfound) { }

    function withdraw(address, uint64) external view virtual returns (bytes memory addressesfound) { }

    function deposit(address, uint64) external view virtual returns (bytes memory addressesfound) { }

    function deployAccounts(uint256) external view virtual returns (bytes memory addressesfound) { }

}
