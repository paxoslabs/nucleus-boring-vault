// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { BaseScript } from "../Base.s.sol";
import { Authority } from "@solmate/auth/Auth.sol";
import { console2 } from "forge-std/console2.sol";
import { EquivalentExchange } from "src/helper/equivalent-exchange/EquivalentExchange.sol";

contract DeployEquivalentExchange is BaseScript {

    // ============================== FILL PER DEPLOYMENT ==============================

    // BoringVault to own and exclusively call EquivalentExchange
    address constant BORING_VAULT = address(0x91FE06C6E9F97E7DE4580A280E03046155f8e1e3);
    // Namespaces the CREATE3 salt for this deployment.
    string constant NAME_ENTROPY = "Transit";

    // The BoringVault is set as both owner and sole authorized caller: EquivalentExchange uses no
    // Authority (address(0)), and Auth's `requiresAuth` admits `msg.sender == owner` directly, so the
    // vault can call execute() while nothing else can.
    function run() external broadcast returns (EquivalentExchange exchange) {
        require(BORING_VAULT != address(0), "BORING_VAULT required");

        bytes32 exchangeSalt =
            makeSalt(broadcaster, false, string(abi.encodePacked(NAME_ENTROPY, ":EquivalentExchange")));

        // Deploy EquivalentExchange owned by the vault, with no Authority.
        exchange = EquivalentExchange(
            CREATEX.deployCreate3(
                exchangeSalt,
                abi.encodePacked(type(EquivalentExchange).creationCode, abi.encode(BORING_VAULT, Authority(address(0))))
            )
        );

        // Post-deploy checks.
        require(exchange.owner() == BORING_VAULT, "owner should be BORING_VAULT");
        require(address(exchange.authority()) == address(0), "authority should be unset");

        console2.log("EquivalentExchange deployed at: ", address(exchange));
        console2.log("Owner (BoringVault): ", BORING_VAULT);
    }

}
