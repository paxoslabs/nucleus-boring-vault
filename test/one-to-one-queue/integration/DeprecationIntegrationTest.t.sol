// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { OneToOneQueue } from "src/helper/one-to-one-queue/OneToOneQueue.sol";
import { SimpleFeeModule } from "src/helper/SimpleFeeModule.sol";
import { QueueAccessAuthority } from "src/helper/one-to-one-queue/QueueAccessAuthority.sol";
import { OneToOneQueueTestBase, tERC20, ERC20 } from "../OneToOneQueueTestBase.t.sol";
import { Test, stdStorage, StdStorage, stdError, console } from "@forge-std/Test.sol";
import { AccessAuthority } from "src/helper/one-to-one-queue/access/AccessAuthority.sol";
import { VerboseAuth } from "src/helper/one-to-one-queue/access/VerboseAuth.sol";

contract DeprecationStep1IntegrationTest is OneToOneQueueTestBase {

    modifier givenContractStartsDeprecation() {
        vm.startPrank(owner);
        rolesAuthority.continueDeprecation();
        vm.stopPrank();
        _;
    }

    function test_submitOrderAndProcessRevertsWhenContractIsDeprecatedForAllButOwner()
        external
        givenContractStartsDeprecation
    {
        vm.startPrank(user1);
        uint256 numberOfOrders = queue.latestOrder() + 1 - queue.lastProcessedOrder();
        OneToOneQueue.SubmitOrderParams memory params =
            _createSubmitOrderParams(1e6, USDC, USDG0, user1, user1, user1, defaultParams);
        bytes memory data = abi.encodeWithSelector(OneToOneQueue.submitOrderAndProcess.selector, params, numberOfOrders);
        vm.expectRevert(
            abi.encodeWithSelector(VerboseAuth.Unauthorized.selector, user1, data, "- Unauthorized - Deprecated "),
            address(queue)
        );
        queue.submitOrderAndProcess(params, numberOfOrders);
        vm.stopPrank();

        vm.startPrank(owner);
        deal(address(USDC), owner, 1e6);
        deal(address(USDG0), address(queue), 1e6);
        USDC.approve(address(queue), 1e6);
        numberOfOrders = queue.latestOrder() + 1 - queue.lastProcessedOrder();
        vm.expectEmit(true, true, true, true);
        emit OrdersProcessedInRange(1, 1);
        queue.submitOrderAndProcess(
            _createSubmitOrderParams(1e6, USDC, USDG0, owner, owner, owner, defaultParams), numberOfOrders
        );
        vm.stopPrank();
    }

    function test_submitOrderAndProcessAllRevertsWhenContractIsDeprecatedForAllButOwner()
        external
        givenContractStartsDeprecation
    {
        vm.startPrank(user1);

        OneToOneQueue.SubmitOrderParams memory params =
            _createSubmitOrderParams(1e6, USDC, USDG0, user1, user1, user1, defaultParams);

        bytes memory data = abi.encodeWithSelector(OneToOneQueue.submitOrderAndProcessAll.selector, params);
        vm.expectRevert(
            abi.encodeWithSelector(VerboseAuth.Unauthorized.selector, user1, data, "- Unauthorized - Deprecated "),
            address(queue)
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

    function test_submitOrderRevertsWhenContractIsDeprecatedForAllButOwner() external givenContractStartsDeprecation {
        vm.startPrank(user1);
        OneToOneQueue.SubmitOrderParams memory params =
            _createSubmitOrderParams(1e6, USDC, USDG0, user1, user1, user1, defaultParams);
        bytes memory data = abi.encodeWithSelector(OneToOneQueue.submitOrder.selector, params);
        vm.expectRevert(
            abi.encodeWithSelector(VerboseAuth.Unauthorized.selector, user1, data, "- Unauthorized - Deprecated "),
            address(queue)
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

    function test_processOrdersPassesWhenContractIsOnlyOnDeprecationStep1() external {
        _submitAnOrder();
        deal(address(USDG0), address(queue), 1e6);

        vm.startPrank(owner);
        rolesAuthority.continueDeprecation();
        vm.stopPrank();

        vm.startPrank(user1);
        _expectOrderProcessedEvent(1, OneToOneQueue.OrderType.DEFAULT, false, false);
        vm.expectEmit(true, true, true, true);
        emit OrdersProcessedInRange(1, 1);
        queue.processOrders(1);
        vm.stopPrank();
    }

}

contract DeprecationStep2IntegrationTest is OneToOneQueueTestBase {

    modifier givenContractFinishesDeprecation() {
        vm.startPrank(owner);
        rolesAuthority.continueDeprecation();
        rolesAuthority.continueDeprecation();
        vm.stopPrank();
        _;
    }

    function test_submitOrderAndProcessRevertsWhenContractIsDeprecatedForAllButOwner()
        external
        givenContractFinishesDeprecation
    {
        vm.startPrank(user1);
        uint256 numberOfOrders = queue.latestOrder() + 1 - queue.lastProcessedOrder();
        OneToOneQueue.SubmitOrderParams memory params =
            _createSubmitOrderParams(1e6, USDC, USDG0, user1, user1, user1, defaultParams);
        bytes memory data = abi.encodeWithSelector(OneToOneQueue.submitOrderAndProcess.selector, params, numberOfOrders);
        vm.expectRevert(
            abi.encodeWithSelector(
                VerboseAuth.Unauthorized.selector, user1, data, "- Paused - Unauthorized - Deprecated "
            ),
            address(queue)
        );
        queue.submitOrderAndProcess(params, numberOfOrders);
        vm.stopPrank();

        vm.startPrank(owner);
        deal(address(USDC), owner, 1e6);
        deal(address(USDG0), address(queue), 1e6);
        USDC.approve(address(queue), 1e6);
        numberOfOrders = queue.latestOrder() + 1 - queue.lastProcessedOrder();
        vm.expectEmit(true, true, true, true);
        emit OrdersProcessedInRange(1, 1);
        queue.submitOrderAndProcess(
            _createSubmitOrderParams(1e6, USDC, USDG0, owner, owner, owner, defaultParams), numberOfOrders
        );
        vm.stopPrank();
    }

    function test_submitOrderAndProcessAllRevertsWhenContractIsDeprecatedForAllButOwner()
        external
        givenContractFinishesDeprecation
    {
        vm.startPrank(user1);

        OneToOneQueue.SubmitOrderParams memory params =
            _createSubmitOrderParams(1e6, USDC, USDG0, user1, user1, user1, defaultParams);

        bytes memory data = abi.encodeWithSelector(OneToOneQueue.submitOrderAndProcessAll.selector, params);
        vm.expectRevert(
            abi.encodeWithSelector(
                VerboseAuth.Unauthorized.selector, user1, data, "- Paused - Unauthorized - Deprecated "
            ),
            address(queue)
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

    function test_submitOrderRevertsWhenContractIsDeprecatedForAllButOwner() external givenContractFinishesDeprecation {
        vm.startPrank(user1);
        OneToOneQueue.SubmitOrderParams memory params =
            _createSubmitOrderParams(1e6, USDC, USDG0, user1, user1, user1, defaultParams);
        bytes memory data = abi.encodeWithSelector(OneToOneQueue.submitOrder.selector, params);
        vm.expectRevert(
            abi.encodeWithSelector(
                VerboseAuth.Unauthorized.selector, user1, data, "- Paused - Unauthorized - Deprecated "
            ),
            address(queue)
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

    function test_cannotFullyDeprecateWithOrdersInTheQueue() external {
        _submitAnOrder();

        vm.startPrank(owner);
        rolesAuthority.continueDeprecation();
        vm.expectRevert(abi.encodeWithSelector(QueueAccessAuthority.QueueNotEmpty.selector), address(rolesAuthority));
        rolesAuthority.continueDeprecation();
        vm.stopPrank();
    }

    function test_processOrdersFailsWhenFullyDeprecatedForAllButOwner() external givenContractFinishesDeprecation {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                VerboseAuth.Unauthorized.selector,
                user1,
                abi.encodeWithSelector(OneToOneQueue.processOrders.selector, 1),
                "- Paused - Deprecated "
            ),
            address(queue)
        );
        queue.processOrders(1);
        vm.stopPrank();

        // No emit since there should be no orders in the queue
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(OneToOneQueue.NotEnoughOrdersToProcess.selector, 1, 0), address(queue));
        queue.processOrders(1);
        vm.stopPrank();
    }

}
