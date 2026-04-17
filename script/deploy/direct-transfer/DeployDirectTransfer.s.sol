// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { console } from "forge-std/console.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
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

        // The stablecoin this implementation+beacon handles. To support another stablecoin
        // (e.g. USDT) deploy a second impl+beacon with a different value here; the salt labels
        // below mix in the token address so the resulting addresses don't collide.
        // mainnet usdc: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
        // our sepolia test usdc: 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238
        ERC20 inputToken = ERC20(0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238);
        string memory tokenLabel = Strings.toHexString(address(inputToken));

        // isCrosschainProtected=false because we want the same implementation and FactoryBeacon addresses across all
        // chains. Token address is mixed in so USDC and USDT deploys land at distinct addresses.
        bytes32 implSalt =
            makeSalt(broadcaster, false, string.concat("DirectTransferAddress:implementation:", tokenLabel));
        bytes32 beaconSalt =
            makeSalt(broadcaster, false, string.concat("DirectTransferAddress:FactoryBeacon:", tokenLabel));

        // Deploy implementation via CREATEX for consistent cross-chain address
        bytes memory implCreationCode = type(DirectTransferAddress).creationCode;
        address implementation = CREATEX.deployCreate3(
            implSalt, abi.encodePacked(implCreationCode, abi.encode(dcdAddress, implOwner, recoveryAccount, inputToken))
        );

        // Deploy FactoryBeacon via CREATEX for consistent cross-chain address
        bytes memory beaconCreationCode = type(FactoryBeacon).creationCode;
        address beacon = CREATEX.deployCreate3(
            beaconSalt, abi.encodePacked(beaconCreationCode, abi.encode(implementation, beaconOwner))
        );

        console.log("DirectTransferAddress implementation:", implementation);
        console.log("  token:", address(inputToken));
        console.log("FactoryBeacon:", beacon);
        console.log("FactoryBeacon owner:", FactoryBeacon(beacon).owner());
    }

}
