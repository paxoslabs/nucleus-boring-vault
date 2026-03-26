// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { stdJson as StdJson } from "@forge-std/StdJson.sol";

interface IAuthority {

    function setAuthority(address newAuthority) external;
    function transferOwnership(address newOwner) external;
    function owner() external returns (address);

}

library ConfigReader {

    using StdJson for string;

    struct Config {
        string nameEntropy;
        address protocolAdmin;
        address base;
        uint8 boringVaultAndBaseDecimals;
        address boringVault;
        address payoutAddress;
        uint16 allowedExchangeRateChangeUpper;
        uint16 allowedExchangeRateChangeLower;
        uint32 minimumUpdateDelayInSeconds;
        uint16 managementFee;
        uint16 performanceFee;
        string boringVaultName;
        string boringVaultSymbol;
        address balancerVault;
        uint32 peerEid;
        address[] requiredDvns;
        address[] optionalDvns;
        uint64 dvnBlockConfirmationsRequired;
        uint8 optionalDvnThreshold;
        address accountant;
        address opMessenger;
        uint64 maxGasForPeer;
        uint64 minGasForPeer;
        address lzEndpoint;
        address mailbox;
        uint32 peerDomainId;
        address manager;
        address teller;
        string tellerContractName;
        address strategist;
        address exchangeRateBot;
        address pauser;
        address rolesAuthority;
        uint256 maxTimeFromLastUpdate;
        address[] withdrawAssets;
        address[] depositAssets;
        address[] rateProviders;
        address[] priceFeeds;
        bool distributorCodeDepositorDeploy;
        bool distributorCodeDepositorIsNativeDepositSupported;
        address distributorCodeDepositor;
        address nativeWrapper;
        uint256 distributorCodeDepositorSupplyCap;
        address registry;
        string policyID;
        uint256 withdrawQueueFeePercentage;
        string withdrawQueueName;
        string withdrawQueueSymbol;
        address withdrawQueueFeeRecipient;
        uint256 withdrawQueueMinimumOrderSize;
        address withdrawQueue;
        address withdrawQueueProcessorAddress;
        address freezeListBeforeTransferHook;
    }

    function toConfig(string memory _config, string memory _chainConfig) internal pure returns (Config memory config) {
        // Reading the 'nameEntropy`
        config.nameEntropy = _config.readString(".nameEntropy");

        // Reading the 'protocolAdmin'
        config.protocolAdmin = _config.readAddress(".protocolAdmin");
        config.base = _config.readAddress(".base");
        config.boringVaultAndBaseDecimals = uint8(_config.readUint(".boringVaultAndBaseDecimals"));

        // Reading from the 'accountant' section
        config.accountant = _config.readAddress(".accountant.address");
        config.payoutAddress = _config.readAddress(".accountant.payoutAddress");
        config.allowedExchangeRateChangeUpper = uint16(_config.readUint(".accountant.allowedExchangeRateChangeUpper"));
        config.allowedExchangeRateChangeLower = uint16(_config.readUint(".accountant.allowedExchangeRateChangeLower"));
        config.minimumUpdateDelayInSeconds = uint32(_config.readUint(".accountant.minimumUpdateDelayInSeconds"));
        config.managementFee = uint16(_config.readUint(".accountant.managementFee"));
        config.performanceFee = uint16(_config.readUint(".accountant.performanceFee"));

        // Reading from the 'boringVault' section
        config.boringVault = _config.readAddress(".boringVault.address");
        config.boringVaultName = _config.readString(".boringVault.boringVaultName");
        config.boringVaultSymbol = _config.readString(".boringVault.boringVaultSymbol");

        // Reading from the 'manager' section
        config.manager = _config.readAddress(".manager.address");

        // Reading from the 'teller' section
        config.teller = _config.readAddress(".teller.address");
        config.maxGasForPeer = uint64(_config.readUint(".teller.maxGasForPeer"));
        config.minGasForPeer = uint64(_config.readUint(".teller.minGasForPeer"));
        config.tellerContractName = _config.readString(".teller.tellerContractName");
        config.withdrawAssets = _config.readAddressArray(".teller.withdrawAssets");
        config.depositAssets = _config.readAddressArray(".teller.depositAssets");

        // layerzero
        if (compareStrings(config.tellerContractName, "MultiChainLayerZeroTellerWithMultiAssetSupport")) {
            config.lzEndpoint = _chainConfig.readAddress(".lzEndpoint");

            config.peerEid = uint32(_config.readUint(".teller.peerEid"));
            config.requiredDvns = _config.readAddressArray(".teller.dvnIfNoDefault.required");
            config.optionalDvns = _config.readAddressArray(".teller.dvnIfNoDefault.optional");
            config.dvnBlockConfirmationsRequired =
                uint64(_config.readUint(".teller.dvnIfNoDefault.blockConfirmationsRequiredIfNoDefault"));
            config.optionalDvnThreshold = uint8(_config.readUint(".teller.dvnIfNoDefault.optionalThreshold"));
        } else if (compareStrings(config.tellerContractName, "MultiChainHyperlaneTellerWithMultiAssetSupport")) {
            config.mailbox = _chainConfig.readAddress(".mailbox");
            config.peerDomainId = uint32(_config.readUint(".teller.peerDomainId"));
        }

        // Reading from the 'rolesAuthority' section
        config.rolesAuthority = _config.readAddress(".rolesAuthority.address");
        config.strategist = _config.readAddress(".rolesAuthority.strategist");
        config.exchangeRateBot = _config.readAddress(".rolesAuthority.exchangeRateBot");
        config.pauser = _config.readAddress(".rolesAuthority.pauser");

        // Reading from the 'distributorCodeDepositor' section
        config.distributorCodeDepositorDeploy = _config.readBool(".distributorCodeDepositor.deploy");
        config.distributorCodeDepositorIsNativeDepositSupported =
            _config.readBool(".distributorCodeDepositor.nativeSupported");
        config.distributorCodeDepositorSupplyCap = _config.readUint(".distributorCodeDepositor.supplyCap");
        config.registry = _config.readAddress(".distributorCodeDepositor.registry");
        config.policyID = _config.readString(".distributorCodeDepositor.policyID");

        // Reading from the 'withdrawQueue' section
        config.withdrawQueueFeePercentage = uint256(_config.readUint(".withdrawQueue.feePercentage"));
        config.withdrawQueueName = _config.readString(".withdrawQueue.name");
        config.withdrawQueueSymbol = _config.readString(".withdrawQueue.symbol");
        config.withdrawQueueFeeRecipient = _config.readAddress(".withdrawQueue.feeRecipient");
        config.withdrawQueueMinimumOrderSize = uint256(_config.readUint(".withdrawQueue.minimumOrderSize"));
        config.withdrawQueueProcessorAddress = _config.readAddress(".withdrawQueue.processorAddress");

        // Reading from the 'chainConfig' section
        config.balancerVault = _chainConfig.readAddress(".balancerVault");
        config.nativeWrapper = _chainConfig.readAddress(".nativeWrapper");

        return config;
    }

    function compareStrings(string memory a, string memory b) internal pure returns (bool) {
        return (keccak256(abi.encodePacked(a)) == keccak256(abi.encodePacked(b)));
    }

}
