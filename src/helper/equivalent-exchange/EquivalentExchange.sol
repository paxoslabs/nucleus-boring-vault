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
        bytes[] calldata targetData
    )
        external
        requiresAuth
    {
        uint256 tokensLength = tokens.length;
        if (tokensLength != amountsIn.length) revert LengthMismatch();

        uint256 targetsLength = targets.length;
        if (targetsLength != targetData.length) revert LengthMismatch();

        uint8[] memory tokenDecimals = new uint8[](tokensLength);
        uint256 totalIn;

        for (uint256 i; i < tokensLength; ++i) {
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

        for (uint256 i; i < targetsLength; ++i) {
            targets[i].functionCall(targetData[i]);
        }

        uint256 totalOut;

        for (uint256 i; i < tokensLength; ++i) {
            ERC20 token = tokens[i];
            uint256 balance = token.balanceOf(address(this));
            if (balance > 0) token.safeTransfer(msg.sender, balance);
            totalOut += _normalize(balance, tokenDecimals[i]);
        }

        if (totalOut < totalIn) revert InsufficientReturn(totalIn, totalOut);

        emit Executed(msg.sender, totalIn, totalOut);
    }

    function _normalize(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        if (decimals <= NORMALIZED_DECIMALS) {
            return amount * (10 ** (NORMALIZED_DECIMALS - decimals));
        }
        return amount / (10 ** (decimals - NORMALIZED_DECIMALS));
    }

}
