// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import {
    BaseDecoderAndSanitizer,
    DecoderCustomTypes
} from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

/// @notice Decodes the Uniswap Universal Router surface for a single-hop, exact-in V4 stablecoin swap: the Permit2
///         `approve` that funds the router, and an `execute` program of exactly one `V4_SWAP` command. Enforced, not
///         just inspected:
///         - the command may not set the allow-revert flag, so any failure reverts the whole tx;
///         - the program must be exactly [V4_SWAP];
///         - inside the swap, the only allowed actions are one SWAP_EXACT_IN_SINGLE plus SETTLE_ALL / TAKE_ALL.
/// @dev `TAKE_ALL` sends the output to `msgSender()` — the vault, as the `execute` caller — with no recipient
///      parameter, so the output returns to the vault and cannot be redirected. The swap commits the canonical v4
///      PoolId (keccak256 of the full pool key) plus the swap direction (zeroForOne), so a merkle leaf pins the
///      exact pool — including the hooks contract — and the specific direction it may trade.
abstract contract UniswapUniversalStablecoinDecoderAndSanitizer is BaseDecoderAndSanitizer {

    //============================== ERRORS ===============================

    error UniswapUniversalStablecoinDecoderAndSanitizer__LengthMismatch();
    error UniswapUniversalStablecoinDecoderAndSanitizer__UnexpectedCommandLength(uint256 commandCount);
    error UniswapUniversalStablecoinDecoderAndSanitizer__UnexpectedCommand();
    error UniswapUniversalStablecoinDecoderAndSanitizer__UnsupportedAction(uint256 action);
    error UniswapUniversalStablecoinDecoderAndSanitizer__UnexpectedActionLength(uint256 actionLength);

    //============================== COMMAND IDS ===============================
    // From the modern (V4) Uniswap Commands.sol. A command byte's low 7 bits (0x7f) are the command type; the
    // high bit (0x80) is the allow-revert flag. The constant below is the full 8-bit value expected by the decoder
    // (allow-revert flag unset), so matching against the full byte also rejects the allow-revert flag.

    bytes1 internal constant COMMAND_TYPE_MASK = 0xff;
    bytes1 internal constant COMMAND_V4_SWAP = 0x10;

    //============================== V4 SWAP ACTION IDS ===============================
    // From Uniswap v4-periphery Actions.sol.

    uint256 internal constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint256 internal constant SETTLE_ALL = 0x0c;
    uint256 internal constant TAKE_ALL = 0x0f;

    //============================== ENTRYPOINTS ===============================

    // @desc Universal Router entrypoint; decodes a single-hop exact-in V4 swap
    function execute(
        bytes calldata commands,
        bytes[] calldata inputs
    )
        external
        pure
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
        pure
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

    /// @dev The program must be exactly one V4_SWAP command (allow-revert flag unset). The swap's PoolId and
    ///      direction are committed.
    function _decodeCommands(
        bytes calldata commands,
        bytes[] calldata inputs
    )
        internal
        pure
        returns (bytes memory addressesFound)
    {
        if (commands.length != 1) {
            revert UniswapUniversalStablecoinDecoderAndSanitizer__UnexpectedCommandLength(commands.length);
        }
        if (commands.length != inputs.length) revert UniswapUniversalStablecoinDecoderAndSanitizer__LengthMismatch();
        if (commands[0] & COMMAND_TYPE_MASK != COMMAND_V4_SWAP) {
            revert UniswapUniversalStablecoinDecoderAndSanitizer__UnexpectedCommand();
        }

        addressesFound = abi.encodePacked(_handleV4Swap(inputs[0]));
    }

    //============================== V4 SWAP ACTION DISPATCH ===============================

    /// @dev Requires exactly three actions: SWAP_EXACT_IN_SINGLE followed by SETTLE_ALL and TAKE_ALL. Commits the
    ///      canonical v4 PoolId (the keccak256 of the full pool key) and the swap direction (zeroForOne), so the leaf
    ///      pins both the exact pool — including its hooks contract — and the direction it may trade. `hookData` is
    /// not
    ///      committed. Uniswap reverts on its own if the deltas are not settled, so settle/take presence is not checked
    ///      here.
    function _handleV4Swap(bytes calldata input) internal pure returns (bytes memory poolIdAndDirection) {
        (bytes memory actions, bytes[] memory params) = abi.decode(input, (bytes, bytes[]));
        if (actions.length != params.length) revert UniswapUniversalStablecoinDecoderAndSanitizer__LengthMismatch();
        if (actions.length != 3) {
            revert UniswapUniversalStablecoinDecoderAndSanitizer__UnexpectedActionLength(actions.length);
        }

        uint256 action0 = uint8(actions[0]);
        if (action0 != SWAP_EXACT_IN_SINGLE) {
            revert UniswapUniversalStablecoinDecoderAndSanitizer__UnsupportedAction(action0);
        }
        DecoderCustomTypes.V4ExactInputSingleParams memory p =
            abi.decode(params[0], (DecoderCustomTypes.V4ExactInputSingleParams));

        // Commit the canonical v4 PoolId plus direction. The PoolId is keccak256(abi.encode(poolKey)) — `abi.encode`
        // (NOT encodePacked) is required so this equals Uniswap's PoolIdLibrary.toId. Hashing all five pool-key fields
        // pins the exact pool (including the hooks contract); `zeroForOne` then pins the direction it may trade.
        bytes32 poolId = keccak256(abi.encode(p.poolKey));
        poolIdAndDirection = abi.encodePacked(poolId, p.zeroForOne);

        uint256 action1 = uint8(actions[1]);
        if (action1 != SETTLE_ALL && action1 != TAKE_ALL) {
            revert UniswapUniversalStablecoinDecoderAndSanitizer__UnsupportedAction(action1);
        }
        uint256 action2 = uint8(actions[2]);
        if (action2 != SETTLE_ALL && action2 != TAKE_ALL) {
            revert UniswapUniversalStablecoinDecoderAndSanitizer__UnsupportedAction(action2);
        }
    }

}
