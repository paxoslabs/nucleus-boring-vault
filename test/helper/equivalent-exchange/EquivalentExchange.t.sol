// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { EquivalentExchange } from "src/helper/equivalent-exchange/EquivalentExchange.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { Authority } from "@solmate/auth/Auth.sol";
import { Test } from "@forge-std/Test.sol";

contract RevertingTarget {

    error TargetReverted();

    function alwaysRevert() external pure {
        revert TargetReverted();
    }

}

contract tERC20 is ERC20 {

    constructor(uint8 _decimals) ERC20("test token", "TT", _decimals) { }

}

contract EquivalentExchangeTest is Test {

    EquivalentExchange internal exchange;

    address internal owner = makeAddr("owner");
    address internal unauthorized = makeAddr("unauthorized");

    function setUp() external {
        exchange = new EquivalentExchange(owner, Authority(address(0)));
    }

    function test_Execute_RevertsIfUnauthorized() external {
        ERC20[] memory tokens = new ERC20[](0);
        uint256[] memory amountsIn = new uint256[](0);
        address[] memory targets = new address[](0);
        bytes[] memory targetData = new bytes[](0);

        vm.prank(unauthorized);
        vm.expectRevert("UNAUTHORIZED");
        exchange.execute(tokens, amountsIn, targets, targetData, address(0), ERC20(address(0)));
    }

    function test_Execute_RevertsIfTokensAndAmountsLengthMismatch() external {
        ERC20[] memory tokens = new ERC20[](1);
        uint256[] memory amountsIn = new uint256[](0);
        address[] memory targets = new address[](0);
        bytes[] memory targetData = new bytes[](0);

        vm.prank(owner);
        vm.expectRevert(EquivalentExchange.LengthMismatch.selector);
        exchange.execute(tokens, amountsIn, targets, targetData, address(0), ERC20(address(0)));
    }

    function test_Execute_RevertsIfTargetsAndTargetDataLengthMismatch() external {
        ERC20[] memory tokens = new ERC20[](0);
        uint256[] memory amountsIn = new uint256[](0);
        address[] memory targets = new address[](1);
        bytes[] memory targetData = new bytes[](0);

        vm.prank(owner);
        vm.expectRevert(EquivalentExchange.LengthMismatch.selector);
        exchange.execute(tokens, amountsIn, targets, targetData, address(0), ERC20(address(0)));
    }

    function test_Execute_BubblesUpTargetRevert() external {
        RevertingTarget target = new RevertingTarget();

        ERC20[] memory tokens = new ERC20[](0);
        uint256[] memory amountsIn = new uint256[](0);
        address[] memory targets = new address[](1);
        bytes[] memory targetData = new bytes[](1);

        targets[0] = address(target);
        targetData[0] = abi.encodeWithSelector(RevertingTarget.alwaysRevert.selector);

        vm.prank(owner);
        vm.expectRevert(RevertingTarget.TargetReverted.selector);
        exchange.execute(tokens, amountsIn, targets, targetData, address(0), ERC20(address(0)));
    }

    function test_Execute_SelfCallReverts() external {
        ERC20[] memory tokens = new ERC20[](0);
        uint256[] memory amountsIn = new uint256[](0);
        address[] memory targets = new address[](1);
        bytes[] memory targetData = new bytes[](1);

        targets[0] = address(exchange);
        targetData[0] = abi.encodeWithSelector(EquivalentExchange.execute.selector, tokens, amountsIn, targets, targetData, address(0), ERC20(address(0)));

        vm.prank(owner);
        vm.expectRevert("UNAUTHORIZED");
        exchange.execute(tokens, amountsIn, targets, targetData, address(0), ERC20(address(0)));
    }

    function test_Execute_RevertsIfDanglingApproval() external {
        tERC20 token = new tERC20(18);
        deal(address(token), owner, 2e18);

        ERC20[] memory tokens = new ERC20[](1);
        uint256[] memory amountsIn = new uint256[](1);
        address[] memory targets = new address[](0);
        bytes[] memory targetData = new bytes[](0);

        tokens[0] = ERC20(address(token));
        amountsIn[0] = 1e18;

        vm.startPrank(owner);
        token.approve(address(exchange), 2e18);

        vm.expectRevert(abi.encodeWithSelector(EquivalentExchange.DanglingApproval.selector, address(token)));
        exchange.execute(tokens, amountsIn, targets, targetData, address(0), ERC20(address(0)));
        vm.stopPrank();
    }

    function test_Execute_RevertsIfSubsidyProviderHasInsufficientBalance() external {
        address subsidyProvider = makeAddr("subsidyProvider");
        address recipient = makeAddr("recipient");
        tERC20 token = new tERC20(18);
        deal(address(token), owner, 1e18);

        ERC20[] memory tokens = new ERC20[](1);
        uint256[] memory amountsIn = new uint256[](1);
        address[] memory targets = new address[](1);
        bytes[] memory targetData = new bytes[](1);

        tokens[0] = ERC20(address(token));
        amountsIn[0] = 1e18;
        targets[0] = address(token);
        targetData[0] = abi.encodeWithSelector(ERC20.transfer.selector, recipient, 1e18);

        vm.prank(subsidyProvider);
        token.approve(address(exchange), 1e18);

        vm.startPrank(owner);
        token.approve(address(exchange), 1e18);

        vm.expectRevert("TRANSFER_FROM_FAILED");
        exchange.execute(tokens, amountsIn, targets, targetData, subsidyProvider, ERC20(address(token)));
        vm.stopPrank();
    }

    function test_Execute_RevertsIfSubsidyProviderHasInsufficientAllowance() external {
        address subsidyProvider = makeAddr("subsidyProvider");
        address recipient = makeAddr("recipient");
        tERC20 token = new tERC20(18);
        deal(address(token), owner, 1e18);
        deal(address(token), subsidyProvider, 1e18);

        ERC20[] memory tokens = new ERC20[](1);
        uint256[] memory amountsIn = new uint256[](1);
        address[] memory targets = new address[](1);
        bytes[] memory targetData = new bytes[](1);

        tokens[0] = ERC20(address(token));
        amountsIn[0] = 1e18;
        targets[0] = address(token);
        targetData[0] = abi.encodeWithSelector(ERC20.transfer.selector, recipient, 1e18);

        vm.startPrank(owner);
        token.approve(address(exchange), 1e18);

        vm.expectRevert("TRANSFER_FROM_FAILED");
        exchange.execute(tokens, amountsIn, targets, targetData, subsidyProvider, ERC20(address(token)));
        vm.stopPrank();
    }

    function test_Execute_SweepsEntireBalanceOfMultipleTokensWithDifferentDecimals() external {
        tERC20 tokenA = new tERC20(6);
        tERC20 tokenB = new tERC20(18);

        deal(address(tokenA), owner, 1e6);
        deal(address(tokenB), owner, 1e18);
        deal(address(tokenB), address(exchange), 0.5e18);

        ERC20[] memory tokens = new ERC20[](2);
        uint256[] memory amountsIn = new uint256[](2);
        address[] memory targets = new address[](0);
        bytes[] memory targetData = new bytes[](0);

        tokens[0] = ERC20(address(tokenA));
        tokens[1] = ERC20(address(tokenB));
        amountsIn[0] = 1e6;
        amountsIn[1] = 1e18;

        vm.startPrank(owner);
        tokenA.approve(address(exchange), 1e6);
        tokenB.approve(address(exchange), 1e18);

        exchange.execute(tokens, amountsIn, targets, targetData, address(0), ERC20(address(0)));
        vm.stopPrank();

        assertEq(tokenA.balanceOf(owner), 1e6, "owner should receive back tokenA");
        assertEq(tokenB.balanceOf(owner), 1.5e18, "owner should receive pulled tokenB plus pre-funded tokenB");
        assertEq(tokenA.balanceOf(address(exchange)), 0, "exchange should have no tokenA");
        assertEq(tokenB.balanceOf(address(exchange)), 0, "exchange should have no tokenB");
    }

    function test_Execute_Invariant_TotalOutLessThanTotalIn() external {
        address recipient = makeAddr("recipient");
        address subsidyProvider = makeAddr("subsidyProvider");
        tERC20 token = new tERC20(18);
        deal(address(token), owner, 1e18);

        ERC20[] memory tokens = new ERC20[](1);
        uint256[] memory amountsIn = new uint256[](1);
        address[] memory targets = new address[](1);
        bytes[] memory targetData = new bytes[](1);

        tokens[0] = ERC20(address(token));
        amountsIn[0] = 1e18;
        targets[0] = address(token);
        targetData[0] = abi.encodeWithSelector(ERC20.transfer.selector, recipient, 0.5e18);

        vm.startPrank(owner);
        token.approve(address(exchange), 1e18);

        // Subsidy provider is valid but has no funds/allowance, so the subsidy pull fails
        // and the invariant cannot be satisfied.
        vm.expectRevert("TRANSFER_FROM_FAILED");
        exchange.execute(tokens, amountsIn, targets, targetData, subsidyProvider, ERC20(address(token)));
        vm.stopPrank();
    }

    function test_Execute_Invariant_TotalOutGreaterThanTotalIn() external {
        tERC20 token = new tERC20(18);
        deal(address(token), owner, 1e18);
        deal(address(token), address(exchange), 0.5e18);

        ERC20[] memory tokens = new ERC20[](1);
        uint256[] memory amountsIn = new uint256[](1);
        address[] memory targets = new address[](0);
        bytes[] memory targetData = new bytes[](0);

        tokens[0] = ERC20(address(token));
        amountsIn[0] = 1e18;

        vm.startPrank(owner);
        token.approve(address(exchange), 1e18);
        exchange.execute(tokens, amountsIn, targets, targetData, address(0), ERC20(address(0)));
        vm.stopPrank();

        assertEq(token.balanceOf(owner), 1.5e18, "owner should receive input plus pre-funded surplus");
        assertEq(token.balanceOf(address(exchange)), 0, "exchange should be empty");
    }

    function test_Execute_Invariant_TotalOutEqualToTotalIn() external {
        tERC20 token = new tERC20(18);
        deal(address(token), owner, 1e18);

        ERC20[] memory tokens = new ERC20[](1);
        uint256[] memory amountsIn = new uint256[](1);
        address[] memory targets = new address[](0);
        bytes[] memory targetData = new bytes[](0);

        tokens[0] = ERC20(address(token));
        amountsIn[0] = 1e18;

        vm.startPrank(owner);
        token.approve(address(exchange), 1e18);
        exchange.execute(tokens, amountsIn, targets, targetData, address(0), ERC20(address(0)));
        vm.stopPrank();

        assertEq(token.balanceOf(owner), 1e18, "owner should receive back exactly what was pulled");
        assertEq(token.balanceOf(address(exchange)), 0, "exchange should be empty");
    }

    function test_Execute_SubsidyProviderPaysOnlyNecessaryAmount() external {
        address recipient = makeAddr("recipient");
        address subsidyProvider = makeAddr("subsidyProvider");
        tERC20 token = new tERC20(18);
        deal(address(token), owner, 1e18);
        deal(address(token), subsidyProvider, 2e18);

        ERC20[] memory tokens = new ERC20[](1);
        uint256[] memory amountsIn = new uint256[](1);
        address[] memory targets = new address[](1);
        bytes[] memory targetData = new bytes[](1);

        tokens[0] = ERC20(address(token));
        amountsIn[0] = 1e18;
        targets[0] = address(token);
        targetData[0] = abi.encodeWithSelector(ERC20.transfer.selector, recipient, 0.5e18);

        vm.prank(subsidyProvider);
        token.approve(address(exchange), 1e18);

        vm.startPrank(owner);
        token.approve(address(exchange), 1e18);
        exchange.execute(tokens, amountsIn, targets, targetData, subsidyProvider, ERC20(address(token)));
        vm.stopPrank();

        assertEq(token.balanceOf(recipient), 0.5e18, "recipient should receive the routed tokens");
        assertEq(token.balanceOf(owner), 1e18, "owner should end with original principal");
        assertEq(token.balanceOf(subsidyProvider), 1.5e18, "subsidy provider should only pay the shortfall");
        assertEq(token.allowance(subsidyProvider, address(exchange)), 0.5e18, "subsidy allowance should only decrease by shortfall");
        assertEq(token.balanceOf(address(exchange)), 0, "exchange should be empty");
    }

    function test_Execute_Invariant_HoldsWithMultipleTokensOfDifferentDecimals() external {
        address recipient = makeAddr("recipient");
        tERC20 tokenA = new tERC20(6);
        tERC20 tokenB = new tERC20(18);

        deal(address(tokenA), owner, 1e6);
        deal(address(tokenB), owner, 1e18);
        deal(address(tokenB), address(exchange), 0.5e18);

        ERC20[] memory tokens = new ERC20[](2);
        uint256[] memory amountsIn = new uint256[](2);
        address[] memory targets = new address[](1);
        bytes[] memory targetData = new bytes[](1);

        tokens[0] = ERC20(address(tokenA));
        tokens[1] = ERC20(address(tokenB));
        amountsIn[0] = 1e6;
        amountsIn[1] = 1e18;
        targets[0] = address(tokenA);
        targetData[0] = abi.encodeWithSelector(ERC20.transfer.selector, recipient, 0.5e6);

        // Normalized accounting:
        // totalIn  = 1e6 * 1e12 + 1e18 = 2e18
        // tokenA out = (1e6 - 0.5e6) * 1e12 = 0.5e18
        // tokenB out = 1e18 + 0.5e18 = 1.5e18
        // totalOut = 0.5e18 + 1.5e18 = 2e18
        // totalOut == totalIn, so the invariant holds.

        vm.startPrank(owner);
        tokenA.approve(address(exchange), 1e6);
        tokenB.approve(address(exchange), 1e18);
        exchange.execute(tokens, amountsIn, targets, targetData, address(0), ERC20(address(0)));
        vm.stopPrank();

        assertEq(tokenA.balanceOf(recipient), 0.5e6, "recipient should receive half of tokenA");
        assertEq(tokenA.balanceOf(owner), 0.5e6, "owner should receive remaining tokenA");
        assertEq(tokenB.balanceOf(owner), 1.5e18, "owner should receive all tokenB including pre-funded");
        assertEq(tokenA.balanceOf(address(exchange)), 0, "exchange should have no tokenA");
        assertEq(tokenB.balanceOf(address(exchange)), 0, "exchange should have no tokenB");
    }

    function test_Execute_RevertsIfDanglingApprovalOnZeroAmountToken() external {
        tERC20 token = new tERC20(18);
        deal(address(token), owner, 1e18);

        ERC20[] memory tokens = new ERC20[](1);
        uint256[] memory amountsIn = new uint256[](1);
        address[] memory targets = new address[](0);
        bytes[] memory targetData = new bytes[](0);

        tokens[0] = ERC20(address(token));
        amountsIn[0] = 0;

        vm.startPrank(owner);
        token.approve(address(exchange), 1e18);

        vm.expectRevert(abi.encodeWithSelector(EquivalentExchange.DanglingApproval.selector, address(token)));
        exchange.execute(tokens, amountsIn, targets, targetData, address(0), ERC20(address(0)));
        vm.stopPrank();
    }

}
