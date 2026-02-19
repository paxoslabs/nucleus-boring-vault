// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { BeforeTransferHook } from "src/interfaces/BeforeTransferHook.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";

contract FreezeListBeforeTransferHook is BeforeTransferHook {

    mapping(address => bool) public freezeList;

    error FrozenAddress(address frozenAddress);

    function setFreezeList(address[] calldata addresses, bool isFrozen) external {
        uint256 length = addresses.length;
        for (uint256 i; i < length;) {
            freezeList[addresses[i]] = isFrozen;
            unchecked {
                ++i;
            }
        }
    }

    function beforeTransfer(address sender, bytes calldata data) external view override {
        if (bytes4(data[0:4]) == ERC20.transfer.selector) {
            // First word of data after selctor is the address
            address to = abi.decode(data[4:36], (address));
            if (freezeList[to]) revert FrozenAddress(to);
            if (freezeList[sender]) revert FrozenAddress(sender);
        } else if (bytes4(data[0:4]) == ERC20.transferFrom.selector) {
            address from = abi.decode(data[4:36], (address));
            address to = abi.decode(data[36:68], (address));
            if (freezeList[from]) revert FrozenAddress(from);
            if (freezeList[to]) revert FrozenAddress(from);
        } else {
            revert InvalidSelector(bytes4(data[0:4]));
        }
    }

}
