// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { BoringVault } from "src/base/BoringVault.sol";
import { BaseScript } from "script/Base.s.sol";
import { ConfigReader } from "script/ConfigReader.s.sol";
import { stdJson as StdJson } from "@forge-std/StdJson.sol";
import { FreezeListBeforeTransferHook } from "src/helper/FreezeListBeforeTransferHook.sol";
import { console } from "@forge-std/console.sol";

contract DeployFreezeListBeforeTransferHookScript is BaseScript {

    using StdJson for string;

    function run() public returns (address) {
        return deploy(getConfig());
    }

    function _deploy(ConfigReader.Config memory config) public override broadcast returns (address) {
        // Require config Values
        require(config.boringVault != address(0), "boringVault must not be zero address");
        require(config.boringVault.code.length != 0, "boringVault must have code");

        // only deploy a freeze list hook IF one is not already provided. This will probably only happen if deploying on
        // a new chain.
        if (config.beforeTransferHookAddress == address(0)) {
            console.log("03_DeployFreezeListBeforeTransferHook: NO HOOK PROVIDED: Deploying new hook...");
            bytes32 freezeListBeforeTransferHookSalt = makeSalt(
                broadcaster, false, string(abi.encodePacked(config.nameEntropy, ":FreezeListBeforeTransferHook"))
            );

            // Create Contract
            bytes memory creationCode = type(FreezeListBeforeTransferHook).creationCode;
            address freezeListBeforeTransferHook = CREATEX.deployCreate3(
                freezeListBeforeTransferHookSalt, abi.encodePacked(creationCode, abi.encode(broadcaster))
            );

            // Set the hook on the BoringVault
            BoringVault(payable(config.boringVault)).setBeforeTransferHook(freezeListBeforeTransferHook);
            console.log("New Before Transfer Hook Address: ", freezeListBeforeTransferHook);

            config.beforeTransferHookAddress = freezeListBeforeTransferHook;
            require(
                FreezeListBeforeTransferHook(config.beforeTransferHookAddress).owner() == broadcaster,
                "Freeze List should have admin set to deployer at deployment"
            );
        } else {
            require(
                FreezeListBeforeTransferHook(config.beforeTransferHookAddress).owner() == config.protocolAdmin,
                "The provided freezeListBeforeTransferHook's owner does not match the provided protocolAdmin"
            );
            // if one is provided configure it
            BoringVault(payable(config.boringVault)).setBeforeTransferHook(config.beforeTransferHookAddress);
        }

        // Post Deploy Checks
        require(
            address(BoringVault(payable(config.boringVault)).hook()) == config.beforeTransferHookAddress,
            "BoringVault must have freeze hook"
        );
        return config.beforeTransferHookAddress;
    }

}
