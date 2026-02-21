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

    event FreezeListUpdated(address indexed addressUpdated, bool isFrozen);

    constructor(address owner) Auth(owner, Authority(address(0))) { }

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
     * same or similar rules
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
     */
    function setFreezeList(address[] calldata addresses, bool isFrozen) external requiresAuth {
        uint256 length = addresses.length;
        for (uint256 i; i < length;) {
            freezeList[addresses[i]] = isFrozen;
            emit FreezeListUpdated(addresses[i], isFrozen);
            unchecked {
                ++i;
            }
        }
    }

}
