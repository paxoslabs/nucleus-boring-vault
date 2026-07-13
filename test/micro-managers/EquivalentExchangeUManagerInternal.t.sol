// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { Test } from "@forge-std/Test.sol";
import { EquivalentExchangeUManager } from "src/micro-managers/EquivalentExchangeUManager.sol";

/// @notice Exposes EquivalentExchangeUManager's internal pure helpers for direct testing.
contract EquivalentExchangeUManagerExternal is EquivalentExchangeUManager {

    // The UManager constructor only stores the manager/boringVault addresses and wires up Auth,
    // none of which the pure normalization helpers depend on, so dummy addresses are sufficient.
    constructor() EquivalentExchangeUManager(address(this), address(this), address(this)) { }

    function normalize(uint256 amount, uint8 decimals) external pure returns (uint256) {
        return _normalize(amount, decimals);
    }

    function denormalize(uint256 normalizedAmount, uint8 decimals) external pure returns (uint256) {
        return _denormalize(normalizedAmount, decimals);
    }

}

contract EquivalentExchangeUManagerInternal is Test {

    EquivalentExchangeUManagerExternal internal harness;

    function setUp() external {
        harness = new EquivalentExchangeUManagerExternal();
    }

    // ============================== _normalize ==============================

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

    function test_Normalize_ZeroAmount() external view {
        assertEq(harness.normalize(0, 6), 0);
        assertEq(harness.normalize(0, 18), 0);
        assertEq(harness.normalize(0, 24), 0);
    }

    // ============================== _denormalize ==============================

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

    function test_Denormalize_ZeroAmount() external view {
        assertEq(harness.denormalize(0, 6), 0);
        assertEq(harness.denormalize(0, 18), 0);
        assertEq(harness.denormalize(0, 24), 0);
    }

    // A non-zero shortfall that does not divide evenly into the token's units must round up so the
    // subsidy never underestimates what is owed.
    function test_Denormalize_RoundsUp() external view {
        // 1.5 units of a 6-decimal token (1.5e12 normalized) must round up to 2 native units.
        assertEq(harness.denormalize(1_500_000_000_000, 6), 2);
        // One wei above a whole unit rounds up to the next unit.
        assertEq(harness.denormalize(1e12 + 1, 6), 2);
        // Non-zero normalized amounts below one unit round up.
        assertEq(harness.denormalize(999_999, 6), 1);
        assertEq(harness.denormalize(1, 6), 1);
    }

    // ============================== round-trip properties ==============================

    // denormalize (round up) then normalize must never underestimate the original normalized amount.
    // This is the property _coverShortfall relies on to keep the value invariant intact.
    function testFuzz_DenormalizeThenNormalize_NoUnderestimate(uint256 shortfall, uint8 decimals) external view {
        decimals = uint8(bound(decimals, 0, 30));
        // Keep the shortfall small enough that denormalization cannot overflow for large decimals.
        shortfall = bound(shortfall, 0, 1e30);

        uint256 nativeAmount = harness.denormalize(shortfall, decimals);
        uint256 renormalized = harness.normalize(nativeAmount, decimals);

        // For decimals <= 18, denormalize rounds up so renormalized >= shortfall.
        // For decimals > 18, denormalize scales up exactly and normalize scales back down exactly.
        if (decimals <= 18) {
            assertGe(renormalized, shortfall);
        } else {
            assertEq(renormalized, shortfall);
        }
    }

    // normalize then denormalize must return at least the original native amount (never loses funds
    // owed) for tokens with <= 18 decimals, where normalization is lossless.
    function testFuzz_NormalizeThenDenormalize_LosslessUnder18(uint256 amount, uint8 decimals) external view {
        decimals = uint8(bound(decimals, 0, 18));
        amount = bound(amount, 0, 1e30);

        uint256 normalized = harness.normalize(amount, decimals);
        assertEq(harness.denormalize(normalized, decimals), amount);
    }

}
