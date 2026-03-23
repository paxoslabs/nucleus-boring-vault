// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

interface IFallbackHook {

    function onFallback(address sender, bytes calldata data) external payable returns (bytes memory);

}
