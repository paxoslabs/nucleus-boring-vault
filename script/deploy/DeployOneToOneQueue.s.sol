// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { BaseScript } from "../Base.s.sol";
import "@forge-std/Script.sol";
import { OneToOneQueue } from "src/helper/one-to-one-queue/OneToOneQueue.sol";
import { QueueAccessAuthority } from "src/helper/one-to-one-queue/QueueAccessAuthority.sol";
import { SimpleFeeModule } from "src/helper/SimpleFeeModule.sol";

contract DeployOneToOneQueue is BaseScript {

    address owner = getMultisig();
    uint256 constant OFFER_FEE_PERCENTAGE = 2; // 0.02% FEE
    string constant QUEUE_ERC721_NAME = "USDG Queue";
    string constant QUEUE_ERC721_SYMBOL = "USDGQ";
    address constant OFFER_ASSET_RECIPIENT = 0x2E30A79590cc4BDE82e7187cD2CAAdAC8e2D0f85; // the boring vault address
    address FEE_RECIPIENT = getMultisig(); // the address to send fees to

    address constant PAUSE_CONTRACT = 0x858d3eE2a16F7B6E43C8D87a5E1F595dE32f4419;
    address constant PAUSE_EOA = 0xe5CcB29Cb9C886da329098A184302E2D5Ff0cD9E;
    address[] PAUSERS = [PAUSE_CONTRACT, PAUSE_EOA];

    bytes32 constant SALT_FEE_MODULE = 0x1Ab5a40491925cB445fd59e607330046bEac68E500937845393939393924fe11;
    bytes32 constant SALT_ONE_TO_ONE_QUEUE = 0x1Ab5a40491925cB445fd59e607330046bEac68E5009378453978cd3939222212;
    bytes32 constant SALT_QUEUE_ACCESS_AUTHORITY = 0x1Ab5a40491925cB445fd59e607330046bEac68E50094ab253939393939222213;

    function run() external broadcast {
        // Deploy the Fee Module
        bytes memory feeModuleCreationCode = type(SimpleFeeModule).creationCode;
        address feeModule = CREATEX.deployCreate3(
            SALT_FEE_MODULE, abi.encodePacked(feeModuleCreationCode, abi.encode(OFFER_FEE_PERCENTAGE))
        );
        console.log("Fee module deployed at: ", feeModule);

        // Deploy the OneToOneQueue
        // NOTE: the recovery address is set to the owner multisig
        bytes memory oneToOneQueueCreationCode = type(OneToOneQueue).creationCode;
        address oneToOneQueue = CREATEX.deployCreate3(
            SALT_ONE_TO_ONE_QUEUE,
            abi.encodePacked(
                oneToOneQueueCreationCode,
                abi.encode(
                    QUEUE_ERC721_NAME,
                    QUEUE_ERC721_SYMBOL,
                    OFFER_ASSET_RECIPIENT,
                    FEE_RECIPIENT,
                    feeModule,
                    owner,
                    owner
                )
            )
        );
        console.log("OneToOneQueue deployed at: ", oneToOneQueue);

        bytes memory queueAccessAuthorityCreationCode = type(QueueAccessAuthority).creationCode;
        address queueAccessAuthority = CREATEX.deployCreate3(
            SALT_QUEUE_ACCESS_AUTHORITY,
            abi.encodePacked(queueAccessAuthorityCreationCode, abi.encode(owner, oneToOneQueue, PAUSERS))
        );
        console.log("Queue access authority deployed at: ", queueAccessAuthority);

        console.log("Next Steps: ");
        console.log("1. Multisig queue.setAuthority(queueAccessAuthority);");
        console.log("2. Multisig queue.addOfferAsset(offerAsset) and queue.addWantAsset...");
    }

}
