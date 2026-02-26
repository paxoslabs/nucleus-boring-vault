// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { BoringVault } from "./../../../src/base/BoringVault.sol";
import { BaseScript } from "./../../Base.s.sol";
import { ConfigReader } from "../../ConfigReader.s.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { stdJson as StdJson } from "@forge-std/StdJson.sol";

contract DeployIonBoringVaultScript is BaseScript {

    using StdJson for string;

    function run() public returns (address boringVault) {
        return deploy(getConfig());
    }

    function deploy(ConfigReader.Config memory config) public override broadcast returns (address) {
        // Require config Values
        bytes32 boringVaultSalt =
            makeSalt(broadcaster, false, string(abi.encodePacked(config.nameEntropy, ":BoringVault")));
        require(keccak256(bytes(config.boringVaultName)) != keccak256(bytes("")));
        require(keccak256(bytes(config.boringVaultSymbol)) != keccak256(bytes("")));

        // Create Contract
        bytes memory creationCode = type(BoringVault).creationCode;
        BoringVault boringVault = BoringVault(
            payable(CREATEX.deployCreate3(
                    boringVaultSalt,
                    abi.encodePacked(
                        creationCode,
                        abi.encode(
                            broadcaster,
                            config.boringVaultName,
                            config.boringVaultSymbol,
                            config.boringVaultAndBaseDecimals // decimals
                        )
                    )
                ))
        );

        // Post Deploy Checks
        require(boringVault.owner() == broadcaster, "owner should be the deployer");
        require(address(boringVault.hook()) == address(0), "before transfer hook should be zero");
        require(
            boringVault.decimals() == ERC20(config.base).decimals(), "boringVault decimals should be the same as base"
        );
        return address(boringVault);
    }

}
