// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { GranularityDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/GranularityDecoderAndSanitizer.sol";

abstract contract CurveDecoderAndSanitizer is GranularityDecoderAndSanitizer {

    //============================== CURVE ===============================

    // @desc exchange on curve; commits the min_dy slippage floor at `_granularity()` resolution
    // @tag granularity:uint256:slippage protection bound
    function exchange(
        int128,
        int128,
        uint256,
        uint256 min_dy
    )
        external
        view
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = _bound(min_dy);
    }

    // @desc add liquidity on curve; commits the min_mint_amount slippage floor at `_granularity()` resolution
    // @tag granularity:uint256:slippage protection bound
    function add_liquidity(
        uint256[] calldata,
        uint256 min_mint_amount
    )
        external
        view
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = _bound(min_mint_amount);
    }

    // @desc remove liquidity on curve
    function remove_liquidity(uint256, uint256[] calldata) external pure virtual returns (bytes memory addressesFound) {
        // Nothing to sanitize or return
        return addressesFound;
    }

    function deposit(uint256, address receiver) external view virtual returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(receiver);
    }

    function withdraw(uint256) external pure virtual returns (bytes memory addressesFound) {
        // Nothing to sanitize or return
        return addressesFound;
    }

    // @desc claim rewards on curve
    // @tag user:address:the address of the user receiving rewards
    function claim_rewards(address _addr) external pure virtual returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(_addr);
    }

}
