// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IFeeModule } from "src/interfaces/IFeeModule.sol";
import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import { IAuth } from "src/interfaces/IAuth.sol";

interface IWithdrawQueue is IAuth {

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
        PENDING_REFUND,
        COMPLETE_REFUNDED,
        FAILED_TRANSFER_REFUNDED
    }

    enum ApprovalMethod {
        EIP20_APPROVE,
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
    }

    struct SubmitOrderParams {
        uint256 amountOffer;
        IERC20 wantAsset;
        address intendedDepositor;
        address receiver;
        address refundReceiver;
        SignatureParams signatureParams;
    }

    function setFeeModule(IFeeModule _feeModule) external;
    function setFeeRecipient(address _feeRecipient) external;
    function setTellerWithMultiAssetSupport(TellerWithMultiAssetSupport _newTeller) external;
    function updateAssetMinimumOrderSize(uint256 _newMinimum) external;
    function manageERC20(IERC20 token, uint256 amount, address receiver) external;
    function forceProcessOrders(uint256[] calldata orderIndices) external;
    function forceProcess(uint256 orderIndex) external;
    function cancelOrder(uint256 orderIndex) external;
    function cancelOrderWithSignature(uint256 orderIndex, uint256 deadline, bytes calldata cancelSignature) external;
    function refundOrder(uint256 orderIndex) external;
    function refundOrders(uint256[] calldata orderIndices) external;
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
    function CANCEL_ORDER_TYPEHASH() external view returns (bytes32);
    function nonces(address user) external view returns (uint256);
    function offerAsset() external view returns (IERC20);
    function minimumOrderSize() external view returns (uint256);
    function feeModule() external view returns (IFeeModule);
    function feeRecipient() external view returns (address);
    function tellerWithMultiAssetSupport() external view returns (TellerWithMultiAssetSupport);
    function orderAtQueueIndex(uint256 orderIndex)
        external
        view
        returns (
            uint256 amountOffer,
            IERC20 wantAsset,
            address refundReceiver,
            OrderType orderType,
            bool didOrderFailTransfer
        );
    function lastProcessedOrder() external view returns (uint256);
    function latestOrder() external view returns (uint256);

}
