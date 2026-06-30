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

    event Executed(
        address indexed caller,
        uint256 totalIn,
        uint256 totalOut,
        uint256 totalSubsidyAmount,
        ERC20 indexed subsidyToken
    );

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
        targetData[0] = abi.encodeWithSelector(
            EquivalentExchange.execute.selector, tokens, amountsIn, targets, targetData, address(0), ERC20(address(0))
        );

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
        assertEq(
            token.allowance(subsidyProvider, address(exchange)),
            0.5e18,
            "subsidy allowance should only decrease by shortfall"
        );
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

    function test_Execute_EmitsExecutedEventWithMultipleDecimalsAndSurplus() external {
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

        // totalIn  = 1e6 * 1e12 + 1e18 = 2e18
        // totalOut = 1e6 * 1e12 + 1.5e18 = 2.5e18

        vm.startPrank(owner);
        tokenA.approve(address(exchange), 1e6);
        tokenB.approve(address(exchange), 1e18);

        vm.expectEmit(true, true, true, true);
        emit Executed(owner, 2e18, 2.5e18, 0, ERC20(address(0)));
        exchange.execute(tokens, amountsIn, targets, targetData, address(0), ERC20(address(0)));
        vm.stopPrank();
    }

    function test_Execute_EmitsExecutedEventWithSubsidy() external {
        address recipient = makeAddr("recipient");
        address subsidyProvider = makeAddr("subsidyProvider");
        tERC20 tokenA = new tERC20(6);
        tERC20 tokenB = new tERC20(18);

        deal(address(tokenA), owner, 1e6);
        deal(address(tokenB), owner, 1e18);
        deal(address(tokenB), subsidyProvider, 0.5e18);

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

        // totalIn  = 1e6 * 1e12 + 1e18 = 2e18
        // tokenA out = (1e6 - 0.5e6) * 1e12 = 0.5e18
        // tokenB out = 1e18
        // totalOut before subsidy = 0.5e18 + 1e18 = 1.5e18
        // subsidy = 0.5e18
        // totalOut after subsidy = 2e18

        vm.prank(subsidyProvider);
        tokenB.approve(address(exchange), 0.5e18);

        vm.startPrank(owner);
        tokenA.approve(address(exchange), 1e6);
        tokenB.approve(address(exchange), 1e18);

        vm.expectEmit(true, true, true, true);
        emit Executed(owner, 2e18, 2e18, 0.5e18, ERC20(address(tokenB)));
        exchange.execute(tokens, amountsIn, targets, targetData, subsidyProvider, ERC20(address(tokenB)));
        vm.stopPrank();
    }

    function test_Execute_TokenWithMoreThan18Decimals() external {
        address recipient = makeAddr("recipient");
        tERC20 token = new tERC20(24);
        deal(address(token), owner, 1e24);

        ERC20[] memory tokens = new ERC20[](1);
        uint256[] memory amountsIn = new uint256[](1);
        address[] memory targets = new address[](1);
        bytes[] memory targetData = new bytes[](1);

        tokens[0] = ERC20(address(token));
        amountsIn[0] = 1e24;
        targets[0] = address(token);
        targetData[0] = abi.encodeWithSelector(ERC20.transfer.selector, recipient, 0.5e24);

        // Normalized accounting for 24-decimal token:
        // totalIn  = 1e24 / 1e6 = 1e18
        // totalOut = (1e24 - 0.5e24) / 1e6 = 0.5e18
        // The invariant would fail without a subsidy, so we use an address(0) subsidy provider
        // which causes the subsidy pull to revert.
        vm.startPrank(owner);
        token.approve(address(exchange), 1e24);

        vm.expectRevert("TRANSFER_FROM_FAILED");
        exchange.execute(tokens, amountsIn, targets, targetData, address(0), ERC20(address(token)));
        vm.stopPrank();

        // Now run the same route with no transfer so the invariant holds.
        targets = new address[](0);
        targetData = new bytes[](0);

        vm.startPrank(owner);
        token.approve(address(exchange), 1e24);
        exchange.execute(tokens, amountsIn, targets, targetData, address(0), ERC20(address(0)));
        vm.stopPrank();

        assertEq(token.balanceOf(owner), 1e24, "owner should receive back all 24-decimal tokens");
        assertEq(token.balanceOf(address(exchange)), 0, "exchange should be empty");
    }

    function test_Execute_SubsidyTokenWithDifferentDecimals() external {
        address recipient = makeAddr("recipient");
        address subsidyProvider = makeAddr("subsidyProvider");
        tERC20 inputToken = new tERC20(18);
        tERC20 subsidyToken = new tERC20(6);

        deal(address(inputToken), owner, 1e18);
        deal(address(subsidyToken), subsidyProvider, 1e6);

        ERC20[] memory tokens = new ERC20[](1);
        uint256[] memory amountsIn = new uint256[](1);
        address[] memory targets = new address[](1);
        bytes[] memory targetData = new bytes[](1);

        tokens[0] = ERC20(address(inputToken));
        amountsIn[0] = 1e18;
        targets[0] = address(inputToken);
        targetData[0] = abi.encodeWithSelector(ERC20.transfer.selector, recipient, 0.5e18);

        // totalIn  = 1e18
        // totalOut = 0.5e18
        // shortfall = 0.5e18 normalized -> 0.5e6 units of 6-decimal subsidy token

        vm.prank(subsidyProvider);
        subsidyToken.approve(address(exchange), 1e6);

        vm.startPrank(owner);
        inputToken.approve(address(exchange), 1e18);
        exchange.execute(tokens, amountsIn, targets, targetData, subsidyProvider, ERC20(address(subsidyToken)));
        vm.stopPrank();

        assertEq(inputToken.balanceOf(recipient), 0.5e18, "recipient should receive half of input token");
        assertEq(inputToken.balanceOf(owner), 0.5e18, "owner should receive remaining input token");
        assertEq(subsidyToken.balanceOf(owner), 0.5e6, "owner should receive 6-decimal subsidy");
        assertEq(subsidyToken.balanceOf(subsidyProvider), 0.5e6, "subsidy provider should pay half of 6-decimal tokens");
        assertEq(inputToken.balanceOf(address(exchange)), 0, "exchange should have no input token");
        assertEq(subsidyToken.balanceOf(address(exchange)), 0, "exchange should have no subsidy token");
    }

    function test_Execute_DenormalizeRoundsUp() external {
        address subsidyProvider = makeAddr("subsidyProvider");
        address recipient = makeAddr("recipient");
        tERC20 inputToken = new tERC20(18);
        tERC20 subsidyToken = new tERC20(6);

        deal(address(inputToken), owner, 1e18);
        deal(address(subsidyToken), subsidyProvider, 1e6);

        ERC20[] memory tokens = new ERC20[](1);
        uint256[] memory amountsIn = new uint256[](1);
        address[] memory targets = new address[](1);
        bytes[] memory targetData = new bytes[](1);

        tokens[0] = ERC20(address(inputToken));
        amountsIn[0] = 1e18;
        targets[0] = address(inputToken);
        // Transfer out 1 wei to create a shortfall of exactly 1 normalized unit.
        targetData[0] = abi.encodeWithSelector(ERC20.transfer.selector, recipient, 1);

        // totalIn  = 1e18
        // totalOut = 1e18 - 1
        // shortfall = 1 normalized unit
        // _denormalize(1, 6) rounds up to 1 unit of the 6-decimal subsidy token.
        // _normalize(1, 6) = 1e12, so totalOut after subsidy >= totalIn.

        vm.prank(subsidyProvider);
        subsidyToken.approve(address(exchange), 1e6);

        vm.startPrank(owner);
        inputToken.approve(address(exchange), 1e18);
        exchange.execute(tokens, amountsIn, targets, targetData, subsidyProvider, ERC20(address(subsidyToken)));
        vm.stopPrank();

        assertEq(inputToken.balanceOf(recipient), 1, "recipient should receive 1 wei");
        assertEq(inputToken.balanceOf(owner), 1e18 - 1, "owner should receive all but 1 wei of input");
        assertEq(subsidyToken.balanceOf(owner), 1, "owner should receive 1 unit of 6-decimal subsidy");
        assertEq(subsidyToken.balanceOf(subsidyProvider), 1e6 - 1, "subsidy provider should pay 1 unit");
        assertEq(inputToken.balanceOf(address(exchange)), 0, "exchange should have no input token");
        assertEq(subsidyToken.balanceOf(address(exchange)), 0, "exchange should have no subsidy token");
    }

    function test_Execute_CallerCannotSubsidizeItselfDueToDanglingApproval() external {
        // A caller cannot act as its own subsidy provider because _pull requires the
        // caller's allowance to be fully consumed. When the subsidy path tries to pull
        // from msg.sender, no allowance remains and the transfer reverts.
        tERC20 token = new tERC20(18);
        deal(address(token), owner, 2e18);

        ERC20[] memory tokens = new ERC20[](1);
        uint256[] memory amountsIn = new uint256[](1);
        address[] memory targets = new address[](1);
        bytes[] memory targetData = new bytes[](1);

        tokens[0] = ERC20(address(token));
        amountsIn[0] = 1e18;
        targets[0] = address(token);
        // Cause a shortfall so the subsidy path is hit.
        targetData[0] = abi.encodeWithSelector(ERC20.transfer.selector, makeAddr("recipient"), 0.5e18);

        vm.startPrank(owner);
        token.approve(address(exchange), 2e18);

        vm.expectRevert();
        exchange.execute(tokens, amountsIn, targets, targetData, owner, ERC20(address(token)));
        vm.stopPrank();
    }

    function test_Execute_CannotSelfSubsidizeWithUnlistedSubsidyToken() external {
        // If the subsidy token is not part of the `tokens` array, its dangling approval is not
        // checked and it might be usable for a self-subsidy attack. For this reason, the subsidy
        // provider must not be msg.sender.
        tERC20 inputToken = new tERC20(18);
        tERC20 subsidyToken = new tERC20(18);
        deal(address(inputToken), owner, 1e18);
        deal(address(subsidyToken), owner, 1e18);

        ERC20[] memory tokens = new ERC20[](1);
        uint256[] memory amountsIn = new uint256[](1);
        address[] memory targets = new address[](1);
        bytes[] memory targetData = new bytes[](1);

        tokens[0] = ERC20(address(inputToken));
        amountsIn[0] = 1e18;
        targets[0] = address(inputToken);
        // Cause a shortfall so the subsidy path is hit.
        targetData[0] = abi.encodeWithSelector(ERC20.transfer.selector, makeAddr("recipient"), 0.5e18);

        vm.startPrank(owner);
        inputToken.approve(address(exchange), 1e18);
        subsidyToken.approve(address(exchange), 1e18);

        vm.expectRevert(EquivalentExchange.CannotSelfSubsidize.selector);
        exchange.execute(tokens, amountsIn, targets, targetData, owner, ERC20(address(subsidyToken)));
        vm.stopPrank();
    }

    function test_Execute_CannotSelfSubsidizeWithListedSubsidyToken() external {
        // When the subsidy token is also listed in `tokens`, the existing dangling-approval
        // check in _pull triggers before the subsidy path is reached, so the revert reason
        // is DanglingApproval rather than CannotSelfSubsidize.
        tERC20 token = new tERC20(18);
        deal(address(token), owner, 2e18);

        ERC20[] memory tokens = new ERC20[](1);
        uint256[] memory amountsIn = new uint256[](1);
        address[] memory targets = new address[](1);
        bytes[] memory targetData = new bytes[](1);

        tokens[0] = ERC20(address(token));
        amountsIn[0] = 1e18;
        targets[0] = address(token);
        // Cause a shortfall so the subsidy path would be hit.
        targetData[0] = abi.encodeWithSelector(ERC20.transfer.selector, makeAddr("recipient"), 0.5e18);

        vm.startPrank(owner);
        token.approve(address(exchange), 2e18);

        vm.expectRevert(abi.encodeWithSelector(EquivalentExchange.DanglingApproval.selector, address(token)));
        exchange.execute(tokens, amountsIn, targets, targetData, owner, ERC20(address(token)));
        vm.stopPrank();
    }

}
