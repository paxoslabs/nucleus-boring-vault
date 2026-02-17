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
contract GenerateRedEnvelopeCalldata_pxlPYUSDc is BaseScript {

    // =============================================================================
    // DEPLOYMENT PARAMETERS — REVIEW AND UPDATE FOR EACH USE
    // =============================================================================

    /// @dev Deployed RedEnvelope contract that will receive ownership and execute flashUpgrade
    address constant RED_ENVELOPE_ADDRESS = 0x2Cb6d683bA54B56a403b9F14Ae33Ab7384291568;
    // deployed on mainnet

    /// @dev Pre-upgrade contracts (being replaced by flashUpgrade)
    address constant ACCOUNTANT1_ADDRESS = 0x095d1b7257A20cf615c90E0D6a0e61c89FcC61a9;
    address constant TELLER1_ADDRESS = 0x0aFfa0b97b5E43C81c79D03df1a934f7f8E40080;
    address constant ROLES_AUTHORITY_ADDRESS = 0x88d961F9f5bae22B01FCa2A14bd1b145f4faa2D5;

    /// @dev Accountant performance fee in basis points (1e4 = 100%). E.g. 2000 = 20%
    uint16 constant ACCOUNTANT_PERFORMANCE_FEE_BPS = 500;
    /// @dev Offer fee percentage in basis points. E.g. 2 = 0.02%
    uint256 constant OFFER_FEE_PERCENTAGE_BPS = 0;

    /// @dev Assets allowed for deposit (add DEPOSIT_ASSET_2, ... and extend array in run() if needed)
    address constant DEPOSIT_ASSET_1 = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC
    address constant DEPOSIT_ASSET_2 = 0xe343167631d89B6Ffc58B88d6b7fB0228795491D; // USDG
    address constant DEPOSIT_ASSET_3 = 0x6c3ea9036406852006290770BEdFcAbA0e23A0e8; // pyUSD

    /// @dev Assets allowed for withdraw (add WITHDRAW_ASSET_2, ... and extend array in run() if needed)
    address constant WITHDRAW_ASSET_1 = 0x6c3ea9036406852006290770BEdFcAbA0e23A0e8; // pyUSD

    /// @dev Address that can call processOrders on the new WithdrawQueue
    address constant WITHDRAW_QUEUE_PROCESSOR_ADDRESS = 0xf1F0068dffb624e8319DF87D6322aFa83E5Ec759;

    /// @dev Minimum order size for the WithdrawQueue (e.g. 10e6 for 6-decimal tokens)
    uint256 constant MINIMUM_ORDER_SIZE = 5e6;

    /// @dev ERC721 name and symbol for the new WithdrawQueue receipt NFT
    string constant QUEUE_ERC721_NAME = "pxlPYUSDc Withdraw Queue NFT";
    string constant QUEUE_ERC721_SYMBOL = "unpxlPYUSDc";

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

        address[] memory depositAssets = new address[](3);
        depositAssets[0] = DEPOSIT_ASSET_1;
        depositAssets[1] = DEPOSIT_ASSET_2;
        depositAssets[2] = DEPOSIT_ASSET_3;

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
