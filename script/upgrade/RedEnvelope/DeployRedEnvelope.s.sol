// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { BaseScript } from "script/Base.s.sol";
import { RedEnvelopeUpgrade, CONTRACT } from "src/helper/upgrade/RedEnvelope.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";
import {
    MultiChainLayerZeroTellerWithMultiAssetSupport
} from "src/base/Roles/CrossChain/MultiChainLayerZeroTellerWithMultiAssetSupport.sol";
import { DistributorCodeDepositor } from "src/helper/DistributorCodeDepositor.sol";
import { WithdrawQueue } from "src/base/Roles/WithdrawQueue.sol";
import { SimpleFeeModule } from "src/helper/SimpleFeeModule.sol";

contract DeployRedEnvelope is BaseScript {

    function run() public returns (address redEnvelope) {
        return deploy();
    }

    function deploy() public broadcast returns (address) {
        bytes32 SALT = 0x1Ab5a40491925cB445fd59e607330046bEac68E5004728234324239e83f23083;
        address createx = address(CREATEX);
        address multisig = getMultisig();
        address layerZeroEndpoint = 0x1a44076050125825900e736c501f859c50fE728c;
        require(
            block.chainid == 1, "Only eth mainnet (the provided layerzero endpoint in this script is for mainnet only)"
        );

        // Deploy RedEnvelope with minimal constructor (deployer is creationCodeSetter)
        bytes memory constructorParams = abi.encode(createx, multisig, layerZeroEndpoint, broadcaster);
        RedEnvelopeUpgrade redEnvelopeUpgrade = RedEnvelopeUpgrade(
            CREATEX.deployCreate3(SALT, abi.encodePacked(type(RedEnvelopeUpgrade).creationCode, constructorParams))
        );

        // Deployer sets creation code for each contract (deployer is creationCodeSetter)
        redEnvelopeUpgrade.setContractCreationCode(CONTRACT.ACCOUNTANT2, type(AccountantWithRateProviders).creationCode);
        redEnvelopeUpgrade.setContractCreationCode(
            CONTRACT.TELLER2, type(MultiChainLayerZeroTellerWithMultiAssetSupport).creationCode
        );
        redEnvelopeUpgrade.setContractCreationCode(CONTRACT.DCD2, type(DistributorCodeDepositor).creationCode);
        redEnvelopeUpgrade.setContractCreationCode(CONTRACT.WITHDRAW_QUEUE, type(WithdrawQueue).creationCode);
        redEnvelopeUpgrade.setContractCreationCode(CONTRACT.FEE_MODULE, type(SimpleFeeModule).creationCode);

        // Transfer creationCodeSetter role to multisig so it can update creation code later if needed
        redEnvelopeUpgrade.transferCreationCodeSetter(multisig);

        return address(redEnvelopeUpgrade);
    }

}
