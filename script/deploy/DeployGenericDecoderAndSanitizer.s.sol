// SPDX-License-Identifier: MIT
pragma solidity =0.8.21;

import { console } from "forge-std/console.sol";
import { GenericDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/GenericDecoderAndSanitizer.sol";
import { BaseScript } from "script/Base.s.sol";
import "src/helper/Constants.sol";

/// @notice Deploys `GenericDecoderAndSanitizer` deterministically via CreateX (CREATE3).
contract DeployGenericDecoderAndSanitizer is BaseScript {

    // ---- fill per deployment ----
    address constant BORING_VAULT = address(0x91FE06C6E9F97E7DE4580A280E03046155f8e1e3);
    // Uniswap V3 NonfungiblePositionManager (for the V3 position decoder); same address on most chains.
    address constant UNISWAP_V3_NFPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;

    bytes32 SALT = makeSalt(broadcaster, false, "Transit: GenericDecoderAndSanitizer2");

    function run() public broadcast {
        address decoder = CREATEX.deployCreate3(
            SALT,
            abi.encodePacked(type(GenericDecoderAndSanitizer).creationCode, abi.encode(BORING_VAULT, UNISWAP_V3_NFPM))
        );
        console.log("GenericDecoderAndSanitizer:", decoder);
    }

}
