// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { BaseScript } from "./../../Base.s.sol";
import { ConfigReader } from "../../ConfigReader.s.sol";
import { RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { DistributorCodeDepositor } from "src/helper/DistributorCodeDepositor.sol";
import { DCDAssetSpecificFeeModule } from "src/helper/DCDAssetSpecificFeeModule.sol";

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

        // Create Contract
        // Have to cut some corners here with local variables to avoid stack too deep errors
        DistributorCodeDepositor distributorCodeDepositor = DistributorCodeDepositor(
            CREATEX.deployCreate3(
                config.distributorCodeDepositorSalt,
                abi.encodePacked(
                    type(DistributorCodeDepositor).creationCode,
                    abi.encode(
                        config.teller,
                        config.distributorCodeDepositorIsNativeDepositSupported ? config.nativeWrapper : address(0),
                        config.rolesAuthority,
                        config.distributorCodeDepositorIsNativeDepositSupported,
                        config.distributorCodeDepositorSupplyCap,
                        // Included this inline to avoid stack too deep errors
                        CREATEX.deployCreate3(
                            keccak256(
                                abi.encodePacked(config.distributorCodeDepositorSalt, "DCDAssetSpecificFeeModule")
                            ),
                            abi.encodePacked(
                                    type(DCDAssetSpecificFeeModule).creationCode, abi.encode(config.protocolAdmin)
                                )
                        ),
                        config.protocolAdmin,
                        config.registry,
                        config.policyID,
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
