// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { OneToOneQueue } from "src/helper/one-to-one-queue/OneToOneQueue.sol";
import { SimpleFeeModule } from "src/helper/SimpleFeeModule.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { QueueAccessAuthority, AccessAuthority } from "src/helper/one-to-one-queue/QueueAccessAuthority.sol";
import { IAccessAuthorityHook } from "src/helper/one-to-one-queue/access/AccessAuthority.sol";
import { Test, stdStorage, StdStorage, stdError, console } from "@forge-std/Test.sol";
import { OneToOneQueueTestBase, tERC20, ERC20 } from "../OneToOneQueueTestBase.t.sol";
import { VerboseAuth, Authority } from "src/helper/one-to-one-queue/access/VerboseAuth.sol";

contract AccessAuthorityTest is OneToOneQueueTestBase {

    /// @notice Emitted when deprecation continues to next step
    /// @param newStep The new deprecation step
    event DeprecationContinued(uint8 newStep);

    /// @notice Emitted when deprecation is finalized
    /// @param newStep The new deprecation step
    event DeprecationFinished(uint8 newStep);

    event AccessAuthorityHookUpdated(address indexed oldHook, address indexed newHook);

    function test_pause() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                VerboseAuth.Unauthorized.selector,
                address(this),
                abi.encodeWithSelector(AccessAuthority.pause.selector),
                "- Not a pauser or owner "
            ),
            address(rolesAuthority)
        );
        rolesAuthority.pause();

        // Pauser1 can pause
        vm.startPrank(pauser1);
        vm.expectEmit(true, true, true, true);
        emit Pausable.Paused(pauser1);
        rolesAuthority.pause();
        vm.stopPrank();

        // Owner can also pause but must unpause first
        vm.startPrank(owner);

        vm.expectEmit(true, true, true, true);
        emit Pausable.Paused(owner);
        rolesAuthority.pause();
        vm.stopPrank();

        assertTrue(rolesAuthority.paused());

        vm.startPrank(user1);
        OneToOneQueue.SubmitOrderParams memory params =
            _createSubmitOrderParams(1e6, USDC, USDG0, user1, user1, user1, defaultParams);
        bytes memory data = abi.encodeWithSelector(OneToOneQueue.submitOrder.selector, params);
        vm.expectRevert(
            abi.encodeWithSelector(VerboseAuth.Unauthorized.selector, user1, data, "- Paused "), address(queue)
        );
        queue.submitOrder(params);
        vm.stopPrank();
    }

    function test_unpause() external {
        vm.startPrank(pauser1);
        rolesAuthority.pause();
        vm.stopPrank();

        vm.startPrank(owner);
        vm.expectEmit(true, true, true, true);
        emit Pausable.Unpaused(owner);
        rolesAuthority.unpause();
        vm.stopPrank();

        assertFalse(rolesAuthority.paused());
    }

    function test_beginDeprecation() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                VerboseAuth.Unauthorized.selector,
                address(this),
                abi.encodeWithSelector(AccessAuthority.continueDeprecation.selector),
                "- No Authority Set: Owner Only "
            ),
            address(rolesAuthority)
        );
        rolesAuthority.continueDeprecation();

        vm.startPrank(owner);
        vm.expectEmit(true, true, true, true);
        emit AccessAuthority.DeprecationContinued(1);
        rolesAuthority.continueDeprecation();
        assertEq(rolesAuthority.deprecationStep(), 1);
        assertFalse(rolesAuthority.isFullyDeprecated());
        vm.stopPrank();

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
    }

    function test_continueDeprecation() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                VerboseAuth.Unauthorized.selector,
                address(this),
                abi.encodeWithSelector(AccessAuthority.continueDeprecation.selector),
                "- No Authority Set: Owner Only "
            ),
            address(rolesAuthority)
        );
        rolesAuthority.continueDeprecation();

        _submitAnOrder();

        vm.startPrank(owner);
        rolesAuthority.continueDeprecation();

        vm.expectRevert(abi.encodeWithSelector(QueueAccessAuthority.QueueNotEmpty.selector), address(rolesAuthority));
        rolesAuthority.continueDeprecation();

        deal(address(USDG0), address(queue), 1e6);
        queue.processOrders(1);

        vm.expectEmit(true, true, true, true);
        emit AccessAuthority.DeprecationContinued(2);
        emit AccessAuthority.DeprecationFinished(2);
        rolesAuthority.continueDeprecation();

        assertEq(rolesAuthority.deprecationStep(), 2);
        assertTrue(rolesAuthority.isFullyDeprecated());
        assertTrue(rolesAuthority.paused());
        vm.stopPrank();

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

        data = abi.encodeWithSelector(OneToOneQueue.processOrders.selector, 1);
        vm.expectRevert(
            abi.encodeWithSelector(VerboseAuth.Unauthorized.selector, user1, data, "- Paused - Deprecated "),
            address(queue)
        );
        queue.processOrders(1);

        vm.stopPrank();
    }

    function test_setAccessAuthorityHook() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                VerboseAuth.Unauthorized.selector,
                address(this),
                abi.encodeWithSelector(AccessAuthority.setAccessAuthorityHook.selector, address(0)),
                "- No Authority Set: Owner Only "
            ),
            address(rolesAuthority)
        );
        rolesAuthority.setAccessAuthorityHook(IAccessAuthorityHook(address(0)));

        vm.startPrank(owner);
        vm.expectEmit(true, true, true, true);
        emit AccessAuthority.AccessAuthorityHookUpdated(address(0), address(0));
        rolesAuthority.setAccessAuthorityHook(IAccessAuthorityHook(address(0)));
        vm.stopPrank();
    }

    function test_setAuthority() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                VerboseAuth.Unauthorized.selector,
                address(this),
                abi.encodeWithSelector(VerboseAuth.setAuthority.selector, address(0)),
                "- Not authorized"
            ),
            address(queue)
        );
        queue.setAuthority(Authority(address(0)));

        vm.startPrank(owner);
        vm.expectEmit(true, true, true, true);
        emit VerboseAuth.AuthorityUpdated(owner, Authority(address(0)));
        queue.setAuthority(Authority(address(0)));
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                VerboseAuth.Unauthorized.selector,
                address(this),
                abi.encodeWithSelector(VerboseAuth.setAuthority.selector, address(0)),
                "- No Authority Set: Owner Only "
            ),
            address(queue)
        );
        queue.setAuthority(Authority(address(0)));

        assertEq(address(queue.authority()), address(0));
    }

}

contract AccessAuthorityHook is IAccessAuthorityHook {

    function canCallVerbose(
        address user,
        address target,
        bytes calldata data
    )
        external
        view
        returns (bool, string memory)
    {
        return (false, "I am a test value");
    }

}

contract AccessAuthorityHookTest is OneToOneQueueTestBase {

    event AccessAuthorityHookUpdated(address indexed oldHook, address indexed newHook);

    function test_canCallVerbose_withAccessAuthorityHook() external {
        AccessAuthorityHook accessAuthorityHook = new AccessAuthorityHook();
        vm.startPrank(owner);
        vm.expectEmit(true, true, true, true);
        emit AccessAuthority.AccessAuthorityHookUpdated(address(0), address(accessAuthorityHook));
        rolesAuthority.setAccessAuthorityHook(accessAuthorityHook);
        vm.stopPrank();

        assertEq(address(rolesAuthority.accessAuthorityHook()), address(accessAuthorityHook));

        vm.startPrank(user1);
        OneToOneQueue.SubmitOrderParams memory params =
            _createSubmitOrderParams(1e6, USDC, USDG0, user1, user1, user1, defaultParams);
        bytes memory data = abi.encodeWithSelector(OneToOneQueue.submitOrder.selector, params);
        vm.expectRevert(abi.encodeWithSelector(VerboseAuth.Unauthorized.selector, user1, data, "I am a test value"));
        queue.submitOrder(params);
        vm.stopPrank();
    }

}
