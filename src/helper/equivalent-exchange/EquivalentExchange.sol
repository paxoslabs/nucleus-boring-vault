// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { Auth, Authority } from "@solmate/auth/Auth.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";

contract EquivalentExchange is Auth {

    using SafeTransferLib for ERC20;
    using Address for address;

    uint256 internal constant NORMALIZED_DECIMALS = 18;

    event Executed(address indexed caller, uint256 totalIn, uint256 totalOut);

    error LengthMismatch();
    error DanglingApproval(address token);
    error InsufficientReturn(uint256 totalIn, uint256 totalOut);

    constructor(address _owner, Authority _authority) Auth(_owner, _authority) { }

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
            totalOut += _coverShortfall(subsidyToken, subsidyProvider, totalIn - totalOut);
        }

        if (totalOut < totalIn) revert InsufficientReturn(totalIn, totalOut);

        emit Executed(msg.sender, totalIn, totalOut);
    }

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
            if (amountIn > 0) {
                token.safeTransferFrom(msg.sender, address(this), amountIn);
                totalIn += _normalize(amountIn, decimals);
            }

            if (token.allowance(msg.sender, address(this)) != 0) {
                revert DanglingApproval(address(token));
            }
        }
    }

    function _sweep(ERC20[] calldata tokens, uint8[] memory tokenDecimals) internal returns (uint256 totalOut) {
        for (uint256 i; i < tokens.length; ++i) {
            ERC20 token = tokens[i];
            uint256 balance = token.balanceOf(address(this));
            if (balance > 0) token.safeTransfer(msg.sender, balance);
            totalOut += _normalize(balance, tokenDecimals[i]);
        }
    }

    function _coverShortfall(ERC20 subsidyToken, address subsidyProvider, uint256 shortfall)
        internal
        returns (uint256)
    {
        uint8 subsidyDecimals = subsidyToken.decimals();
        uint256 subsidyAmount = _denormalize(shortfall, subsidyDecimals);
        subsidyToken.safeTransferFrom(subsidyProvider, msg.sender, subsidyAmount);
        return _normalize(subsidyAmount, subsidyDecimals);
    }

    function _normalize(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        if (decimals <= NORMALIZED_DECIMALS) {
            return amount * (10 ** (NORMALIZED_DECIMALS - decimals));
        }
        return amount / (10 ** (decimals - NORMALIZED_DECIMALS));
    }

    function _denormalize(uint256 normalizedAmount, uint8 decimals) internal pure returns (uint256) {
        if (decimals <= NORMALIZED_DECIMALS) {
            uint256 factor = 10 ** (NORMALIZED_DECIMALS - decimals);
            return (normalizedAmount + factor - 1) / factor;
        }
        return normalizedAmount * (10 ** (decimals - NORMALIZED_DECIMALS));
    }

}
