// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { BeforeTransferHook } from "src/interfaces/BeforeTransferHook.sol";

contract FreezeListBeforeTransferHook is BeforeTransferHook {

    mapping(address => bool) public freezeList;

    error FrozenAddress(address from);

    function setFreezeList(address[] calldata addresses, bool isFrozen) external {
        uint256 length = addresses.length;
        for (uint256 i; i < length;) {
            freezeList[addresses[i]] = isFrozen;
            unchecked {
                ++i;
            }
        }
    }

    function beforeTransfer(address from) external view override {
        if (freezeList[from]) revert FrozenAddress(from);
    }

}
