// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { BoringVault } from "src/base/BoringVault.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { IVelodromeV1Router } from "../interfaces/IVelodromeV1Router.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title VelodromeBuyback
 * @dev no permissioned functions, as token destinations will always be the vault or the sender of tokens
 * @custom:security-contact security@paxoslabs.com
 */
contract VelodromeBuyback is Ownable {

    /**
     * @notice The VelodromeV1 router contract used for swapping assets
     */
    IVelodromeV1Router public immutable router;

    /**
     * @notice The accountant contract
     */
    AccountantWithRateProviders public immutable accountant;

    error BuyBackBot__NotEnoughQuoteAssetReceived(uint256 expected, uint256 actual);

    constructor(address _router, AccountantWithRateProviders _accountant, address _owner) Ownable(_owner) {
        router = IVelodromeV1Router(_router);
        accountant = _accountant;
    }

    /**
     * @notice Buys boring vault tokens with a quote asset and verifies the swap rate against the accountant's rate
     * @dev Takes user's tokens, swaps them for vault tokens, and verifies that the rate received is at least
     *      as good as the rate from the accountant
     * @param quoteAsset The ERC20 token to use for purchasing vault tokens
     * @param amount The amount of quote asset to spend
     */
    function buyAndSwapEnforcingRate(ERC20 quoteAsset, uint256 amount) external onlyOwner {
        quoteAsset.transferFrom(msg.sender, address(this), amount);
        quoteAsset.approve(address(router), amount);

        BoringVault vault = accountant.vault();

        uint256[] memory amounts = router.swapExactTokensForTokensSimple(
            amount, 0, address(quoteAsset), address(vault), true, address(this), block.timestamp
        );
        uint256 amountReceived = amounts[amounts.length - 1];

        uint256 rateInQuote = accountant.getRateInQuote(quoteAsset);

        uint256 minAmountReceived = amount * vault.decimals() / rateInQuote;
        if (amountReceived < minAmountReceived) {
            revert BuyBackBot__NotEnoughQuoteAssetReceived(minAmountReceived, amounts[amounts.length - 1]);
        }

        vault.transfer(msg.sender, amountReceived);
    }

    /// @dev function to prevent tokens from being locked in the bot, ONLY able to be collected to the vault
    function sweepDustToVault(ERC20 token) external onlyOwner {
        token.transfer(address(accountant.vault()), token.balanceOf(address(this)));
    }

}
