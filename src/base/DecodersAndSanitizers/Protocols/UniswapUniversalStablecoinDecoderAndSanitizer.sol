// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import {
    BaseDecoderAndSanitizer,
    DecoderCustomTypes
} from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

/// @notice Decodes the Uniswap Universal Router surface for a single-hop, exact-in V4 stablecoin swap: the Permit2
///         `approve` that funds the router, and an `execute` program of exactly two commands — one `V4_SWAP` followed
///         by one `SWEEP` of the swap's output token back to the vault. Enforced, not just inspected:
///         - neither command may set the allow-revert flag, so any failure reverts the whole tx;
///         - the program must be exactly [V4_SWAP, SWEEP];
///         - inside the swap, the only allowed actions are one SWAP_EXACT_IN_SINGLE plus SETTLE_ALL / TAKE_ALL;
///         - the sweep must move the swap's output currency to the vault, so the output cannot be stranded in the
///           router.
/// @dev Exact-in consumes all input, so a single output sweep suffices. The swap commits its output currency (to
///      match the sweep token) and its price floor (`amountIn * 1e18 / amountOutMinimum`, the worst input-per-output
///      rate the merkle leaf will accept); the pool's fee/tickSpacing/hooks are not committed.
abstract contract UniswapUniversalStablecoinDecoderAndSanitizer is BaseDecoderAndSanitizer {

    //============================== ERRORS ===============================

    error UniswapUniversalStablecoinDecoderAndSanitizer__LengthMismatch();
    error UniswapUniversalStablecoinDecoderAndSanitizer__UnexpectedCommandLength(uint256 commandCount);
    error UniswapUniversalStablecoinDecoderAndSanitizer__UnexpectedCommand();
    error UniswapUniversalStablecoinDecoderAndSanitizer__SweepTokenNotOutput(address token);
    error UniswapUniversalStablecoinDecoderAndSanitizer__SweepRecipientNotVault(address recipient);
    error UniswapUniversalStablecoinDecoderAndSanitizer__UnsupportedAction(uint256 action);
    error UniswapUniversalStablecoinDecoderAndSanitizer__SingleHopOnly();
    error UniswapUniversalStablecoinDecoderAndSanitizer__NoSwapAction();

    //============================== COMMAND IDS ===============================
    // From the modern (V4) Uniswap Commands.sol. A command byte's low 7 bits (0x7f) are the command type; the
    // high bit (0x80) is the allow-revert flag.  The constants below are the
    // full 8-bit values expected by the decoder (allow-revert flag unset).

    bytes1 internal constant COMMAND_TYPE_MASK = 0xff;
    bytes1 internal constant COMMAND_SWEEP = 0x04;
    bytes1 internal constant COMMAND_V4_SWAP = 0x10;

    //============================== V4 SWAP ACTION IDS ===============================
    // From Uniswap v4-periphery Actions.sol.

    uint256 internal constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint256 internal constant SETTLE_ALL = 0x0c;
    uint256 internal constant TAKE_ALL = 0x0f;

    /// @dev Fixed-point scale for the committed swap price. `amountIn / amountOutMinimum` would truncate to ~1 for a
    ///      stablecoin pair, so the price is scaled: `amountIn * PRICE_SCALE / amountOutMinimum` — the worst (max)
    ///      input paid per unit of output. The scale also sets the price's resolution.
    uint256 private constant PRICE_SCALE = 1e18;

    /// @dev Universal Router recipient sentinel that resolves to the original caller (the vault), per
    ///      `ActionConstants.MSG_SENDER`. A SWEEP to this or to the vault address both deliver to the vault.
    address internal constant ADDRESS_MSG_SENDER = address(1);

    //============================== ENTRYPOINTS ===============================

    // @desc Universal Router entrypoint; decodes a single-hop V4 swap followed by its closing SWEEP
    function execute(
        bytes calldata commands,
        bytes[] calldata inputs
    )
        external
        view
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = _decodeCommands(commands, inputs);
    }

    // @desc Universal Router entrypoint with a deadline; the deadline is not address data and is not committed
    function execute(
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256
    )
        external
        view
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = _decodeCommands(commands, inputs);
    }

    //============================== PERMIT2 ===============================
    // Target is the Permit2 contract, not the router.

    // @desc Permit2 AllowanceTransfer.approve — grants `spender` (the Universal Router) an expiring allowance over
    //       `token` in the Permit2 ledger. The vault uses this no-signature path because it is keyless.
    // @tag token:address:the token being granted
    // @tag spender:address:the address allowed to pull the token via Permit2
    function approve(
        address token,
        address spender,
        uint160,
        uint48
    )
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(token, spender);
    }

    //============================== COMMAND DISPATCH ===============================

    /// @dev The program must be exactly [V4_SWAP, SWEEP], neither allowing revert, and the SWEEP must return the
    ///      swap's output currency to the vault. The sweep recipient is constrained to the vault (or the MSG_SENDER
    ///      sentinel that resolves to it), so only the swept token and the swap's committed price floor are returned.
    function _decodeCommands(
        bytes calldata commands,
        bytes[] calldata inputs
    )
        internal
        view
        returns (bytes memory addressesFound)
    {
        // Exact-in single-hop: one swap, one sweep of the output. Nothing more, nothing less.
        if (commands.length != 2) {
            revert UniswapUniversalStablecoinDecoderAndSanitizer__UnexpectedCommandLength(commands.length);
        }
        if (commands.length != inputs.length) revert UniswapUniversalStablecoinDecoderAndSanitizer__LengthMismatch();

        bytes1 swapCommand = commands[0];
        bytes1 sweepCommand = commands[1];
        if (swapCommand & COMMAND_TYPE_MASK != COMMAND_V4_SWAP) {
            revert UniswapUniversalStablecoinDecoderAndSanitizer__UnexpectedCommand();
        }
        if (sweepCommand & COMMAND_TYPE_MASK != COMMAND_SWEEP) {
            revert UniswapUniversalStablecoinDecoderAndSanitizer__UnexpectedCommand();
        }

        (address currencyOut, uint256 price) = _handleV4Swap(inputs[0]);
        address token = _handleSweep(inputs[1], currencyOut);

        addressesFound = abi.encodePacked(price, token);
    }

    //============================== V4 SWAP ACTION DISPATCH ===============================

    /// @dev Requires exactly one SWAP_EXACT_IN_SINGLE plus only SETTLE_ALL / TAKE_ALL actions, reverting on anything
    ///      else. Decodes the swap's pool key + direction (output currency, for the sweep check) and its
    ///      amounts (the committed price floor); Uniswap reverts on its own if the deltas are not settled, so
    ///      settle/take presence is not checked here.
    function _handleV4Swap(bytes calldata input) internal pure returns (address currencyOut, uint256 price) {
        (bytes memory actions, bytes[] memory params) = abi.decode(input, (bytes, bytes[]));
        if (actions.length != params.length) revert UniswapUniversalStablecoinDecoderAndSanitizer__LengthMismatch();
        bool swapSeen;
        for (uint256 i; i < actions.length; ++i) {
            uint256 action = uint8(actions[i]);
            if (action == SWAP_EXACT_IN_SINGLE) {
                if (swapSeen) revert UniswapUniversalStablecoinDecoderAndSanitizer__SingleHopOnly();
                swapSeen = true;
                DecoderCustomTypes.V4ExactInputSingleParams memory p =
                    abi.decode(params[i], (DecoderCustomTypes.V4ExactInputSingleParams));
                currencyOut = p.zeroForOne ? p.poolKey.currency1 : p.poolKey.currency0;
                // Reverts on amountOutMinimum == 0 (a swap with no output floor is unsafe and should never be
                // approved).
                price = (uint256(p.amountIn) * PRICE_SCALE) / p.amountOutMinimum;
            } else if (action != SETTLE_ALL && action != TAKE_ALL) {
                revert UniswapUniversalStablecoinDecoderAndSanitizer__UnsupportedAction(action);
            }
        }
        if (!swapSeen) revert UniswapUniversalStablecoinDecoderAndSanitizer__NoSwapAction();
    }

    /// @dev Decodes the SWEEP command input and validates that the swap's output currency is returned to the vault.
    ///      The amountMin parameter is not checked because, for a single-hop swap, it is identical to the swap
    ///      command's amountOutMinimum, which is checked.
    function _handleSweep(bytes calldata input, address currencyOut) internal view returns (address token) {
        address recipient;
        (token, recipient,) = abi.decode(input, (address, address, uint256));
        if (token != currencyOut) revert UniswapUniversalStablecoinDecoderAndSanitizer__SweepTokenNotOutput(token);
        if (recipient != boringVault && recipient != ADDRESS_MSG_SENDER) {
            revert UniswapUniversalStablecoinDecoderAndSanitizer__SweepRecipientNotVault(recipient);
        }
    }

}
