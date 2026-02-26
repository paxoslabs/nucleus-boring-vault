// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { BaseScript } from "./../../Base.s.sol";
import { stdJson as StdJson } from "@forge-std/StdJson.sol";
import { ConfigReader, IAuthority } from "../../ConfigReader.s.sol";
import { SimpleFeeModule, IFeeModule } from "src/helper/SimpleFeeModule.sol";
import { WithdrawQueue } from "src/base/Roles/WithdrawQueue.sol";
import { RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";
import "src/helper/Constants.sol";

/**
 * Deploy the Withdraw Queue and Fee Module
 */
contract DeployWithdrawQueueAndFeeModule is BaseScript {

    using StdJson for string;

    function run() public {
        deploy(getConfig());
    }

    function deploy(ConfigReader.Config memory config) public override broadcast returns (address) {
        require(
            keccak256(bytes(config.withdrawQueueName)) != keccak256(bytes("")), "withdrawQueueName must not be empty"
        );
        require(
            keccak256(bytes(config.withdrawQueueSymbol)) != keccak256(bytes("")),
            "withdrawQueueSymbol must not be empty"
        );
        require(
            config.withdrawQueueFeeRecipient == config.protocolAdmin,
            "withdrawQueueFeeRecipient must be the protocol admin"
        );
        require(config.teller != address(0), "teller must not be zero address");
        require(
            config.withdrawQueueProcessorAddress != address(0), "withdrawQueueProcessorAddress must not be zero address"
        );
        address feeModule;
        {
            // Deploy the Fee Module
            bytes32 feeModuleSalt =
                makeSalt(broadcaster, false, string(abi.encodePacked(config.nameEntropy, ":SimpleFeeModule")));
            bytes memory feeModuleCreationCode = type(SimpleFeeModule).creationCode;
            feeModule = CREATEX.deployCreate3(
                feeModuleSalt, abi.encodePacked(feeModuleCreationCode, abi.encode(config.withdrawQueueFeePercentage))
            );
        }
        // Deploy the Withdraw Queue
        bytes32 withdrawQueueSalt =
            makeSalt(broadcaster, false, string(abi.encodePacked(config.nameEntropy, ":WithdrawQueue")));
        bytes memory withdrawQueueCreationCode = type(WithdrawQueue).creationCode;
        address withdrawQueue = CREATEX.deployCreate3(
            withdrawQueueSalt,
            abi.encodePacked(
                withdrawQueueCreationCode,
                abi.encode(
                    config.withdrawQueueName,
                    config.withdrawQueueSymbol,
                    config.withdrawQueueFeeRecipient,
                    config.teller,
                    feeModule,
                    config.withdrawQueueMinimumOrderSize,
                    broadcaster
                )
            )
        );
        config.withdrawQueue = withdrawQueue;

        // Set Role Capabilities
        RolesAuthority(config.rolesAuthority)
            .setRoleCapability(
                WITHDRAW_QUEUE_PROCESSOR_ROLE, address(withdrawQueue), WithdrawQueue.processOrders.selector, true
            );

        // Set Public Capabilities
        RolesAuthority(config.rolesAuthority)
            .setPublicCapability(address(withdrawQueue), WithdrawQueue.submitOrder.selector, true);
        RolesAuthority(config.rolesAuthority)
            .setPublicCapability(address(withdrawQueue), WithdrawQueue.cancelOrder.selector, true);
        RolesAuthority(config.rolesAuthority)
            .setPublicCapability(address(withdrawQueue), WithdrawQueue.cancelOrderWithSignature.selector, true);
        RolesAuthority(config.rolesAuthority).setUserRole(address(withdrawQueue), SOLVER_ROLE, true);

        // Assign roles to addresses
        RolesAuthority(config.rolesAuthority)
            .setUserRole(config.withdrawQueueProcessorAddress, WITHDRAW_QUEUE_PROCESSOR_ROLE, true);

        return address(withdrawQueue);
    }

}
