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

        address smartDepositForwarder;

        // Receiver of sanctioned funds
        address recoveryAccount;

        // SmartDepositForwarder: Can call methods on SDA instances (e.g. depositAndForward)
        // Should be a 1/1 Safe where the owner maps to a key in a KMS to allow for easy key rotation.

        // Staging Safe SmartDepositForwarder
        address stagingSmartDepositForwarder = 0xBEFf07A518C51CD98DE81Ce4546c88BEBB120d7E;

        // Prod Safe SmartDepositForwarder
        address prodSmartDepositForwarder = 0x7d77F3f150348a2b4b2a0AED07Ed96ee84172D57;

        // Set FactoryBeaconOwner per chain
        if (block.chainid == 11_155_111) {
            dcdAddress = 0x6c5642bE66014d45A8E2Abf2A0F59455DB1b7843; // Sepolia test DCD address

            // ONLY allow same owner for smartDepositFactoryBeacon as owner of implementation contract on
            // testnet.
            // Live chains should re-use the protocol multisig for given production chain (which should have a
            // multi-signer quorum of at least 3/5, and can be found via the address-book-tui.) This is to limit the
            // risk of a vulnerability allowing an attacker to upgrade to a malicious implementation contract,
            // compromising any forwarded user funds.
            smartDepositFactoryBeaconOwner = smartDepositForwarder;
            smartDepositForwarder = stagingSmartDepositForwarder;
            recoveryAccount = 0xa9bEBCdc3ac382d74bEeA7fbddd9485A610f3aBf;
        } else if (block.chainid == 1) {
            smartDepositFactoryBeaconOwner = 0x0000000000417626Ef34D62C4DC189b021603f2F; // mainnet protocol multisig
            recoveryAccount = 0x0000000000417626Ef34D62C4DC189b021603f2F;
            smartDepositForwarder = prodSmartDepositForwarder;
        } else if (block.chainid == 8453) {
            smartDepositFactoryBeaconOwner = 0xE5a5F3A6C88B894710992e1C2626be0DEB99566E; // base protocol multisig
            recoveryAccount = 0xE5a5F3A6C88B894710992e1C2626be0DEB99566E;
            smartDepositForwarder = prodSmartDepositForwarder;
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
            implSalt, abi.encodePacked(implCreationCode, abi.encode(dcdAddress, smartDepositForwarder, recoveryAccount))
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
        require(SmartDepositAddress(implementation).owner() == smartDepositForwarder, "impl owner mismatch");
        require(
            SmartDepositAddress(implementation).recoveryAccount() == recoveryAccount, "impl recoveryAccount mismatch"
        );

        console.log("SmartDepositAddress implementation:", implementation);
        console.log("SmartDepositFactoryBeacon:", smartDepositFactoryBeacon);
        console.log("SmartDepositFactoryBeacon owner:", SmartDepositFactoryBeacon(smartDepositFactoryBeacon).owner());
    }

}
