// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { Auth, Authority } from "@solmate/auth/Auth.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";

/// @title EquivalentExchange
/// @notice Stateless helper that sanitizes 1:1 token swaps.
/// @dev The caller supplies a set of tokens and an arbitrary list of calls (a swap route). The contract
///      pulls the specified input amounts from the caller, executes the calls, sweeps its entire balance
///      of the listed tokens back to the caller, and reverts unless the total normalized value returned
///      is greater than or equal to the total normalized value pulled in.
///
///      Every listed token is treated as worth one unit of every other token, after normalizing for
///      decimals. This allows merkle-gated BoringVault rebalances to guarantee no net loss of principal
///      for stable-equivalent assets regardless of the underlying swap route.
///
///      A subsidy can be provisioned to cover any shortfall between `totalIn` and `totalOut`. This
///      supports the accounting concept of provisioning: a caller may allocate reserves up front so
///      that a swap route can absorb slippage, fees, or minor value drift without breaking the invariant
///      that the caller must receive back at least what it put in.
///
///      Security assumptions:
///      - All listed tokens must implement standard ERC20 behavior, including `decimals()`.
///      - Fee-on-transfer and rebasing tokens are not supported.
///      - Listed assets should be genuinely value-equivalent (e.g. stablecoin basket); the merkle tree
///        is responsible for only pairing equivalent assets.
///      - The caller must grant this contract an allowance for exactly the amounts being pulled; any
///        residual allowance after the pull causes a revert.
///      - The merkle gating of execute() must only allow token approvals to this contract that are required tokens in
///       each execute() tokens array. It should be impossible to approve a token to be spent and not have it accounted
/// for in the balance check of an execute
contract EquivalentExchange is Auth {

    using SafeTransferLib for ERC20;
    using Address for address;

    /// @notice Decimal scale used for normalizing token amounts for 1:1 comparison.
    uint256 internal constant NORMALIZED_DECIMALS = 18;

    /// @notice Emitted when an `execute` call completes successfully.
    /// @param caller The address that called `execute`.
    /// @param totalIn Total normalized value pulled from the caller.
    /// @param totalOut Total normalized value swept back to the caller (and any subsidy applied).
    event Executed(
        address indexed caller,
        uint256 totalIn,
        uint256 totalOut,
        uint256 totalSubsidyAmount,
        ERC20 indexed subsidyToken
    );

    /// @notice Thrown when two array arguments are expected to have the same length but do not.
    error LengthMismatch();

    /// @notice Thrown when a listed token still has a non-zero caller allowance after the pull.
    /// @param token The token address with the dangling approval.
    error DanglingApproval(address token);

    /// @notice Thrown when the caller attempts to act as its own subsidy provider.
    error CannotSelfSubsidize();

    /// @notice Sets up the Auth inheritance with the provided owner and authority.
    /// @param _owner The initial owner of the contract.
    /// @param _authority The initial Authority contract used for `requiresAuth` checks.
    constructor(address _owner, Authority _authority) Auth(_owner, _authority) { }

    /// @notice Pulls tokens from the caller, executes an arbitrary swap route, sweeps the listed tokens
    ///         back, and enforces that the normalized output is at least the normalized input.
    /// @dev Array length mismatches are reverted immediately. Each listed token must have zero residual
    ///      allowance from the caller after the pull, preventing the swap route from pulling additional
    ///      funds out of the caller.
    ///
    ///      If the sweep does not cover `totalIn`, a subsidy is pulled from `subsidyProvider` in
    ///      `subsidyToken` to cover the shortfall. Any remaining shortfall after the subsidy would
    ///      violate the output >= input invariant and is guarded by an assert.
    ///
    ///      The function is access controlled via `requiresAuth`; actual vault usage is intended to be
    ///      gated upstream by `ManagerWithMerkleVerification`.
    /// @param tokens List of tokens to pull from the caller and later sweep back.
    /// @param amountsIn Amount of each token to pull from the caller. Use `0` for output-only tokens.
    /// @param targets Addresses to call in order during the swap route.
    /// @param targetData Calldata for each corresponding target.
    /// @param subsidyProvider Address to pull a subsidy from if the swap route underperforms.
    /// @param subsidyToken Token used to cover any shortfall.
    function execute(
        ERC20[] calldata tokens,
        uint256[] calldata amountsIn,
        address[] calldata targets,
        bytes[] calldata targetData,
        address subsidyProvider,
        ERC20 subsidyToken
    )
        external
        requiresAuth
    {
        if (tokens.length != amountsIn.length) revert LengthMismatch();
        if (targets.length != targetData.length) revert LengthMismatch();

        (uint8[] memory tokenDecimals, uint256 totalIn) = _pull(tokens, amountsIn);

        for (uint256 i; i < targets.length; ++i) {
            targets[i].functionCall(targetData[i]);
        }

        uint256 totalOut = _sweep(tokens, tokenDecimals);

        if (totalOut < totalIn) {
            if (subsidyProvider == msg.sender) revert CannotSelfSubsidize();
            totalOut += _coverShortfall(subsidyToken, subsidyProvider, totalIn - totalOut);
        }

        // Invariant: the caller must receive back at least what it put in. This is unreachable with
        // the current subsidy logic because _coverShortfall either covers the shortfall or reverts;
        // it is kept as a self-documenting guard against future changes to the subsidy behavior.
        assert(totalOut >= totalIn);

        emit Executed(msg.sender, totalIn, totalOut, totalIn - totalOut, subsidyToken);
    }

    /// @notice Pulls `amountsIn` of `tokens` from the caller and records their decimal values.
    /// @dev Reverts if any listed token still has a non-zero allowance from the caller after the pull.
    /// @param tokens List of tokens to pull from the caller.
    /// @param amountsIn Amount of each token to pull; parallel to `tokens`.
    /// @return tokenDecimals Array of decimal values for each token, in the same order as `tokens`.
    /// @return totalIn Total normalized value pulled from the caller.
    function _pull(
        ERC20[] calldata tokens,
        uint256[] calldata amountsIn
    )
        internal
        returns (uint8[] memory tokenDecimals, uint256 totalIn)
    {
        tokenDecimals = new uint8[](tokens.length);

        for (uint256 i; i < tokens.length; ++i) {
            ERC20 token = tokens[i];
            uint8 decimals = token.decimals();
            tokenDecimals[i] = decimals;

            uint256 amountIn = amountsIn[i];
            if (amountIn != 0) {
                token.safeTransferFrom(msg.sender, address(this), amountIn);
                totalIn += _normalize(amountIn, decimals);
            }

            if (token.allowance(msg.sender, address(this)) != 0) {
                revert DanglingApproval(address(token));
            }
        }
    }

    /// @notice Sweeps the contract's entire balance of each listed token back to the caller.
    /// @dev The balance is observed after the swap calls have run. The returned value is the sum of
    ///      all balances normalized to `NORMALIZED_DECIMALS`.
    /// @param tokens List of tokens to sweep.
    /// @param tokenDecimals Array of decimal values for each token, parallel to `tokens`.
    /// @return totalOut Total normalized value swept to the caller.
    function _sweep(ERC20[] calldata tokens, uint8[] memory tokenDecimals) internal returns (uint256 totalOut) {
        for (uint256 i; i < tokens.length; ++i) {
            ERC20 token = tokens[i];
            uint256 balance = token.balanceOf(address(this));
            if (balance != 0) token.safeTransfer(msg.sender, balance);
            totalOut += _normalize(balance, tokenDecimals[i]);
        }
    }

    /// @notice Pulls a subsidy from `subsidyProvider` to cover a shortfall between output and input.
    /// @dev The subsidy amount is denormalized from the 18-decimal shortfall to the subsidy token's
    ///      native decimals, transferred to the caller, and then re-normalized for accounting.
    /// @param subsidyToken Token to pull as a subsidy.
    /// @param subsidyProvider Address to pull the subsidy from.
    /// @param shortfall Shortfall in normalized 18-decimal units.
    /// @return The normalized value of the subsidy that was transferred.
    function _coverShortfall(ERC20 subsidyToken, address subsidyProvider, uint256 shortfall)
        internal
        returns (uint256)
    {
        uint8 subsidyDecimals = subsidyToken.decimals();
        uint256 subsidyAmount = _denormalize(shortfall, subsidyDecimals);
        subsidyToken.safeTransferFrom(subsidyProvider, msg.sender, subsidyAmount);
        return _normalize(subsidyAmount, subsidyDecimals);
    }

    /// @notice Rescales an amount to `NORMALIZED_DECIMALS` (18).
    /// @dev Tokens with fewer than 18 decimals are scaled up; tokens with more than 18 decimals are
    ///      scaled down.
    /// @param amount The amount to normalize.
    /// @param decimals The token's native decimal count.
    /// @return The amount normalized to 18 decimals.
    function _normalize(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        if (decimals <= NORMALIZED_DECIMALS) {
            return amount * (10 ** (NORMALIZED_DECIMALS - decimals));
        }
        return amount / (10 ** (decimals - NORMALIZED_DECIMALS));
    }

    /// @notice Rescales an amount from `NORMALIZED_DECIMALS` (18) to a token's native decimals.
    /// @dev For tokens with fewer than 18 decimals, the result is rounded up to avoid underestimating
    ///      the amount needed. Tokens with more than 18 decimals are scaled up.
    /// @param normalizedAmount The amount in 18-decimal normalized units.
    /// @param decimals The target token's native decimal count.
    /// @return The amount in the target token's native decimal units.
    function _denormalize(uint256 normalizedAmount, uint8 decimals) internal pure returns (uint256) {
        if (decimals <= NORMALIZED_DECIMALS) {
            uint256 factor = 10 ** (NORMALIZED_DECIMALS - decimals);
            return (normalizedAmount + factor - 1) / factor;
        }
        return normalizedAmount * (10 ** (decimals - NORMALIZED_DECIMALS));
    }

}
