// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { UManager, ERC20 } from "src/micro-managers/UManager.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title EquivalentExchangeUManager
 * @notice UManager that executes a batch of merkle-verified BoringVault actions
 *         and enforces a value invariant across a stored basket of value-equivalent
 *         tokens.
 * @dev Subsidy, if required, is pulled from an approval-based subsidy payer.
 *      The subsidy payer must pre-approve the UManager to spend the subsidy
 *      token; if the approved/available amount is insufficient, the call reverts.
 */
contract EquivalentExchangeUManager is UManager {

    using SafeTransferLib for ERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Decimal scale used for normalizing token amounts for 1:1 comparison.
    uint256 internal constant NORMALIZED_DECIMALS = 18;

    /// @notice Selector for increaseAllowance(address,uint256).
    bytes4 internal constant INCREASE_ALLOWANCE_SELECTOR = 0x39509351;

    /// @notice Tokens treated as a value-equivalent basket for the vault.
    EnumerableSet.AddressSet internal basketTokens;

    error EmptyBasket();
    error TokenNotInBasket();
    error InsufficientSubsidy();
    error DanglingApproval();
    error TokenDeltaLengthMismatch();
    error TokenDeltaOutOfBounds(address token);

    event BasketTokensUpdated(address[] tokens);
    event Executed(
        address indexed caller,
        ERC20 indexed subsidyToken,
        uint256 totalBeforeNormalized,
        uint256 totalAfterNormalized,
        uint256 subsidyAmount,
        uint256 subsidyAmountNormalized
    );

    /**
     * @notice A batch of merkle-verified BoringVault actions, as parallel arrays.
     * @dev The downstream manager enforces that all five arrays are the same length, so this contract skips those
     * checks.
     * @param manageProofs Merkle proof for each action.
     * @param decodersAndSanitizers Decoder/sanitizer to extract each action's gated addresses.
     * @param targets Contract each action calls.
     * @param targetData Calldata for each action.
     * @param values ETH value for each action.
     */
    struct ManageCalls {
        bytes32[][] manageProofs;
        address[] decodersAndSanitizers;
        address[] targets;
        bytes[] targetData;
        uint256[] values;
    }

    /**
     * @notice Bound on how far the vault's balance of a basket token may move in each direction.
     * @dev Unsigned magnitudes in the token's native units, so the tolerated band is
     *      [-negativeDelta, +positiveDelta]. Entry `i` bounds basket token `i` in `getBasketTokens()`
     *      order; rebuild after any `setBasketTokens`, which can reorder the basket.
     * @param negativeDelta Largest tolerated decrease, inclusive. Reverts if the balance falls by more.
     * @param positiveDelta Largest tolerated increase, inclusive. Reverts if the balance rises by more.
     */
    struct TokenDelta {
        uint256 negativeDelta;
        uint256 positiveDelta;
    }

    constructor(address _owner, address _manager, address _boringVault) UManager(_owner, _manager, _boringVault) { }

    /**
     * @notice Sets the basket of value-equivalent tokens used for accounting.
     * @custom:access OWNER_ROLE / MULTISIG_ROLE should be granted authority - redefines which tokens the value
     * invariant covers and the order `maxDeltas` binds to, so a wrong basket silently leaves tokens unbounded.
     */
    function setBasketTokens(ERC20[] calldata tokens) external requiresAuth {
        // Remove all existing tokens by popping from the end. Length shrinks on
        // each removal, so we must iterate backwards to avoid out-of-bounds reads.
        uint256 existingLength = basketTokens.length();
        for (uint256 i = existingLength; i > 0; --i) {
            basketTokens.remove(basketTokens.at(i - 1));
        }

        // Add new tokens.
        uint256 newLength = tokens.length;
        for (uint256 i; i < newLength; ++i) {
            basketTokens.add(address(tokens[i]));
        }

        // Emit the resulting set (deduplicated, in stored order) rather than the raw input, so the
        // event is an accurate record of the basket's actual contents.
        emit BasketTokensUpdated(basketTokens.values());
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
     * @notice Executes a batch of merkle-verified BoringVault actions, enforces a per-token bound on
     *         each basket token's balance change over the batch, and enforces that the vault's aggregate
     *         basket value does not decrease (topping up any shortfall from the subsidy payer).
     * @dev `maxDeltas` must be exactly as long as the basket, so every basket token is bounded. Movement is
     *      measured over the batch ONLY; the subsidy pulled afterwards is not counted against any bound.
     *
     *      Subsidy, if needed, is pulled from the indicated subsidy payer using ERC20 transferFrom; the
     *      payer must have approved the UManager. The amount pulled is the aggregate shortfall, converted
     *      to the subsidy token and rounded up to a whole native unit.
     * @param calls Batch of merkle-verified BoringVault actions to execute.
     * @param subsidyPayer Address that provides the subsidy tokens via approval.
     * @param subsidyToken Token to use as subsidy. Must be a basket token.
     * @param maxDeltas Per-direction balance-change bounds, parallel to `getBasketTokens()` (see TokenDelta).
     * @return subsidyAmount Subsidy pulled from `subsidyPayer`, in `subsidyToken`'s native units. This is the
     * amount actually transferred, inclusive of `_denormalize`'s round-up.
     * @custom:access STRATEGIST_ROLE should be granted authority - confined to calls the merkle root already
     * allows, and cannot lower the basket's total value. Note `maxDeltas` is supplied by the caller, so it
     * guards against a bad route, not against a bad strategist.
     */
    function execute(
        ManageCalls calldata calls,
        address subsidyPayer,
        ERC20 subsidyToken,
        TokenDelta[] calldata maxDeltas
    )
        external
        requiresAuth
        returns (uint256 subsidyAmount)
    {
        // Read the basket once into memory. Every loop below indexes this snapshot, so a basket change
        // mid-batch cannot leave `maxDeltas[i]` and `tokens[i]` pointing at different tokens.
        address[] memory tokens = basketTokens.values();
        uint256 basketLength = tokens.length;

        if (basketLength == 0) revert EmptyBasket();
        if (!basketTokens.contains(address(subsidyToken))) revert TokenNotInBasket();
        if (maxDeltas.length != basketLength) revert TokenDeltaLengthMismatch();

        // Snapshot the pre-batch balances the delta bounds are measured against. Normalizing them is
        // deferred to the post-batch loop, which reads each token's decimals anyway.
        uint256[] memory beforeBalances = new uint256[](basketLength);

        for (uint256 i; i < basketLength; ++i) {
            beforeBalances[i] = ERC20(tokens[i]).balanceOf(boringVault);
        }

        // Execute the merkle-verified action batch directly from BoringVault.
        _manageVaultWithMerkleVerification(calls);

        // Bounds constrain what the batch did, so they are checked before any subsidy is pulled.
        uint256 totalBefore;
        uint256 totalAfter;

        for (uint256 i; i < basketLength; ++i) {
            ERC20 token = ERC20(tokens[i]);
            uint256 balanceBefore = beforeBalances[i];
            uint256 balanceAfter = token.balanceOf(boringVault);

            uint256 delta;
            uint256 maxDelta;

            // Select the magnitude for whichever direction the balance moved, so both subtractions stay
            // unsigned and no signed cast is needed. An unchanged balance matches neither branch and
            // leaves both at zero, which the check below admits.
            if (balanceAfter < balanceBefore) {
                delta = balanceBefore - balanceAfter;
                maxDelta = maxDeltas[i].negativeDelta;
            } else if (balanceAfter > balanceBefore) {
                delta = balanceAfter - balanceBefore;
                maxDelta = maxDeltas[i].positiveDelta;
            }

            if (delta > maxDelta) revert TokenDeltaOutOfBounds(address(token));

            // A single decimals() read scales both totals, so they cannot disagree on scale.
            uint8 decimals = token.decimals();
            totalBefore += _normalize(balanceBefore, decimals);
            totalAfter += _normalize(balanceAfter, decimals);
        }

        // Cover any aggregate shortfall using the indicated subsidy token. The subsidy inflow is
        // intentionally not counted against subsidyToken's delta bound.
        uint256 subsidyAmountNormalized;
        if (totalAfter < totalBefore) {
            uint256 shortfall = totalBefore - totalAfter;
            (subsidyAmount, subsidyAmountNormalized) = _coverShortfall(shortfall, subsidyPayer, subsidyToken);
            totalAfter += subsidyAmountNormalized;
        }

        // Final invariant check. _coverShortfall either covers the shortfall or
        // reverts; this assert is a self-documenting guard against future
        // changes to subsidy behavior.
        assert(totalAfter >= totalBefore);

        // Ensure no approvals to basket tokens remain outstanding.
        _enforceNoDanglingApprovals(calls);

        emit Executed(msg.sender, subsidyToken, totalBefore, totalAfter, subsidyAmount, subsidyAmountNormalized);
    }

    /**
     * @notice Covers a normalized shortfall by transferring subsidy from the
     *         subsidy payer to the vault.
     * @dev The subsidy token must be a basket token. The payer must have a
     *      sufficient balance and approval to cover the shortfall.
     * @param shortfall Shortfall in 18-decimal normalized units.
     * @param subsidyPayer Address that provides the subsidy tokens via approval.
     * @param subsidyToken Token to use as subsidy.
     * @return subsidyAmount Amount of subsidy transferred, in the subsidy token's native units.
     * @return subsidyAmountNormalized Total normalized value of subsidy transferred.
     */
    function _coverShortfall(
        uint256 shortfall,
        address subsidyPayer,
        ERC20 subsidyToken
    )
        internal
        returns (uint256 subsidyAmount, uint256 subsidyAmountNormalized)
    {
        uint8 decimals = subsidyToken.decimals();
        uint256 balance = subsidyToken.balanceOf(subsidyPayer);
        uint256 allowance = subsidyToken.allowance(subsidyPayer, address(this));
        uint256 available = balance < allowance ? balance : allowance;
        uint256 normalizedAvailable = _normalize(available, decimals);

        if (normalizedAvailable < shortfall) revert InsufficientSubsidy();

        subsidyAmount = _denormalize(shortfall, decimals);

        // Defensive: never transfer more than the available amount we observed.
        if (subsidyAmount > available) subsidyAmount = available;

        subsidyToken.safeTransferFrom(subsidyPayer, boringVault, subsidyAmount);

        // Re-normalize the actual amount transferred for accounting.
        subsidyAmountNormalized = _normalize(subsidyAmount, decimals);
    }

    //============================== APPROVAL TRACKING ===============================

    /**
     * @notice Ensures that any ERC20#approve or ERC20#increaseAllowance calls made
     *         by the vault to basket tokens during the batch have been fully reset
     *         to zero by the end of execution.
     * @param calls Batch of merkle-verified BoringVault actions.
     */
    function _enforceNoDanglingApprovals(ManageCalls calldata calls) internal view {
        uint256 callsLength = calls.targets.length;

        for (uint256 i; i < callsLength; ++i) {
            address target = calls.targets[i];
            if (!basketTokens.contains(target)) continue;

            bytes calldata targetData = calls.targetData[i];

            // Length check is >= 68 because some token contracts (e.g., compiled
            // with older Solidity versions) may tolerate trailing calldata on
            // low-level calls rather than reverting. approve(address,uint256) and
            // increaseAllowance(address,uint256) both require 4 + 32 + 32 = 68
            // bytes at minimum.
            if (targetData.length < 68) continue;

            bytes4 selector = bytes4(targetData[0:4]);
            if (selector != ERC20.approve.selector && selector != INCREASE_ALLOWANCE_SELECTOR) continue;

            // Spender is the first argument, located at byte offset 4 (selector)
            // + 32 (zero-padded address) = 36. Amount is the second argument,
            // spanning the next 32 bytes. This layout is identical for approve
            // and increaseAllowance.
            (address spender, uint256 amount) = abi.decode(targetData[4:68], (address, uint256));
            // A zero-amount approval cannot create a dangling allowance, so it
            // does not need to be checked. Note: this only skips the current call;
            // any preceding or subsequent non-zero approval to the same token and
            // spender will still be checked normally.
            if (amount == 0) continue;

            if (ERC20(target).allowance(boringVault, spender) != 0) {
                revert DanglingApproval();
            }
        }
    }

    /**
     * @notice Forwards a batch to ManagerWithMerkleVerification.
     * @dev Kept separate only to keep `execute` under the stack limit; inlining it is "stack too deep".
     * @param calls Batch of merkle-verified BoringVault actions.
     */
    function _manageVaultWithMerkleVerification(ManageCalls calldata calls) internal {
        manager.manageVaultWithMerkleVerification(
            calls.manageProofs, calls.decodersAndSanitizers, calls.targets, calls.targetData, calls.values
        );
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
