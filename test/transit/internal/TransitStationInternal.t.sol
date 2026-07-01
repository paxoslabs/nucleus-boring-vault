// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Test } from "forge-std/Test.sol";
import { Authority } from "@solmate/auth/Auth.sol";
import { RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { TransitStationInternal } from "test/transit/internal/TransitStationInternal.sol";

/// @notice Minimal LayerZero endpoint mock sufficient for `TransitStationInternal` construction.
contract MockEndpoint {

    uint32 public immutable eid;

    constructor(uint32 _eid) {
        eid = _eid;
    }

    function setDelegate(address) external pure { }

}

contract TransitStationInternalTest is Test {

    TransitStationInternal internal station;

    function setUp() public {
        RolesAuthority rolesAuthority = new RolesAuthority(address(this), Authority(address(0)));
        MockEndpoint endpoint = new MockEndpoint(1);
        station = new TransitStationInternal(
            address(this),
            Authority(address(rolesAuthority)),
            address(endpoint),
            address(1),
            address(2),
            address(3),
            address(4)
        );
    }

    // ========================================= _toTokenDecimals =========================================

    function testToTokenDecimals_LessThan18Decimals() external view {
        assertEq(station.exposedToTokenDecimals(1e18, 6), 1e6);
        assertEq(station.exposedToTokenDecimals(123_456_789e12, 6), 123_456_789);
        assertEq(station.exposedToTokenDecimals(1e12, 6), 1);
        assertEq(station.exposedToTokenDecimals(0.5e12, 6), 0);
    }

    function testToTokenDecimals_MoreThan18Decimals() external view {
        assertEq(station.exposedToTokenDecimals(1e18, 21), 1e21);
        assertEq(station.exposedToTokenDecimals(2e18, 27), 2e27);
    }

    function testToTokenDecimals_Equals18Decimals() external view {
        assertEq(station.exposedToTokenDecimals(1e18, 18), 1e18);
        assertEq(station.exposedToTokenDecimals(123_456_789e18, 18), 123_456_789e18);
    }

    function testToTokenDecimals_ZeroDecimals() external view {
        assertEq(station.exposedToTokenDecimals(1e18, 0), 1);
        assertEq(station.exposedToTokenDecimals(0.5e18, 0), 0);
    }

    // ========================================= _toNormalizedDecimals =========================================

    function testToNormalizedDecimals_LessThan18Decimals() external view {
        assertEq(station.exposedToNormalizedDecimals(1e6, 6), 1e18);
        assertEq(station.exposedToNormalizedDecimals(123_456_789, 6), 123_456_789e12);
    }

    function testToNormalizedDecimals_MoreThan18Decimals() external view {
        assertEq(station.exposedToNormalizedDecimals(1e21, 21), 1e18);
        assertEq(station.exposedToNormalizedDecimals(2e27, 27), 2e18);
    }

    function testToNormalizedDecimals_Equals18Decimals() external view {
        assertEq(station.exposedToNormalizedDecimals(1e18, 18), 1e18);
        assertEq(station.exposedToNormalizedDecimals(123_456_789e18, 18), 123_456_789e18);
    }

    function testToNormalizedDecimals_ZeroDecimals() external view {
        assertEq(station.exposedToNormalizedDecimals(1, 0), 1e18);
        assertEq(station.exposedToNormalizedDecimals(5, 0), 5e18);
    }

    // ========================================= Round-trip invariants =========================================

    function testRoundTrip_Fuzz(uint256 amountNormalized18, uint8 decimals) external view {
        decimals = uint8(bound(decimals, 0, 27));
        amountNormalized18 = bound(amountNormalized18, 0, type(uint128).max);

        uint256 tokenUnits = station.exposedToTokenDecimals(amountNormalized18, decimals);
        uint256 normalizedAgain = station.exposedToNormalizedDecimals(tokenUnits, decimals);

        // Truncation toward zero means re-normalizing cannot exceed the original.
        assertLe(normalizedAgain, amountNormalized18);

        // For tokens with >= 18 decimals, the round trip is exact because scaling is pure multiplication/division.
        if (decimals >= 18) {
            assertEq(normalizedAgain, amountNormalized18);
        }
    }

}
