// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IFeeModule } from "src/interfaces/IFeeModule.sol";

interface IOneToOneQueue {

    enum OrderType {
        DEFAULT,
        PRE_FILLED,
        REFUND
    }

    enum OrderStatus {
        NOT_FOUND,
        PENDING,
        COMPLETE,
        COMPLETE_PRE_FILLED,
        COMPLETE_REFUNDED,
        FAILED_TRANSFER,
        FAILED_REFUND
    }

    enum ApprovalMethod {
        EIP20_APROVE,
        EIP2612_PERMIT
    }

    struct SignatureParams {
        ApprovalMethod approvalMethod;
        uint8 approvalV;
        bytes32 approvalR;
        bytes32 approvalS;
        bool submitWithSignature;
        uint256 deadline;
        bytes eip2612Signature;
        uint256 nonce;
    }

    struct SubmitOrderParams {
        uint256 amountOffer;
        IERC20 offerAsset;
        IERC20 wantAsset;
        address intendedDepositor;
        address receiver;
        address refundReceiver;
        SignatureParams signatureParams;
    }

    function setFeeModule(IFeeModule _feeModule) external;
    function setFeeRecipient(address _feeRecipient) external;
    function setRecoveryAddress(address _recoveryAddress) external;
    function addOfferAsset(address _asset, uint256 _minimumOrderSize) external;
    function updateAssetMinimumOrderSize(address _asset, uint256 _newMinimum) external;
    function removeOfferAsset(address _asset) external;
    function addWantAsset(address _asset) external;
    function removeWantAsset(address _asset) external;
    function updateOfferAssetRecipient(address _newAddress) external;
    function manageERC20(IERC20 token, uint256 amount, address receiver) external;
    function forceRefundOrders(uint256[] calldata orderIndices) external;
    function forceProcessOrders(uint256[] calldata orderIndices) external;
    function forceRefund(uint256 orderIndex) external;
    function forceProcess(uint256 orderIndex) external;
    function submitOrderAndProcess(
        SubmitOrderParams calldata params,
        uint256 ordersToProcess
    )
        external
        returns (uint256 orderIndex);
    function submitOrderAndProcessAll(SubmitOrderParams calldata params) external returns (uint256 orderIndex);
    function getOrderStatus(uint256 orderIndex) external view returns (OrderStatus);
    function submitOrder(SubmitOrderParams calldata params) external returns (uint256 orderIndex);
    function processOrders(uint256 ordersToProcess) external;
    function usedSignatureHashes(bytes32 hash) external view returns (bool);
    function supportedOfferAssets(address asset) external view returns (bool);
    function supportedWantAssets(address asset) external view returns (bool);
    function minimumOrderSizePerAsset(address asset) external view returns (uint256);
    function feeModule() external view returns (IFeeModule);
    function offerAssetRecipient() external view returns (address);
    function feeRecipient() external view returns (address);
    function recoveryAddress() external view returns (address);
    function queue(uint256 orderIndex)
        external
        view
        returns (
            uint128 amountOffer,
            uint128 amountWant,
            IERC20 offerAsset,
            IERC20 wantAsset,
            address refundReceiver,
            OrderType orderType,
            bool didOrderFailTransfer
        );
    function lastProcessedOrder() external view returns (uint256);
    function latestOrder() external view returns (uint256);

}
