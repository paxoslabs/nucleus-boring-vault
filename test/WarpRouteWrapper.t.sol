// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.4;

import { BoringVault } from "src/base/BoringVault.sol";
import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";
import { VaultArchitectureSharedSetup, IPredicateRegistry } from "test/shared-setup/VaultArchitectureSharedSetup.t.sol";
import { WarpRouteWrapper, WarpRoute } from "src/helper/WarpRouteWrapper.sol";
import { Statement, Attestation } from "@predicate/interfaces/IPredicateRegistry.sol";

bytes32 constant MAGIC_VALUE_TRANFER_REMOTE = keccak256("MAGIC_VALUE_TRANFER_REMOTE");

// Minimal mock implementing the WarpRoute interface.
//
// The WarpRouteWrapper is designed to work with a Hyperlane warp route for the
// specific BoringVault share token that gets deployed. Since that deployment is
// environment-specific we use a mock here that faithfully emits the same
// SentTransferRemote event defined in Hyperlane's TokenRouter:
// https://github.com/hyperlane-xyz/hyperlane-monorepo/blob/main/solidity/contracts/token/libs/TokenRouter.sol
contract MockWarpRoute {

    event SentTransferRemote(uint32 indexed destination, bytes32 indexed recipient, uint256 amountOrId);

    function transferRemote(
        uint32 _destination,
        bytes32 _recipient,
        uint256 _amountOrId
    )
        external
        payable
        returns (bytes32 messageId)
    {
        emit SentTransferRemote(_destination, _recipient, _amountOrId);
        // Return a dummy value since nothing is used in this test with the return messageId. Hyperlane has this value
        // returned through a series of function calls resulting in a hash performed in the Mailbox of a collection of
        // bytes thrown together with a library. We instead return this "magic number" as a way to still test that the
        // implementation correctly returns what Hyperlane provides.
        return MAGIC_VALUE_TRANFER_REMOTE;
    }

}

uint256 constant FORK_BLOCK_NUMBER = 24_528_436;

contract WarpRouteWrapperTest is VaultArchitectureSharedSetup {

    using FixedPointMathLib for uint256;

    // Mirrors MockWarpRoute.SentTransferRemote — declared here so vm.expectEmit can
    // reference it without triggering the Solidity 0.8.21 NatSpec bug that occurs
    // when using the `ContractName.EventName` emit syntax across compilation units.
    event SentTransferRemote(uint32 indexed destination, bytes32 indexed recipient, uint256 amountOrId);

    WarpRouteWrapper public warpRouteWrapper;
    MockWarpRoute public mockWarpRoute;

    address public owner = makeAddr("owner");

    // Arbitrum chain domain ID per the Hyperlane registry:
    uint32 public constant DESTINATION_DOMAIN = 42_161;

    function setUp() external {
        _startFork("MAINNET_RPC_URL", FORK_BLOCK_NUMBER);

        (attesterOne, attesterOnePk) = makeAddrAndKey("attesterOne");
        policyOne = "policyOne";

        predicateRegistry = IPredicateRegistry(0xe15a8Ca5BD8464283818088c1760d8f23B6a216E);
        vm.prank(predicateRegistry.owner());
        predicateRegistry.registerAttester(attesterOne);

        address[] memory assets = new address[](1);
        assets[0] = address(USDC);

        (boringVault, teller, accountant) =
            _deployVaultArchitecture("Stablecoin Earn", "earnUSDC", 6, address(USDC), assets, 1e6);

        mockWarpRoute = new MockWarpRoute();

        warpRouteWrapper = new WarpRouteWrapper(
            teller, WarpRoute(address(mockWarpRoute)), DESTINATION_DOMAIN, address(predicateRegistry), policyOne, owner
        );
    }

    // Verifies that depositAndBridge deposits the asset into the vault and
    // calls transferRemote on the warp route, producing a SentTransferRemote event
    // with the correct destination, recipient, and share amount.
    // The test should pass when the kyt is enabled for this asset
    function test_depositAndBridge_emitsSentTransferRemote_predicateEnabled() external {
        vm.prank(owner);
        warpRouteWrapper.updateKytStatus(ERC20(address(USDC)), true);

        uint256 depositAmount = 100e6;
        uint256 minimumMint = 100e6;
        bytes32 recipient = bytes32(uint256(uint160(address(this))));

        uint256 quoteRate = accountant.getRateInQuoteSafe(ERC20(address(USDC)));
        uint256 expectedShares = depositAmount.mulDivDown(ONE_SHARE, quoteRate);

        deal(address(USDC), address(this), depositAmount);
        USDC.approve(address(warpRouteWrapper), depositAmount);

        Attestation memory attestation = _createAttestationForDepositAndBridge(
            "test-uuid", address(this), address(warpRouteWrapper), address(USDC), depositAmount, minimumMint
        );

        vm.expectEmit(address(mockWarpRoute));
        emit SentTransferRemote(DESTINATION_DOMAIN, recipient, expectedShares);

        (uint256 sharesMinted, bytes32 messageId) =
            warpRouteWrapper.depositAndBridge(ERC20(address(USDC)), depositAmount, minimumMint, recipient, attestation);

        assertEq(sharesMinted, expectedShares, "shares minted must equal expected shares");
        assertTrue(messageId == MAGIC_VALUE_TRANFER_REMOTE, "messageId must be the magic value");
        assertEq(USDC.balanceOf(address(boringVault)), depositAmount, "boring vault must hold the deposited USDC");
    }

    // The same test should work just with a blank attestation
    function test_depositAndBridge_emitsSentTransferRemote_predicateDisabled() external {
        uint256 depositAmount = 100e6;
        uint256 minimumMint = 100e6;
        bytes32 recipient = bytes32(uint256(uint160(address(this))));

        uint256 quoteRate = accountant.getRateInQuoteSafe(ERC20(address(USDC)));
        uint256 expectedShares = depositAmount.mulDivDown(ONE_SHARE, quoteRate);

        deal(address(USDC), address(this), depositAmount);
        USDC.approve(address(warpRouteWrapper), depositAmount);

        Attestation memory attestation;

        vm.expectEmit(address(mockWarpRoute));
        emit SentTransferRemote(DESTINATION_DOMAIN, recipient, expectedShares);

        (uint256 sharesMinted, bytes32 messageId) =
            warpRouteWrapper.depositAndBridge(ERC20(address(USDC)), depositAmount, minimumMint, recipient, attestation);

        assertEq(sharesMinted, expectedShares, "shares minted must equal expected shares");
        assertTrue(messageId == MAGIC_VALUE_TRANFER_REMOTE, "messageId must be the magic value");
        assertEq(USDC.balanceOf(address(boringVault)), depositAmount, "boring vault must hold the deposited USDC");
    }

    // ---------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------

    // Creates an Attestation matching the encodedSigAndArgs that WarpRouteWrapper
    // passes to _authorizeTransaction, which encodes the `deposit` selector together
    // with (depositAsset, depositAmount, minimumMint).
    function _createAttestationForDepositAndBridge(
        string memory uuid,
        address msgSender,
        address target,
        address depositAsset,
        uint256 depositAmount,
        uint256 minimumMint
    )
        internal
        view
        returns (Attestation memory)
    {
        bytes memory encodedSigAndArgs =
            abi.encodeWithSignature("deposit(address,uint256,uint256)", depositAsset, depositAmount, minimumMint);
        return _createAttestation(uuid, msgSender, target, 0, encodedSigAndArgs);
    }

}
