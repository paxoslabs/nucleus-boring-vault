// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { console } from "forge-std/console.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { BaseScript } from "script/Base.s.sol";
import { DistributorCodeDepositor } from "src/helper/DistributorCodeDepositor.sol";
import { DirectTransferAddress } from "src/direct-transfer/DirectTransferAddress.sol";
import { FactoryBeacon } from "src/direct-transfer/FactoryBeacon.sol";

/**
 * @notice Due to CREATEX deployments, manual verification post-deployment is required.
 *         Save the deployed contract addresses from the logs and verify them with `forge verify-contract`.
 *         Example:
 *         `forge verify-contract --watch --chain sepolia \
 *             <FactoryBeacon address> \
 *             src/direct-transfer/FactoryBeacon.sol:FactoryBeacon \
 *             --verifier etherscan --etherscan-api-key <etherscan api key>`
 *         `forge verify-contract --watch --chain sepolia \
 *             <DirectTransferAddress implementation address> \
 *             src/direct-transfer/DirectTransferAddress.sol:DirectTransferAddress \
 *             --verifier etherscan --etherscan-api-key <etherscan api key>`
 *         After deploying, make sure to update database with newly deployed FactoryBeacon so offchain systems know
 *         which contract to use to deploy new Direct Transfer Address proxies with.
 */
contract DeployDirectTransfer is BaseScript {

    function run() external broadcast {
        address dcdAddress;
        ERC20 inputToken;
        if (block.chainid == 11_155_111) {
            // Sepolia test vault DCD address from here:
            dcdAddress = 0x6c5642bE66014d45A8E2Abf2A0F59455DB1b7843;
            inputToken = ERC20(0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238); // sepolia test USDC
        } else {
            revert("unsupported chain; add dcd + inputToken for this chainid");
        }

        bytes32 implSalt;
        bytes32 factoryBeaconSalt;
        {
            string memory tokenAddrString = Strings.toHexString(address(inputToken));
            string memory dcdAddrString = Strings.toHexString(dcdAddress);

            // isCrosschainProtected=false because we want the same implementation and FactoryBeacon addresses across
            // all chains. Token and DCD addresses are added in so deploys with different inputs land at distinct
            // addresses. "v1" in implementation salt so there's a clear upgrade path (next version would be "v2").
            implSalt = makeSalt(
                broadcaster,
                false,
                string.concat("DirectTransferAddress:implementation:v1:", tokenAddrString, ":", dcdAddrString)
            );

            factoryBeaconSalt = makeSalt(
                broadcaster,
                false,
                string.concat("DirectTransferAddress:FactoryBeacon:", tokenAddrString, ":", dcdAddrString)
            );
        }

        // Deploy implementation via CREATEX for consistent cross-chain address
        address recoveryAccount = 0xa9bEBCdc3ac382d74bEeA7fbddd9485A610f3aBf;
        address implOwner = 0xBEFf07A518C51CD98DE81Ce4546c88BEBB120d7E;
        bytes memory implCreationCode = type(DirectTransferAddress).creationCode;
        address implementation = CREATEX.deployCreate3(
            implSalt, abi.encodePacked(implCreationCode, abi.encode(dcdAddress, implOwner, recoveryAccount, inputToken))
        );

        // Deploy FactoryBeacon via CREATEX for consistent cross-chain address
        address beaconOwner = implOwner;
        bytes memory beaconCreationCode = type(FactoryBeacon).creationCode;
        address beacon = CREATEX.deployCreate3(
            factoryBeaconSalt, abi.encodePacked(beaconCreationCode, abi.encode(implementation, beaconOwner))
        );

        require(implementation.code.length > 0, "impl not deployed");
        require(beacon.code.length > 0, "beacon not deployed");
        require(FactoryBeacon(beacon).implementation() == implementation, "beacon impl mismatch");
        require(FactoryBeacon(beacon).owner() == beaconOwner, "beacon owner mismatch");
        require(address(DirectTransferAddress(implementation).token()) == address(inputToken), "impl token mismatch");
        require(address(DirectTransferAddress(implementation).DCD()) == dcdAddress, "impl dcd mismatch");
        require(DirectTransferAddress(implementation).owner() == implOwner, "impl owner mismatch");
        require(
            DirectTransferAddress(implementation).recoveryAccount() == recoveryAccount, "impl recoveryAccount mismatch"
        );

        console.log("DirectTransferAddress implementation:", implementation);
        console.log("  token:", address(inputToken));
        console.log("FactoryBeacon:", beacon);
        console.log("FactoryBeacon owner:", FactoryBeacon(beacon).owner());
    }

}
