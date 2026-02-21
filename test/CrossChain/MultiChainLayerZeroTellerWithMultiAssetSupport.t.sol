// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { MultiChainBaseTest, MultiChainTellerBase, ERC20, BridgeData } from "./MultiChainBase.t.sol";
import {
    MultiChainLayerZeroTellerWithMultiAssetSupport
} from "src/base/Roles/CrossChain/MultiChainLayerZeroTellerWithMultiAssetSupport.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { TestHelperOz5 } from "./@layerzerolabs-custom/test-evm-foundry-custom/TestHelperOz5.sol";

import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import { OAppAuthCore } from "src/base/Roles/CrossChain/OAppAuth/OAppAuthCore.sol";

import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";
import { console } from "forge-std/Test.sol";

contract MultiChainLayerZeroTellerWithMultiAssetSupportTest is MultiChainBaseTest, TestHelperOz5 {

    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    function setUp() public virtual override(MultiChainBaseTest, TestHelperOz5) {
        MultiChainBaseTest.setUp();
        TestHelperOz5.setUp();
    }

    function testBridgingShares(uint256 sharesToBridge) external virtual {
        MultiChainLayerZeroTellerWithMultiAssetSupport sourceTeller =
            MultiChainLayerZeroTellerWithMultiAssetSupport(sourceTellerAddr);
        MultiChainLayerZeroTellerWithMultiAssetSupport destinationTeller =
            MultiChainLayerZeroTellerWithMultiAssetSupport(destinationTellerAddr);

        sharesToBridge = uint96(bound(sharesToBridge, 1, 1000e18));
        uint256 startingShareBalance = boringVault.balanceOf(address(this));
        // Setup chains on bridge.
        sourceTeller.addChain(DESTINATION_SELECTOR, true, true, address(destinationTeller), CHAIN_MESSAGE_GAS_LIMIT, 0);
        destinationTeller.addChain(SOURCE_SELECTOR, true, true, sourceTellerAddr, CHAIN_MESSAGE_GAS_LIMIT, 0);

        // Bridge shares.
        address to = vm.addr(1);

        BridgeData memory data = BridgeData({
            chainSelector: DESTINATION_SELECTOR,
            destinationChainReceiver: to,
            bridgeFeeToken: ERC20(NATIVE),
            messageGas: 80_000,
            data: ""
        });

        uint256 quote = sourceTeller.previewFee(sharesToBridge, data);
        bytes32 id = sourceTeller.bridge{ value: quote }(sharesToBridge, data);

        verifyPackets(uint32(DESTINATION_SELECTOR), addressToBytes32(destinationTellerAddr));

        assertEq(
            boringVault.balanceOf(address(this)), startingShareBalance - sharesToBridge, "Should have burned shares."
        );

        assertEq(boringVault.balanceOf(to), sharesToBridge, "to address should have shares");
    }

    function testDepositAndBridge(uint256 amount) external virtual {
        MultiChainLayerZeroTellerWithMultiAssetSupport sourceTeller =
            MultiChainLayerZeroTellerWithMultiAssetSupport(sourceTellerAddr);
        MultiChainLayerZeroTellerWithMultiAssetSupport destinationTeller =
            MultiChainLayerZeroTellerWithMultiAssetSupport(destinationTellerAddr);

        sourceTeller.addChain(DESTINATION_SELECTOR, true, true, destinationTellerAddr, CHAIN_MESSAGE_GAS_LIMIT, 0);
        destinationTeller.addChain(SOURCE_SELECTOR, true, true, sourceTellerAddr, CHAIN_MESSAGE_GAS_LIMIT, 0);

        amount = bound(amount, 0.0001e18, 10_000e18);
        // make a user and give them WETH
        address user = makeAddr("A user");
        address userChain2 = makeAddr("A user on chain 2");
        deal(address(WETH), user, amount);

        // approve teller to spend WETH
        vm.startPrank(user);
        vm.deal(user, 10e18);
        WETH.approve(address(boringVault), amount);

        // perform depositAndBridge
        BridgeData memory data = BridgeData({
            chainSelector: DESTINATION_SELECTOR,
            destinationChainReceiver: userChain2,
            bridgeFeeToken: ERC20(NATIVE),
            messageGas: 80_000,
            data: ""
        });

        uint256 ONE_SHARE = 10 ** boringVault.decimals();

        // so you don't really need to know exact shares in reality
        // just need to pass in a number roughly the same size to get quote
        // I still get the real number here for testing
        uint256 shares = amount.mulDivDown(ONE_SHARE, accountant.getRateInQuoteSafe(WETH));
        uint256 quote = sourceTeller.previewFee(shares, data);
        uint256 wethBefore = WETH.balanceOf(address(boringVault));

        sourceTeller.depositAndBridge{ value: quote }(WETH, amount, shares, data);
        verifyPackets(uint32(DESTINATION_SELECTOR), addressToBytes32(destinationTellerAddr));

        assertEq(boringVault.balanceOf(user), 0, "Should have burned shares.");

        assertEq(boringVault.balanceOf(userChain2), shares);

        assertEq(WETH.balanceOf(address(boringVault)), wethBefore + shares);
        vm.stopPrank();
    }

    function testReverts() public virtual override {
        MultiChainLayerZeroTellerWithMultiAssetSupport sourceTeller =
            MultiChainLayerZeroTellerWithMultiAssetSupport(sourceTellerAddr);
        MultiChainLayerZeroTellerWithMultiAssetSupport destinationTeller =
            MultiChainLayerZeroTellerWithMultiAssetSupport(destinationTellerAddr);

        super.testReverts();

        // if the token is not NATIVE, should revert
        address NOT_NATIVE = 0xfAbA6f8e4a5E8Ab82F62fe7C39859FA577269BE3;
        BridgeData memory data = BridgeData(
            DESTINATION_SELECTOR, address(this), ERC20(NOT_NATIVE), 80_000, abi.encode(DESTINATION_SELECTOR)
        );
        sourceTeller.addChain(DESTINATION_SELECTOR, true, true, destinationTellerAddr, CHAIN_MESSAGE_GAS_LIMIT, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                MultiChainLayerZeroTellerWithMultiAssetSupport.MultiChainLayerZeroTellerWithMultiAssetSupport_InvalidToken
                    .selector
            )
        );
        sourceTeller.bridge(1e18, data);

        // Call now succeeds.
        data = BridgeData(DESTINATION_SELECTOR, address(this), ERC20(NATIVE), 80_000, abi.encode(DESTINATION_SELECTOR));
        uint256 quote = sourceTeller.previewFee(1e18, data);

        sourceTeller.bridge{ value: quote }(1e18, data);
    }

    function _deploySourceAndDestinationTeller() internal virtual override {
        MultiChainLayerZeroTellerWithMultiAssetSupport sourceTeller =
            MultiChainLayerZeroTellerWithMultiAssetSupport(sourceTellerAddr);
        MultiChainLayerZeroTellerWithMultiAssetSupport destinationTeller =
            MultiChainLayerZeroTellerWithMultiAssetSupport(destinationTellerAddr);

        setUpEndpoints(2, LibraryType.UltraLightNode);

        sourceTellerAddr = _deployOApp(
            type(MultiChainLayerZeroTellerWithMultiAssetSupport).creationCode,
            abi.encode(address(this), address(boringVault), address(accountant), endpoints[uint32(SOURCE_SELECTOR)])
        );

        destinationTellerAddr = _deployOApp(
            type(MultiChainLayerZeroTellerWithMultiAssetSupport).creationCode,
            abi.encode(
                address(this), address(boringVault), address(accountant), endpoints[uint32(DESTINATION_SELECTOR)]
            )
        );

        // config and wire the oapps
        address[] memory oapps = new address[](2);
        oapps[0] = sourceTellerAddr;
        oapps[1] = destinationTellerAddr;
        this.wireOApps(oapps);

        bytes32 peer1 = OAppAuthCore(sourceTellerAddr).peers(uint32(DESTINATION_SELECTOR));
        bytes32 peer2 = OAppAuthCore(destinationTellerAddr).peers(uint32(SOURCE_SELECTOR));
    }

}
