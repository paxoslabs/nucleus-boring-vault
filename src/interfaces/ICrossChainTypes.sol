// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { ERC20 } from "@solmate/tokens/ERC20.sol";

/**
 * @notice Shared cross-chain struct types used across CrossChainTellerBase,
 * MultiChainTellerBase, and BeforeTransferHook. Defined here to avoid circular
 * imports between those files.
 */

struct BridgeData {
    uint32 chainSelector;
    address destinationChainReceiver;
    ERC20 bridgeFeeToken;
    uint64 messageGas;
    bytes data;
}

struct Chain {
    bool allowMessagesFrom;
    bool allowMessagesTo;
    address targetTeller;
    uint64 messageGasLimit;
    uint64 minimumMessageGas;
}
