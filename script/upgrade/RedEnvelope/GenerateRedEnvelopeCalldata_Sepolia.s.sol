// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { BaseScript } from "script/Base.s.sol";
import { RedEnvelopeUpgrade } from "src/helper/upgrade/RedEnvelope.sol";
import { IAccountantWithRateProviders } from "src/interfaces/Roles/IAccountantWithRateProviders.sol";
import { ITellerWithMultiAssetSupport } from "src/interfaces/Roles/ITellerWithMultiAssetSupport.sol";
import { RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { TELLER_ROLE } from "src/helper/Constants.sol";
import { console } from "@forge-std/Console.sol";

/**
 * Generates calldata for the multisig to call RedEnvelope.flashUpgrade(...) and simulates the call as multisig.
 * For simulation to succeed, run on a fork after RedEnvelope is deployed and ownership of
 * Accountant and Roles Authority has been transferred to the RedEnvelope contract.
 */
contract GenerateRedEnvelopeCalldata_Sepolia is BaseScript {

    // =============================================================================
    // DEPLOYMENT PARAMETERS — REVIEW AND UPDATE FOR EACH USE
    // =============================================================================

    /// @dev Deployed RedEnvelope contract that will receive ownership and execute flashUpgrade
    address constant RED_ENVELOPE_ADDRESS = 0xEcF917f182Fd9D9f4775A4BF3950C94E6dab9f65;

    /// @dev Pre-upgrade contracts (being replaced by flashUpgrade)
    address constant ACCOUNTANT1_ADDRESS = 0xFE01b0becc666b50b43d368dCbd55577f6187824;
    address constant TELLER1_ADDRESS = 0x738F9744a0EdE4307aAc5b4Ed0B046bc38e61fCB;
    address constant ROLES_AUTHORITY_ADDRESS = 0xbCE0FeEb3523A5D81C01F66A9b41f580A71FA8d3;

    /// @dev Accountant performance fee in basis points (1e4 = 100%). E.g. 2000 = 20%
    uint16 constant ACCOUNTANT_PERFORMANCE_FEE_BPS = 2000;
    /// @dev Offer fee percentage in basis points. E.g. 2 = 0.02%
    uint256 constant OFFER_FEE_PERCENTAGE_BPS = 2;

    /// @dev Assets allowed for deposit (add DEPOSIT_ASSET_2, ... and extend array in run() if needed)
    address constant DEPOSIT_ASSET_1 = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    /// @dev Assets allowed for withdraw (add WITHDRAW_ASSET_2, ... and extend array in run() if needed)
    address constant WITHDRAW_ASSET_1 = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;

    /// @dev Address that can call processOrders on the new WithdrawQueue
    address constant WITHDRAW_QUEUE_PROCESSOR_ADDRESS = 0xCb8FA722B2a138faC6B6D60013025E2504b9B753;
    /// @dev Recipient of queue fees. Set to address(0) to use the chain multisig (getMultisig()); otherwise set
    /// explicit address.
    address constant QUEUE_FEE_RECIPIENT_ADDRESS = address(0);

    /// @dev Minimum order size for the WithdrawQueue (e.g. 10e6 for 6-decimal tokens)
    uint256 constant MINIMUM_ORDER_SIZE = 10e6;

    /// @dev ERC721 name and symbol for the new WithdrawQueue receipt NFT
    string constant QUEUE_ERC721_NAME = "unTEST";
    string constant QUEUE_ERC721_SYMBOL = "unTEST";

    // =============================================================================

    function run() public {
        // A few checks to ensure the pre-upgrade contracts were provided correctly
        require(
            address(ITellerWithMultiAssetSupport(TELLER1_ADDRESS).accountant()) == ACCOUNTANT1_ADDRESS,
            "Teller1 accountant mismatch"
        );
        require(
            RolesAuthority(ROLES_AUTHORITY_ADDRESS).doesUserHaveRole(TELLER1_ADDRESS, TELLER_ROLE),
            "Teller must have TELLER_ROLE on the provided RolesAuthority"
        );

        address multisig = getMultisig();
        address queueFeeRecipient = QUEUE_FEE_RECIPIENT_ADDRESS == address(0) ? multisig : QUEUE_FEE_RECIPIENT_ADDRESS;

        address[] memory depositAssets = new address[](1);
        depositAssets[0] = DEPOSIT_ASSET_1;
        address[] memory withdrawAssets = new address[](1);
        withdrawAssets[0] = WITHDRAW_ASSET_1;

        RedEnvelopeUpgrade.FlashUpgradeParams memory params = RedEnvelopeUpgrade.FlashUpgradeParams({
            accountant1: IAccountantWithRateProviders(ACCOUNTANT1_ADDRESS),
            teller1: ITellerWithMultiAssetSupport(TELLER1_ADDRESS),
            authority: RolesAuthority(ROLES_AUTHORITY_ADDRESS),
            accountantPerformanceFee: ACCOUNTANT_PERFORMANCE_FEE_BPS,
            offerFeePercentage: OFFER_FEE_PERCENTAGE_BPS,
            depositAssets: depositAssets,
            withdrawAssets: withdrawAssets,
            withdrawQueueProcessorAddress: WITHDRAW_QUEUE_PROCESSOR_ADDRESS,
            queueFeeRecipient: queueFeeRecipient,
            minimumOrderSize: MINIMUM_ORDER_SIZE,
            queueErc721Name: QUEUE_ERC721_NAME,
            queueErc721Symbol: QUEUE_ERC721_SYMBOL
        });

        bytes memory calldataBytes = abi.encodeWithSelector(RedEnvelopeUpgrade.flashUpgrade.selector, params);

        console.log("=== For Gnosis Safe UI ===");
        console.log("Target (RedEnvelope):", RED_ENVELOPE_ADDRESS);
        console.log("Calldata (hex):");
        console.logBytes(calldataBytes);

        vm.startPrank(multisig);
        params.accountant1.transferOwnership(RED_ENVELOPE_ADDRESS);
        params.authority.transferOwnership(RED_ENVELOPE_ADDRESS);
        RedEnvelopeUpgrade(RED_ENVELOPE_ADDRESS).flashUpgrade(params);
        vm.stopPrank();
    }

}
