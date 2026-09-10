// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { stdJson as StdJson } from "@forge-std/StdJson.sol";
import { console2 } from "forge-std/console2.sol";

import { PaxgyDynamicDepositFeeModule } from "src/helper/PaxgyDynamicDepositFeeModule.sol";
import { PaxgyDynamicWithdrawalFeeModule } from "src/helper/PaxgyDynamicWithdrawalFeeModule.sol";
import { PaxgXauRateProvider } from "src/oracles/PaxgXauRateProvider.sol";
import { IPriceFeed } from "src/interfaces/IPriceFeed.sol";
import { IRateProvider } from "src/interfaces/IRateProvider.sol";
import { BaseScript } from "../Base.s.sol";

/**
 * @notice Deploys the PAXGy pricing stack in one run: the {PaxgXauRateProvider} composite oracle
 * (XAU per PAXG) followed by the {PaxgyDynamicDepositFeeModule} and {PaxgyDynamicWithdrawalFeeModule}
 * that price against it, all via CreateX CREATE3.
 * @dev The Chainlink PAXG/USD and XAU/USD feeds and the PAXG token only exist on Ethereum mainnet, so the
 * run is gated to chain id 1. The vault share token is read from the deployment config's
 * `.boringVault.address`, so the modules can only be wired to a vault that has already been deployed and
 * recorded. Deploying the oracle in the same run removes the cross-script address handoff: the modules
 * always bind to the oracle this run produced and verified.
 */
contract PaxgyOracleFeeModuleSetup is BaseScript {

    using StdJson for string;

    // Vanity salt cracked for this deployer; CreateX rejects it from any other sender.
    bytes32 constant RATE_PROVIDER_SALT = 0x12341eD9cb38Ae1b15016c6eD9F88e247f2AF76f005555555555555555550901;
    address constant RATE_PROVIDER_SALT_DEPLOYER = 0x12341eD9cb38Ae1b15016c6eD9F88e247f2AF76f;

    string constant DEPOSIT_FEE_MODULE_NAME_ENTROPY = "Paxgy: DynamicDepositFeeModule";
    string constant WITHDRAWAL_FEE_MODULE_NAME_ENTROPY = "Paxgy: DynamicWithdrawalFeeModule";

    // Chainlink Ethereum mainnet feeds. Verify against docs.chain.link before broadcasting.
    address constant PAXG_USD_FEED = 0x9944D86CEB9160aF5C5feB251FD671923323f8C3;
    address constant XAU_USD_FEED = 0x214eD9Da11D2fbe465a6fc601a91E62EbEc1a0D6;

    string constant PAXG_USD_DESCRIPTION = "PAXG / USD";
    string constant XAU_USD_DESCRIPTION = "XAU / USD";

    // PAXG token (18 decimals): its decimals define the oracle's output precision, and it is the only
    // asset either fee module prices.
    address constant PAXG_TOKEN = 0x45804880De22913dAFE09f4980848ECE6EcbAf78;

    // The Chainlink PAXG/USD feed's heartbeat is 86400s (24h); we add 100s to account for block delay.
    uint256 constant MAX_TIME_FROM_LAST_UPDATE = 86_500;

    // Fixed withdrawal fee in basis points: 10 = 0.10%.
    uint256 constant WITHDRAWAL_FIXED_FEE_BPS = 10;

    /// @notice Prompts for the deployment config file, then deploys the oracle and both fee modules.
    function run() public returns (address rateProvider, address depositFeeModule, address withdrawalFeeModule) {
        return _deployPricingStack(requestConfigFileFromUser().readAddress(".boringVault.address"));
    }

    /// @notice Non-interactive entrypoint.
    /// @param deployFile Config file name relative to CONFIG_PATH_ROOT, e.g. "paxgy.json".
    function run(string memory deployFile)
        public
        returns (address rateProvider, address depositFeeModule, address withdrawalFeeModule)
    {
        string memory config = vm.readFile(string.concat(CONFIG_PATH_ROOT, deployFile));
        return _deployPricingStack(config.readAddress(".boringVault.address"));
    }

    function _deployPricingStack(address shares)
        internal
        broadcast
        returns (address rateProvider, address depositFeeModule, address withdrawalFeeModule)
    {
        if (block.chainid != 1) {
            revert("PaxgyOracleFeeModuleSetup: PAXG/XAU feeds and PAXG only exist on Ethereum mainnet (chainid 1)");
        }
        require(broadcaster == RATE_PROVIDER_SALT_DEPLOYER, "PaxgyOracleFeeModuleSetup: broadcaster does not own salt");
        require(shares != address(0), "PaxgyOracleFeeModuleSetup: config .boringVault.address is unset");
        require(shares.code.length != 0, "PaxgyOracleFeeModuleSetup: boring vault has no code on this chain");

        rateProvider = _deployRateProvider();
        depositFeeModule = _deployDepositFeeModule(rateProvider, shares);
        withdrawalFeeModule = _deployWithdrawalFeeModule(rateProvider, shares);

        console2.log("PAXGy shares (BoringVault): ", shares);
        console2.log("PaxgXauRateProvider: ", rateProvider);
        console2.log("PaxgyDynamicDepositFeeModule: ", depositFeeModule);
        console2.log("PaxgyDynamicWithdrawalFeeModule: ", withdrawalFeeModule);
    }

    function _deployRateProvider() internal returns (address rateProvider) {
        rateProvider = CREATEX.deployCreate3(
            RATE_PROVIDER_SALT,
            abi.encodePacked(
                type(PaxgXauRateProvider).creationCode,
                abi.encode(
                    PAXG_USD_DESCRIPTION,
                    XAU_USD_DESCRIPTION,
                    ERC20(PAXG_TOKEN),
                    IPriceFeed(PAXG_USD_FEED),
                    IPriceFeed(XAU_USD_FEED),
                    MAX_TIME_FROM_LAST_UPDATE
                )
            )
        );

        // The constructor validates each feed's description and decimals, but it does not confirm the
        // wiring produced a usable composite oracle. Fail here rather than ship an oracle that reverts or
        // mis-scales at the consumer's first getRate().
        PaxgXauRateProvider oracle = PaxgXauRateProvider(rateProvider);

        // Output precision must be 18: the fee modules and accountant compare getRate() against a hardcoded
        // 1e18 peg, so any other precision silently mis-scales every downstream fee.
        require(oracle.RATE_DECIMALS() == 18, "PaxgyOracleFeeModuleSetup: RATE_DECIMALS != 18");

        // Guards against a swapped or edited constant that still happens to share a description.
        require(address(oracle.PAXG_USD_FEED()) == PAXG_USD_FEED, "PaxgyOracleFeeModuleSetup: PAXG/USD feed mismatch");
        require(address(oracle.XAU_USD_FEED()) == XAU_USD_FEED, "PaxgyOracleFeeModuleSetup: XAU/USD feed mismatch");

        // Exercises the staleness and positivity guards against the real feeds; the band catches gross
        // scaling/wiring errors: PAXG is backed 1:1 by one troy ounce of gold, so XAU per PAXG sits within
        // ~10% of 1e18 in any normal market.
        uint256 rate = oracle.getRate();
        require(rate >= 0.9e18 && rate <= 1.1e18, "PaxgyOracleFeeModuleSetup: getRate() outside sane band");

        console2.log("PaxgXauRateProvider getRate(): ", rate);
    }

    function _deployDepositFeeModule(address rateProvider, address shares) internal returns (address feeModule) {
        bytes32 salt = makeSalt(broadcaster, false, DEPOSIT_FEE_MODULE_NAME_ENTROPY);

        feeModule = CREATEX.deployCreate3(
            salt,
            abi.encodePacked(
                type(PaxgyDynamicDepositFeeModule).creationCode,
                abi.encode(IRateProvider(rateProvider), IERC20(PAXG_TOKEN), IERC20(shares))
            )
        );

        PaxgyDynamicDepositFeeModule module = PaxgyDynamicDepositFeeModule(feeModule);
        require(
            address(module.RATE_PROVIDER()) == rateProvider, "PaxgyOracleFeeModuleSetup: deposit rate provider mismatch"
        );
        require(address(module.PAXG()) == PAXG_TOKEN, "PaxgyOracleFeeModuleSetup: deposit PAXG mismatch");
        require(address(module.SHARES()) == shares, "PaxgyOracleFeeModuleSetup: deposit shares mismatch");
    }

    function _deployWithdrawalFeeModule(address rateProvider, address shares) internal returns (address feeModule) {
        bytes32 salt = makeSalt(broadcaster, false, WITHDRAWAL_FEE_MODULE_NAME_ENTROPY);

        feeModule = CREATEX.deployCreate3(
            salt,
            abi.encodePacked(
                type(PaxgyDynamicWithdrawalFeeModule).creationCode,
                abi.encode(IRateProvider(rateProvider), IERC20(PAXG_TOKEN), IERC20(shares), WITHDRAWAL_FIXED_FEE_BPS)
            )
        );

        PaxgyDynamicWithdrawalFeeModule module = PaxgyDynamicWithdrawalFeeModule(feeModule);
        require(
            address(module.RATE_PROVIDER()) == rateProvider,
            "PaxgyOracleFeeModuleSetup: withdrawal rate provider mismatch"
        );
        require(address(module.PAXG()) == PAXG_TOKEN, "PaxgyOracleFeeModuleSetup: withdrawal PAXG mismatch");
        require(address(module.SHARES()) == shares, "PaxgyOracleFeeModuleSetup: withdrawal shares mismatch");
        require(
            module.FIXED_FEE_BPS() == WITHDRAWAL_FIXED_FEE_BPS,
            "PaxgyOracleFeeModuleSetup: withdrawal fixed fee mismatch"
        );
    }

}
