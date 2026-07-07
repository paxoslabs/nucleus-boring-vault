// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { UManager, ERC20 } from "src/micro-managers/UManager.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title EquivalentExchangeUManager
 * @notice UManager that executes a merkle-verified batch of BoringVault actions
 *         and enforces an EquivalentExchange-style value invariant across a
 *         stored basket of value-equivalent tokens.
 * @dev Subsidy, if required, is pulled from an approval-based subsidy payer.
 *      The subsidy payer must pre-approve the UManager to spend the subsidy
 *      token; if the approved/available amount is insufficient, the call reverts.
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
    error EquivalentExchangeUManager__MaxSubsidyExceeded();

    event BasketTokensUpdated(ERC20[] tokens);
    event Executed(address indexed caller, uint256 totalBefore, uint256 totalAfter, uint256 subsidyNormalized);

    constructor(address _owner, address _manager, address _boringVault) UManager(_owner, _manager, _boringVault) { }

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
     *         enforces that the vault's aggregate basket value does not decrease
     *         beyond the caller-specified maximum subsidy.
     * @dev Subsidy, if needed, is pulled from the indicated subsidy payer using
     *      ERC20 transferFrom. The payer must have approved the UManager.
     * @param manageProofs Merkle proofs for each manage call.
     * @param decodersAndSanitizers Decoder/sanitizer for each manage call.
     * @param targets Targets for each manage call.
     * @param targetData Calldata for each manage call.
     * @param values ETH values for each manage call.
     * @param subsidyPayer Address that provides the subsidy tokens via approval.
     * @param subsidyToken Token to use as subsidy. Must be a basket token.
     * @param maxSubsidy Maximum normalized subsidy the caller is willing to
     *        provide for this transaction. Reverts if the shortfall exceeds this.
     */
    function execute(
        bytes32[][] calldata manageProofs,
        address[] calldata decodersAndSanitizers,
        address[] calldata targets,
        bytes[] calldata targetData,
        uint256[] calldata values,
        address subsidyPayer,
        ERC20 subsidyToken,
        uint256 maxSubsidy
    )
        external
        requiresAuth
    {
        uint256 targetsLength = targets.length;
        if (
            targetsLength != manageProofs.length || targetsLength != decodersAndSanitizers.length
                || targetsLength != targetData.length || targetsLength != values.length
        ) {
            revert EquivalentExchangeUManager__LengthMismatch();
        }

        uint256 basketLength = basketTokens.length();
        if (basketLength == 0) revert EquivalentExchangeUManager__EmptyBasket();

        // Snapshot vault's basket value before the rebalance.
        uint256 totalBefore = _totalBasketValue(boringVault);

        // Execute the merkle-verified action batch directly from BoringVault.
        manager.manageVaultWithMerkleVerification(manageProofs, decodersAndSanitizers, targets, targetData, values);

        // Snapshot vault's basket value after the rebalance.
        uint256 totalAfter = _totalBasketValue(boringVault);

        // Cover any shortfall using the indicated subsidy token, capped by maxSubsidy.
        uint256 subsidyNormalized;
        if (totalAfter < totalBefore) {
            uint256 shortfall = totalBefore - totalAfter;
            if (shortfall > maxSubsidy) revert EquivalentExchangeUManager__MaxSubsidyExceeded();

            subsidyNormalized = _coverShortfall(shortfall, subsidyPayer, subsidyToken);
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
     * @notice Covers a normalized shortfall by transferring subsidy from the
     *         subsidy payer to the vault.
     * @dev The subsidy token must be a basket token. The payer must have a
     *      sufficient balance and approval to cover the shortfall.
     * @param shortfall Shortfall in 18-decimal normalized units.
     * @param subsidyPayer Address that provides the subsidy tokens via approval.
     * @param subsidyToken Token to use as subsidy.
     * @return subsidyAmountNormalized Total normalized value of subsidy transferred.
     */
    function _coverShortfall(
        uint256 shortfall,
        address subsidyPayer,
        ERC20 subsidyToken
    )
        internal
        returns (uint256 subsidyAmountNormalized)
    {
        if (!basketTokens.contains(address(subsidyToken))) revert EquivalentExchangeUManager__TokenNotInBasket();

        uint8 decimals = subsidyToken.decimals();
        uint256 balance = subsidyToken.balanceOf(subsidyPayer);
        uint256 allowance = subsidyToken.allowance(subsidyPayer, address(this));
        uint256 available = balance < allowance ? balance : allowance;
        uint256 normalizedAvailable = _normalize(available, decimals);

        if (normalizedAvailable < shortfall) revert EquivalentExchangeUManager__InsufficientSubsidy();

        uint256 subsidyAmount = _denormalize(shortfall, decimals);

        // Defensive: never transfer more than the available amount we observed.
        if (subsidyAmount > available) subsidyAmount = available;

        subsidyToken.safeTransferFrom(subsidyPayer, boringVault, subsidyAmount);

        // Re-normalize the actual amount transferred for accounting.
        subsidyAmountNormalized = _normalize(subsidyAmount, decimals);
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
