// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import {
    BaseDecoderAndSanitizer,
    DecoderCustomTypes
} from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

/// @notice Decodes the Uniswap Universal Router surface for a single-hop, exact-in V4 stablecoin swap: the Permit2
///         `approve` that funds the router, and an `execute` program shaped as one `V4_SWAP` followed by the `SWEEP`s
///         that return funds to the vault. The program is enforced, not just inspected: the swap must be a single
///         exact-in pool swap, and the only commands allowed after it are SWEEPs of exactly the swap's input and
///         output currencies, each to the vault, as the final commands. The swap's own actions may only settle/take
///         to the router (no recipient-bearing TAKE), so swapped funds cannot be diverted and cannot be left
///         stranded in the router.
abstract contract UniswapUniversalStablecoinDecoderAndSanitizer is BaseDecoderAndSanitizer {

    //============================== ERRORS ===============================

    error UniswapUniversalStablecoinDecoderAndSanitizer__LengthMismatch();
    error UniswapUniversalStablecoinDecoderAndSanitizer__SwapMustComeFirst();
    error UniswapUniversalStablecoinDecoderAndSanitizer__OnlySweepsAfterSwap(uint256 command);
    error UniswapUniversalStablecoinDecoderAndSanitizer__UnsupportedAction(uint256 action);
    error UniswapUniversalStablecoinDecoderAndSanitizer__SingleHopOnly();
    error UniswapUniversalStablecoinDecoderAndSanitizer__NoSwapAction();
    error UniswapUniversalStablecoinDecoderAndSanitizer__SweepRecipientNotVault(address recipient);
    error UniswapUniversalStablecoinDecoderAndSanitizer__SweepTokenNotInRoute(address token);
    error UniswapUniversalStablecoinDecoderAndSanitizer__IncompleteSweep();
    error UniswapUniversalStablecoinDecoderAndSanitizer__AllowRevertNotPermitted(uint256 command);

    //============================== COMMAND IDS ===============================
    // From the modern (V4) Uniswap Commands.sol. A command byte's low 7 bits (0x7f) are the command type; the
    // high bit (0x80) is the allow-revert flag.

    bytes1 internal constant COMMAND_TYPE_MASK = 0x7f;
    bytes1 internal constant FLAG_ALLOW_REVERT = 0x80;
    bytes1 internal constant COMMAND_SWEEP = 0x04;
    bytes1 internal constant V4_SWAP = 0x10;

    //============================== V4 SWAP ACTION IDS ===============================
    // From Uniswap v4-periphery Actions.sol.

    uint256 internal constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint256 internal constant SETTLE_ALL = 0x0c;
    uint256 internal constant TAKE_ALL = 0x0f;

    /// @dev Universal Router recipient sentinel that resolves to the original caller (the vault), per
    ///      `ActionConstants.MSG_SENDER`. A SWEEP to this or to the vault address both deliver to the vault.
    address internal constant ADDRESS_MSG_SENDER = address(1);

    //============================== ENTRYPOINTS ===============================

    // @desc Universal Router entrypoint; decodes a single-hop V4 swap followed by its closing SWEEPs
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

    /// @dev Enforces the program shape: command 0 is the V4 swap (giving the input/output currencies); every command
    ///      after it is a SWEEP to the vault, and together they must sweep exactly the input and output currencies.
    ///      So a SWEEP always closes the program for precisely the swapped tokens.
    function _decodeCommands(
        bytes calldata commands,
        bytes[] calldata inputs
    )
        internal
        view
        returns (bytes memory addressesFound)
    {
        if (commands.length != inputs.length) revert UniswapUniversalStablecoinDecoderAndSanitizer__LengthMismatch();
        // Every command must let a revert bubble up (allow-revert flag unset), so a failing command — e.g. a sweep
        // that does not return the funds — reverts the whole tx rather than being silently skipped.
        for (uint256 i; i < commands.length; ++i) {
            bytes1 command = commands[i];
            if (command & FLAG_ALLOW_REVERT != 0) {
                revert UniswapUniversalStablecoinDecoderAndSanitizer__AllowRevertNotPermitted(uint256(uint8(command)));
            }
        }
        if (commands.length == 0 || commands[0] & COMMAND_TYPE_MASK != V4_SWAP) {
            revert UniswapUniversalStablecoinDecoderAndSanitizer__SwapMustComeFirst();
        }

        address currencyIn;
        address currencyOut;
        (currencyIn, currencyOut, addressesFound) = _handleV4Swap(inputs[0]);

        bool sweptIn;
        bool sweptOut;
        for (uint256 i = 1; i < commands.length; ++i) {
            bytes1 command = commands[i] & COMMAND_TYPE_MASK;
            if (command != COMMAND_SWEEP) {
                revert UniswapUniversalStablecoinDecoderAndSanitizer__OnlySweepsAfterSwap(uint256(uint8(command)));
            }
            // SWEEP input = (address token, address recipient, uint256 amountMin)
            (address token, address recipient,) = abi.decode(inputs[i], (address, address, uint256));
            if (recipient != boringVault && recipient != ADDRESS_MSG_SENDER) {
                revert UniswapUniversalStablecoinDecoderAndSanitizer__SweepRecipientNotVault(recipient);
            }
            if (token == currencyIn) sweptIn = true;
            else if (token == currencyOut) sweptOut = true;
            else revert UniswapUniversalStablecoinDecoderAndSanitizer__SweepTokenNotInRoute(token);
            addressesFound = abi.encodePacked(addressesFound, token, recipient);
        }
        if (!sweptIn || !sweptOut) revert UniswapUniversalStablecoinDecoderAndSanitizer__IncompleteSweep();
    }

    //============================== V4 SWAP ACTION DISPATCH ===============================

    /// @dev The V4_SWAP input is `(bytes actions, bytes[] params)`. Requires exactly one exact-in single-hop swap and
    ///      returns its input/output currencies. The only other allowed actions are SETTLE_ALL (pay the input owed to
    ///      the pool) and TAKE_ALL (take the whole owed output to the router); both are required for the swap's
    ///      flash-accounting deltas to net to zero. Recipient-bearing TAKE/TAKE_PORTION are rejected so output cannot
    ///      be sent anywhere but the router, to be swept by the caller.
    function _handleV4Swap(bytes calldata input)
        internal
        pure
        returns (address currencyIn, address currencyOut, bytes memory addressesFound)
    {
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
                (currencyIn, currencyOut) = p.zeroForOne
                    ? (p.poolKey.currency0, p.poolKey.currency1)
                    : (p.poolKey.currency1, p.poolKey.currency0);
                addressesFound =
                    abi.encodePacked(addressesFound, _poolKey(p.poolKey), p.zeroForOne, uint256(p.amountOutMinimum));
            } else if (action == SETTLE_ALL || action == TAKE_ALL) {
                (address currency,) = abi.decode(params[i], (address, uint256));
                addressesFound = abi.encodePacked(addressesFound, currency);
            } else {
                revert UniswapUniversalStablecoinDecoderAndSanitizer__UnsupportedAction(action);
            }
        }
        if (!swapSeen) revert UniswapUniversalStablecoinDecoderAndSanitizer__NoSwapAction();
    }

    //============================== HELPERS ===============================

    /// @dev Pool identity is pinned exactly: both currencies, the fee/tickSpacing that select the pool, and the
    ///      hooks contract (arbitrary code, so it must be an approved address).
    function _poolKey(DecoderCustomTypes.V4PoolKey memory key) internal pure returns (bytes memory) {
        return abi.encodePacked(key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks);
    }

}
