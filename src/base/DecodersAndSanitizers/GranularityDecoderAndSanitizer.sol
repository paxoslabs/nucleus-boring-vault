// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

/// @notice Shared slippage-bound commitment for decoders. A bound is committed as `bound / _granularity()` plus a
///         `bound % _granularity() == 0` flag, so a band of `_granularity()` adjacent values maps to one merkle leaf
///         — the strategist can move the bound within that band without a new leaf while the leaf still pins a
///         floor/cap. `_granularity()` defaults to 0, which omits the bound entirely (any value allowed); a decoder
///         overrides it to set a per-deployment resolution.
abstract contract GranularityDecoderAndSanitizer is BaseDecoderAndSanitizer {

    function _granularity() internal view virtual returns (uint256) {
        return 0;
    }

    function _bound(uint256 amount) internal view returns (bytes memory) {
        uint256 g = _granularity();
        if (g == 0) return "";
        return abi.encodePacked(amount / g, amount % g == 0);
    }

}
