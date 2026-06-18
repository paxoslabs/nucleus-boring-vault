// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

abstract contract CurveDecoderAndSanitizer is BaseDecoderAndSanitizer {

    //============================== CURVE ===============================

    // @desc exchange on curve
    function exchange(int128, int128, uint256, uint256) external pure virtual returns (bytes memory addressesFound) {
        // Nothing to sanitize or return
        return addressesFound;
    }

    // @desc add liquidity on curve
    function add_liquidity(uint256[] calldata, uint256) external pure virtual returns (bytes memory addressesFound) {
        // Nothing to sanitize or return
        return addressesFound;
    }

    // @desc remove liquidity on curve
    // @tag user:address:the address of the user receiving rewards
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
