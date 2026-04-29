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

        // Can call upgradeTo() to upgrade DTA implementation
        address factoryBeaconOwner; // ethereum protocol owner multisig

        // Receiver of sanctioned funds
        address recoveryAccount = 0xa9bEBCdc3ac382d74bEeA7fbddd9485A610f3aBf;

        // Can call methods on DTA instances (e.g. depositAndForward)
        address implOwner = 0xBEFf07A518C51CD98DE81Ce4546c88BEBB120d7E;

        if (block.chainid == 11_155_111) {
            dcdAddress = 0x6c5642bE66014d45A8E2Abf2A0F59455DB1b7843; // Sepolia test DCD address

            inputToken = ERC20(0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238); // Sepolia test USDC

            // Use same owner for factoryBeacon as implementation contract since it's
            // just testnet. live chains should use a multi-signer multisig reuiqirng 3/5
            // quorum or more to upgrade implementation.
            factoryBeaconOwner = implOwner;
        } else if (block.chainid == 1) {
            factoryBeaconOwner = 0x0000000000417626Ef34D62C4DC189b021603f2F;
        } else {
            revert("unsupported chain; set dcdAddress, inputToken, and factoryBeaconOwner for this chainid");
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
        bytes memory implCreationCode = type(DirectTransferAddress).creationCode;
        address implementation = CREATEX.deployCreate3(
            implSalt, abi.encodePacked(implCreationCode, abi.encode(dcdAddress, implOwner, recoveryAccount, inputToken))
        );

        // Deploy FactoryBeacon via CREATEX for consistent cross-chain address
        bytes memory factoryBeaconCreationCode = type(FactoryBeacon).creationCode;
        address factoryBeacon = CREATEX.deployCreate3(
            factoryBeaconSalt,
            abi.encodePacked(factoryBeaconCreationCode, abi.encode(implementation, factoryBeaconOwner))
        );

        require(implementation.code.length > 0, "impl not deployed");
        require(factoryBeacon.code.length > 0, "factoryBeacon not deployed");
        require(FactoryBeacon(factoryBeacon).implementation() == implementation, "factoryBeacon impl mismatch");
        require(FactoryBeacon(factoryBeacon).owner() == factoryBeaconOwner, "factoryBeacon owner mismatch");
        require(address(DirectTransferAddress(implementation).token()) == address(inputToken), "impl token mismatch");
        require(address(DirectTransferAddress(implementation).DCD()) == dcdAddress, "impl dcd mismatch");
        require(DirectTransferAddress(implementation).owner() == implOwner, "impl owner mismatch");
        require(
            DirectTransferAddress(implementation).recoveryAccount() == recoveryAccount, "impl recoveryAccount mismatch"
        );

        console.log("DirectTransferAddress implementation:", implementation);
        console.log("  token:", address(inputToken));
        console.log("FactoryBeacon:", factoryBeacon);
        console.log("FactoryBeacon owner:", FactoryBeacon(factoryBeacon).owner());
    }

}
