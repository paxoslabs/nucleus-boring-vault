// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import {
    MultiChainTellerBase_MessagesNotAllowedFrom,
    MultiChainTellerBase_MessagesNotAllowedFromSender,
    MultiChainTellerBase_DestinationChainReceiverIsZeroAddress
} from "src/base/Roles/CrossChain/MultiChainTellerBase.sol";

import { MultiChainBaseTest, MultiChainTellerBase, ERC20, BridgeData } from "./MultiChainBase.t.sol";
import {
    MultiChainHyperlaneTellerWithMultiAssetSupport
} from "src/base/Roles/CrossChain/MultiChainHyperlaneTellerWithMultiAssetSupport.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { IMailbox } from "src/interfaces/hyperlane/IMailbox.sol";

import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";

import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";

// Is only testing the function calls created from a single source chain. These
// tests do not guarantee correct behavior on the destination chain.
contract MultiChainHyperlaneTellerWithMultiAssetSupportTest is MultiChainBaseTest {

    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    IMailbox constant ETHEREUM_MAILBOX = IMailbox(0xc005dc82818d67AF737725bD4bf75435d065D239);

    uint32 constant SOURCE_DOMAIN = 1; // Ethereum
    uint32 constant DESTINATION_DOMAIN = 42_161; // Arbitrum for Testing

    MultiChainHyperlaneTellerWithMultiAssetSupport sourceTeller;
    MultiChainHyperlaneTellerWithMultiAssetSupport destinationTeller;

    function setUp() public virtual override(MultiChainBaseTest) {
        MultiChainBaseTest.setUp();

        sourceTeller = MultiChainHyperlaneTellerWithMultiAssetSupport(sourceTellerAddr);
        destinationTeller = MultiChainHyperlaneTellerWithMultiAssetSupport(destinationTellerAddr);
    }

    function testBridgingShares(uint256 sharesToBridge) external virtual {
        sharesToBridge = uint96(bound(sharesToBridge, 1, 1000e18));
        uint256 startingShareBalance = boringVault.balanceOf(address(this));

        // Setup chains on bridge.
        sourceTeller.addChain(DESTINATION_DOMAIN, true, true, destinationTellerAddr, CHAIN_MESSAGE_GAS_LIMIT, 0);

        destinationTeller.addChain(SOURCE_DOMAIN, true, true, sourceTellerAddr, CHAIN_MESSAGE_GAS_LIMIT, 0);

        // Bridge shares.
        address to = vm.addr(1);

        BridgeData memory data = BridgeData({
            chainSelector: DESTINATION_DOMAIN,
            destinationChainReceiver: to,
            bridgeFeeToken: ERC20(NATIVE),
            messageGas: 80_000,
            data: ""
        });

        uint256 quote = _getTypedTeller(sourceTellerAddr).previewFee(sharesToBridge, data);
        assertTrue(quote != 0, "Quote should not be 0");

        bytes32 id = sourceTeller.bridge{ value: quote }(sharesToBridge, data);

        assertEq(
            boringVault.balanceOf(address(this)),
            startingShareBalance - sharesToBridge,
            "Should have burned shares on source chain"
        );
    }

    function testDepositAndBridge(uint256 amount) external virtual {
        sourceTeller.addChain(DESTINATION_DOMAIN, true, true, destinationTellerAddr, CHAIN_MESSAGE_GAS_LIMIT, 0);
        destinationTeller.addChain(SOURCE_DOMAIN, true, true, sourceTellerAddr, CHAIN_MESSAGE_GAS_LIMIT, 0);

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
            chainSelector: DESTINATION_DOMAIN,
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

        assertEq(boringVault.balanceOf(user), 0, "Should have burned shares.");

        assertEq(WETH.balanceOf(address(boringVault)), wethBefore + shares);
        vm.stopPrank();
    }

    function testReverts() public virtual override {
        super.testReverts();

        // if the token is not NATIVE, should revert
        address NOT_NATIVE = 0xfAbA6f8e4a5E8Ab82F62fe7C39859FA577269BE3;
        BridgeData memory data =
            BridgeData(DESTINATION_DOMAIN, address(this), ERC20(NOT_NATIVE), 80_000, abi.encode(DESTINATION_DOMAIN));
        sourceTeller.addChain(DESTINATION_DOMAIN, true, true, destinationTellerAddr, CHAIN_MESSAGE_GAS_LIMIT, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                MultiChainHyperlaneTellerWithMultiAssetSupport.MultiChainHyperlaneTellerWithMultiAssetSupport_InvalidBridgeFeeToken
                    .selector
            )
        );
        sourceTeller.bridge(1e18, data);

        // Call now succeeds.
        data = BridgeData(DESTINATION_DOMAIN, address(this), ERC20(NATIVE), 80_000, abi.encode(DESTINATION_DOMAIN));
        uint256 quote = sourceTeller.previewFee(1e18, data);

        sourceTeller.bridge{ value: quote }(1e18, data);
    }

    function testRevertsOnHandle() public {
        bytes memory payload = "";

        // If the caller on `handle` is not mailbox, should revert.
        vm.expectRevert(
            abi.encodeWithSelector(
                MultiChainHyperlaneTellerWithMultiAssetSupport.MultiChainHyperlaneTellerWithMultiAssetSupport_CallerMustBeMailbox
                    .selector,
                address(this)
            )
        );
        destinationTeller.handle(
            SOURCE_DOMAIN,
            _addressToBytes32(sourceTellerAddr), // correct sender
            payload
        );

        // If the `sender` param is not the teller, should revert.
        vm.startPrank(address(ETHEREUM_MAILBOX));
        vm.expectRevert(
            abi.encodeWithSelector(
                MultiChainTellerBase_MessagesNotAllowedFromSender.selector, uint256(SOURCE_DOMAIN), address(this)
            )
        );
        destinationTeller.handle(
            SOURCE_DOMAIN,
            _addressToBytes32(address(this)), // wrong sender
            payload
        );
        vm.stopPrank();

        // Set `SOURCE_DOMAIN`'s `allowMessagesFrom` to be false
        vm.prank(destinationTeller.owner());
        destinationTeller.addChain(SOURCE_DOMAIN, false, true, sourceTellerAddr, CHAIN_MESSAGE_GAS_LIMIT, 0);

        vm.startPrank(address(ETHEREUM_MAILBOX));
        vm.expectRevert(
            abi.encodeWithSelector(MultiChainTellerBase_MessagesNotAllowedFrom.selector, uint256(SOURCE_DOMAIN))
        );
        destinationTeller.handle(
            SOURCE_DOMAIN, // now disallowed
            _addressToBytes32(sourceTellerAddr), // correct sender
            payload
        );
        vm.stopPrank();
    }

    function testRevertOnInvalidBytes32Address() public {
        bytes32 invalidSender = bytes32(uint256(type(uint168).max));

        vm.startPrank(address(ETHEREUM_MAILBOX));
        vm.expectRevert(
            abi.encodeWithSelector(
                MultiChainHyperlaneTellerWithMultiAssetSupport.MultiChainHyperlaneTellerWithMultiAssetSupport_InvalidBytes32Address
                    .selector,
                invalidSender
            )
        );
        destinationTeller.handle(SOURCE_DOMAIN, invalidSender, "");
        vm.stopPrank();
    }

    /**
     * Trying to bridge token to the zero address should fail as it will simply
     * burn the token. We don't want to allow this in a bridging context.
     */
    function testRevertOnInvalidDestinationReceiver() public {
        deal(address(WETH), address(this), 1e18);

        sourceTeller.addChain(DESTINATION_DOMAIN, true, true, destinationTellerAddr, CHAIN_MESSAGE_GAS_LIMIT, 0);

        WETH.approve(address(boringVault), 1e18);

        vm.expectRevert(abi.encodeWithSelector(MultiChainTellerBase_DestinationChainReceiverIsZeroAddress.selector));
        sourceTeller.depositAndBridge(
            WETH, 1e18, 1e18, BridgeData(DESTINATION_DOMAIN, address(0), ERC20(NATIVE), 80_000, "")
        );
    }

    function _getTypedTeller(address addr) internal returns (MultiChainHyperlaneTellerWithMultiAssetSupport) {
        return MultiChainHyperlaneTellerWithMultiAssetSupport(addr);
    }

    function _deploySourceAndDestinationTeller() internal virtual override {
        sourceTellerAddr = address(
            new MultiChainHyperlaneTellerWithMultiAssetSupport(
                address(this), address(boringVault), address(accountant), ETHEREUM_MAILBOX
            )
        );

        destinationTellerAddr = address(
            new MultiChainHyperlaneTellerWithMultiAssetSupport(
                address(this), address(boringVault), address(accountant), ETHEREUM_MAILBOX
            )
        );
    }

    function _addressToBytes32(address _address) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_address)));
    }

}
