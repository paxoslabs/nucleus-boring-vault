// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

interface BeforeTransferHook {

    error InvalidSelector(bytes4 selector);

    function beforeTransfer(address sender, bytes calldata data) external view;

}
