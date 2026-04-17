// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { console } from "forge-std/console.sol";
import { BaseScript } from "script/Base.s.sol";
import { DistributorCodeDepositor } from "src/helper/DistributorCodeDepositor.sol";
import { DirectTransferAddress } from "src/direct-transfer/DirectTransferAddress.sol";
import { FactoryBeacon } from "src/direct-transfer/FactoryBeacon.sol";
import { SimpleBeaconProxy } from "src/direct-transfer/SimpleBeaconProxy.sol";

contract DeployDirectTransfer is BaseScript {

    function run() external broadcast {
        // sepolia dcd address from here:
        // https://paxoslabs.slack.com/archives/C09E8FBMA3T/p1774381184792619?thread_ts=1774378030.319969&cid=C09E8FBMA3T
        address dcdAddress = address(0x6c5642bE66014d45A8E2Abf2A0F59455DB1b7843);
        address beaconOwner = broadcaster;
        address implOwner = beaconOwner;
        // TODO: replace with a multisig before production use.
        address recoveryAccount = broadcaster;

        // isCrosschainProtected=false because we want the same implementation and FactoryBeacon addresses across all
        // chains
        bytes32 implSalt = makeSalt(broadcaster, false, "DirectTransferAddress:implementation");
        bytes32 beaconSalt = makeSalt(broadcaster, false, "DirectTransferAddress:FactoryBeacon");

        // Deploy implementation via CREATEX for consistent cross-chain address
        bytes memory implCreationCode = type(DirectTransferAddress).creationCode;
        address implementation = CREATEX.deployCreate3(
            implSalt, abi.encodePacked(implCreationCode, abi.encode(dcdAddress, implOwner, recoveryAccount))
        );

        // Deploy FactoryBeacon via CREATEX for consistent cross-chain address
        bytes memory beaconCreationCode = type(FactoryBeacon).creationCode;
        address beacon = CREATEX.deployCreate3(
            beaconSalt, abi.encodePacked(beaconCreationCode, abi.encode(implementation, beaconOwner))
        );

        console.log("DirectTransferAddress implementation:", implementation);
        console.log("FactoryBeacon:", beacon);
        console.log("FactoryBeacon owner:", FactoryBeacon(beacon).owner());
    }

}
