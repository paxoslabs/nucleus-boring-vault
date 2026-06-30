// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { EquivalentExchange } from "src/helper/equivalent-exchange/EquivalentExchange.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { Authority } from "@solmate/auth/Auth.sol";
import { Test } from "@forge-std/Test.sol";

import { IUniswapV3Router } from "src/interfaces/IUniswapV3Router.sol";
import { BalancerVault } from "src/interfaces/BalancerVault.sol";
import { DecoderCustomTypes } from "src/interfaces/DecoderCustomTypes.sol";
import { MainnetAddresses } from "test/resources/MainnetAddresses.sol";

contract EquivalentExchangeIntegrationTest is Test, MainnetAddresses {
    using SafeTransferLib for ERC20;

    EquivalentExchange internal exchange;

    function setUp() external {
        _startFork("MAINNET_RPC_URL", 19_826_676);
        exchange = new EquivalentExchange(address(this), Authority(address(0)));
    }

    function _startFork(string memory rpcKey, uint256 blockNumber) internal returns (uint256 forkId) {
        forkId = vm.createFork(vm.envString(rpcKey), blockNumber);
        vm.selectFork(forkId);
    }

    function _setupSubsidyProvider(address subsidyProvider, uint256 amount) internal {
        deal(address(USDT), subsidyProvider, amount);
        vm.prank(subsidyProvider);
        USDT.safeApprove(address(exchange), amount);
    }

    function test_Execute_UniswapV3_SwapUSDCForUSDT() external {
        uint256 amountIn = 10_000e6;
        address subsidyProvider = makeAddr("uniswapSubsidyProvider");

        deal(address(USDC), address(this), amountIn);
        _setupSubsidyProvider(subsidyProvider, amountIn);

        ERC20[] memory tokens = new ERC20[](2);
        uint256[] memory amountsIn = new uint256[](2);
        address[] memory targets = new address[](2);
        bytes[] memory targetData = new bytes[](2);

        tokens[0] = USDC;
        tokens[1] = USDT;
        amountsIn[0] = amountIn;
        amountsIn[1] = 0;

        // 1. Approve the Uniswap V3 router to spend USDC from EquivalentExchange.
        targets[0] = address(USDC);
        targetData[0] = abi.encodeWithSelector(ERC20.approve.selector, uniV3Router, amountIn);

        // 2. Swap USDC -> USDT through the 0.01% pool, sending output back to EquivalentExchange.
        IUniswapV3Router.ExactInputSingleParams memory params = IUniswapV3Router.ExactInputSingleParams({
            tokenIn: address(USDC),
            tokenOut: address(USDT),
            fee: 100,
            recipient: address(exchange),
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        targets[1] = uniV3Router;
        targetData[1] = abi.encodeWithSelector(IUniswapV3Router.exactInputSingle.selector, params);

        USDC.safeApprove(address(exchange), amountIn);
        exchange.execute(tokens, amountsIn, targets, targetData, subsidyProvider, USDT);

        assertEq(USDC.balanceOf(address(this)), 0, "caller should have no USDC left");
        assertGe(USDT.balanceOf(address(this)), amountIn, "caller should receive at least amountIn of USDT");
        assertEq(USDC.balanceOf(address(exchange)), 0, "exchange should have no USDC");
        assertEq(USDT.balanceOf(address(exchange)), 0, "exchange should have no USDT");
        assertLe(USDT.balanceOf(subsidyProvider), amountIn, "subsidy provider should not be overcompensated");
    }

    function test_Execute_BalancerV2_SwapUSDCForUSDT() external {
        uint256 amountIn = 10_000e6;
        // Balancer USDC/DAI/USDT stable pool.
        bytes32 poolId = 0x06df3b2bbb68adc8b0e302443692037ed9f91b42000000000000000000000063;
        address subsidyProvider = makeAddr("balancerSubsidyProvider");

        deal(address(USDC), address(this), amountIn);
        _setupSubsidyProvider(subsidyProvider, amountIn);

        ERC20[] memory tokens = new ERC20[](2);
        uint256[] memory amountsIn = new uint256[](2);
        address[] memory targets = new address[](2);
        bytes[] memory targetData = new bytes[](2);

        tokens[0] = USDC;
        tokens[1] = USDT;
        amountsIn[0] = amountIn;
        amountsIn[1] = 0;

        // 1. Approve the Balancer vault to spend USDC from EquivalentExchange.
        targets[0] = address(USDC);
        targetData[0] = abi.encodeWithSelector(ERC20.approve.selector, address(balancerVault), amountIn);

        // 2. Swap USDC -> USDT through Balancer, sending output back to EquivalentExchange.
        DecoderCustomTypes.SingleSwap memory singleSwap = DecoderCustomTypes.SingleSwap({
            poolId: poolId,
            kind: DecoderCustomTypes.SwapKind.GIVEN_IN,
            assetIn: address(USDC),
            assetOut: address(USDT),
            amount: amountIn,
            userData: new bytes(0)
        });
        DecoderCustomTypes.FundManagement memory funds = DecoderCustomTypes.FundManagement({
            sender: address(exchange),
            fromInternalBalance: false,
            recipient: address(exchange),
            toInternalBalance: false
        });

        targets[1] = address(balancerVault);
        targetData[1] = abi.encodeWithSelector(BalancerVault.swap.selector, singleSwap, funds, 0, block.timestamp);

        USDC.safeApprove(address(exchange), amountIn);
        exchange.execute(tokens, amountsIn, targets, targetData, subsidyProvider, USDT);

        assertEq(USDC.balanceOf(address(this)), 0, "caller should have no USDC left");
        assertGe(USDT.balanceOf(address(this)), amountIn, "caller should receive at least amountIn of USDT");
        assertEq(USDC.balanceOf(address(exchange)), 0, "exchange should have no USDC");
        assertEq(USDT.balanceOf(address(exchange)), 0, "exchange should have no USDT");
        assertLe(USDT.balanceOf(subsidyProvider), amountIn, "subsidy provider should not be overcompensated");
    }

}
