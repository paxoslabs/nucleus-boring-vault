// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Test, stdStorage, StdStorage, stdError, console } from "@forge-std/Test.sol";
import { MockERC20 } from "@forge-std/mocks/MockERC20.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { Attestation } from "@predicate/interfaces/IPredicateRegistry.sol";
import { DistributorCodeDepositor } from "src/helper/DistributorCodeDepositor.sol";
import { SmartDepositAddress } from "src/smart-deposit/SmartDepositAddress.sol";
import { SmartDepositFactoryBeacon } from "src/smart-deposit/SmartDepositFactoryBeacon.sol";
import { BeaconProxy } from "@openzeppelin-v5.0.1/contracts/proxy/beacon/BeaconProxy.sol";

/// @dev Pulls `depositAsset` from msg.sender (matching the real DCD's safeTransferFrom on deposit)
///      and sends `shareToken` to `to` at a 1:1 rate from a pre-funded pool, so tests can assert
///      userDestinationAddress share balances without a forked vault. The function signature for
/// DistributorCodeDepositor.deposit
/// matches the real   `DistributorCodeDepositor.deposit` function so the caller's cast to `DistributorCodeDepositor`
/// works properly.
contract MockDCD {

    using SafeTransferLib for ERC20;

    address public immutable boringVault;
    ERC20 public shareToken;

    constructor(address _boringVault) {
        boringVault = _boringVault;
    }

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

abstract contract BaseSmartDepositTest is Test {

    // SDA Events
    event Initialized(address indexed userDestinationAddress, address indexed token);
    event Forwarded(address indexed to, uint256 amount, uint256 shares);
    event Refunded(address indexed token, address indexed to, uint256 amount);
    event Recovered(address indexed token, address indexed to, uint256 amount);

    /// SmartDepositFactoryBeacon events
    event BeaconProxyDeployed(
        address indexed userDestinationAddress,
        bytes32 indexed organizationId,
        address indexed inputToken,
        address boringVault,
        address smartDepositAddress
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
    SmartDepositAddress impl;
    SmartDepositFactoryBeacon beacon;

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

        mockDCD = new MockDCD(boringVault);
        mockDCD.setShareToken(ERC20(address(shareToken)));
        // Pre-fund the mock DCD so it can settle share transfers on deposit().
        deal(address(shareToken), address(mockDCD), MOCK_DCD_SHARE_POOL);

        impl = new SmartDepositAddress(DistributorCodeDepositor(address(mockDCD)), owner, recoveryAccount);
        beacon = new SmartDepositFactoryBeacon(address(impl), beaconAdmin);
    }

    // ---------- helpers ----------

    /// @dev Deploy a SDA beacon proxy directly (no CreateX) and initialize it against the shared impl.
    ///      SmartDepositFactoryBeacon.deployBeaconProxy is exercised separately in SmartDepositFactoryBeacon.t.sol,
    /// which needs a forked or etched CreateX at 0x1077..391f. For SDA-only unit tests we instantiate the proxy
    /// separately.
    function _deploySDA(address userDestinationAddress) internal returns (SmartDepositAddress sda) {
        bytes memory initData = abi.encodeWithSelector(
            SmartDepositAddress.initialize.selector, userDestinationAddress, ERC20(address(token))
        );
        BeaconProxy proxy = new BeaconProxy(address(beacon), initData);
        sda = SmartDepositAddress(address(proxy));
    }

    function _expectForwardedEvent(address sda, address to, uint256 amount, uint256 shares) internal {
        vm.expectEmit(true, true, true, true, sda);
        emit Forwarded(to, amount, shares);
    }

    function _expectRefundedEvent(address sda, address tokenAddress, address to, uint256 amount) internal {
        vm.expectEmit(true, true, true, true, sda);
        emit Refunded(tokenAddress, to, amount);
    }

    function _expectRecoveredEvent(address sda, address tokenAddress, address to, uint256 amount) internal {
        vm.expectEmit(true, true, true, true, sda);
        emit Recovered(tokenAddress, to, amount);
    }

    function _expectBeaconProxyDeployedEvent(
        address userDestinationAddress,
        bytes32 organizationId,
        address inputToken,
        address _boringVault,
        address sda
    )
        internal
    {
        vm.expectEmit(true, true, true, true, address(beacon));
        emit BeaconProxyDeployed(userDestinationAddress, organizationId, inputToken, _boringVault, sda);
    }

}
