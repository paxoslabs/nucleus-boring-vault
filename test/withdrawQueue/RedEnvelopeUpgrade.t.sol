// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Test } from "@forge-std/Test.sol";
import { RedEnvelopeUpgrade, CONTRACT } from "src/helper/upgrade/RedEnvelope.sol";
import { IAccountantWithRateProviders } from "src/interfaces/Roles/IAccountantWithRateProviders.sol";
import { ITellerWithMultiAssetSupport } from "src/interfaces/Roles/ITellerWithMultiAssetSupport.sol";
import { RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { ICreateX } from "lib/createx/src/ICreateX.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";
import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import { DistributorCodeDepositor } from "src/helper/DistributorCodeDepositor.sol";
import { WithdrawQueue } from "src/base/Roles/WithdrawQueue.sol";
import { SimpleFeeModule } from "src/helper/SimpleFeeModule.sol";

/**
 * @notice Test that mimics the earnUSDG RedEnvelope deployment and upgrade flow
 * @dev Follows the same pattern as DeployRedEnvelope.s.sol and GenerateRedEnvelopeCalldata_pxlUSDGc.s.sol
 *      to ensure the test matches the production deployment process
 */
contract RedEnvelopeUpgradeTest is Test {

    // =============================================================================
    // DEPLOYMENT PARAMETERS (matching GenerateRedEnvelopeCalldata_pxlUSDGc.s.sol)
    // =============================================================================
    address constant LAYER_ZERO_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;

    // Pre-upgrade contracts (earnUSDG on mainnet)
    address constant ACCOUNTANT1_ADDRESS = 0x99cCA5087479E092F63874E7Fb7356C143623B26;
    address constant TELLER1_ADDRESS = 0x094c771B02094482C2D514ac46d793c8A9f5F693;
    address constant ROLES_AUTHORITY_ADDRESS = 0xaeeC053e978A4Bfc05BEBf297250cE8528B8530d;

    // Upgrade parameters
    uint16 constant ACCOUNTANT_PERFORMANCE_FEE_BPS = 500; // 5%
    uint256 constant OFFER_FEE_PERCENTAGE_BPS = 2; // 0.02%

    // Assets
    address constant DEPOSIT_ASSET_1 = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC
    address constant DEPOSIT_ASSET_2 = 0xe343167631d89B6Ffc58B88d6b7fB0228795491D; // USDG
    address constant WITHDRAW_ASSET_1 = 0xe343167631d89B6Ffc58B88d6b7fB0228795491D; // USDG

    // Queue parameters
    address constant WITHDRAW_QUEUE_PROCESSOR_ADDRESS = 0xCb8FA722B2a138faC6B6D60013025E2504b9B753;
    address constant QUEUE_FEE_RECIPIENT_ADDRESS = address(0); // Will use multisig
    uint256 constant MINIMUM_ORDER_SIZE = 10e6;
    string constant QUEUE_ERC721_NAME = "unearnUSDG";
    string constant QUEUE_ERC721_SYMBOL = "unearnUSDG";

    // Test multisig (overriding production multisig for testing)
    address constant MULTISIG = 0x0000000000417626Ef34D62C4DC189b021603f2F;

    // =============================================================================

    RedEnvelopeUpgrade public redEnvelopeContract;
    ICreateX public createX;

    function setUp() public {
        // Fork Ethereum mainnet
        uint256 forkId = vm.createFork(vm.envString("MAINNET_RPC_URL"));
        vm.selectFork(forkId);

        // Get CreateX address
        createX = ICreateX(vm.envAddress("CREATEX"));

        // =============================================================================
        // DEPLOYMENT (matching DeployRedEnvelope.s.sol flow)
        // =============================================================================

        // Deploy RedEnvelope with CreateX and multisig as owner
        redEnvelopeContract = new RedEnvelopeUpgrade(address(createX), MULTISIG, LAYER_ZERO_ENDPOINT, address(this));

        // Deployer (this test contract) sets creation codes for all contracts
        // This matches the DeployRedEnvelope script where the deployer is creationCodeSetter initially
        redEnvelopeContract.setContractCreationCode(
            CONTRACT.ACCOUNTANT2, type(AccountantWithRateProviders).creationCode
        );
        redEnvelopeContract.setContractCreationCode(CONTRACT.TELLER2, type(TellerWithMultiAssetSupport).creationCode);
        redEnvelopeContract.setContractCreationCode(CONTRACT.DCD2, type(DistributorCodeDepositor).creationCode);
        redEnvelopeContract.setContractCreationCode(CONTRACT.WITHDRAW_QUEUE, type(WithdrawQueue).creationCode);
        redEnvelopeContract.setContractCreationCode(CONTRACT.FEE_MODULE, type(SimpleFeeModule).creationCode);

        // Transfer creationCodeSetter role to multisig (matching DeployRedEnvelope script)
        redEnvelopeContract.transferCreationCodeSetter(MULTISIG);
    }

    function testFlashUpgrade() public {
        // =============================================================================
        // PREPARE UPGRADE (matching GenerateRedEnvelopeCalldata_earnUSDG.s.sol flow)
        // =============================================================================

        address queueFeeRecipient = QUEUE_FEE_RECIPIENT_ADDRESS == address(0) ? MULTISIG : QUEUE_FEE_RECIPIENT_ADDRESS;

        // Build deposit and withdraw asset arrays
        address[] memory depositAssets = new address[](2);
        depositAssets[0] = DEPOSIT_ASSET_1;
        depositAssets[1] = DEPOSIT_ASSET_2;

        address[] memory withdrawAssets = new address[](1);
        withdrawAssets[0] = WITHDRAW_ASSET_1;

        // Build FlashUpgradeParams with all parameters
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

        // =============================================================================
        // EXECUTE UPGRADE (matching GenerateRedEnvelopeCalldata_earnUSDG.s.sol flow)
        // =============================================================================

        // Multisig transfers ownership of Accountant1 and RolesAuthority to RedEnvelope
        vm.startPrank(MULTISIG);
        params.accountant1.transferOwnership(address(redEnvelopeContract));
        params.authority.transferOwnership(address(redEnvelopeContract));
        // Multisig calls flashUpgrade on RedEnvelope
        RedEnvelopeUpgrade.DeployedContracts memory deployedContracts = redEnvelopeContract.flashUpgrade(params);
        vm.stopPrank();

        // =============================================================================
        // VERIFY RESULTS
        // =============================================================================

        // Verify ownership was returned to multisig
        assertEq(params.authority.owner(), MULTISIG, "RolesAuthority ownership not returned");
        assertEq(params.accountant1.owner(), MULTISIG, "Accountant1 ownership not returned");

        assertEq(deployedContracts.accountant2.owner(), MULTISIG, "Accountant2 ownership not returned");
        assertEq(deployedContracts.teller2.owner(), MULTISIG, "Teller2 ownership not returned");
        assertEq(deployedContracts.withdrawQueue.owner(), MULTISIG, "WithdrawQueue ownership not returned");

        // Verify new contracts were deployed
        assertTrue(address(deployedContracts.accountant2) != address(0), "Accountant2 not deployed");
        assertTrue(address(deployedContracts.teller2) != address(0), "Teller2 not deployed");
        assertTrue(address(deployedContracts.dcd2) != address(0), "DCD2 not deployed");
        assertTrue(address(deployedContracts.withdrawQueue) != address(0), "WithdrawQueue not deployed");
        assertTrue(address(deployedContracts.feeModule) != address(0), "FeeModule not deployed");
    }

}
