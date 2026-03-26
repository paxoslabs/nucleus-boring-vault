// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { BaseScript } from "./../../Base.s.sol";
import { ConfigReader } from "../../ConfigReader.s.sol";
import { RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { DistributorCodeDepositor } from "src/helper/DistributorCodeDepositor.sol";
import { DCDAssetSpecificFeeModule } from "src/helper/DCDAssetSpecificFeeModule.sol";
import "src/helper/Constants.sol";

/**
 * Deploy the Distributor Code Depositor contract.
 */
contract DeployDistributorCodeDepositor is BaseScript {

    function run() public {
        deploy(getConfig());
    }

    function _deploy(ConfigReader.Config memory config) public override broadcast returns (address) {
        // Require config Values
        require(config.distributorCodeDepositorDeploy, "Distributor Code Depositor must be set true to be deployed");

        address nativeWrapper =
            config.distributorCodeDepositorIsNativeDepositSupported ? config.nativeWrapper : address(0);

        bytes32 distributorCodeDepositorSalt =
            makeSalt(broadcaster, false, string(abi.encodePacked(config.nameEntropy, ":DistributorCodeDepositor")));

        // Create Contract
        // Have to cut some corners here with local variables to avoid stack too deep errors
        // To avoid "stack too deep", split the arguments into intermediate local variables.

        bytes32 feeModuleSalt = keccak256(abi.encodePacked(distributorCodeDepositorSalt, "DCDAssetSpecificFeeModule"));
        address assetSpecificFeeModule = CREATEX.deployCreate3(
            feeModuleSalt,
            abi.encodePacked(type(DCDAssetSpecificFeeModule).creationCode, abi.encode(config.protocolAdmin))
        );

        address teller = config.teller;
        address rolesAuthority = config.rolesAuthority;
        bool isNativeSupported = config.distributorCodeDepositorIsNativeDepositSupported;
        uint256 supplyCap = config.distributorCodeDepositorSupplyCap;
        address protocolAdmin = config.protocolAdmin;
        address registry = config.registry;
        string memory policyID = config.policyID;

        bytes memory dcdInitCalldata = abi.encode(
            teller,
            nativeWrapper,
            rolesAuthority,
            isNativeSupported,
            supplyCap,
            assetSpecificFeeModule,
            protocolAdmin,
            registry,
            policyID,
            protocolAdmin
        );

        DistributorCodeDepositor distributorCodeDepositor = DistributorCodeDepositor(
            CREATEX.deployCreate3(
                distributorCodeDepositorSalt,
                abi.encodePacked(type(DistributorCodeDepositor).creationCode, dcdInitCalldata)
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

        // Grant the DEPOSITOR ROLE to the distributor code depositor
        RolesAuthority(config.rolesAuthority).setUserRole(address(distributorCodeDepositor), DEPOSITOR_ROLE, true);

        return address(distributorCodeDepositor);
    }

}
