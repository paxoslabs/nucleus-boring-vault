// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

abstract contract SkyDecoderAndSanitizer is BaseDecoderAndSanitizer {

    //============================== SKY DssLitePsm / UsdsPsmWrapper ===============================

    // @desc Sky PSM wrapper sellGem, swaps gem for USDS
    // @tag usr:address:the recipient of the USDS
    function sellGem(address usr, uint256) external pure virtual returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(usr);
    }

    // @desc Sky PSM wrapper buyGem, swaps USDS for gem
    // @tag usr:address:the recipient of the gem
    function buyGem(address usr, uint256) external pure virtual returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(usr);
    }

    //============================== SKY PSM3 ===============================

    // @desc Sky PSM3 swapExactIn, swaps an exact amount of assetIn for assetOut
    // @tag assetIn:address:the asset sold to the PSM
    // @tag assetOut:address:the asset bought from the PSM
    // @tag receiver:address:the recipient of assetOut
    // @tag referralCode:uint256:the referral code attributed to the swap
    function swapExactIn(
        address assetIn,
        address assetOut,
        uint256,
        uint256,
        address receiver,
        uint256 referralCode
    )
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(assetIn, assetOut, receiver, referralCode);
    }

}
