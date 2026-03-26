// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { BridgeData } from "src/base/Roles/CrossChain/CrossChainTellerBase.sol";
import { DecoderCustomTypes } from "src/interfaces/DecoderCustomTypes.sol";

abstract contract NucleusDecoderAndSanitizer is BaseDecoderAndSanitizer {

    error NucleusDecoderAndSanitizer__ExitFunctionForInternalBurnUseOnly();

    // @desc deposit into nucleus via the teller
    // @tag depositAsset:address:ERC20 to deposit, must be supported and approved
    function deposit(
        ERC20 depositAsset,
        uint256 depositAmount,
        uint256 minimumMint
    )
        external
        pure
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(depositAsset);
    }

    // @desc deposit into nucleus via the predicate proxy
    // @tag depositAsset:address:ERC20 to deposit, must be supported and approved
    // @tag recipient:address:receiver of shares
    // @tag teller:address:teller contract to deposit with
    function deposit(
        ERC20 depositAsset,
        uint256 depositAmount,
        uint256 minimumMint,
        address recipient,
        address teller,
        DecoderCustomTypes.PredicateMessage calldata predicateMessage
    )
        external
        pure
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(depositAsset, recipient, teller);
    }

    // add the deposit with receiver for forward compatibility with audited teller
    // @desc teller deposit with receiver (post-Feb 2025 audits)
    // @tag depositAsset:address:ERC20 to deposit
    // @tag to:address:receiver
    function deposit(
        ERC20 depositAsset,
        uint256 depositAmount,
        uint256 minimumMint,
        address to
    )
        external
        pure
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(depositAsset, to);
    }

    // @desc bridge shares using teller
    // @tag chainSelector:uint32:chain selector
    // @tag destinationChainReceiver:address:receiver
    // @tag bridgeFeeToken:address:fee token
    // @tag messageGas:uint64:gas for message
    function bridge(uint256 shareAmount, BridgeData calldata data) external pure returns (bytes memory addressesFound) {
        addressesFound =
            abi.encodePacked(data.chainSelector, data.destinationChainReceiver, data.bridgeFeeToken, data.messageGas);
    }

    // @desc teller deposit and bridge
    // @tag depositAsset:address:ERC20 to deposit
    // @tag chainSelector:uint32:chain selector
    // @tag destinationChainReceiver:address:receiver
    // @tag bridgeFeeToken:address:fee token
    // @tag messageGas:uint64:gas for message
    function depositAndBridge(
        ERC20 depositAsset,
        uint256 depositAmount,
        uint256 minimumMint,
        BridgeData calldata data
    )
        external
        pure
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(
            depositAsset, data.chainSelector, data.destinationChainReceiver, data.bridgeFeeToken, data.messageGas
        );
    }

    // @desc updateAtomicRequest to withdraw from vault using newer UCP
    // @tag offer:address:ERC20 to withdraw
    // @tag want:address:ERC20 to withdraw into
    // @tag recipient:address:receiver
    function updateAtomicRequest(
        ERC20 offer,
        ERC20 want,
        DecoderCustomTypes.AtomicRequestUCP calldata userRequest
    )
        external
        pure
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(offer, want, userRequest.recipient);
    }

    // @desc claim fees from a nucleus vault, must be authorized to call
    // @tag token:address:ERC20 to claim fees with
    function claimFees(ERC20 token) external pure returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(token);
    }

    // @desc Allows burner to burn shares, in exchange for assets, only supports burning with all but share amount 0
    function exit(
        address to,
        ERC20 asset,
        uint256 assetAmount,
        address from,
        uint256
    )
        external
        view
        returns (bytes memory addressesFound)
    {
        if (to != address(0) || address(asset) != address(0) || assetAmount != 0 || from != boringVault) {
            revert NucleusDecoderAndSanitizer__ExitFunctionForInternalBurnUseOnly();
        }
    }

    // @desc bulk withdraw from teller
    // @tag withdrawAsset:address:ERC20 to withdraw
    // @tag to:address:receiver
    function bulkWithdraw(
        ERC20 withdrawAsset,
        uint256 shareAmount,
        uint256 minimumAssets,
        address to
    )
        external
        pure
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(withdrawAsset, to);
    }

    // @desc deleverage using the LHYPEDeleverage contract
    function deleverage(
        uint256,
        uint256,
        uint256,
        bytes32[] memory,
        address
    )
        external
        pure
        returns (bytes memory addressesFound)
    {
        // Nothing to decode
    }

    // @desc process orders using the one to one queue
    function processOrders(uint256 ordersToProcess) external pure returns (bytes memory addressesFound) {
        // Nothing to decode
    }

}
