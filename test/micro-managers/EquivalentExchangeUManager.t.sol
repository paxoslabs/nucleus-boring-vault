// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { Test } from "@forge-std/Test.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { EquivalentExchangeUManager } from "src/micro-managers/EquivalentExchangeUManager.sol";

/// @notice Unit tests for EquivalentExchangeUManager's external/public surface.
contract EquivalentExchangeUManagerTest is Test {

    // Re-declared so the test can build the expected event for vm.expectEmit.
    event BasketTokensUpdated(ERC20[] tokens);

    EquivalentExchangeUManager internal uManager;

    ERC20 internal tokenA;
    ERC20 internal tokenB;
    ERC20 internal tokenC;
    ERC20 internal tokenD;

    function setUp() external {
        // owner = this test contract; with no Authority set, only the owner passes requiresAuth.
        // manager and boringVault addresses are irrelevant to basket bookkeeping.
        uManager = new EquivalentExchangeUManager(address(this), address(this), address(this));

        tokenA = ERC20(makeAddr("tokenA"));
        tokenB = ERC20(makeAddr("tokenB"));
        tokenC = ERC20(makeAddr("tokenC"));
        tokenD = ERC20(makeAddr("tokenD"));
    }

    // ============================== helpers ==============================

    function _arr(ERC20 t0) internal pure returns (ERC20[] memory a) {
        a = new ERC20[](1);
        a[0] = t0;
    }

    function _arr(ERC20 t0, ERC20 t1) internal pure returns (ERC20[] memory a) {
        a = new ERC20[](2);
        a[0] = t0;
        a[1] = t1;
    }

    function _arr(ERC20 t0, ERC20 t1, ERC20 t2) internal pure returns (ERC20[] memory a) {
        a = new ERC20[](3);
        a[0] = t0;
        a[1] = t1;
        a[2] = t2;
    }

    // ============================== setBasketTokens: happy paths ==============================

    function test_SetBasketTokens_StoresTokensInOrder() external {
        uManager.setBasketTokens(_arr(tokenA, tokenB, tokenC));

        address[] memory stored = uManager.getBasketTokens();
        assertEq(stored.length, 3);
        // EnumerableSet preserves insertion order when there have been no removals.
        assertEq(stored[0], address(tokenA));
        assertEq(stored[1], address(tokenB));
        assertEq(stored[2], address(tokenC));

        assertTrue(uManager.isBasketToken(tokenA));
        assertTrue(uManager.isBasketToken(tokenB));
        assertTrue(uManager.isBasketToken(tokenC));
        assertFalse(uManager.isBasketToken(tokenD));
    }

    function test_SetBasketTokens_ReplacesPreviousBasket() external {
        uManager.setBasketTokens(_arr(tokenA, tokenB, tokenC));

        // Overwrite with a disjoint set; exercises the backwards-removal loop that clears the old set.
        uManager.setBasketTokens(_arr(tokenD));

        address[] memory stored = uManager.getBasketTokens();
        assertEq(stored.length, 1);
        assertEq(stored[0], address(tokenD));

        // All previous tokens must be gone.
        assertFalse(uManager.isBasketToken(tokenA));
        assertFalse(uManager.isBasketToken(tokenB));
        assertFalse(uManager.isBasketToken(tokenC));
        assertTrue(uManager.isBasketToken(tokenD));
    }

    function test_SetBasketTokens_OverlappingReplacementKeepsMembership() external {
        uManager.setBasketTokens(_arr(tokenA, tokenB));
        // New basket shares tokenB and adds tokenC; tokenA must drop out.
        uManager.setBasketTokens(_arr(tokenB, tokenC));

        assertFalse(uManager.isBasketToken(tokenA));
        assertTrue(uManager.isBasketToken(tokenB));
        assertTrue(uManager.isBasketToken(tokenC));
        assertEq(uManager.getBasketTokens().length, 2);
    }

    // The three tests below empty baskets of size 1, 2, and 3 by re-setting to an empty array, which
    // runs only the internal removal loop. This guards the backwards-iteration fix: an earlier forward
    // iteration over a cached length broke for size >= 2, because EnumerableSet.remove swaps-and-pops so
    // at(i) shifts and eventually reads out of bounds as the set shrinks.

    function test_SetBasketTokens_EmptiesSizeOneBasket() external {
        uManager.setBasketTokens(_arr(tokenA));

        uManager.setBasketTokens(new ERC20[](0));

        assertEq(uManager.getBasketTokens().length, 0);
        assertFalse(uManager.isBasketToken(tokenA));
    }

    function test_SetBasketTokens_EmptiesSizeTwoBasket() external {
        uManager.setBasketTokens(_arr(tokenA, tokenB));

        uManager.setBasketTokens(new ERC20[](0));

        assertEq(uManager.getBasketTokens().length, 0);
        assertFalse(uManager.isBasketToken(tokenA));
        assertFalse(uManager.isBasketToken(tokenB));
    }

    function test_SetBasketTokens_EmptiesSizeThreeBasket() external {
        uManager.setBasketTokens(_arr(tokenA, tokenB, tokenC));

        uManager.setBasketTokens(new ERC20[](0));

        assertEq(uManager.getBasketTokens().length, 0);
        assertFalse(uManager.isBasketToken(tokenA));
        assertFalse(uManager.isBasketToken(tokenB));
        assertFalse(uManager.isBasketToken(tokenC));
    }

    function test_SetBasketTokens_DeduplicatesInput() external {
        // The underlying EnumerableSet ignores repeated adds, so duplicates collapse to one entry.
        uManager.setBasketTokens(_arr(tokenA, tokenA, tokenB));

        address[] memory stored = uManager.getBasketTokens();
        assertEq(stored.length, 2);
        assertEq(stored[0], address(tokenA));
        assertEq(stored[1], address(tokenB));
    }

    function test_SetBasketTokens_IdempotentWhenReapplyingSameSet() external {
        uManager.setBasketTokens(_arr(tokenA, tokenB));
        uManager.setBasketTokens(_arr(tokenA, tokenB));

        address[] memory stored = uManager.getBasketTokens();
        assertEq(stored.length, 2);
        assertEq(stored[0], address(tokenA));
        assertEq(stored[1], address(tokenB));
    }

    // ============================== setBasketTokens: events ==============================

    function test_SetBasketTokens_EmitsEventWithRawInput() external {
        ERC20[] memory tokens = _arr(tokenA, tokenB);

        // The event echoes the raw input array (including any duplicates), not the resulting set.
        vm.expectEmit(true, true, true, true, address(uManager));
        emit BasketTokensUpdated(tokens);

        uManager.setBasketTokens(tokens);
    }

    // ============================== setBasketTokens: access control ==============================

    function test_SetBasketTokens_RevertWhen_CallerNotAuthorized() external {
        address stranger = makeAddr("stranger");

        vm.prank(stranger);
        vm.expectRevert(bytes("UNAUTHORIZED"));
        uManager.setBasketTokens(_arr(tokenA));
    }

    // ============================== execute: guard reverts ==============================
    // These paths revert before execute reaches the manager/vault, so they need no integration
    // stack: the basket tokens are never called and _manageVaultWithMerkleVerification is unreachable.

    function _noCalls() internal pure returns (EquivalentExchangeUManager.ManageCall[] memory) {
        return new EquivalentExchangeUManager.ManageCall[](0);
    }

    function test_Execute_RevertWhen_BasketEmpty() external {
        // No basket configured, so execute reverts at the first guard before any token is touched.
        vm.expectRevert(EquivalentExchangeUManager.EquivalentExchangeUManager__EmptyBasket.selector);
        uManager.execute(_noCalls(), makeAddr("payer"), tokenA, 0);
    }

    function test_Execute_RevertWhen_SubsidyTokenNotInBasket() external {
        uManager.setBasketTokens(_arr(tokenA));

        // tokenB is not part of the basket; the guard fires before _totalBasketValue, so the codeless
        // dummy basket token is never called.
        vm.expectRevert(EquivalentExchangeUManager.EquivalentExchangeUManager__TokenNotInBasket.selector);
        uManager.execute(_noCalls(), makeAddr("payer"), tokenB, 0);
    }

    function test_Execute_RevertWhen_CallerNotAuthorized() external {
        uManager.setBasketTokens(_arr(tokenA));

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(bytes("UNAUTHORIZED"));
        uManager.execute(_noCalls(), makeAddr("payer"), tokenA, 0);
    }

    // ============================== isBasketToken ==============================

    function test_IsBasketToken_TrueForMember() external {
        uManager.setBasketTokens(_arr(tokenA, tokenB));

        assertTrue(uManager.isBasketToken(tokenA));
        assertTrue(uManager.isBasketToken(tokenB));
    }

    function test_IsBasketToken_FalseForNonMember() external {
        uManager.setBasketTokens(_arr(tokenA, tokenB));

        assertFalse(uManager.isBasketToken(tokenC));
        assertFalse(uManager.isBasketToken(tokenD));
    }

    function test_IsBasketToken_FalseForZeroAddress() external {
        uManager.setBasketTokens(_arr(tokenA));

        // The zero address is never added, so it must never be reported as a basket token.
        assertFalse(uManager.isBasketToken(ERC20(address(0))));
    }

    function test_IsBasketToken_ReflectsRemoval() external {
        uManager.setBasketTokens(_arr(tokenA, tokenB));
        assertTrue(uManager.isBasketToken(tokenA));

        // tokenA is dropped from the new basket and must no longer register as a member.
        uManager.setBasketTokens(_arr(tokenB, tokenC));

        assertFalse(uManager.isBasketToken(tokenA));
        assertTrue(uManager.isBasketToken(tokenB));
        assertTrue(uManager.isBasketToken(tokenC));
    }

    function test_IsBasketToken_FalseWhenBasketEmpty() external view {
        assertFalse(uManager.isBasketToken(tokenA));
    }

    // ============================== read accessors on empty state ==============================

    function test_GetBasketTokens_EmptyByDefault() external view {
        assertEq(uManager.getBasketTokens().length, 0);
        assertFalse(uManager.isBasketToken(tokenA));
    }

}
