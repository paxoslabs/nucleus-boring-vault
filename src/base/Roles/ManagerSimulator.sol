// SPDX-License-Identifier: MIT
pragma solidity =0.8.21;

import { BoringVault } from "src/base/BoringVault.sol";
import { MerkleProofLib } from "@solmate/utils/MerkleProofLib.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { BalancerVault } from "src/interfaces/BalancerVault.sol";

/**
 * @title ManagerWithTokenBalanceVerification
 * @custom:security-contact security@paxoslabs.com
 */
contract ManagerSimulator {

    // CONSTANTS
    bytes4 SINGLE_MANAGE_SELECTOR = 0xf6e715d0;

    /// @dev not exactly an error. Errors with data so we can simulate calls and get this data with a dry run
    error ResultingTokenBalancesPostSimulation(address[] tokens, uint256[] tokenBals);
    error ResultingTokenBalancesEachStepPostSimulation(
        address[] tokens, uint8[] decimals, uint256[][] tokenBalsEachStep
    );

    // ERRORS
    error ManagerSimulator__ErrorGettingTokenBalance(address token, bytes response);
    error ManagerSimulator__ManagementError(address target, bytes targetData, uint256 value, bytes response);
    error ManagerSimulator__TokenHasNoCode(address token);

    // ManageCall struct
    struct ManageCall {
        address target;
        bytes targetData;
        uint256 valueToSend;
    }

    // Native token address signifier
    address public constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint8 public immutable nativeTokenDecimals;

    constructor(uint8 _nativeTokenDecimals) {
        nativeTokenDecimals = _nativeTokenDecimals;
    }

    /**
     * @dev helper function to get an array of token balances including native and reverts with exact token responsible
     * @param boringVault to get token balances of
     * @param tokens to scan for balances
     */
    function tokenBalances(
        BoringVault boringVault,
        address[] calldata tokens
    )
        public
        view
        returns (uint256[] memory tokenBals)
    {
        uint256 length = tokens.length;
        if (length == 0) {
            return tokenBals;
        }

        tokenBals = new uint256[](length);

        for (uint256 i; i < length;) {
            address token = tokens[i];
            if (token == NATIVE) {
                tokenBals[i] = address(boringVault).balance;
            } else {
                if (address(token).code.length == 0) revert ManagerSimulator__TokenHasNoCode(token);

                (bool success, bytes memory response) =
                    token.staticcall(abi.encodeWithSelector(ERC20.balanceOf.selector, address(boringVault)));

                if (!success) {
                    revert ManagerSimulator__ErrorGettingTokenBalance(token, response);
                }

                tokenBals[i] = abi.decode(response, (uint256));
            }

            unchecked {
                ++i;
            }
        }

        return tokenBals;
    }

    /**
     * @dev function to do token simulation, errors with the simulation data to avoid necessitating a sent transaction
     * @param boringVault to simulate on
     * @param manageCalls to perform
     * @param tokens to retrieve simulations for
     */
    function tokenBalancesSimulation(
        BoringVault boringVault,
        ManageCall[] calldata manageCalls,
        address[] calldata tokens
    )
        external
    {
        _manageVault(boringVault, manageCalls);
        uint256[] memory tokenBals = tokenBalances(boringVault, tokens);

        // Function will always revert
        revert ResultingTokenBalancesPostSimulation(tokens, tokenBals);
    }

    function _getTokensDecimals(address[] calldata tokens) internal returns (uint8[] memory decimals) {
        uint256 tokensLength = tokens.length;
        decimals = new uint8[](tokensLength);
        // get the token decimals
        for (uint256 i; i < tokensLength;) {
            if (tokens[i] == NATIVE) {
                decimals[i] = nativeTokenDecimals;
            } else {
                decimals[i] = ERC20(tokens[i]).decimals();
            }

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev function to do simulation but return values at each step including before any manage calls, then after each
     * one
     * @param boringVault to simulate on
     * @param manageCalls to perform
     * @param tokens to retrieve simulations for
     */
    function tokenBalancesSimulationReturnEachStep(
        BoringVault boringVault,
        ManageCall[] calldata manageCalls,
        address[] calldata tokens
    )
        external
    {
        uint256 length = manageCalls.length;

        uint8[] memory decimals = _getTokensDecimals(tokens);
        uint256[][] memory tokenBalsEachStep = new uint256[][](length + 1);

        // initialize tokenBalsEachStep with beginning balances
        tokenBalsEachStep[0] = tokenBalances(boringVault, tokens);

        // Do each manage call and collect token balances after
        for (uint256 i; i < length;) {
            ManageCall memory call = manageCalls[i];
            (bool success, bytes memory response) = address(boringVault)
                .call(abi.encodeWithSelector(SINGLE_MANAGE_SELECTOR, call.target, call.targetData, call.valueToSend));

            if (!success) {
                revert ManagerSimulator__ManagementError(call.target, call.targetData, call.valueToSend, response);
            }

            tokenBalsEachStep[i + 1] = tokenBalances(boringVault, tokens);

            unchecked {
                ++i;
            }
        }

        // Function will always revert
        revert ResultingTokenBalancesEachStepPostSimulation(tokens, decimals, tokenBalsEachStep);
    }

    /// NOTE _manageVault calls manage() directly for simplicity, and does not simulate errors with decoders, tree
    /// permissions or micromanagers
    function _manageVault(BoringVault boringVault, ManageCall[] calldata manageCalls) internal {
        // for loop to do execution, if failure error verbose
        uint256 length = manageCalls.length;
        for (uint256 i; i < length;) {
            ManageCall memory call = manageCalls[i];
            (bool success, bytes memory response) = address(boringVault)
                .call(abi.encodeWithSelector(SINGLE_MANAGE_SELECTOR, call.target, call.targetData, call.valueToSend));

            if (!success) {
                revert ManagerSimulator__ManagementError(call.target, call.targetData, call.valueToSend, response);
            }

            unchecked {
                ++i;
            }
        }
    }

}
