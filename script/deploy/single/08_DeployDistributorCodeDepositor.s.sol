// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { BaseScript } from "./../../Base.s.sol";
import { ConfigReader } from "../../ConfigReader.s.sol";
import { RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { DistributorCodeDepositor } from "../../../src/helper/DistributorCodeDepositor.sol";

/**
 * Deploy the Distributor Code Depositor contract.
 */
contract DeployDistributorCodeDepositor is BaseScript {

    function run() public {
        deploy(getConfig());
    }

    function deploy(ConfigReader.Config memory config) public override broadcast returns (address) {
        // Require config Values
        require(config.distributorCodeDepositorDeploy, "Distributor Code Depositor must be set true to be deployed");

        address nativeWrapper =
            config.distributorCodeDepositorIsNativeDepositSupported ? config.nativeWrapper : address(0);

        bytes32 distributorCodeDepositorSalt =
            makeSalt(broadcaster, false, string(abi.encodePacked(config.nameEntropy, ":DistributorCodeDepositor")));

        // Create Contract
        bytes memory creationCode = type(DistributorCodeDepositor).creationCode;
        DistributorCodeDepositor distributorCodeDepositor = DistributorCodeDepositor(
            CREATEX.deployCreate3(
                distributorCodeDepositorSalt,
                abi.encodePacked(
                    creationCode,
                    abi.encode(
                        config.teller,
                        nativeWrapper,
                        config.rolesAuthority,
                        config.distributorCodeDepositorIsNativeDepositSupported,
                        config.protocolAdmin
                    )
                )
            )
        );

        RolesAuthority(config.rolesAuthority)
            .setPublicCapability(address(distributorCodeDepositor), distributorCodeDepositor.deposit.selector, true);
        RolesAuthority(config.rolesAuthority)
            .setPublicCapability(
                address(distributorCodeDepositor), distributorCodeDepositor.depositWithPermit.selector, true
            );
        if (config.distributorCodeDepositorIsNativeDepositSupported) {
            RolesAuthority(config.rolesAuthority)
                .setPublicCapability(
                    address(distributorCodeDepositor), distributorCodeDepositor.depositNative.selector, true
                );
        }

        return address(distributorCodeDepositor);
    }

}
