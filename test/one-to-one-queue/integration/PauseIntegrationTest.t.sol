// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { OneToOneQueue } from "src/helper/one-to-one-queue/OneToOneQueue.sol";
import { SimpleFeeModule } from "src/helper/SimpleFeeModule.sol";
import { OneToOneQueueTestBase, tERC20, ERC20 } from "../OneToOneQueueTestBase.t.sol";
import { Test, stdStorage, StdStorage, stdError, console } from "@forge-std/Test.sol";
import { AccessAuthority } from "src/helper/one-to-one-queue/access/AccessAuthority.sol";
import { VerboseAuth } from "src/helper/one-to-one-queue/access/VerboseAuth.sol";

contract PauseQueueIntegrationTest is OneToOneQueueTestBase {

    modifier givenContractIsPaused() {
        vm.prank(pauser1);
        rolesAuthority.pause();
        _;
    }

    // Not testing admin functions such as setters. Only owner may call them anyways, and owners bypass pause. Therefore
    // they would all just behave as expected anyways.
    function test_submitOrderAndProcessRevertsWhenContractIsPausedForAllButOwner() external givenContractIsPaused {
        vm.startPrank(user1);

        uint256 numberOfOrders = queue.latestOrder() + 1 - queue.lastProcessedOrder();
        OneToOneQueue.SubmitOrderParams memory params =
            _createSubmitOrderParams(1e6, USDC, USDG0, user1, user1, user1, defaultParams);
        bytes memory data = abi.encodeWithSelector(OneToOneQueue.submitOrderAndProcess.selector, params, numberOfOrders);
        vm.expectRevert(
            abi.encodeWithSelector(VerboseAuth.Unauthorized.selector, user1, data, "- Paused "), address(queue)
        );
        queue.submitOrderAndProcess(params, numberOfOrders);
        vm.stopPrank();

        vm.startPrank(owner);
        deal(address(USDC), owner, 1e6);
        deal(address(USDG0), address(queue), 1e6);
        USDC.approve(address(queue), 1e6);
        vm.expectEmit(true, true, true, true);
        emit OrdersProcessedInRange(1, 1);
        queue.submitOrderAndProcess(
            _createSubmitOrderParams(1e6, USDC, USDG0, owner, owner, owner, defaultParams), numberOfOrders
        );
        vm.stopPrank();
    }

    function test_submitOrderAndProcessAllRevertsWhenContractIsPausedForAllButOwner() external givenContractIsPaused {
        vm.startPrank(user1);

        OneToOneQueue.SubmitOrderParams memory params =
            _createSubmitOrderParams(1e6, USDC, USDG0, user1, user1, user1, defaultParams);
        bytes memory data = abi.encodeWithSelector(OneToOneQueue.submitOrderAndProcessAll.selector, params);
        vm.expectRevert(
            abi.encodeWithSelector(VerboseAuth.Unauthorized.selector, user1, data, "- Paused "), address(queue)
        );
        queue.submitOrderAndProcessAll(params);
        vm.stopPrank();

        vm.startPrank(owner);
        deal(address(USDC), owner, 1e6);
        deal(address(USDG0), address(queue), 1e6);
        USDC.approve(address(queue), 1e6);
        vm.expectEmit(true, true, true, true);
        emit OrdersProcessedInRange(1, 1);
        queue.submitOrderAndProcessAll(_createSubmitOrderParams(1e6, USDC, USDG0, owner, owner, owner, defaultParams));
        vm.stopPrank();
    }

    function test_submitOrderRevertsWhenContractIsPausedForAllButOwner() external givenContractIsPaused {
        vm.startPrank(user1);

        OneToOneQueue.SubmitOrderParams memory params =
            _createSubmitOrderParams(1e6, USDC, USDG0, user1, user1, user1, defaultParams);
        bytes memory data = abi.encodeWithSelector(OneToOneQueue.submitOrder.selector, params);

        vm.expectRevert(
            abi.encodeWithSelector(VerboseAuth.Unauthorized.selector, user1, data, "- Paused "), address(queue)
        );
        queue.submitOrder(params);
        vm.stopPrank();

        vm.startPrank(owner);
        deal(address(USDC), owner, 1e6);
        USDC.approve(address(queue), 1e6);
        queue.submitOrder(_createSubmitOrderParams(1e6, USDC, USDG0, owner, owner, owner, defaultParams));
        assertEq(queue.ownerOf(1), owner);
        vm.stopPrank();
    }

    function test_processOrdersRevertsWhenContractIsPausedForAllButOwner() external {
        _submitAnOrder();

        vm.prank(pauser1);
        rolesAuthority.pause();

        vm.startPrank(user1);
        bytes memory data = abi.encodeWithSelector(OneToOneQueue.processOrders.selector, 1);
        vm.expectRevert(
            abi.encodeWithSelector(VerboseAuth.Unauthorized.selector, user1, data, "- Paused "), address(queue)
        );
        queue.processOrders(1);
        vm.stopPrank();

        vm.startPrank(owner);
        deal(address(USDG0), address(queue), 1e6);
        vm.expectEmit(true, true, true, true);
        emit OrdersProcessedInRange(1, 1);
        queue.processOrders(1);
        vm.stopPrank();
    }

}
