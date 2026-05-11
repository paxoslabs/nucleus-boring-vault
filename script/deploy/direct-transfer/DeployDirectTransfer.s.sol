// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { console } from "forge-std/console.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { BaseScript } from "script/Base.s.sol";
import { DirectTransferAddress } from "src/direct-transfer/DirectTransferAddress.sol";
import { DirectTransferFactoryBeacon } from "src/direct-transfer/DirectTransferFactoryBeacon.sol";

/**
 * @notice Due to CREATEX deployments, manual verification post-deployment is required.
 *         Save the deployed contract addresses from the logs and verify them with `forge verify-contract`.
 *         Example:
 *         `forge verify-contract --watch --chain sepolia \
 *             <DirectTransferFactoryBeacon address> \
 *             src/direct-transfer/DirectTransferFactoryBeacon.sol:DirectTransferFactoryBeacon \
 *             --verifier etherscan --etherscan-api-key <etherscan api key>`
 *         `forge verify-contract --watch --chain sepolia \
 *             <DirectTransferAddress implementation address> \
 *             src/direct-transfer/DirectTransferAddress.sol:DirectTransferAddress \
 *             --verifier etherscan --etherscan-api-key <etherscan api key>`
 *         After deploying, make sure to update database with newly deployed DirectTransferFactoryBeacon so offchain
 * systems know
 *         which contract to use to deploy new Direct Transfer Address proxies with.
 */
contract DeployDirectTransfer is BaseScript {

    function run() external broadcast {
        address dcdAddress;

        // Can call upgradeTo() to upgrade DTA implementation
        address directTransferFactoryBeaconOwner; // ethereum protocol owner multisig

        // Receiver of sanctioned funds
        address recoveryAccount = 0xa9bEBCdc3ac382d74bEeA7fbddd9485A610f3aBf;

        // Can call methods on DTA instances (e.g. depositAndForward)
        address implOwner = 0xBEFf07A518C51CD98DE81Ce4546c88BEBB120d7E;

        if (block.chainid == 11_155_111) {
            dcdAddress = 0x6c5642bE66014d45A8E2Abf2A0F59455DB1b7843; // Sepolia test DCD address

            // Use same owner for directTransferFactoryBeacon as implementation contract since it's
            // just testnet. live chains should use a multi-signer multisig reuiqirng 3/5
            // quorum or more to upgrade implementation.
            directTransferFactoryBeaconOwner = implOwner;
        } else if (block.chainid == 1) {
            directTransferFactoryBeaconOwner = 0x0000000000417626Ef34D62C4DC189b021603f2F;
        } else {
            revert("unsupported chain; set dcdAddress and directTransferFactoryBeaconOwner for this chainid");
        }

        bytes32 implSalt;
        bytes32 directTransferFactoryBeaconSalt;
        {
            string memory dcdAddrString = Strings.toHexString(dcdAddress);

            // isCrosschainProtected=false because we want the same implementation and DirectTransferFactoryBeacon
            // addresses across all chains. DCD address is added so deploys with different inputs land at distinct
            // addresses. "v1" in
            // implementation salt so there's a clear upgrade path (next version would be "v2").
            implSalt = makeSalt(
                broadcaster, false, string.concat("DirectTransferAddress:implementation:v1:", dcdAddrString)
            );

            directTransferFactoryBeaconSalt = makeSalt(
                broadcaster, false, string.concat("DirectTransferAddress:DirectTransferFactoryBeacon:", dcdAddrString)
            );
        }

        // Deploy implementation via CREATEX for consistent cross-chain address
        bytes memory implCreationCode = type(DirectTransferAddress).creationCode;
        address implementation = CREATEX.deployCreate3(
            implSalt, abi.encodePacked(implCreationCode, abi.encode(dcdAddress, implOwner, recoveryAccount))
        );

        // Deploy DirectTransferFactoryBeacon via CREATEX for consistent cross-chain address
        bytes memory directTransferFactoryBeaconCreationCode = type(DirectTransferFactoryBeacon).creationCode;
        address directTransferFactoryBeacon = CREATEX.deployCreate3(
            directTransferFactoryBeaconSalt,
            abi.encodePacked(
                directTransferFactoryBeaconCreationCode, abi.encode(implementation, directTransferFactoryBeaconOwner)
            )
        );

        require(implementation.code.length > 0, "impl not deployed");
        require(directTransferFactoryBeacon.code.length > 0, "directTransferFactoryBeacon not deployed");
        require(
            DirectTransferFactoryBeacon(directTransferFactoryBeacon).implementation() == implementation,
            "directTransferFactoryBeacon impl mismatch"
        );
        require(
            DirectTransferFactoryBeacon(directTransferFactoryBeacon).owner() == directTransferFactoryBeaconOwner,
            "directTransferFactoryBeacon owner mismatch"
        );
        require(address(DirectTransferAddress(implementation).DCD()) == dcdAddress, "impl dcd mismatch");
        require(DirectTransferAddress(implementation).owner() == implOwner, "impl owner mismatch");
        require(
            DirectTransferAddress(implementation).recoveryAccount() == recoveryAccount, "impl recoveryAccount mismatch"
        );

        console.log("DirectTransferAddress implementation:", implementation);
        console.log("DirectTransferFactoryBeacon:", directTransferFactoryBeacon);
        console.log(
            "DirectTransferFactoryBeacon owner:", DirectTransferFactoryBeacon(directTransferFactoryBeacon).owner()
        );
    }

}
