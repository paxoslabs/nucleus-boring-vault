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

}
