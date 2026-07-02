// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { UManager, ERC20 } from "src/micro-managers/UManager.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

// TODO: note that this is not compatible with inherited UManager rate limiting
//       behavior because `execute` can include an arbitrary number of calls

// TODO: if we decide to keep tokens in this contract, provide a way to get them out

/**
 * @title EquivalentExchangeUManager
 * @notice UManager that executes a merkle-verified batch of BoringVault actions
 *         and enforces an EquivalentExchange-style value invariant across a
 *         stored basket of value-equivalent tokens.
 * @dev Subsidy, if required, is sourced from the UManager's own balances of
 *      basket tokens. The caller provides an ordered `subsidyTokens` array
 *      specifying which basket-token balances to use and in what order. The
 *      UManager must be pre-funded with any tokens that may be needed to cover
 *      shortfalls; if the provided subsidy tokens are insufficient, the call
 *      reverts.
 */
contract EquivalentExchangeUManager is UManager {

    using SafeTransferLib for ERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Decimal scale used for normalizing token amounts for 1:1 comparison.
    uint256 internal constant NORMALIZED_DECIMALS = 18;

    /// @notice Tokens treated as a value-equivalent basket for the vault.
    EnumerableSet.AddressSet internal basketTokens;

    error EquivalentExchangeUManager__LengthMismatch();
    error EquivalentExchangeUManager__EmptyBasket();
    error EquivalentExchangeUManager__TokenNotInBasket();
    error EquivalentExchangeUManager__InsufficientSubsidy();

    event BasketTokensUpdated(ERC20[] tokens);
    event Executed(
        address indexed caller,
        uint256 totalBefore,
        uint256 totalAfter,
        uint256 subsidyNormalized
    );

    constructor(address _owner, address _manager, address _boringVault)
        UManager(_owner, _manager, _boringVault)
    { }

    /**
     * @notice Sets the basket of value-equivalent tokens used for accounting.
     * @dev Callable by OWNER_ROLE / MULTISIG_ROLE.
     */
    function setBasketTokens(ERC20[] calldata tokens) external requiresAuth {
        // Remove all existing tokens.
        uint256 existingLength = basketTokens.length();
        for (uint256 i; i < existingLength; ++i) {
            basketTokens.remove(basketTokens.at(i));
        }

        // Add new tokens.
        uint256 newLength = tokens.length;
        for (uint256 i; i < newLength; ++i) {
            basketTokens.add(address(tokens[i]));
        }

        emit BasketTokensUpdated(tokens);
    }

    /**
     * @notice Returns the basket tokens as an array.
     */
    function getBasketTokens() external view returns (address[] memory) {
        return basketTokens.values();
    }

    /**
     * @notice Returns whether a token is part of the basket.
     */
    function isBasketToken(ERC20 token) external view returns (bool) {
        return basketTokens.contains(address(token));
    }

    /**
     * @notice Executes a merkle-verified batch of BoringVault actions and
     *         enforces that the vault's aggregate basket value does not decrease.
     * @dev Subsidy, if needed, is pulled from the UManager's own balances of
     *      the indicated subsidy tokens in order until the shortfall is covered.
     * @param manageProofs Merkle proofs for each manage call.
     * @param decodersAndSanitizers Decoder/sanitizer for each manage call.
     * @param targets Targets for each manage call.
     * @param targetData Calldata for each manage call.
     * @param values ETH values for each manage call.
     * @param subsidyTokens Ordered list of tokens to use as subsidy. Each must
     *        be a basket token and must belong to this UManager.
     */
    function execute(
        bytes32[][] calldata manageProofs,
        address[] calldata decodersAndSanitizers,
        address[] calldata targets,
        bytes[] calldata targetData,
        uint256[] calldata values,
        ERC20[] calldata subsidyTokens
    )
        external
        requiresAuth
        enforceRateLimit
    {
        uint256 targetsLength = targets.length;
        if (
            targetsLength != manageProofs.length
                || targetsLength != decodersAndSanitizers.length
                || targetsLength != targetData.length
                || targetsLength != values.length
        ) {
            revert EquivalentExchangeUManager__LengthMismatch();
        }

        uint256 basketLength = basketTokens.length();
        if (basketLength == 0) revert EquivalentExchangeUManager__EmptyBasket();

        // Snapshot vault's basket value before the rebalance.
        uint256 totalBefore = _totalBasketValue(boringVault);

        // Execute the merkle-verified action batch directly from BoringVault.
        manager.manageVaultWithMerkleVerification(
            manageProofs, decodersAndSanitizers, targets, targetData, values
        );

        // Snapshot vault's basket value after the rebalance.
        uint256 totalAfter = _totalBasketValue(boringVault);

        // Cover any shortfall using the indicated subsidy tokens.
        uint256 subsidyNormalized;
        if (totalAfter < totalBefore) {
            uint256 shortfall = totalBefore - totalAfter;
            subsidyNormalized = _coverShortfall(shortfall, subsidyTokens);
            totalAfter += subsidyNormalized;
        }

        // Final invariant check. _coverShortfall either covers the shortfall or
        // reverts; this assert is a self-documenting guard against future
        // changes to subsidy behavior.
        assert(totalAfter >= totalBefore);

        emit Executed(msg.sender, totalBefore, totalAfter, subsidyNormalized);
    }


    /**
     * @notice Returns the total normalized value of the basket held by `account`.
     */
    function _totalBasketValue(address account) internal view returns (uint256 total) {
        uint256 length = basketTokens.length();
        for (uint256 i; i < length; ++i) {
            ERC20 token = ERC20(basketTokens.at(i));
            total += _normalize(token.balanceOf(account), token.decimals());
        }
    }

    /**
     * @notice Attempts to cover a normalized shortfall by transferring subsidy
     *         tokens held by this contract to the vault.
     * @dev Iterates through `subsidyTokens` in order. Each token must be a
     *      basket token. For each token, it transfers the lesser of the UManager
     *      balance or the amount needed (denormalized to the token's decimals).
     * @param shortfall Shortfall in 18-decimal normalized units.
     * @param subsidyTokens Ordered list of tokens to use as subsidy.
     * @return subsidyNormalized Total normalized value of subsidy transferred.
     */
    function _coverShortfall(uint256 shortfall, ERC20[] calldata subsidyTokens)
        internal
        returns (uint256 subsidyNormalized)
    {
        uint256 length = subsidyTokens.length;
        uint256 remaining = shortfall;

        for (uint256 i; i < length; ++i) {
            if (remaining == 0) break;

            ERC20 token = subsidyTokens[i];
            if (!basketTokens.contains(address(token))) revert EquivalentExchangeUManager__TokenNotInBasket();

            uint256 balance = token.balanceOf(address(this));
            if (balance == 0) continue;

            uint8 decimals = token.decimals();
            uint256 normalizedBalance = _normalize(balance, decimals);
            uint256 useNormalized = normalizedBalance < remaining ? normalizedBalance : remaining;
            uint256 useAmount = _denormalize(useNormalized, decimals);

            // Defensive: never transfer more than the balance we observed.
            if (useAmount > balance) useAmount = balance;

            token.safeTransfer(boringVault, useAmount);

            // Re-normalize the actual amount transferred for accounting.
            subsidyNormalized += _normalize(useAmount, decimals);
            remaining = shortfall > subsidyNormalized ? shortfall - subsidyNormalized : 0;
        }

        if (remaining != 0) revert EquivalentExchangeUManager__InsufficientSubsidy();
    }

    /**
     * @notice Rescales an amount to NORMALIZED_DECIMALS (18).
     */
    function _normalize(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        if (decimals <= NORMALIZED_DECIMALS) {
            return amount * (10 ** (NORMALIZED_DECIMALS - decimals));
        }
        return amount / (10 ** (decimals - NORMALIZED_DECIMALS));
    }

    /**
     * @notice Rescales an amount from NORMALIZED_DECIMALS (18) to a token's
     *         native decimals, rounding up to avoid underestimating.
     */
    function _denormalize(uint256 normalizedAmount, uint8 decimals) internal pure returns (uint256) {
        if (decimals <= NORMALIZED_DECIMALS) {
            uint256 factor = 10 ** (NORMALIZED_DECIMALS - decimals);
            return (normalizedAmount + factor - 1) / factor;
        }
        return normalizedAmount * (10 ** (decimals - NORMALIZED_DECIMALS));
    }

}
