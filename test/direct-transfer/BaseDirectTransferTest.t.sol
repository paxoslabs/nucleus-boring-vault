// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Test, stdStorage, StdStorage, stdError, console } from "@forge-std/Test.sol";
import { MockERC20 } from "@forge-std/mocks/MockERC20.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { Attestation } from "@predicate/interfaces/IPredicateRegistry.sol";
import { DistributorCodeDepositor } from "src/helper/DistributorCodeDepositor.sol";
import { DirectTransferAddress } from "src/direct-transfer/DirectTransferAddress.sol";
import { FactoryBeacon } from "src/direct-transfer/FactoryBeacon.sol";
import { SimpleBeacon } from "src/direct-transfer/SimpleBeacon.sol";
import { SimpleBeaconProxy } from "src/direct-transfer/SimpleBeaconProxy.sol";

/// @dev Pulls `depositAsset` from msg.sender (matching the real DCD's safeTransferFrom on deposit)
///      and sends `shareToken` to `to` at a 1:1 rate from a pre-funded pool, so tests can assert
///      receiver share balances without a forked vault. The function signature for DistributorCodeDepositor.deposit
/// matches the real   `DistributorCodeDepositor.deposit` function so the caller's cast to `DistributorCodeDepositor`
/// works properly.
contract MockDCD {

    using SafeTransferLib for ERC20;

    ERC20 public shareToken;

    function setShareToken(ERC20 _shareToken) external {
        shareToken = _shareToken;
    }

    function deposit(
        ERC20 depositAsset,
        uint256 depositAmount,
        uint256, /* minimumMint */
        address to,
        bytes calldata, /* distributorCode */
        Attestation calldata /* attestation */
    )
        external
        returns (uint256 shares)
    {
        depositAsset.safeTransferFrom(msg.sender, address(this), depositAmount);
        shares = depositAmount;
        shareToken.safeTransfer(to, shares);
    }

}

abstract contract BaseDirectTransferTest is Test {

    // DTA Events
    event Forwarded(address indexed from, address indexed to, uint256 amount, uint256 shares);
    event Refunded(address indexed from, address indexed to, uint256 amount);
    event Recovered(address indexed from, address indexed to, uint256 amount);

    /// FactoryBeacon events
    event BeaconProxyDeployed(
        address indexed directTransferAddress, address indexed user, bytes32 organizationId, address inputToken
    );
    event Upgraded(address indexed implementation);

    // ---------- actors ----------

    address owner = makeAddr("owner");
    address user = makeAddr("user");
    address user2 = makeAddr("user2");
    address recoveryAccount = makeAddr("recoveryAccount");
    address beaconAdmin = makeAddr("beaconAdmin");
    address alice;
    uint256 alicePk;

    // ---------- shared deployed contracts ----------

    MockERC20 token;
    MockERC20 shareToken;
    MockDCD mockDCD;
    DirectTransferAddress impl;
    FactoryBeacon beacon;

    // ---------- default salt inputs ----------

    address boringVault = makeAddr("boringVault");
    /// @dev Example UUID encoded as bytes32
    bytes32 constant ORG_ID = bytes32(0x00000000000000000000000000000000700768aec71d42cc9ff913b777d6d379);

    /// @dev Generous pre-funded share pool the MockDCD draws from on deposit.
    uint256 constant MOCK_DCD_SHARE_POOL = type(uint128).max;

    function setUp() public virtual {
        (alice, alicePk) = makeAddrAndKey("alice");

        token = new MockERC20();
        token.initialize("Test Token", "TTK", 6);

        shareToken = new MockERC20();
        shareToken.initialize("Share Token", "SHR", 6);

        mockDCD = new MockDCD();
        mockDCD.setShareToken(ERC20(address(shareToken)));
        // Pre-fund the mock DCD so it can settle share transfers on deposit().
        deal(address(shareToken), address(mockDCD), MOCK_DCD_SHARE_POOL);

        impl = new DirectTransferAddress(
            DistributorCodeDepositor(address(mockDCD)), owner, recoveryAccount, ERC20(address(token))
        );
        beacon = new FactoryBeacon(address(impl), beaconAdmin);
    }

    // ---------- helpers ----------

    /// @dev Deploy a DTA beacon proxy directly (no CreateX) and initialize it against the shared impl.
    ///      FactoryBeacon.deployBeaconProxy is exercised separately in FactoryBeacon.t.sol, which needs
    ///      a forked or etched CreateX at 0xba5Ed0…. For DTA-only unit tests we instantiate the proxy separately.
    function _deployDTA(address userDestinationAddress) internal returns (DirectTransferAddress dta) {
        bytes memory initData =
            abi.encodeWithSelector(DirectTransferAddress.initialize.selector, userDestinationAddress);
        SimpleBeaconProxy proxy = new SimpleBeaconProxy(address(beacon), initData);
        dta = DirectTransferAddress(address(proxy));
    }

    function _expectForwardedEvent(address dta, address to, uint256 amount, uint256 shares) internal {
        vm.expectEmit(true, true, true, true, dta);
        emit Forwarded(dta, to, amount, shares);
    }

    function _expectRefundedEvent(address dta, address to, uint256 amount) internal {
        vm.expectEmit(true, true, true, true, dta);
        emit Refunded(dta, to, amount);
    }

    function _expectRecoveredEvent(address dta, address to, uint256 amount) internal {
        vm.expectEmit(true, true, true, true, dta);
        emit Recovered(dta, to, amount);
    }

    function _expectBeaconProxyDeployedEvent(
        address dta,
        address userDestinationAddress,
        bytes32 organizationId,
        address inputToken
    )
        internal
    {
        vm.expectEmit(true, true, true, true, address(beacon));
        emit BeaconProxyDeployed(dta, userDestinationAddress, organizationId, inputToken);
    }

}
