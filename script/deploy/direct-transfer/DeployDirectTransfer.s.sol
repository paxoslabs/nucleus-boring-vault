// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { console } from "forge-std/console.sol";
import { BaseScript } from "script/Base.s.sol";
import { DistributorCodeDepositor } from "src/helper/DistributorCodeDepositor.sol";
import { DirectTransferAddress2 } from "src/direct-transfer/DirectTransferAddress2.sol";
import { FactoryBeacon } from "src/direct-transfer/FactoryBeacon.sol";
import { SimpleBeaconProxy } from "src/direct-transfer/SimpleBeaconProxy.sol";

contract DeployDirectTransfer is BaseScript {

    function run() external broadcast {
        // sepolia dcd address from here:
        // https://paxoslabs.slack.com/archives/C09E8FBMA3T/p1774381184792619?thread_ts=1774378030.319969&cid=C09E8FBMA3T
        address dcdAddress = address(0x6c5642bE66014d45A8E2Abf2A0F59455DB1b7843);
        address beaconOwner = broadcaster;
        address proxyReceiver = broadcaster;

        DirectTransferAddress2 implementation = new DirectTransferAddress2(DistributorCodeDepositor(dcdAddress));
        FactoryBeacon beacon = new FactoryBeacon(address(implementation), beaconOwner);
        bytes memory initData = abi.encodeWithSelector(DirectTransferAddress2.initialize.selector, proxyReceiver);

        console.log("DirectTransferAddress2 implementation:", address(implementation));
        console.log("FactoryBeacon:", address(beacon));
        console.log("FactoryBeacon owner:", beacon.owner());
    }

}
