// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { Test } from "@forge-std/Test.sol";
import { EquivalentExchange } from "src/helper/equivalent-exchange/EquivalentExchange.sol";
import { Auth, Authority } from "@solmate/auth/Auth.sol";

contract EquivalentExchangeExternal is EquivalentExchange {

    constructor() EquivalentExchange(address(this), Authority(address(0))) { }

    function normalize(uint256 amount, uint8 decimals) external pure returns (uint256) {
        return _normalize(amount, decimals);
    }

    function denormalize(uint256 normalizedAmount, uint8 decimals) external pure returns (uint256) {
        return _denormalize(normalizedAmount, decimals);
    }

}

contract EquivalentExchangeInternal is Test {

    EquivalentExchangeExternal internal harness;

    function setUp() external {
        harness = new EquivalentExchangeExternal();
    }

    function test_Normalize_SixDecimals() external view {
        assertEq(harness.normalize(1_000_000, 6), 1e18);
        assertEq(harness.normalize(1, 6), 1e12);
    }

    function test_Normalize_EighteenDecimals() external view {
        assertEq(harness.normalize(1e18, 18), 1e18);
        assertEq(harness.normalize(1, 18), 1);
    }

    function test_Normalize_TwentyFourDecimals() external view {
        assertEq(harness.normalize(1e24, 24), 1e18);
        // Values not aligned to 10**(24-18) are truncated during normalization.
        assertEq(harness.normalize(1_000_000_000_000_000_000_100_000, 24), 1_000_000_000_000_000_000);
    }

    function test_Denormalize_SixDecimals() external view {
        assertEq(harness.denormalize(1e18, 6), 1_000_000);
        // Non-zero normalized amounts below one 6-decimal unit round up.
        assertEq(harness.denormalize(100_000, 6), 1);
    }

    function test_Denormalize_EighteenDecimals() external view {
        assertEq(harness.denormalize(1e18, 18), 1e18);
        assertEq(harness.denormalize(1, 18), 1);
    }

    function test_Denormalize_TwentyFourDecimals() external view {
        assertEq(harness.denormalize(1e18, 24), 1e24);
        assertEq(harness.denormalize(1, 24), 1e6);
    }

}
