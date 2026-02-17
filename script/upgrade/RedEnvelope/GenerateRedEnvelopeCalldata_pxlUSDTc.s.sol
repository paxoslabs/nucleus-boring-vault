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
contract GenerateRedEnvelopeCalldata_pxlUSDTc is BaseScript {

    // =============================================================================
    // DEPLOYMENT PARAMETERS — REVIEW AND UPDATE FOR EACH USE
    // =============================================================================

    /// @dev Deployed RedEnvelope contract that will receive ownership and execute flashUpgrade
    address constant RED_ENVELOPE_ADDRESS = 0x2Cb6d683bA54B56a403b9F14Ae33Ab7384291568;
    // deployed on mainnet

    /// @dev Pre-upgrade contracts (being replaced by flashUpgrade)
    address constant ACCOUNTANT1_ADDRESS = 0x8864fD53aE4Dc56F2E0E8bEaFc9CcE39c0c2dd3F;
    address constant TELLER1_ADDRESS = 0x6a12293FE7395f3E1FFcCF6E689A3a2c6926166D;
    address constant ROLES_AUTHORITY_ADDRESS = 0xc34Fd9a670Aed5f67B7033274B4E91804303d037;

    /// @dev Accountant performance fee in basis points (1e4 = 100%). E.g. 2000 = 20%
    uint16 constant ACCOUNTANT_PERFORMANCE_FEE_BPS = 500;
    /// @dev Offer fee percentage in basis points. E.g. 2 = 0.02%
    uint256 constant OFFER_FEE_PERCENTAGE_BPS = 0;

    /// @dev Assets allowed for deposit (add DEPOSIT_ASSET_2, ... and extend array in run() if needed)
    address constant DEPOSIT_ASSET_1 = 0xdAC17F958D2ee523a2206206994597C13D831ec7; // USDT

    /// @dev Assets allowed for withdraw (add WITHDRAW_ASSET_2, ... and extend array in run() if needed)
    address constant WITHDRAW_ASSET_1 = 0xdAC17F958D2ee523a2206206994597C13D831ec7; // USDT

    /// @dev Address that can call processOrders on the new WithdrawQueue
    address constant WITHDRAW_QUEUE_PROCESSOR_ADDRESS = 0xf1f0A2A9Af8a79100fc0819f7e1a956803E80Cbc;

    /// @dev Minimum order size for the WithdrawQueue (e.g. 10e6 for 6-decimal tokens)
    uint256 constant MINIMUM_ORDER_SIZE = 5e6;

    /// @dev ERC721 name and symbol for the new WithdrawQueue receipt NFT
    string constant QUEUE_ERC721_NAME = "pxlUSDTc Withdraw Queue NFT";
    string constant QUEUE_ERC721_SYMBOL = "unpxlUSDTc";

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
        address queueFeeRecipient = multisig;

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
