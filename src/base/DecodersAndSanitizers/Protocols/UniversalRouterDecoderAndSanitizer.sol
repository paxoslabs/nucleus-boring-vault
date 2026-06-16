// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import {
    BaseDecoderAndSanitizer,
    DecoderCustomTypes
} from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

/// @notice Decodes the Uniswap Universal Router `execute` entrypoint, which dispatches V2, V3, and V4 swaps
///         (plus wrap / sweep / pay-portion / balance-check companions) through a single command program. One
///         `execute` call carries `commands` (one byte per command) and a parallel `inputs` array; this contract
///         walks both, extracts the committed bytes per command, and reverts on any command/action outside the
///         supported set. Also decodes the Permit2 `approve` the vault uses to fund the router (a call to the
///         Permit2 contract, not the router — the same decoder serves both targets).
abstract contract UniversalRouterDecoderAndSanitizer is BaseDecoderAndSanitizer {

    //============================== ERRORS ===============================

    error UniversalRouterDecoderAndSanitizer__LengthMismatch();
    error UniversalRouterDecoderAndSanitizer__BadV3PathFormat();
    error UniversalRouterDecoderAndSanitizer__UnsupportedCommand(uint256 command);
    error UniversalRouterDecoderAndSanitizer__UnsupportedAction(uint256 action);

    //============================== GRANULARITY ===============================

    /**
     * @notice Resolution at which a swap's slippage bound (exact-in `amountOutMinimum`, exact-out
     *         `amountInMaximum`) is committed to the merkle leaf, as `bound / granularity` plus a
     *         `bound % granularity == 0` flag. A band of `granularity` adjacent values maps to one leaf, so the
     *         strategist can move the bound within that band without a new leaf while the leaf still pins a
     *         floor/cap it cannot escape.
     * @dev A value of 0 omits the bound entirely, allowing any value (the treatment Uniswap V3 amounts get on the
     *      direct SwapRouter decoder). Set per deployment.
     */
    uint256 internal immutable granularity;

    constructor(uint256 _granularity) {
        granularity = _granularity;
    }

    //============================== COMMAND IDS (Uniswap Commands.sol, modern V4 router)
    // =============================== A command byte's low 7 bits (0x7f) are the type; the high bit (0x80) is the
    // allow-revert flag.

    bytes1 internal constant COMMAND_TYPE_MASK = 0x7f;
    bytes1 internal constant V3_SWAP_EXACT_IN = 0x00;
    bytes1 internal constant V3_SWAP_EXACT_OUT = 0x01;
    bytes1 internal constant SWEEP = 0x04;
    bytes1 internal constant PAY_PORTION = 0x06;
    bytes1 internal constant V2_SWAP_EXACT_IN = 0x08;
    bytes1 internal constant V2_SWAP_EXACT_OUT = 0x09;
    bytes1 internal constant WRAP_ETH = 0x0b;
    bytes1 internal constant UNWRAP_WETH = 0x0c;
    bytes1 internal constant BALANCE_CHECK_ERC20 = 0x0e;
    bytes1 internal constant V4_SWAP = 0x10;

    //============================== V4 ACTION IDS (Uniswap v4-periphery Actions.sol) ===============================

    uint256 internal constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint256 internal constant SWAP_EXACT_IN = 0x07; // multi-hop; gated, see _handleV4Action
    uint256 internal constant SWAP_EXACT_OUT_SINGLE = 0x08;
    uint256 internal constant SWAP_EXACT_OUT = 0x09; // multi-hop; gated, see _handleV4Action
    uint256 internal constant SETTLE = 0x0b;
    uint256 internal constant SETTLE_ALL = 0x0c;
    uint256 internal constant SETTLE_PAIR = 0x0d;
    uint256 internal constant TAKE = 0x0e;
    uint256 internal constant TAKE_ALL = 0x0f;
    uint256 internal constant TAKE_PORTION = 0x10;
    uint256 internal constant TAKE_PAIR = 0x11;

    //============================== ENTRYPOINTS ===============================

    // @desc Universal Router entrypoint; decodes the V2/V3/V4 command program
    // @tag packedArgs:bytes:per-command extracted addresses, pool keys, and granular slippage bounds
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
    // @tag packedArgs:bytes:per-command extracted addresses, pool keys, and granular slippage bounds
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

    // @desc Permit2 AllowanceTransfer.approve — grants `spender` (e.g. the Universal Router) an expiring allowance
    //       over `token` in the Permit2 ledger. The vault uses this no-signature path because it is keyless; the
    //       signature-based `permit` (the router's PERMIT2_PERMIT command) is unusable by a contract and omitted.
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
        if (commands.length != inputs.length) revert UniversalRouterDecoderAndSanitizer__LengthMismatch();
        for (uint256 i; i < commands.length; ++i) {
            bytes1 command = commands[i] & COMMAND_TYPE_MASK;
            addressesFound = abi.encodePacked(addressesFound, _handleCommand(command, inputs[i]));
        }
    }

    function _handleCommand(bytes1 command, bytes calldata input) internal view returns (bytes memory) {
        if (command == V4_SWAP) return _handleV4Swap(input);

        if (command == V3_SWAP_EXACT_IN || command == V3_SWAP_EXACT_OUT) {
            // (address recipient, uint256 amount, uint256 slippageBound, bytes path, bool payerIsUser)
            (address recipient,, uint256 slippageBound, bytes memory path,) =
                abi.decode(input, (address, uint256, uint256, bytes, bool));
            return abi.encodePacked(recipient, _extractV3PathAddresses(path), _bound(slippageBound));
        }
        if (command == V2_SWAP_EXACT_IN || command == V2_SWAP_EXACT_OUT) {
            // (address recipient, uint256 amount, uint256 slippageBound, address[] path, bool payerIsUser)
            (address recipient,, uint256 slippageBound, address[] memory path,) =
                abi.decode(input, (address, uint256, uint256, address[], bool));
            bytes memory pathAddresses;
            for (uint256 i; i < path.length; ++i) {
                pathAddresses = abi.encodePacked(pathAddresses, path[i]);
            }
            return abi.encodePacked(recipient, pathAddresses, _bound(slippageBound));
        }
        if (command == WRAP_ETH || command == UNWRAP_WETH) {
            // (address recipient, uint256 amount)
            (address recipient,) = abi.decode(input, (address, uint256));
            return abi.encodePacked(recipient);
        }
        if (command == SWEEP || command == PAY_PORTION) {
            // (address token, address recipient, uint256 amountOrBips)
            (address token, address recipient,) = abi.decode(input, (address, address, uint256));
            return abi.encodePacked(token, recipient);
        }
        if (command == BALANCE_CHECK_ERC20) {
            // A side-effect-free guard: the router does a staticcall `balanceOf` and reverts if below a minimum.
            // It moves no funds and changes no state, so nothing is committed — the executor may use balance
            // checks freely. (Only commit nothing for commands that are provably side-effect-free like this.)
            return "";
        }
        revert UniversalRouterDecoderAndSanitizer__UnsupportedCommand(uint256(uint8(command)));
    }

    //============================== V4 ACTION DISPATCH ===============================

    /// @dev The V4_SWAP input is `(bytes actions, bytes[] params)`: each byte of `actions` is an action id with a
    ///      parallel `params` entry.
    function _handleV4Swap(bytes calldata input) internal view returns (bytes memory addressesFound) {
        (bytes memory actions, bytes[] memory params) = abi.decode(input, (bytes, bytes[]));
        if (actions.length != params.length) revert UniversalRouterDecoderAndSanitizer__LengthMismatch();
        for (uint256 i; i < actions.length; ++i) {
            addressesFound = abi.encodePacked(addressesFound, _handleV4Action(uint8(actions[i]), params[i]));
        }
    }

    function _handleV4Action(uint256 action, bytes memory param) internal view returns (bytes memory) {
        if (action == SWAP_EXACT_IN_SINGLE) {
            DecoderCustomTypes.V4ExactInputSingleParams memory p =
                abi.decode(param, (DecoderCustomTypes.V4ExactInputSingleParams));
            return abi.encodePacked(_poolKey(p.poolKey), p.zeroForOne, _bound(p.amountOutMinimum));
        }
        if (action == SWAP_EXACT_OUT_SINGLE) {
            DecoderCustomTypes.V4ExactOutputSingleParams memory p =
                abi.decode(param, (DecoderCustomTypes.V4ExactOutputSingleParams));
            return abi.encodePacked(_poolKey(p.poolKey), p.zeroForOne, _bound(p.amountInMaximum));
        }
        if (action == SETTLE) {
            (address currency,,) = abi.decode(param, (address, uint256, bool));
            return abi.encodePacked(currency);
        }
        if (action == SETTLE_ALL || action == TAKE_ALL) {
            (address currency,) = abi.decode(param, (address, uint256));
            return abi.encodePacked(currency);
        }
        if (action == SETTLE_PAIR) {
            (address currency0, address currency1) = abi.decode(param, (address, address));
            return abi.encodePacked(currency0, currency1);
        }
        if (action == TAKE || action == TAKE_PORTION) {
            (address currency, address recipient,) = abi.decode(param, (address, address, uint256));
            return abi.encodePacked(currency, recipient);
        }
        if (action == TAKE_PAIR) {
            (address currency0, address currency1, address recipient) = abi.decode(param, (address, address, address));
            return abi.encodePacked(currency0, currency1, recipient);
        }
        // SWAP_EXACT_IN / SWAP_EXACT_OUT (multi-hop) carry PathKey[] structs whose layout differs across
        // v4-periphery versions; they stay gated until pinned to the deployed periphery commit and verified.
        revert UniversalRouterDecoderAndSanitizer__UnsupportedAction(action);
    }

    //============================== HELPERS ===============================

    /// @dev Pool identity is pinned exactly: both currencies, the fee/tickSpacing that select the pool, and the
    ///      hooks contract (arbitrary code, so it must be an approved address, never granular).
    function _poolKey(DecoderCustomTypes.V4PoolKey memory key) internal pure returns (bytes memory) {
        return abi.encodePacked(key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks);
    }

    /// @dev A V3 path is `(token(20) fee(3))+ token(20)` packed: an address every 23 bytes with a trailing 20-byte
    ///      token, so a valid length is `20 mod 23`. Extracts every token address (direction-agnostic — exact-out
    ///      paths are reversed but use the same layout).
    function _extractV3PathAddresses(bytes memory path) internal pure returns (bytes memory found) {
        if (path.length % 23 != 20) revert UniversalRouterDecoderAndSanitizer__BadV3PathFormat();
        uint256 numAddresses = 1 + (path.length / 23);
        for (uint256 i; i < numAddresses; ++i) {
            address token;
            uint256 offset = i * 23;
            // load 32 bytes at the chunk start and keep the high 20 (the address)
            assembly {
                token := shr(96, mload(add(add(path, 0x20), offset)))
            }
            found = abi.encodePacked(found, token);
        }
    }

    /// @dev Commit a slippage bound at `granularity` resolution, or omit it entirely when granularity is 0.
    function _bound(uint256 amount) internal view returns (bytes memory) {
        if (granularity == 0) return "";
        return abi.encodePacked(amount / granularity, amount % granularity == 0);
    }

}
