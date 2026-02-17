// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { WithdrawQueueIntegrationBaseTest } from "./WithdrawQueueIntegrationBaseTest.t.sol";

contract WithdrawQueueHappyPathTest is WithdrawQueueIntegrationBaseTest {

    function test_WithdrawQueueHappyPath() external {
        _happyPath(1e6, 1e6, 1e6);
    }

    function test_WithdrawQueueHappyPathSubmitAndProcessAll() external {
        _happySubmitAndProcessAllPath(1e6, 1e6);
    }

}
