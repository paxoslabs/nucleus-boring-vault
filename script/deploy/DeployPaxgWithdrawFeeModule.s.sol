// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { PaxgyDynamicWithdrawalFeeModule } from "src/helper/PaxgyDynamicWithdrawalFeeModule.sol";
import { IRateProvider } from "src/interfaces/IRateProvider.sol";
import { BaseScript } from "../Base.s.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { console2 } from "forge-std/console2.sol";

/**
 * @notice Deploys the {PaxgyDynamicWithdrawalFeeModule} with a 10 bps fixed fee via CreateX CREATE3.
 * @dev The module prices PAXG withdrawals against the {PaxgXauRateProvider} (XAU per PAXG) and the mainnet
 * PAXG token, so deployment is gated to chain id 1 to match the oracle and token wiring. Set RATE_PROVIDER
 * to the address emitted by DeployPaxgXauRateProvider before broadcasting; the run reverts if it is unset or has
 * no code on this chain, so a misconfigured deploy fails loudly rather than wiring a dead oracle.
 */
contract DeployPaxgWithdrawFeeModule is BaseScript {

    // The PaxgXauRateProvider deployed by DeployPaxgXauRateProvider.s.sol. Set before broadcasting.
    address constant RATE_PROVIDER = address(0);

    // The PAXGy vault share token (BoringVault). Set before broadcasting.
    address constant SHARES = address(0);

    // PAXG token (18 decimals), the only withdraw asset this module prices.
    address constant PAXG_TOKEN = 0x45804880De22913dAFE09f4980848ECE6EcbAf78;

    // Fixed withdrawal fee in basis points: 10 = 0.10%.
    uint256 constant FIXED_FEE_BPS = 10;

    function run() public broadcast {
        if (block.chainid != 1) {
            revert("PAXGy modules deploy on Ethereum mainnet (chainid 1)");
        }
        require(RATE_PROVIDER != address(0), "Set RATE_PROVIDER to the deployed PaxgXauRateProvider");
        require(RATE_PROVIDER.code.length != 0, "RATE_PROVIDER has no code on this chain");
        require(SHARES != address(0), "Set SHARES to the PAXGy vault share token");
        require(SHARES.code.length != 0, "SHARES has no code on this chain");

        bytes32 salt = makeSalt(broadcaster, false, "Paxgy: DynamicWithdrawalFeeModule");

        bytes memory creationCode = type(PaxgyDynamicWithdrawalFeeModule).creationCode;

        address feeModule = CREATEX.deployCreate3(
            salt,
            abi.encodePacked(
                creationCode,
                abi.encode(IRateProvider(RATE_PROVIDER), IERC20(PAXG_TOKEN), IERC20(SHARES), FIXED_FEE_BPS)
            )
        );

        console2.log("PaxgyDynamicWithdrawalFeeModule: ", feeModule);
    }

}
