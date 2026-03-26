// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { BoringVault } from "src/base/BoringVault.sol";
import { BaseScript } from "script/Base.s.sol";
import { ConfigReader } from "script/ConfigReader.s.sol";
import { stdJson as StdJson } from "@forge-std/StdJson.sol";
import { FreezeListBeforeTransferHook } from "src/helper/FreezeListBeforeTransferHook.sol";

contract DeployFreezeListBeforeTransferHookScript is BaseScript {

    using StdJson for string;

    function run() public returns (address) {
        return deploy(getConfig());
    }

    function _deploy(ConfigReader.Config memory config) public override broadcast returns (address) {
        // Require config Values
        require(config.boringVault != address(0), "boringVault must not be zero address");
        require(config.boringVault.code.length != 0, "boringVault must have code");

        bytes32 freezeListBeforeTransferHookSalt =
            makeSalt(broadcaster, false, string(abi.encodePacked(config.nameEntropy, ":FreezeListBeforeTransferHook")));

        // Create Contract
        bytes memory creationCode = type(FreezeListBeforeTransferHook).creationCode;
        address freezeListBeforeTransferHook = CREATEX.deployCreate3(
            freezeListBeforeTransferHookSalt, abi.encodePacked(creationCode, abi.encode(broadcaster))
        );

        // Set the hook on the BoringVault
        BoringVault(payable(config.boringVault)).setBeforeTransferHook(freezeListBeforeTransferHook);

        // Post Deploy Checks
        require(
            address(BoringVault(payable(config.boringVault)).hook()) == freezeListBeforeTransferHook,
            "BoringVault must have freeze hook"
        );
        require(
            FreezeListBeforeTransferHook(freezeListBeforeTransferHook).owner() == broadcaster,
            "Freeze List should have admin set to deployer at deployment"
        );

        return freezeListBeforeTransferHook;
    }

}
