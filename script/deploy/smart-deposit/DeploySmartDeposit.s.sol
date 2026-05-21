// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { console } from "forge-std/console.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { BaseScript } from "script/Base.s.sol";
import { SmartDepositAddress } from "src/smart-deposit/SmartDepositAddress.sol";
import { SmartDepositFactoryBeacon } from "src/smart-deposit/SmartDepositFactoryBeacon.sol";

/**
 * @notice Due to CREATEX deployments, manual verification post-deployment is required.
 *         Save the deployed contract addresses from the logs and verify them with `forge verify-contract`.
 *         Example:
 *         `forge verify-contract --watch --chain sepolia \
 *             <SmartDepositFactoryBeacon address> \
 *             src/smart-deposit/SmartDepositFactoryBeacon.sol:SmartDepositFactoryBeacon \
 *             --verifier etherscan --etherscan-api-key <etherscan api key>`
 *         `forge verify-contract --watch --chain sepolia \
 *             <SmartDepositAddress implementation address> \
 *             src/smart-deposit/SmartDepositAddress.sol:SmartDepositAddress \
 *             --verifier etherscan --etherscan-api-key <etherscan api key>`
 *         After deploying, make sure to update the `paxoslabs` database with the newly deployed
 *         SmartDepositFactoryBeacon so offchain systems know which contract to use to
 *         deploy new Smart Deposit Address proxies with. The `insert_smart_deposit_module.sql`
 *         script in the `backend-v2` project should be used for this.
 */
contract DeploySmartDeposit is BaseScript {

    function run() external broadcast {
        address dcdAddress;

        // Can call upgradeTo() to upgrade SDA implementation
        address smartDepositFactoryBeaconOwner; // ethereum protocol owner multisig

        // Receiver of sanctioned funds
        address recoveryAccount = 0xa9bEBCdc3ac382d74bEeA7fbddd9485A610f3aBf;

        // SmartDepositOwnerAndForwarder: Can call methods on SDA instances (e.g. depositAndForward)
        // Should be a 1/1 Safe to allow for easy key rotation + transaction batching.

        // Staging Safe
        address stagingSmartDepositOwnerAndForwarder = 0xBEFf07A518C51CD98DE81Ce4546c88BEBB120d7E;

        // Prod Safe
        address prodSmartDepositOwnerAndForwarder = 0x5e4ff2d30A9f1Dd7E6ef666cF774841295c3b5D1;

        address smartDepositOwnerAndForwarder = stagingSmartDepositOwnerAndForwarder;

        if (block.chainid == 11_155_111) {
            dcdAddress = 0x6c5642bE66014d45A8E2Abf2A0F59455DB1b7843; // Sepolia test DCD address

            // Use same owner for smartDepositFactoryBeacon as implementation contract since it's
            // just testnet. live chains should use a multi-signer multisig reuiqirng 3/5
            // quorum or more to upgrade implementation.
            smartDepositFactoryBeaconOwner = smartDepositOwnerAndForwarder;
        } else if (block.chainid == 1) {
            // Only allow protocol multi-sig owner to upgrade implementations on mainnet
            smartDepositFactoryBeaconOwner = 0x0000000000417626Ef34D62C4DC189b021603f2F;
        } else {
            revert("unsupported chain; set dcdAddress and smartDepositFactoryBeaconOwner for this chainid");
        }

        bytes32 implSalt;
        bytes32 smartDepositFactoryBeaconSalt;
        {
            string memory dcdAddrString = Strings.toHexString(dcdAddress);

            // isCrosschainProtected=false because we want the same implementation and SmartDepositFactoryBeacon
            // addresses across all chains. DCD address is added so deploys with different inputs land at distinct
            // addresses. "v1" in
            // implementation salt so there's a clear upgrade path (next version would be "v2").
            implSalt =
                makeSalt(broadcaster, false, string.concat("SmartDepositAddress:implementation:v1:", dcdAddrString));

            smartDepositFactoryBeaconSalt = makeSalt(
                broadcaster, false, string.concat("SmartDepositAddress:SmartDepositFactoryBeacon:", dcdAddrString)
            );
        }

        // Deploy implementation via CREATEX for consistent cross-chain address
        bytes memory implCreationCode = type(SmartDepositAddress).creationCode;
        address implementation = CREATEX.deployCreate3(
            implSalt,
            abi.encodePacked(implCreationCode, abi.encode(dcdAddress, smartDepositOwnerAndForwarder, recoveryAccount))
        );

        // Deploy SmartDepositFactoryBeacon via CREATEX for consistent cross-chain address
        bytes memory smartDepositFactoryBeaconCreationCode = type(SmartDepositFactoryBeacon).creationCode;
        address smartDepositFactoryBeacon = CREATEX.deployCreate3(
            smartDepositFactoryBeaconSalt,
            abi.encodePacked(
                smartDepositFactoryBeaconCreationCode, abi.encode(implementation, smartDepositFactoryBeaconOwner)
            )
        );

        require(implementation.code.length > 0, "impl not deployed");
        require(smartDepositFactoryBeacon.code.length > 0, "smartDepositFactoryBeacon not deployed");
        require(
            SmartDepositFactoryBeacon(smartDepositFactoryBeacon).implementation() == implementation,
            "smartDepositFactoryBeacon impl mismatch"
        );
        require(
            SmartDepositFactoryBeacon(smartDepositFactoryBeacon).owner() == smartDepositFactoryBeaconOwner,
            "smartDepositFactoryBeacon owner mismatch"
        );
        require(address(SmartDepositAddress(implementation).DCD()) == dcdAddress, "impl dcd mismatch");
        require(SmartDepositAddress(implementation).owner() == smartDepositOwnerAndForwarder, "impl owner mismatch");
        require(
            SmartDepositAddress(implementation).recoveryAccount() == recoveryAccount, "impl recoveryAccount mismatch"
        );

        console.log("SmartDepositAddress implementation:", implementation);
        console.log("SmartDepositFactoryBeacon:", smartDepositFactoryBeacon);
        console.log("SmartDepositFactoryBeacon owner:", SmartDepositFactoryBeacon(smartDepositFactoryBeacon).owner());
    }

}
