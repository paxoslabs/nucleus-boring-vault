// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { BridgeData } from "src/base/Roles/CrossChain/CrossChainTellerBase.sol";

interface BeforeTransferHook {

    function beforeTransfer(address from, address to, address msgSender, uint256 amount) external view;
    function beforeBridge(address msgSender, uint256 shareAmount, BridgeData calldata data) external view;
    function beforeReceiveBridge(uint256 shareAmount, address destinationChainReceiver) external view;

}
