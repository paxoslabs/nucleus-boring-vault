// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { ICreateX } from "lib/createx/src/ICreateX.sol";
import { RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";
import "src/helper/Constants.sol";
import { IAccountantWithRateProviders } from "src/interfaces/Roles/IAccountantWithRateProviders.sol";
import { ITellerWithMultiAssetSupport, ERC20 } from "src/interfaces/Roles/ITellerWithMultiAssetSupport.sol";
import { IDistributorCodeDepositor } from "src/interfaces/IDistributorCodeDepositor.sol";
import { IWithdrawQueue } from "src/interfaces/Roles/IWithdrawQueue.sol";
import { IFeeModule } from "src/interfaces/IFeeModule.sol";

import { SSTORE2 } from "lib/solmate/src/utils/SSTORE2.sol";

/**
 * @dev interface for the accountant we are replacing (Accountant1). All else being equal, we only use this to call
 * `accountantState()`
 */
interface IAccountant1 {

    function accountantState()
        external
        view
        returns (
            address payoutAddress,
            uint128 feesOwedInBase,
            uint128 totalSharesLastUpdate,
            uint96 exchangeRate,
            uint16 allowedExchangeRateChangeUpper,
            uint16 allowedExchangeRateChangeLower,
            uint64 lastUpdateTimestamp,
            bool isPaused,
            uint32 minimumUpdateDelayInSeconds,
            uint16 managementFee
        );

}

/// @notice enum to track the contract a bytecode is saved for
enum CONTRACT {
    ACCOUNTANT2,
    TELLER2,
    DCD2,
    WITHDRAW_QUEUE,
    FEE_MODULE
}

/**
 * @title RedEnvelopeUpgrade
 * @notice Red Envelope is the codename for a PaxosLabs Feb 2026 vault upgrade that includes the following:
 * - Upgrade the Teller contract to support withdraw and deposit asset distinctly
 * - The Teller also has bulkDeposit removed
 * - A new DistributorCodeDepositor is also created
 * - Upgrade the Accountant contract to support performance fees
 * - The new WithdrawQueue contract is deployed with a supporting Fee Module
 *
 * @dev This contract uses a "flash-upgrade" method to upgrade the vault with temporarily provided ownership.
 * @custom:security-contact security@molecularlabs.io
 */
contract RedEnvelopeUpgrade {

    using SSTORE2 for address;

    struct FlashUpgradeParams {
        IAccountantWithRateProviders accountant1;
        ITellerWithMultiAssetSupport teller1;
        RolesAuthority authority;
        uint16 accountantPerformanceFee;
        uint256 offerFeePercentage;
        address[] depositAssets;
        address[] withdrawAssets;
        address withdrawQueueProcessorAddress;
        address queueFeeRecipient;
        uint256 minimumOrderSize;
        string queueErc721Name;
        string queueErc721Symbol;
    }

    struct DeployedContracts {
        IAccountantWithRateProviders accountant2;
        ITellerWithMultiAssetSupport teller2;
        IDistributorCodeDepositor dcd2;
        IWithdrawQueue withdrawQueue;
        IFeeModule feeModule;
    }

    // Constants and immutables
    address public immutable layerZeroEndpoint;
    ICreateX public immutable CREATEX;
    address public immutable multisig;

    /// @dev creationCodeSetter is the only role that can call setContractCreationCode. No other privileges.
    address public creationCodeSetter;

    /// @dev pointer here refers to the SSTORE2 address the contract creation code is saved in
    mapping(CONTRACT => address) public contractCreationCodePointer;

    event ContractDeployed(CONTRACT indexed contractName, address indexed contractAddress);
    event CreationCodeSetterRoleTransferred(
        address indexed previousCreationCodeSetter, address indexed newCreationCodeSetter
    );

    constructor(address _createx, address _multisig, address _layerZeroEndpoint, address _creationCodeSetter) {
        CREATEX = ICreateX(_createx);
        multisig = _multisig;
        layerZeroEndpoint = _layerZeroEndpoint;
        creationCodeSetter = _creationCodeSetter;
    }

    /**
     * @dev This function is used to save contract creation code. This contract is too large if it imports all the
     * BoringVault contracts. So instead we can upload the creation code on-chain in a different transaction using
     * SSTORE2 and this function, and read from it to deploy. Only the creationCodeSetter can call this.
     */
    function setContractCreationCode(CONTRACT contractType, bytes calldata creationCode) external {
        require(msg.sender == creationCodeSetter, "Only the creationCodeSetter can call this function");
        contractCreationCodePointer[contractType] = SSTORE2.write(creationCode);
    }

    /**
     * @dev Transfers the creationCodeSetter role to a new address. Only the current creationCodeSetter can call this.
     * The creationCodeSetter's only privilege is calling setContractCreationCode.
     */
    function transferCreationCodeSetter(address newCreationCodeSetter) external {
        require(msg.sender == creationCodeSetter, "Only the creationCodeSetter can call this function");
        address previousCreationCodeSetter = creationCodeSetter;
        creationCodeSetter = newCreationCodeSetter;
        emit CreationCodeSetterRoleTransferred(previousCreationCodeSetter, newCreationCodeSetter);
    }

    /**
     * @dev As an emergency measure, we allow the multisig to use this address to do anything. If a dangling ownership
     * is forgotten we can always recover it
     */
    function emergencyProxyCall(address _target, bytes memory _data, uint256 _value) external payable {
        require(msg.sender == multisig, "Only the multisig can call this function");

        (bool success,) = _target.call{ value: _value }(_data);
        require(success, "Emergency proxy call failed");
    }

    /**
     * @notice flash upgrade function. Requires this contract is granted ownership of the accountant and roles authority
     */
    function flashUpgrade(FlashUpgradeParams calldata params)
        external
        returns (DeployedContracts memory deployedContracts)
    {
        require(msg.sender == multisig, "Only the multisig can call this function");
        require(params.accountant1.owner() == address(this), "Accountant1 must be owned by this contract");
        require(params.authority.owner() == address(this), "Authority must be owned by this contract");

        // Freeze the exchange rate from changing on the old accountant
        params.accountant1.updateUpper(1e4);
        params.accountant1.updateLower(1e4);

        // Deploy the new Accountant
        // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        {
            // First fetch the configuration values from the accountant being replaced
            (
                address _payoutAddress,,,
                uint96 _exchangeRate,,,,,
                uint32 _minimumUpdateDelayInSeconds,
                uint16 _managementFee
            ) = IAccountant1(address(params.accountant1)).accountantState();

            // We set the constructor args = the old accountant with only the new performance fee being unique
            bytes memory constructorParams = abi.encode(
                address(this), // Owner is set to this flash-upgrade contract for now
                params.accountant1.vault(),
                _payoutAddress,
                _exchangeRate,
                params.accountant1.base(),
                1e4, // New Accountant is also frozen from rate changes
                1e4, // ^
                _minimumUpdateDelayInSeconds,
                _managementFee,
                params.accountantPerformanceFee
            );

            // Deploy
            deployedContracts.accountant2 = IAccountantWithRateProviders(
                CREATEX.deployCreate3(
                    _makeSalt(false, params.teller1.vault().symbol(), "AccountantRedEnvelope"),
                    abi.encodePacked(contractCreationCodePointer[CONTRACT.ACCOUNTANT2].read(), constructorParams)
                )
            );
            emit ContractDeployed(CONTRACT.ACCOUNTANT2, address(deployedContracts.accountant2));
        }

        // Set the Authority of the new accountant
        deployedContracts.accountant2.setAuthority(params.authority);

        // Set the Role Capabilities for the new accountant
        params.authority
            .setRoleCapability(
                UPDATE_EXCHANGE_RATE_ROLE,
                address(deployedContracts.accountant2),
                IAccountantWithRateProviders.updateExchangeRate.selector,
                true
            );
        params.authority
            .setRoleCapability(
                PAUSER_ROLE, address(deployedContracts.accountant2), IAccountantWithRateProviders.pause.selector, true
            );

        // Deploy the Teller
        // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        // NOTE: We set the owner to this flash-upgrade contract for now.
        // Also this contract does not deploy a regular teller, but a MultiChainLayerZeroTellerWithMultiAssetSupport.
        // And thus it's constructor arg contains the LayerZero endpoint.
        bytes memory teller2ConstructorParams = abi.encode(
            address(this), params.teller1.vault(), address(deployedContracts.accountant2), layerZeroEndpoint
        );
        deployedContracts.teller2 = ITellerWithMultiAssetSupport(
            CREATEX.deployCreate3(
                _makeSalt(false, params.teller1.vault().symbol(), "TellerRedEnvelope"),
                abi.encodePacked(contractCreationCodePointer[CONTRACT.TELLER2].read(), teller2ConstructorParams)
            )
        );
        emit ContractDeployed(CONTRACT.TELLER2, address(deployedContracts.teller2));

        // NOTE: There is no necessary role distinction for the layerzero teller vs normal teller as all added
        // functionality is owner only. Even the bridge functions which will be left non-public until owner discression
        // Set the Authority of the new teller
        deployedContracts.teller2.setAuthority(params.authority);

        // Add the base asset support (both for deposit and withdraw)
        deployedContracts.teller2.addDepositAsset(params.accountant1.base());
        deployedContracts.teller2.addWithdrawAsset(params.accountant1.base());

        // Set the Role Capabilities for the new teller
        // NOTE: IMPORTANT we set the rate provider as address(0) and pegged for all assets
        for (uint256 i; i < params.depositAssets.length; ++i) {
            deployedContracts.teller2.addDepositAsset(ERC20(params.depositAssets[i]));
            deployedContracts.accountant2.setRateProviderData(ERC20(params.depositAssets[i]), true, address(0));
        }

        // NOTE: IMPORTANT we set the rate provider as address(0) and pegged for all assets
        for (uint256 i; i < params.withdrawAssets.length; ++i) {
            deployedContracts.teller2.addWithdrawAsset(ERC20(params.withdrawAssets[i]));
            deployedContracts.accountant2.setRateProviderData(ERC20(params.withdrawAssets[i]), true, address(0));
        }

        // Set the Role Capabilities for the new Teller
        params.authority
            .setRoleCapability(
                DEPOSITOR_ROLE, address(deployedContracts.teller2), ITellerWithMultiAssetSupport.deposit.selector, true
            );
        params.authority
            .setRoleCapability(
                DEPOSITOR_ROLE,
                address(deployedContracts.teller2),
                ITellerWithMultiAssetSupport.depositWithPermit.selector,
                true
            );
        params.authority
            .setRoleCapability(
                PAUSER_ROLE, address(deployedContracts.teller2), ITellerWithMultiAssetSupport.pause.selector, true
            );
        params.authority
            .setRoleCapability(
                SOLVER_ROLE,
                address(deployedContracts.teller2),
                ITellerWithMultiAssetSupport.bulkWithdraw.selector,
                true
            );
        // Grant the TELLER ROLE to the teller2 contract
        params.authority.setUserRole(address(deployedContracts.teller2), TELLER_ROLE, true);

        // Deploy the DistributorCodeDepositor
        // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

        // NOTE: Unlike other contracts, we set the owner to the multisig directly as we do not need any further actions
        // to be completed
        bytes memory dcd2ConstructorParams =
            abi.encode(address(deployedContracts.teller2), address(0), params.authority, false, multisig);
        deployedContracts.dcd2 = IDistributorCodeDepositor(
            CREATEX.deployCreate3(
                _makeSalt(false, params.teller1.vault().symbol(), "DistributorCodeDepositorRedEnvelope"),
                abi.encodePacked(contractCreationCodePointer[CONTRACT.DCD2].read(), dcd2ConstructorParams)
            )
        );
        emit ContractDeployed(CONTRACT.DCD2, address(deployedContracts.dcd2));

        // Set public capabilities for the distributor code depositor
        params.authority
            .setPublicCapability(address(deployedContracts.dcd2), IDistributorCodeDepositor.deposit.selector, true);
        params.authority
            .setPublicCapability(
                address(deployedContracts.dcd2), IDistributorCodeDepositor.depositWithPermit.selector, true
            );

        // Grant the DEPOSITOR ROLE to the distributor code depositor
        params.authority.setUserRole(address(deployedContracts.dcd2), DEPOSITOR_ROLE, true);

        // Deploy the Simple Fee Module
        // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        bytes memory feeModuleConstructorParams = abi.encode(params.offerFeePercentage);
        deployedContracts.feeModule = IFeeModule(
            CREATEX.deployCreate3(
                _makeSalt(false, params.teller1.vault().symbol(), "FeeModuleRedEnvelope"),
                abi.encodePacked(contractCreationCodePointer[CONTRACT.FEE_MODULE].read(), feeModuleConstructorParams)
            )
        );
        emit ContractDeployed(CONTRACT.FEE_MODULE, address(deployedContracts.feeModule));

        // Deploy the Withdraw Queue
        // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        // NOTE: We set the owner to this flash-upgrade contract for now
        bytes memory withdrawQueueConstructorParams = abi.encode(
            params.queueErc721Name,
            params.queueErc721Symbol,
            params.queueFeeRecipient,
            address(deployedContracts.teller2),
            address(deployedContracts.feeModule),
            params.minimumOrderSize,
            address(this)
        );
        deployedContracts.withdrawQueue = IWithdrawQueue(
            CREATEX.deployCreate3(
                _makeSalt(false, params.teller1.vault().symbol(), "WithdrawQueueRedEnvelope"),
                abi.encodePacked(
                    contractCreationCodePointer[CONTRACT.WITHDRAW_QUEUE].read(), withdrawQueueConstructorParams
                )
            )
        );
        emit ContractDeployed(CONTRACT.WITHDRAW_QUEUE, address(deployedContracts.withdrawQueue));

        // Set the Authority of the new withdraw queue
        deployedContracts.withdrawQueue.setAuthority(params.authority);

        // Set the Role Capabilities for the new withdraw queue
        params.authority
            .setRoleCapability(
                WITHDRAW_QUEUE_PROCESSOR_ROLE,
                address(deployedContracts.withdrawQueue),
                IWithdrawQueue.processOrders.selector,
                true
            );

        // Grant the processor role to the processor address
        params.authority.setUserRole(params.withdrawQueueProcessorAddress, WITHDRAW_QUEUE_PROCESSOR_ROLE, true);
        params.authority.setUserRole(address(deployedContracts.withdrawQueue), SOLVER_ROLE, true);

        // Grant public capabilities to the withdraw queue
        params.authority
            .setPublicCapability(address(deployedContracts.withdrawQueue), IWithdrawQueue.submitOrder.selector, true);
        params.authority
            .setPublicCapability(address(deployedContracts.withdrawQueue), IWithdrawQueue.cancelOrder.selector, true);
        params.authority
            .setPublicCapability(
                address(deployedContracts.withdrawQueue), IWithdrawQueue.cancelOrderWithSignature.selector, true
            );

        // Return the ownership of the contracts
        // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        params.authority.transferOwnership(msg.sender);
        params.accountant1.transferOwnership(msg.sender);
        deployedContracts.accountant2.transferOwnership(msg.sender);
        deployedContracts.teller2.transferOwnership(msg.sender);
        deployedContracts.withdrawQueue.transferOwnership(msg.sender);
    }

    /**
     * @dev a CREATEX helper to make a salt programmatically
     */
    function _makeSalt(
        bool isCrosschainProtected,
        string memory symbol,
        string memory nameEntropy
    )
        internal
        view
        returns (bytes32)
    {
        bytes1 crosschainProtectionFlag = isCrosschainProtected ? bytes1(0x01) : bytes1(0x00);
        bytes32 nameEntropyHash = keccak256(abi.encodePacked(symbol, nameEntropy));
        bytes11 nameEntropyHash11 = bytes11(nameEntropyHash);
        return bytes32(abi.encodePacked(address(this), crosschainProtectionFlag, nameEntropyHash11));
    }

}
