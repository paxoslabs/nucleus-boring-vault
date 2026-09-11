// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { BeforeTransferHook } from "src/interfaces/BeforeTransferHook.sol";
import { AtomicQueue } from "src/atomic-queue/AtomicQueue.sol";

contract AtomicQueueDerailBeforeTransferHook is BeforeTransferHook {
    error UnexpectedRevert(address from, bytes returnData);
    error UseOfInvalidContract(address from, address blockedContract, bytes returnData);

    uint256 internal constant DERAIL_GAS_STIPEND = 30_000;
    bytes32 internal constant REENTRANCY_REVERT_HASH =
        keccak256(abi.encodeWithSignature("Error(string)", "REENTRANCY"));

    AtomicQueue public atomicQueue;

    constructor(address _atomicQueue) {
        atomicQueue = AtomicQueue(_atomicQueue);
    }

    /**
     * @dev This use of the beforeTransfer hook derails any attempt to use the vault tokens in a vulnerable AtomicQueue
     * contract.
     *   It does this by weaponizing the reenternacy guard and attempting on every single token transfer, to enter the
     * solve() function.
     *   This is slightly complicated by the fact that this beforeTransfer hook is a view function but we may still
     * utilize this technique by attempting a staticcall to solve() with empty imputs and inspecting the revert message.
     * A staticcall will revert upon an attempt to modify storage with empty data. Whereas a reenterency will revert
     * early (within the modifier) with a specific revert message. We handle the revert data as follows:
     *
     *       1. If the transaction suceeded we panic as this should never happen
     *       2. If the revert message is empty, indicating the revert was NOT due to a reenterency guard, we return
     * empty data and allow the transfer to continue as this transfer is shown to not occur durring use of the
     * vulnerable contract. It's worth noting this practically ocurrs when a transaction passes the reenterncy guard and
     * fails attempting to query offerAsset decimals(). But this may also ocurr even with a real ERC20 offerAsset
     * contract due to an attempted SSTORE within a static call.
     *       3. If the return data matches the reentrancy guard signature, we revert with a revert message to block this
     * interaction with the vulnerable atomicQueue.
     *       4. If for any reason the call reverted with different revert data, we revert with that data.
     */
    function beforeTransfer(address from) external view override {
        bytes memory payload = abi.encodeCall(
            AtomicQueue.solve, (ERC20(address(0)), ERC20(address(0)), new address[](0), new bytes(0), address(0))
        );

        (bool success, bytes memory returnData) = address(atomicQueue).staticcall{ gas: DERAIL_GAS_STIPEND }(payload);

        assert(!success); // The above call should always fail. Either by a reenterncy or by attempting to SSTORE as a
        // staticcall. There should be no possible path that results in a positive success value

        bool haltedWithoutReverting = returnData.length == 0;
        if (haltedWithoutReverting) return;

        if (keccak256(returnData) != REENTRANCY_REVERT_HASH) {
            revert UseOfInvalidContract(from, address(atomicQueue), returnData);
        }

        revert UnexpectedRevert(from, returnData);
    }
}
