// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { ManagerWithMerkleVerification } from "./../../../src/base/Roles/ManagerWithMerkleVerification.sol";
import { BoringVault } from "./../../../src/base/BoringVault.sol";
import { TellerWithMultiAssetSupport } from "./../../../src/base/Roles/TellerWithMultiAssetSupport.sol";
import { AccountantWithRateProviders } from "./../../../src/base/Roles/AccountantWithRateProviders.sol";
import { BaseScript } from "../../Base.s.sol";
import { ConfigReader } from "../../ConfigReader.s.sol";
import { CrossChainTellerBase } from "../../../src/base/Roles/CrossChain/CrossChainTellerBase.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { stdJson as StdJson } from "@forge-std/StdJson.sol";

contract TellerSetup is BaseScript {

    using Strings for address;
    using StdJson for string;

    function run() public virtual {
        deploy(getConfig());
    }

    function deploy(ConfigReader.Config memory config) public virtual override broadcast returns (address) {
        TellerWithMultiAssetSupport teller = TellerWithMultiAssetSupport(config.teller);

        // add the base asset by default for all configurations
        teller.addDepositAsset(ERC20(config.base));
        teller.addWithdrawAsset(ERC20(config.base));

        // add the remaining assets specified in the assets array of config
        for (uint256 i; i < config.assets.length; ++i) {
            // add asset
            teller.addDepositAsset(ERC20(config.assets[i]));
            teller.addWithdrawAsset(ERC20(config.assets[i]));

            string memory isPeggedKey = string(
                abi.encodePacked(".assetToRateProviderAndPriceFeed.", config.assets[i].toHexString(), ".isPegged")
            );

            bool isPegged = getChainConfigFile().readBool(isPeggedKey);

            if (isPegged) {
                teller.accountant().setRateProviderData(ERC20(config.assets[i]), true, address(0));
            } else {
                // set the corresponding rate provider
                string memory key = string(
                    abi.encodePacked(
                        ".assetToRateProviderAndPriceFeed.", config.assets[i].toHexString(), ".rateProvider"
                    )
                );
                address rateProvider = getChainConfigFile().readAddress(key);
                teller.accountant().setRateProviderData(ERC20(config.assets[i]), false, rateProvider);
            }
        }
    }

}
