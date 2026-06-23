// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

/// @notice Curve decoder scoped to stablecoin swaps. Only `exchange` is decoded, and it commits the swap's price —
///         input paid per unit of output, `dx * PRICE_SCALE / min_dy` — rather than the raw `min_dy` amount. Because
///         price is independent of trade size, one merkle leaf pins the worst rate the strategist may accept for a
///         pool (whose address the leaf's target already fixes) at any size, instead of one leaf per amount.
abstract contract StablecoinCurveDecoderAndSanitizer is BaseDecoderAndSanitizer {

    //============================== CURVE ===============================

    /// @dev Fixed-point scale for the committed price.
    uint256 internal constant PRICE_SCALE = 1e18;

    // @desc exchange on curve; commits the price paid (input per unit of output), scaled by 1e18
    // @tag i:int128:index value of coin to send
    // @tag j:int128:index value of coin to receive
    // @tag price:uint256:dx * 1e18 / min_dy — the maximum input the swap pays per unit of output
    function exchange(
        int128 i,
        int128 j,
        uint256 dx,
        uint256 min_dy
    )
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        // NOTE: We need to sanitize i and j because of the price check necessitating we specify price in context of the
        // directionality of the swap.

        // Reverts on min_dy == 0 (a swap with no output floor is unsafe and should never be approved anyway).
        addressesFound = abi.encodePacked(i, j, (dx * PRICE_SCALE) / min_dy);
    }

}
