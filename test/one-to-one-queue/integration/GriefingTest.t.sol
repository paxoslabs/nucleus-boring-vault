// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { OneToOneQueue } from "src/helper/one-to-one-queue/OneToOneQueue.sol";
import { SimpleFeeModule } from "src/helper/SimpleFeeModule.sol";
import { QueueAccessAuthority } from "src/helper/one-to-one-queue/QueueAccessAuthority.sol";
import { OneToOneQueueTestBase, tERC20, ERC20, IERC20 } from "../OneToOneQueueTestBase.t.sol";
import { Test, stdStorage, StdStorage, stdError, console } from "@forge-std/Test.sol";
import { AccessAuthority } from "src/helper/one-to-one-queue/access/AccessAuthority.sol";
import { VerboseAuth } from "src/helper/one-to-one-queue/access/VerboseAuth.sol";

contract BlacklistToken is tERC20 {

    constructor() tERC20(6) { }

    mapping(address => bool) public blacklist;

    function setBlacklist(address account, bool isBlacklisted) public {
        blacklist[account] = isBlacklisted;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(!blacklist[to], "Blacklisted address");
        return super.transfer(to, amount);
    }

}

contract GriefingTest is OneToOneQueueTestBase {

    address blacklistedAddress = makeAddr("blacklistedAddress");
    BlacklistToken blacklistToken;

    function setUp() public override {
        super.setUp();
        (blacklistedAddress,) = makeAddrAndKey("blacklistedAddress");
        blacklistToken = new BlacklistToken();
        vm.startPrank(owner);
        queue.addWantAsset(address(blacklistToken));
        blacklistToken.setBlacklist(blacklistedAddress, true);
        vm.stopPrank();
    }

    function test_griefing() external {
        deal(address(USDC), user1, 3e6);
        deal(address(blacklistToken), address(queue), 3e6);
        // sandwich a griefing order between two normal orders
        OneToOneQueue.SubmitOrderParams memory normalOrder =
            _createSubmitOrderParams(1e6, USDC, IERC20(address(blacklistToken)), user1, user1, user1, defaultParams);
        vm.startPrank(user1);
        USDC.approve(address(queue), 3e6);
        queue.submitOrder(normalOrder);
        queue.submitOrder(
            _createSubmitOrderParams(
                1e6, USDC, IERC20(address(blacklistToken)), user1, blacklistedAddress, user1, defaultParams
            )
        );
        queue.submitOrder(normalOrder);
        vm.stopPrank();

        assertTrue(queue.ownerOf(1) == user1, "user1 should own the first order");
        assertTrue(queue.ownerOf(2) == blacklistedAddress, "blacklisted address should own the second order");
        assertTrue(queue.ownerOf(3) == user1, "user1 should own the third order");

        // process all orders
        OneToOneQueue.Order memory griefingOrder = OneToOneQueue.Order({
            amountOffer: 1e6,
            amountWant: uint128((1e6 - (1e6 * TEST_OFFER_FEE_PERCENTAGE) / 10_000)),
            offerAsset: IERC20(address(USDC)),
            wantAsset: IERC20(address(blacklistToken)),
            refundReceiver: user1,
            orderType: OneToOneQueue.OrderType.DEFAULT,
            didOrderFailTransfer: true
        });
        vm.expectEmit(true, true, true, true);
        emit OrderFailedTransfer(2, recoveryAddress, blacklistedAddress, griefingOrder);
        _expectOrderProcessedEvent(2, OneToOneQueue.OrderType.DEFAULT, false, true);
        queue.processOrders(3);

        // check that the griefing order is at the back of the queue
        // and that the normal orders are complete
        assertEq(
            uint8(queue.getOrderStatus(1)), uint8(OneToOneQueue.OrderStatus.COMPLETE), "normal order should be complete"
        );
        assertEq(
            uint8(queue.getOrderStatus(2)),
            uint8(OneToOneQueue.OrderStatus.FAILED_TRANSFER),
            "griefing order should be failed transfer"
        );
        assertEq(
            uint8(queue.getOrderStatus(3)), uint8(OneToOneQueue.OrderStatus.COMPLETE), "normal order should be complete"
        );
        assertEq(queue.latestOrder(), 3, "latest order should be 3");
        assertEq(queue.lastProcessedOrder(), 3, "last processed order should be 3");

        assertEq(blacklistToken.balanceOf(blacklistedAddress), 0, "blacklisted address should have no balance");
        assertEq(
            blacklistToken.balanceOf(address(recoveryAddress)),
            1e6 - (1e6 * TEST_OFFER_FEE_PERCENTAGE / 10_000),
            "recovery address should have 1e6 balance minus fees"
        );
    }

}
