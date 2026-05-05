// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { BaseScript } from "../Base.s.sol";
import { FreezeListBeforeTransferHook } from "src/helper/FreezeListBeforeTransferHook.sol";
import { console } from "@forge-std/console.sol";

/**
 * @notice Standalone deploy of `FreezeListBeforeTransferHook` with a caller-provided salt.
 */
contract DeployBeforeTransferHook is BaseScript {

    function run() public broadcast returns (address) {
        bytes32 salt = 0x1ab5a40491925cb445fd59e607330046beac68e500b765d39dbd6371a4f596f9;

        bytes memory creationCode = type(FreezeListBeforeTransferHook).creationCode;
        address hook = CREATEX.deployCreate3(salt, abi.encodePacked(creationCode, abi.encode(broadcaster)));

        require(FreezeListBeforeTransferHook(hook).owner() == broadcaster, "owner mismatch");

        console.log("FreezeListBeforeTransferHook: ", hook);
        return hook;
    }

}
