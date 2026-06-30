// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { BaseScript } from "../Base.s.sol";
import { Auth, Authority } from "@solmate/auth/Auth.sol";
import { RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { console2 } from "forge-std/console2.sol";
import { EquivalentExchange } from "src/helper/equivalent-exchange/EquivalentExchange.sol";

uint8 constant EQUIVALENT_EXCHANGE_CALLER_ROLE = 11; // TODO Consider moving this to src/helper/Constants.sol if this role is reused across scripts or an existing RolesAuthority is used.

contract DeployEquivalentExchange is BaseScript {

    // TODO Decide whether to reuse the vault's existing RolesAuthority or keep this fresh one.
    // A fresh authority is isolated and simple, but means the BoringVault is governed by two
    // authorities. Reusing the main vault RolesAuthority avoids that fragmentation but requires
    // coordinating role numbering and permissions with the full vault deployment.

    // TODO Decide whether to keep run() arguments or switch to reading from a deployment-config JSON file,
    // which is the pattern used by most other deploy scripts in this repo.
    function run(
        address boringVault,
        string memory nameEntropy
    )
        external
        broadcast
        returns (EquivalentExchange exchange, RolesAuthority rolesAuthority)
    {
        require(boringVault != address(0), "boringVault required");

        address owner = getMultisig();

        bytes32 rolesAuthoritySalt = makeSalt(broadcaster, false, string(abi.encodePacked(nameEntropy, ":RolesAuthority")));
        bytes32 exchangeSalt = makeSalt(broadcaster, false, string(abi.encodePacked(nameEntropy, ":EquivalentExchange")));

        // Deploy fresh RolesAuthority with the multisig as owner.
        rolesAuthority = RolesAuthority(
            CREATEX.deployCreate3(
                rolesAuthoritySalt,
                abi.encodePacked(type(RolesAuthority).creationCode, abi.encode(owner, Authority(address(0))))
            )
        );

        // Deploy EquivalentExchange pointing at the fresh authority.
        exchange = EquivalentExchange(
            CREATEX.deployCreate3(
                exchangeSalt,
                abi.encodePacked(type(EquivalentExchange).creationCode, abi.encode(owner, Authority(rolesAuthority)))
            )
        );

        // Grant the BoringVault permission to call EquivalentExchange.execute().
        rolesAuthority.setRoleCapability(
            EQUIVALENT_EXCHANGE_CALLER_ROLE,
            address(exchange),
            EquivalentExchange.execute.selector,
            true
        );
        rolesAuthority.setUserRole(boringVault, EQUIVALENT_EXCHANGE_CALLER_ROLE, true);

        // Post-deploy checks.
        require(rolesAuthority.doesUserHaveRole(boringVault, EQUIVALENT_EXCHANGE_CALLER_ROLE), "boringVault should have role");
        require(
            rolesAuthority.canCall(boringVault, address(exchange), EquivalentExchange.execute.selector),
            "boringVault should be able to call execute"
        );

        console2.log("RolesAuthority deployed at: ", address(rolesAuthority));
        console2.log("EquivalentExchange deployed at: ", address(exchange));
        console2.log("Owner: ", owner);
        console2.log("BoringVault: ", boringVault);
    }

}
