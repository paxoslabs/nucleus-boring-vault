// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import {
    BaseDecoderAndSanitizer,
    DecoderCustomTypes
} from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

/// @notice Decodes the Uniswap Universal Router surface needed to perform a stablecoin swap: the Permit2 `approve`
///         that funds the router, the V2/V3/V4 swap commands inside `execute`, and the `SWEEP` that returns any
///         leftover to the vault. Each swap commits its minimum output (exact-in `amountOutMinimum`, exact-out
///         `amountInMaximum`) so the merkle leaf pins the worst price the strategist may accept. `execute` reverts
///         unless the command program contains a SWEEP, so a swap can never leave sweepable funds stranded in the
///         router. Position management and every other command are out of scope — route those through the dedicated
///         manager decoders.
abstract contract UniswapUniversalStablecoinDecoderAndSanitizer is BaseDecoderAndSanitizer {

    //============================== ERRORS ===============================

    error UniswapUniversalStablecoinDecoderAndSanitizer__LengthMismatch();
    error UniswapUniversalStablecoinDecoderAndSanitizer__BadV3PathFormat();
    error UniswapUniversalStablecoinDecoderAndSanitizer__UnsupportedCommand(uint256 command);
    error UniswapUniversalStablecoinDecoderAndSanitizer__UnsupportedAction(uint256 action);
    error UniswapUniversalStablecoinDecoderAndSanitizer__MissingSweep();

    //============================== COMMAND IDS (Uniswap Commands.sol, modern V4 router)
    // =============================== A command byte's low 7 bits (0x7f) are the type; the high bit (0x80) is the
    // allow-revert flag.

    bytes1 internal constant COMMAND_TYPE_MASK = 0x7f;
    bytes1 internal constant V3_SWAP_EXACT_IN = 0x00;
    bytes1 internal constant V3_SWAP_EXACT_OUT = 0x01;
    bytes1 internal constant COMMAND_SWEEP = 0x04;
    bytes1 internal constant V2_SWAP_EXACT_IN = 0x08;
    bytes1 internal constant V2_SWAP_EXACT_OUT = 0x09;
    bytes1 internal constant V4_SWAP = 0x10;

    //============================== V4 SWAP ACTION IDS (Uniswap v4-periphery Actions.sol)
    // ===============================

    uint256 internal constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint256 internal constant SWAP_EXACT_IN = 0x07; // multi-hop; gated, see _handleV4Action
    uint256 internal constant SWAP_EXACT_OUT_SINGLE = 0x08;
    uint256 internal constant SWAP_EXACT_OUT = 0x09; // multi-hop; gated, see _handleV4Action
    uint256 internal constant SETTLE = 0x0b;
    uint256 internal constant SETTLE_ALL = 0x0c;
    uint256 internal constant TAKE = 0x0e;
    uint256 internal constant TAKE_ALL = 0x0f;
    uint256 internal constant TAKE_PORTION = 0x10;

    //============================== ENTRYPOINTS ===============================

    // @desc Universal Router entrypoint; decodes the swap command program and requires a closing SWEEP
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

    //============================== PERMIT2 (target = the Permit2 contract, not the router)
    // ===============================

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

    function _decodeCommands(
        bytes calldata commands,
        bytes[] calldata inputs
    )
        internal
        view
        returns (bytes memory addressesFound)
    {
        if (commands.length != inputs.length) revert UniswapUniversalStablecoinDecoderAndSanitizer__LengthMismatch();
        bool sweepFound;
        for (uint256 i; i < commands.length; ++i) {
            bytes1 command = commands[i] & COMMAND_TYPE_MASK;
            if (command == COMMAND_SWEEP) sweepFound = true;
            addressesFound = abi.encodePacked(addressesFound, _handleCommand(command, inputs[i]));
        }
        // A swap that does not sweep can leave the swapped-out funds sitting in the router for anyone to take.
        if (!sweepFound) revert UniswapUniversalStablecoinDecoderAndSanitizer__MissingSweep();
    }

    function _handleCommand(bytes1 command, bytes calldata input) internal pure returns (bytes memory) {
        if (command == V4_SWAP) return _handleV4Swap(input);

        if (command == V3_SWAP_EXACT_IN || command == V3_SWAP_EXACT_OUT) {
            // input = abi.encode(address recipient, uint256 amount, uint256 minPrice, bytes path, bool payerIsUser)
            (address recipient,, uint256 minPrice) = abi.decode(input, (address, uint256, uint256));
            // The path is the 4th argument: word 3 holds its byte offset within the args, then [length][data].
            uint256 pathOffset = abi.decode(input[96:128], (uint256));
            uint256 pathLength = abi.decode(input[pathOffset:pathOffset + 32], (uint256));
            bytes calldata path = input[pathOffset + 32:pathOffset + 32 + pathLength];
            return abi.encodePacked(recipient, _extractV3PathAddresses(path), minPrice);
        }
        if (command == V2_SWAP_EXACT_IN || command == V2_SWAP_EXACT_OUT) {
            // (address recipient, uint256 amount, uint256 minPrice, address[] path, bool payerIsUser)
            (address recipient,, uint256 minPrice, address[] memory path,) =
                abi.decode(input, (address, uint256, uint256, address[], bool));
            bytes memory pathAddresses;
            for (uint256 i; i < path.length; ++i) {
                pathAddresses = abi.encodePacked(pathAddresses, path[i]);
            }
            return abi.encodePacked(recipient, pathAddresses, minPrice);
        }
        if (command == COMMAND_SWEEP) {
            // (address token, address recipient, uint256 amountMin)
            (address token, address recipient,) = abi.decode(input, (address, address, uint256));
            return abi.encodePacked(token, recipient);
        }
        revert UniswapUniversalStablecoinDecoderAndSanitizer__UnsupportedCommand(uint256(uint8(command)));
    }

    //============================== V4 SWAP ACTION DISPATCH ===============================

    /// @dev The V4_SWAP input is `(bytes actions, bytes[] params)`: each byte of `actions` is an action id with a
    ///      parallel `params` entry.
    function _handleV4Swap(bytes calldata input) internal pure returns (bytes memory addressesFound) {
        (bytes memory actions, bytes[] memory params) = abi.decode(input, (bytes, bytes[]));
        if (actions.length != params.length) revert UniswapUniversalStablecoinDecoderAndSanitizer__LengthMismatch();
        for (uint256 i; i < actions.length; ++i) {
            addressesFound = abi.encodePacked(addressesFound, _handleV4Action(uint8(actions[i]), params[i]));
        }
    }

    function _handleV4Action(uint256 action, bytes memory param) internal pure returns (bytes memory) {
        if (action == SWAP_EXACT_IN_SINGLE) {
            DecoderCustomTypes.V4ExactInputSingleParams memory p =
                abi.decode(param, (DecoderCustomTypes.V4ExactInputSingleParams));
            return abi.encodePacked(_poolKey(p.poolKey), p.zeroForOne, uint256(p.amountOutMinimum));
        }
        if (action == SWAP_EXACT_OUT_SINGLE) {
            DecoderCustomTypes.V4ExactOutputSingleParams memory p =
                abi.decode(param, (DecoderCustomTypes.V4ExactOutputSingleParams));
            return abi.encodePacked(_poolKey(p.poolKey), p.zeroForOne, uint256(p.amountInMaximum));
        }
        if (action == SETTLE) {
            (address currency,,) = abi.decode(param, (address, uint256, bool));
            return abi.encodePacked(currency);
        }
        if (action == SETTLE_ALL || action == TAKE_ALL) {
            (address currency,) = abi.decode(param, (address, uint256));
            return abi.encodePacked(currency);
        }
        if (action == TAKE || action == TAKE_PORTION) {
            (address currency, address recipient,) = abi.decode(param, (address, address, uint256));
            return abi.encodePacked(currency, recipient);
        }
        // The supported set mirrors the V4 swap router (`V4Router._handleAction`): swap singles plus
        // SETTLE/SETTLE_ALL/TAKE/TAKE_ALL/TAKE_PORTION settlement. SWAP_EXACT_IN / SWAP_EXACT_OUT (multi-hop) carry
        // PathKey[] structs whose layout differs across v4-periphery versions, so they stay gated until pinned.
        revert UniswapUniversalStablecoinDecoderAndSanitizer__UnsupportedAction(action);
    }

    //============================== HELPERS ===============================

    /// @dev Pool identity is pinned exactly: both currencies, the fee/tickSpacing that select the pool, and the
    ///      hooks contract (arbitrary code, so it must be an approved address).
    function _poolKey(DecoderCustomTypes.V4PoolKey memory key) internal pure returns (bytes memory) {
        return abi.encodePacked(key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks);
    }

    /// @dev A V3 path is `(token(20) fee(3))+ token(20)` packed: a 23-byte chunk per hop with a trailing 20-byte
    ///      token, so a valid length is `20 mod 23`. Extracts every token address (direction-agnostic — exact-out
    ///      paths are reversed but use the same layout).
    function _extractV3PathAddresses(bytes calldata path) internal pure returns (bytes memory addressesFound) {
        uint256 chunkSize = 23; // 3 bytes for the uint24 fee, 20 bytes for the token address
        uint256 pathLength = path.length;
        if (pathLength % chunkSize != 20) revert UniswapUniversalStablecoinDecoderAndSanitizer__BadV3PathFormat();
        uint256 pathAddressLength = 1 + (pathLength / chunkSize);
        uint256 pathIndex;
        for (uint256 i; i < pathAddressLength; ++i) {
            addressesFound = abi.encodePacked(addressesFound, path[pathIndex:pathIndex + 20]);
            pathIndex += chunkSize;
        }
    }

}
