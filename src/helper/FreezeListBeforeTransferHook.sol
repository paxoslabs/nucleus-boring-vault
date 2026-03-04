// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { BeforeTransferHook, BridgeData } from "src/interfaces/BeforeTransferHook.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { Auth, Authority } from "solmate/auth/Auth.sol";

/**
 * @title FreezeListBeforeTransferHook
 * @notice A before transfer hook for the BoringVault that freezes token transfers
 * @dev Hooks are provided for beforeTransfer, beforeBridge and beforeReceiveBridge allowing developers to differentiate
 * between different types of transfers.
 * @custom:security-contact security@molecularlabs.io
 */
contract FreezeListBeforeTransferHook is BeforeTransferHook, Auth {

    mapping(address => bool) public freezeList;

    error FrozenAddress(address frozenAddress);
    error ZeroAddress();

    event FreezeListUpdated(address indexed addressUpdated, bool indexed isFrozen);

    constructor(address owner) Auth(owner, Authority(address(0))) {
        if (owner == address(0)) revert ZeroAddress();
    }

    /**
     * @notice beforeTransfer hook. Applied in BoringVault on transfer and transferFrom
     */
    function beforeTransfer(address from, address to, address msgSender, uint256 amount) external view {
        if (freezeList[from]) revert FrozenAddress(from);
        if (freezeList[to]) revert FrozenAddress(to);
        if (freezeList[msgSender]) revert FrozenAddress(msgSender);
    }

    /**
     * @notice beforeBridge hook. Applied in CrossChainTellerBase on beforeBridge. This is because shares are directly
     * burned and are not subject to the usual beforeTransfer hooks when bridging but we may still want to apply the
     * same or similar rules.
     * @dev Only the msgSender is checked and not the "to" address because the address being bridged to may or may not
     * follow the same freezing rules of this chain. It's not fair to assume that because an address is frozen on this
     * chain, it must also be frozen on another. Take for example, a maliciously deployed contract on this chain to
     * match the address of a trusted one on another.
     */
    function beforeBridge(address msgSender, uint256 shareAmount, BridgeData calldata data) external view {
        if (freezeList[msgSender]) revert FrozenAddress(msgSender);
    }

    /**
     * @notice beforeReceiveBridge hook. Applied in CrossChainTellerBase on beforeReceiveBridge. This is because shares
     * are directly minted and are not subject to the usual beforeTransfer hooks when receiving but we may still want to
     * apply the same or similar rules
     */
    function beforeReceiveBridge(uint256 shareAmount, address destinationChainReceiver) external view {
        if (freezeList[destinationChainReceiver]) revert FrozenAddress(destinationChainReceiver);
    }

    /**
     * @notice setFreezeList function to add or remove addresses in bulk from the freeze list
     * @dev Callable by OWNER_ROLE
     * @dev We update the unfreeze list first so that if an address is in both arrays we prioritize the freeze list.
     */
    function setFreezeList(
        address[] calldata freezeListAddresses,
        address[] calldata unfreezeListAddresses
    )
        external
        requiresAuth
    {
        uint256 length = unfreezeListAddresses.length;
        for (uint256 i; i < unfreezeListAddresses.length;) {
            freezeList[unfreezeListAddresses[i]] = false;
            emit FreezeListUpdated(unfreezeListAddresses[i], false);
            unchecked {
                ++i;
            }
        }

        length = freezeListAddresses.length;
        for (uint256 i; i < length;) {
            freezeList[freezeListAddresses[i]] = true;
            emit FreezeListUpdated(freezeListAddresses[i], true);
            unchecked {
                ++i;
            }
        }
    }

}
