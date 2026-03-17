// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { ManagerWithMerkleVerification } from "src/base/Roles/ManagerWithMerkleVerification.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";
import { BaseScript } from "script/Base.s.sol";
import { ConfigReader } from "script/ConfigReader.s.sol";
import { CrossChainTellerBase } from "src/base/Roles/CrossChain/CrossChainTellerBase.sol";
import { stdJson as StdJson } from "@forge-std/StdJson.sol";

import { DistributorCodeDepositor } from "src/helper/DistributorCodeDepositor.sol";
import "src/helper/Constants.sol";

/**
 * NOTE Deploys with `Authority` set to zero bytes.
 */
contract DeployRolesAuthority is BaseScript {

    using StdJson for string;

    function run() public virtual returns (address rolesAuthority) {
        return deploy(getConfig());
    }

    // Setup initial roles configurations
    // --- Roles ---
    // 1. STRATEGIST_ROLE
    //     - manager.manageVaultWithMerkleVerification
    //     - assigned to VAULT_STRATEGIST
    // 2. MANAGER_ROLE
    //     - boringVault.manage()
    //     - assigned to MANAGER
    // 3. TELLER_ROLE
    //     - boringVault.enter()
    //     - boringVault.exit()
    //     - assigned to TELLER
    // 4. UPDATE_EXCHANGE_RATE_ROLE
    //     - accountant.updateExchangeRate()
    //     - assigned to EXCHHANGE_RATE_BOT & OWNER
    // 5. SOLVER_ROLE
    //     - teller.bulkWithdraw()
    //     - assigned to SOLVER CONTRACT
    // 6. PAUSER_ROLE
    //     - teller.pause()
    //     - accountant.pause()
    //     - manager.pause()
    // 7. DEPOSITOR_ROLE
    //     - teller.deposit()
    //     - teller.depositAndBridge()
    // --- Public Functions ---
    // 1. teller.deposit()
    // 2. teller.bridge()
    // 3. teller.depositAndBridge()
    // --- Users / Role Assignments ---
    // STRATEGIST_ROLE -> OWNER (multisig)
    // MANAGER_ROLE -> MANAGER (contract)
    // TELLER_ROLE -> TELLER (contract)
    // UPDATE_EXCHANGE_RATE_ROLE -> EXCHANGE_RATE_BOT (EOA) & OWNER (multisig)
    // PAUSER_ROLE -> PAUSER (EOA) & OWNER (multisig)
    function _deploy(ConfigReader.Config memory config) public virtual override broadcast returns (address) {
        // Require config Values
        require(config.boringVault.code.length != 0, "boringVault must have code");
        require(config.manager.code.length != 0, "manager must have code");
        require(config.teller.code.length != 0, "teller must have code");
        require(config.accountant.code.length != 0, "accountant must have code");
        require(config.boringVault != address(0), "boringVault");
        require(config.manager != address(0), "manager");
        require(config.teller != address(0), "teller");
        require(config.accountant != address(0), "accountant");

        bytes32 rolesAuthoritySalt =
            makeSalt(broadcaster, false, string(abi.encodePacked(config.nameEntropy, ":RolesAuthority")));

        // Create Contract
        bytes memory creationCode = type(RolesAuthority).creationCode;
        RolesAuthority rolesAuthority = RolesAuthority(
            CREATEX.deployCreate3(
                rolesAuthoritySalt,
                abi.encodePacked(
                    creationCode,
                    abi.encode(
                        broadcaster,
                        address(0) // `Authority`
                    )
                )
            )
        );

        // --- Set Role Capabilities ---
        rolesAuthority.setRoleCapability(
            STRATEGIST_ROLE,
            config.manager,
            ManagerWithMerkleVerification.manageVaultWithMerkleVerification.selector,
            true
        );

        rolesAuthority.setRoleCapability(
            MANAGER_ROLE, config.boringVault, bytes4(keccak256(abi.encodePacked("manage(address,bytes,uint256)"))), true
        );

        rolesAuthority.setRoleCapability(
            MANAGER_ROLE,
            config.boringVault,
            bytes4(keccak256(abi.encodePacked("manage(address[],bytes[],uint256[])"))),
            true
        );

        rolesAuthority.setRoleCapability(TELLER_ROLE, config.boringVault, BoringVault.enter.selector, true);

        rolesAuthority.setRoleCapability(TELLER_ROLE, config.boringVault, BoringVault.exit.selector, true);

        rolesAuthority.setRoleCapability(
            UPDATE_EXCHANGE_RATE_ROLE, config.accountant, AccountantWithRateProviders.updateExchangeRate.selector, true
        );

        rolesAuthority.setRoleCapability(
            SOLVER_ROLE, config.teller, TellerWithMultiAssetSupport.bulkWithdraw.selector, true
        );

        rolesAuthority.setRoleCapability(PAUSER_ROLE, config.teller, TellerWithMultiAssetSupport.pause.selector, true);
        rolesAuthority.setRoleCapability(
            PAUSER_ROLE, config.accountant, AccountantWithRateProviders.pause.selector, true
        );
        rolesAuthority.setRoleCapability(
            PAUSER_ROLE, config.manager, ManagerWithMerkleVerification.pause.selector, true
        );

        // --- Set Public Capabilities ---
        rolesAuthority.setPublicCapability(config.teller, CrossChainTellerBase.bridge.selector, true);

        // With the DCD gating deposits, we do not make depositAndBridge public capability. This must be manually
        // configured If the DCD is deployed we set the role capability for the DEPOSITOR_ROLE and grant it to the DCD
        // once deployed
        if (config.distributorCodeDepositorDeploy) {
            rolesAuthority.setRoleCapability(
                DEPOSITOR_ROLE, config.teller, TellerWithMultiAssetSupport.deposit.selector, true
            );
            rolesAuthority.setPublicCapability(
                config.distributorCodeDepositor, DistributorCodeDepositor.deposit.selector, true
            );
        } else {
            rolesAuthority.setPublicCapability(config.teller, TellerWithMultiAssetSupport.deposit.selector, true);
        }

        // --- Assign roles to users ---

        rolesAuthority.setUserRole(config.manager, MANAGER_ROLE, true);

        rolesAuthority.setUserRole(config.teller, TELLER_ROLE, true);

        rolesAuthority.setUserRole(config.protocolAdmin, UPDATE_EXCHANGE_RATE_ROLE, true);
        if (config.exchangeRateBot != address(0)) {
            rolesAuthority.setUserRole(config.exchangeRateBot, UPDATE_EXCHANGE_RATE_ROLE, true);
        }

        rolesAuthority.setUserRole(config.protocolAdmin, PAUSER_ROLE, true);
        if (config.pauser != address(0)) {
            rolesAuthority.setUserRole(config.pauser, PAUSER_ROLE, true);
        }

        // Post Deploy Checks
        require(rolesAuthority.doesUserHaveRole(config.manager, MANAGER_ROLE), "manager should have MANAGER_ROLE");

        require(rolesAuthority.doesUserHaveRole(config.teller, TELLER_ROLE), "teller should have TELLER_ROLE");

        require(
            rolesAuthority.doesUserHaveRole(config.protocolAdmin, UPDATE_EXCHANGE_RATE_ROLE),
            "protocolAdmin should have UPDATE_EXCHANGE_RATE_ROLE"
        );
        require(
            rolesAuthority.doesUserHaveRole(config.protocolAdmin, PAUSER_ROLE), "protocolAdmin should have PAUSER_ROLE"
        );

        if (config.exchangeRateBot != address(0)) {
            require(
                rolesAuthority.doesUserHaveRole(config.exchangeRateBot, UPDATE_EXCHANGE_RATE_ROLE),
                "exchangeRateBot should have UPDATE_EXCHANGE_RATE_ROLE"
            );
        }

        if (config.pauser != address(0)) {
            require(rolesAuthority.doesUserHaveRole(config.pauser, PAUSER_ROLE), "pauser should have PAUSER_ROLE");
        }

        require(
            rolesAuthority.canCall(
                config.manager, config.boringVault, bytes4(keccak256(abi.encodePacked("manage(address,bytes,uint256)")))
            ),
            "manager should be able to call boringVault.manage"
        );
        require(
            rolesAuthority.canCall(
                config.manager,
                config.boringVault,
                bytes4(keccak256(abi.encodePacked("manage(address[],bytes[],uint256[])")))
            ),
            "manager should be able to call boringVault.manage"
        );
        require(
            rolesAuthority.canCall(config.teller, config.boringVault, BoringVault.enter.selector),
            "teller should be able to call boringVault.enter"
        );
        require(
            rolesAuthority.canCall(config.teller, config.boringVault, BoringVault.exit.selector),
            "teller should be able to call boringVault.exit"
        );
        require(
            rolesAuthority.canCall(
                config.exchangeRateBot, config.accountant, AccountantWithRateProviders.updateExchangeRate.selector
            ),
            "exchangeRateBot should be able to call accountant.updateExchangeRate"
        );
        require(
            rolesAuthority.canCall(
                config.protocolAdmin, config.accountant, AccountantWithRateProviders.updateExchangeRate.selector
            ),
            "protocolAdmin should be able to call accountant.updateExchangeRate"
        );
        require(
            config.distributorCodeDepositorDeploy
                || rolesAuthority.canCall(address(1), config.teller, TellerWithMultiAssetSupport.deposit.selector),
            "anyone should be able to call teller.deposit"
        );

        // Pauser Roles
        _validatePauserRole(config, rolesAuthority, config.protocolAdmin);
        if (config.pauser != address(0)) {
            _validatePauserRole(config, rolesAuthority, config.pauser);
        }

        return address(rolesAuthority);
    }

    function _validatePauserRole(
        ConfigReader.Config memory config,
        RolesAuthority rolesAuthority,
        address user
    )
        internal
        view
    {
        require(
            rolesAuthority.canCall(user, config.teller, TellerWithMultiAssetSupport.pause.selector),
            "pauser should be able to call teller.pause"
        );
        require(
            rolesAuthority.canCall(user, config.accountant, AccountantWithRateProviders.pause.selector),
            "pauser should be able to call accountant.pause"
        );
        require(
            rolesAuthority.canCall(user, config.manager, ManagerWithMerkleVerification.pause.selector),
            "pauser should be able to call manager.pause"
        );
    }

}
