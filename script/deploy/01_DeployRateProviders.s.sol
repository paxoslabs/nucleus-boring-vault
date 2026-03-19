// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { GenericRateProvider } from "src/helper/GenericRateProvider.sol";
import { BaseScript } from "./../Base.s.sol";
import { stdJson as StdJson } from "@forge-std/StdJson.sol";
import { ConfigReader } from "../ConfigReader.s.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { EthPerTokenRateProvider, IPriceFeed } from "src/oracles/EthPerTokenRateProvider.sol";
import { console2 } from "forge-std/console2.sol";

/// NOTE This script must change based on the supported assets of each vault deployment.
contract DeployRateProviders is BaseScript {

    using StdJson for string;
    using Strings for address;

    function run(string memory fileName, string memory configFileName) public {
        string memory path = string.concat(CONFIG_PATH_ROOT, configFileName);
        string memory config = vm.readFile(path);
        _run(fileName, config);
    }

    function run() public {
        string memory config = requestConfigFileFromUser();
        _run(Strings.toString(block.chainid), config);
    }

    /**
     * For the assets specified in the teller, look at <chainId>.json, and if
     * the rate provider does not exist, either deploy Chainlink, Redstone, or
     * the Generic Rate Provider.
     */
    function _run(string memory fileName, string memory config) internal {
        string memory chainConfig = getChainConfigFile();

        address[] memory assets = config.readAddressArray(".teller.assets");
        uint256 maxTimeFromLastUpdate = chainConfig.readUint(".assetToRateProviderAndPriceFeed.maxTimeFromLastUpdate");

        for (uint256 i; i < assets.length; ++i) {
            require(assets[i].code.length > 0, "asset must have code");
            string memory rateProviderKey =
                string(abi.encodePacked(".assetToRateProviderAndPriceFeed.", assets[i].toHexString(), ".rateProvider"));

            string memory token = assets[i].toHexString();
            console2.log("token: ", token);

            address rateProvider = chainConfig.readAddress(rateProviderKey);

            // must deploy new rate provider and set the value
            if (rateProvider == address(0)) {
                address deployedAddress;

                uint256 priceFeedType = chainConfig.readUint(
                    string(abi.encodePacked(".assetToRateProviderAndPriceFeed.", token, ".priceFeedType"))
                );

                // Generic Rate Provider
                if (priceFeedType == 2) {
                    address target = chainConfig.readAddress(
                        string(abi.encodePacked(".assetToRateProviderAndPriceFeed.", token, ".target"))
                    );

                    string memory signature = chainConfig.readString(
                        string(abi.encodePacked(".assetToRateProviderAndPriceFeed.", token, ".signature"))
                    );

                    uint256 arg = chainConfig.readUint(
                        string(abi.encodePacked(".assetToRateProviderAndPriceFeed.", token, ".arg"))
                    );

                    uint256 expectedMin = chainConfig.readUint(
                        string(abi.encodePacked(".assetToRateProviderAndPriceFeed.", token, ".expectedMin"))
                    );

                    uint256 expectedMax = chainConfig.readUint(
                        string(abi.encodePacked(".assetToRateProviderAndPriceFeed.", token, ".expectedMax"))
                    );

                    deployedAddress = _deployGenericRateProvider(target, signature, arg, expectedMin, expectedMax);
                } else {
                    // Chainlink or Redstone
                    address priceFeed = chainConfig.readAddress(
                        string(
                            abi.encodePacked(".assetToRateProviderAndPriceFeed.", assets[i].toHexString(), ".priceFeed")
                        )
                    );
                    uint8 decimals = uint8(
                        chainConfig.readUint(
                            string(
                                abi.encodePacked(
                                    ".assetToRateProviderAndPriceFeed.", assets[i].toHexString(), ".decimals"
                                )
                            )
                        )
                    );
                    string memory description = chainConfig.readString(
                        string(
                            abi.encodePacked(
                                ".assetToRateProviderAndPriceFeed.", assets[i].toHexString(), ".description"
                            )
                        )
                    );
                    uint256 priceFeedType = chainConfig.readUint(
                        string(
                            abi.encodePacked(
                                ".assetToRateProviderAndPriceFeed.", assets[i].toHexString(), ".priceFeedType"
                            )
                        )
                    );
                    deployedAddress =
                        _deployRateProvider(description, priceFeed, maxTimeFromLastUpdate, decimals, priceFeedType);
                }
                string memory chainConfigFilePath = string.concat(CONFIG_CHAIN_ROOT, fileName, ".json");
                deployedAddress.toHexString().write(chainConfigFilePath, rateProviderKey);
                console2.log("deployedAddress: ", deployedAddress);
            }
        }
    }

    function _deploy(ConfigReader.Config memory config) public override broadcast returns (address) { }

    function _deployGenericRateProvider(
        address target,
        string memory signature,
        uint256 arg,
        uint256 expectedMin,
        uint256 expectedMax
    )
        internal
        broadcast
        returns (address)
    {
        bytes4 functionSig = bytes4(keccak256(bytes(signature)));

        GenericRateProvider rateProvider =
            new GenericRateProvider(target, functionSig, bytes32(arg), 0, 0, 0, 0, 0, 0, 0);

        uint256 rate = rateProvider.getRate();

        console2.log("rate: ", rate);

        require(rate != 0, "rate must not be zero");
        require(rate >= expectedMin, "rate must be greater than or equal to min");
        require(rate <= expectedMax, "rate must be less than or equal to max");

        return address(rateProvider);
    }

    function _deployRateProvider(
        string memory description,
        address priceFeed,
        uint256 maxTimeFromLastUpdate,
        uint8 decimals,
        uint256 priceFeedType
    )
        internal
        broadcast
        returns (address)
    {
        console2.log("priceFeed: ", priceFeed);
        require(maxTimeFromLastUpdate > 0, "max time from last update = 0");
        require(priceFeed.code.length > 0, "price feed must have code");

        EthPerTokenRateProvider rateProvider = new EthPerTokenRateProvider(
            description,
            IPriceFeed(priceFeed),
            maxTimeFromLastUpdate,
            decimals,
            EthPerTokenRateProvider.PriceFeedType(priceFeedType)
        );

        return address(rateProvider);
    }

}
