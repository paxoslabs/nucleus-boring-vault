// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { ERC721Enumerable, ERC721 } from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IFeeModule } from "src/interfaces/IFeeModule.sol";
import { Auth, Authority } from "@solmate/auth/Auth.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { TellerWithMultiAssetSupport, ERC20 } from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";
import { ReentrancyGuard } from "@solmate/utils/ReentrancyGuard.sol";

/**
 * @title WithdrawQueue
 * @notice Handles user withdraws using the Teller in a FIFO order
 * @dev Implements ERC721Enumerable for tokenized order receipts
 * @custom:security-contact security@molecularlabs.io
 */
contract WithdrawQueue is ERC721Enumerable, Auth, ReentrancyGuard {

    using FixedPointMathLib for uint256;
    using SafeERC20 for IERC20;

    /// @notice Type for internal order handling
    enum OrderType {
        DEFAULT, // Normal order in queue
        PRE_FILLED, // Order filled out of order, skip on process
        REFUND // Order marked for refund, on process handle refund only
    }

    /// @notice Return type of a user's order status in the queue
    enum OrderStatus {
        NOT_FOUND,
        PENDING,
        COMPLETE,
        COMPLETE_PRE_FILLED,
        PENDING_REFUND,
        COMPLETE_REFUNDED,
        FAILED_TRANSFER_REFUNDED // In the event an order fails to transfer to it's receiver, we refund it
    }

    /// @notice Approval method for submitting an order
    enum ApprovalMethod {
        EIP20_APPROVE,
        EIP2612_PERMIT
    }

    /// @notice Parameters for submitting and approving an order with signatures
    struct SignatureParams {
        ApprovalMethod approvalMethod;
        uint8 approvalV;
        bytes32 approvalR;
        bytes32 approvalS;
        bool submitWithSignature;
        uint256 deadline;
        bytes eip2612Signature;
    }

    /// @notice Parameters for submitting an order
    struct SubmitOrderParams {
        uint256 amountOffer;
        IERC20 wantAsset;
        address intendedDepositor;
        address receiver;
        address refundReceiver;
        SignatureParams signatureParams;
    }

    /// @notice Represents a withdrawal order in the queue
    struct Order {
        uint256 amountOffer; // Amount of shares to withdraw
        IERC20 wantAsset; // Asset being requested
        address refundReceiver; // Address to receive refunds
        OrderType orderType; // Current type of the order, indicates how the order is processed
        bool didOrderFailTransfer; // Whether the order failed to transfer on process. In this event the shares are
        // refunded
    }

    bytes32 public constant CANCEL_ORDER_TYPEHASH =
        keccak256("Cancel(uint256 orderIndex,uint256 deadline,address queueAddress,uint256 chainId)");

    /// @notice Mapping of intended depositors to their nonces to prevent replay attacks
    mapping(address => uint256) public nonces;

    /// @notice the offer asset to be withdrawn from. This must be the vault of the provided Teller. This may never
    /// change even if a vault's Teller does.
    IERC20 public immutable offerAsset;

    /// @notice Minimum order size of shares to withdraw
    uint256 public minimumOrderSize;

    /// @notice Address of the fee module for calculating fees
    IFeeModule public feeModule;

    /// @notice recipient of queue fees
    address public feeRecipient;

    /// @notice Teller this contract is queueing withdraws for
    TellerWithMultiAssetSupport public tellerWithMultiAssetSupport;

    /// @notice Mapping of order index to Order struct
    mapping(uint256 => Order) public orderAtQueueIndex;

    /// @notice The index of the last order that was processed
    /// @dev Initialized to 0, meaning the queue starts at 1.
    uint256 public lastProcessedOrder;

    /// @notice represents the back of the queue, incremented on submitting orders
    uint256 public latestOrder;

    event FeeModuleUpdated(IFeeModule indexed oldFeeModule, IFeeModule indexed newFeeModule);
    event MinimumOrderSizeUpdated(uint256 oldMinimum, uint256 newMinimum);
    event FeeRecipientUpdated(address indexed oldFeeRecipient, address indexed newFeeRecipient);
    event OrderSubmitted(
        uint256 indexed orderIndex,
        Order order,
        address indexed receiver,
        address indexed depositor,
        bool isSubmittedViaSignature
    );
    event OrdersProcessedInRange(uint256 indexed startIndex, uint256 indexed endIndex);
    event OrderProcessed(
        uint256 indexed orderIndex,
        Order order,
        address indexed receiver,
        bool indexed isForceProcessed,
        uint256 feeAmount,
        uint256 assetsOut
    );
    event OrderRefunded(uint256 indexed orderIndex, Order order);
    event TellerUpdated(TellerWithMultiAssetSupport indexed oldTeller, TellerWithMultiAssetSupport indexed newTeller);
    event OrderMarkedForRefund(uint256 indexed orderIndex, bool indexed isMarkedByUser);

    error ZeroAddress();
    error ZeroAmount();
    error OrderAlreadyProcessed(uint256 orderIndex);
    error InvalidOrderType(uint256 orderIndex, OrderType currentStatus);
    error InvalidOrderIndex(uint256 orderIndex);
    error AmountBelowMinimum(uint256 amount, uint256 minimum);
    error SignatureExpired(uint256 deadline, uint256 currentTimestamp);
    error NotEnoughOrdersToProcess(uint256 ordersToProcess, uint256 latestOrder);
    error InvalidOrdersCount(uint256 ordersToProcess);
    error InvalidEip2612Signature(address intendedDepositor, address depositor);
    error InvalidDepositor(address intendedDepositor, address depositor);
    error PermitFailedAndAllowanceTooLow();
    error TellerVaultMissmatch();
    error OnlyOrderOwnerCanCancel(address attemptedToCancel, address orderOwner);
    error QueueMustBeEmpty();
    error AssetNotSupported(IERC20 asset);
    error InvalidAssetsOut();
    error EmptyArray();
    error VaultInsufficientBalance(IERC20 wantAsset, uint256 expectedAssetsOut, uint256 vaultBalanceOfWantAsset);
    error TellerIsPaused();

    /**
     * @notice Initialize the contract
     * @param _name Name for the ERC721 receipt tokens
     * @param _symbol Symbol for the ERC721 receipt tokens
     * @param _feeRecipient Address of the fee recipient
     * @param _tellerWithMultiAssetSupport Teller this queue handles withdraws for
     * @param _feeModule Address of fee module contract
     * @param _minimumOrderSize Minimum order size of shares to withdraw
     * @param _owner Address of the initial owner
     */
    constructor(
        string memory _name,
        string memory _symbol,
        address _feeRecipient,
        TellerWithMultiAssetSupport _tellerWithMultiAssetSupport,
        IFeeModule _feeModule,
        uint256 _minimumOrderSize,
        address _owner
    )
        ERC721(_name, _symbol)
        Auth(_owner, Authority(address(0)))
    {
        // no zero check on owner in Auth Contract
        if (_owner == address(0)) revert ZeroAddress();
        if (_feeRecipient == address(0)) revert ZeroAddress();
        if (address(_tellerWithMultiAssetSupport) == address(0)) revert ZeroAddress();
        IERC20 _offerAsset = IERC20(address(_tellerWithMultiAssetSupport.vault()));
        if (address(_offerAsset) == address(0)) revert ZeroAddress();
        if (address(_feeModule) == address(0)) revert ZeroAddress();

        feeRecipient = _feeRecipient;
        tellerWithMultiAssetSupport = _tellerWithMultiAssetSupport;
        offerAsset = _offerAsset;
        feeModule = _feeModule;
        minimumOrderSize = _minimumOrderSize;
    }

    /**
     * @notice Set the fee module address
     * @param _feeModule Address of the new fee module
     * @dev May only update the fee module if the queue is empty (no active orders)
     */
    function setFeeModule(IFeeModule _feeModule) external requiresAuth {
        if (address(_feeModule) == address(0)) revert ZeroAddress();
        if (totalSupply() != 0) revert QueueMustBeEmpty();

        IFeeModule oldFeeModule = feeModule;
        feeModule = _feeModule;
        emit FeeModuleUpdated(oldFeeModule, _feeModule);
    }

    /**
     * @notice Set the fee recipient address
     * @param _feeRecipient Address of the new fee module
     */
    function setFeeRecipient(address _feeRecipient) external requiresAuth {
        if (_feeRecipient == address(0)) revert ZeroAddress();

        address oldFeeRecipient = feeRecipient;
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(oldFeeRecipient, _feeRecipient);
    }

    /**
     * @notice Set a new TellerWithMultiAssetSupport
     * @dev The Teller may be updated but the offer asset may not. The new teller's vault() must return the same asset.
     * The queue must also be empty (no active orders)
     */
    function setTellerWithMultiAssetSupport(TellerWithMultiAssetSupport _newTeller) external requiresAuth {
        if (address(_newTeller) == address(0)) revert ZeroAddress();
        if (address(_newTeller.vault()) != address(offerAsset)) revert TellerVaultMissmatch();
        if (totalSupply() != 0) revert QueueMustBeEmpty();

        TellerWithMultiAssetSupport oldTeller = tellerWithMultiAssetSupport;
        tellerWithMultiAssetSupport = _newTeller;
        emit TellerUpdated(oldTeller, _newTeller);
    }

    /**
     * @notice Update the minimum order size
     * @param _newMinimum to update to
     */
    function updateAssetMinimumOrderSize(uint256 _newMinimum) external requiresAuth {
        uint256 oldMinimum = minimumOrderSize;
        minimumOrderSize = _newMinimum;

        emit MinimumOrderSizeUpdated(oldMinimum, _newMinimum);
    }

    /**
     * @dev Allows owner to manage ERC20 tokens in the contract to prevent stuck funds
     */
    function manageERC20(IERC20 token, uint256 amount, address receiver) external requiresAuth {
        if (address(token) == address(0)) revert ZeroAddress();
        if (receiver == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        token.safeTransfer(receiver, amount);
    }

    /**
     * @notice Force process multiple orders
     * @param orderIndices Array of order indices to process
     */
    function forceProcessOrders(uint256[] calldata orderIndices) external requiresAuth {
        uint256 length = orderIndices.length;
        if (length == 0) revert EmptyArray();
        for (uint256 i; i < length;) {
            _forceProcess(orderIndices[i]);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Force process a single order out of sequence
     * @param orderIndex Index of the order to force process
     */
    function forceProcess(uint256 orderIndex) external requiresAuth {
        _forceProcess(orderIndex);
    }

    /**
     * @notice Cancel an order. Upon process shares will be returned rather than withdrawn. Orders may not be
     * un-canceled
     * @dev This is a public function made for users to cancel their own orders that they must be the owner of
     * @param orderIndex Index of the order to cancel
     */
    function cancelOrder(uint256 orderIndex) external requiresAuth {
        if (ownerOf(orderIndex) != msg.sender) revert OnlyOrderOwnerCanCancel(msg.sender, ownerOf(orderIndex));
        _markOrderForRefund(orderIndex, true);
    }

    /**
     * @notice Cancel an order using a signature. Works the same way as cancelOrder, but enforces the signer owns the
     * order to cancel
     * @dev There is no explicit replay protection here as orders marked for refund already may not be marked again.
     */
    function cancelOrderWithSignature(
        uint256 orderIndex,
        uint256 deadline,
        bytes calldata cancelSignature
    )
        external
        requiresAuth
    {
        bytes32 hash = keccak256(abi.encode(CANCEL_ORDER_TYPEHASH, orderIndex, deadline, address(this), block.chainid));
        if (block.timestamp > deadline) revert SignatureExpired(deadline, block.timestamp);
        address signer = ECDSA.recover(hash, cancelSignature);
        if (signer != ownerOf(orderIndex)) revert OnlyOrderOwnerCanCancel(signer, ownerOf(orderIndex));
        _markOrderForRefund(orderIndex, true);
    }

    /**
     * @notice The same as cancelling an order but may be done to any order, not just one owned by the sender. Meant to
     * be a permissioned function for admins to refund orders.
     * @param orderIndex Index of the order to cancel
     */
    function refundOrder(uint256 orderIndex) external requiresAuth {
        _markOrderForRefund(orderIndex, false);
    }

    /**
     * @notice Refund a batch of orders
     */
    function refundOrders(uint256[] calldata orderIndices) external requiresAuth {
        uint256 length = orderIndices.length;
        if (length == 0) revert EmptyArray();
        for (uint256 i; i < length;) {
            _markOrderForRefund(orderIndices[i], false);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Submit and immediately process a number of orders if liquidity is available
     * @param params SubmitOrderParams struct containing all order parameters
     * @param ordersToProcess Number of orders to process
     * @return orderIndex The index of the created order
     */
    function submitOrderAndProcess(
        SubmitOrderParams calldata params,
        uint256 ordersToProcess
    )
        external
        requiresAuth
        returns (uint256 orderIndex)
    {
        orderIndex = submitOrder(params);
        processOrders(ordersToProcess);
    }

    /**
     * @notice Submit and immediately process an order if liquidity is available. Must process all the preceding orders
     * to do so.
     * @param params SubmitOrderParams struct containing all order parameters
     * @return orderIndex The index of the created order
     */
    function submitOrderAndProcessAll(SubmitOrderParams calldata params)
        external
        requiresAuth
        returns (uint256 orderIndex)
    {
        orderIndex = submitOrder(params);
        // This is = pending order count. orderIndex = latestOrder and does not require a cold storage read
        processOrders(orderIndex - lastProcessedOrder);
    }

    /**
     * @notice A user facing function to return an order's status
     */
    function getOrderStatus(uint256 orderIndex) external view returns (OrderStatus) {
        if (orderIndex == 0 || orderIndex > latestOrder) return OrderStatus.NOT_FOUND;
        Order memory order = orderAtQueueIndex[orderIndex];

        if (order.orderType == OrderType.PRE_FILLED) {
            return OrderStatus.COMPLETE_PRE_FILLED;
        }

        if (order.didOrderFailTransfer) {
            return OrderStatus.FAILED_TRANSFER_REFUNDED;
        }

        if (orderIndex > lastProcessedOrder) {
            return order.orderType == OrderType.REFUND ? OrderStatus.PENDING_REFUND : OrderStatus.PENDING;
        } else {
            return order.orderType == OrderType.REFUND ? OrderStatus.COMPLETE_REFUNDED : OrderStatus.COMPLETE;
        }
    }

    /**
     * @notice Submit an order at the back of the queue
     * @param params SubmitOrderParams struct containing all order parameters
     */
    function submitOrder(SubmitOrderParams calldata params) public requiresAuth returns (uint256 orderIndex) {
        {
            if (params.amountOffer < minimumOrderSize) revert AmountBelowMinimum(params.amountOffer, minimumOrderSize);
            if (params.receiver == address(0)) revert ZeroAddress();
            if (params.refundReceiver == address(0)) revert ZeroAddress();
            if (!tellerWithMultiAssetSupport.isWithdrawSupported(ERC20(address(params.wantAsset)))) {
                revert AssetNotSupported(params.wantAsset);
            }
        }

        address depositor = _verifyDepositor(params);

        // Increment the latestOrder as this one is being minted
        unchecked {
            orderIndex = ++latestOrder;
        }

        // Create order
        Order memory order = Order({
            amountOffer: params.amountOffer,
            wantAsset: params.wantAsset,
            refundReceiver: params.refundReceiver,
            orderType: OrderType.DEFAULT,
            didOrderFailTransfer: false
        });
        orderAtQueueIndex[orderIndex] = order;

        // Transfer the offer assets to the queue to hold until process
        offerAsset.safeTransferFrom(depositor, address(this), params.amountOffer);

        // Mint NFT receipt to receiver
        _safeMint(params.receiver, orderIndex);

        emit OrderSubmitted(orderIndex, order, params.receiver, depositor, params.signatureParams.submitWithSignature);
    }

    /**
     * @notice Process orders sequentially from the queue
     * @param ordersToProcess Number of orders to attempt processing
     * @dev Processes orders starting from lastProcessedOrder + 1
     *      Skips all non DEFAULT type orders
     */
    function processOrders(uint256 ordersToProcess) public nonReentrant requiresAuth {
        if (ordersToProcess == 0) revert InvalidOrdersCount(ordersToProcess);

        uint256 startIndex;
        uint256 endIndex;

        unchecked {
            startIndex = lastProcessedOrder + 1;
            endIndex = lastProcessedOrder + ordersToProcess;
        }

        // Ensure we don't go beyond existing orders
        if (endIndex > latestOrder) revert NotEnoughOrdersToProcess(ordersToProcess, latestOrder);

        // Essentially performing WHILE(++lastProcessedOrder < endIndex)
        // However, using local variables to avoid unnecessary storage reads
        for (uint256 i; i < ordersToProcess;) {
            uint256 orderIndex = startIndex + i;

            Order memory order = orderAtQueueIndex[orderIndex];

            if (order.orderType != OrderType.DEFAULT) {
                if (order.orderType == OrderType.REFUND) {
                    _burn(orderIndex);
                    _refundOrder(order, orderIndex);
                }
                unchecked {
                    ++lastProcessedOrder;
                    ++i;
                }
                // ignore
                continue;
            }

            if (tellerWithMultiAssetSupport.isPaused()) revert TellerIsPaused();

            // receiver is the owner of the receipt token
            address receiver = ownerOf(orderIndex);

            // Burn the order after noting the receiver, but before the withdraw.
            _burn(orderIndex);

            uint256 feeAmount = feeModule.calculateOfferFees(order.amountOffer, offerAsset, order.wantAsset, receiver);

            BoringVault vault = BoringVault(payable(address(offerAsset)));
            // The following line will revert if the accountant is paused. Meaning a paused accountant will not result
            // in refunded orders. It is technically possible the accountant pause between this call and a bulkWithdraw.
            // But this is not feasible in any normal operation
            uint256 expectedAssetsOut = tellerWithMultiAssetSupport.accountant()
                .getRateInQuoteSafe(ERC20(address(order.wantAsset)))
                .mulDivDown((order.amountOffer - feeAmount), 10 ** vault.decimals());

            uint256 vaultBalanceOfWantAsset = order.wantAsset.balanceOf(address(vault));
            if (vaultBalanceOfWantAsset < expectedAssetsOut) {
                revert VaultInsufficientBalance(order.wantAsset, expectedAssetsOut, vaultBalanceOfWantAsset);
            }

            unchecked {
                ++lastProcessedOrder;
                ++i;
            }

            try tellerWithMultiAssetSupport.bulkWithdraw(
                ERC20(address(order.wantAsset)), order.amountOffer - feeAmount, 0, receiver
            ) returns (
                uint256 assetsOut
            ) {
                if (assetsOut == 0) {
                    revert InvalidAssetsOut();
                }
                assert(assetsOut == expectedAssetsOut);

                // After the withdraw succeeds, transfer the fees to the fee recipient if fees > 0
                if (feeAmount > 0) {
                    offerAsset.safeTransfer(feeRecipient, feeAmount);
                }
            } catch {
                orderAtQueueIndex[orderIndex].didOrderFailTransfer = true;
                // refresh the order from storage with the updated didOrderFailTransfer
                order = orderAtQueueIndex[orderIndex];
                _refundOrder(order, orderIndex);
            }

            emit OrderProcessed(orderIndex, order, receiver, false, feeAmount, expectedAssetsOut);
        }

        emit OrdersProcessedInRange(startIndex, endIndex);
    }

    /**
     * @dev helper function to handle the signature verification and permit for submitting an order
     */
    function _verifyDepositor(SubmitOrderParams calldata params) internal returns (address depositor) {
        if (params.signatureParams.submitWithSignature) {
            if (block.timestamp > params.signatureParams.deadline) {
                revert SignatureExpired(params.signatureParams.deadline, block.timestamp);
            }
            bytes32 hash = keccak256(
                abi.encode(
                    params.amountOffer,
                    params.wantAsset,
                    params.receiver,
                    params.refundReceiver,
                    params.signatureParams.deadline,
                    params.signatureParams.approvalMethod,
                    nonces[params.intendedDepositor]++,
                    address(feeModule),
                    params.intendedDepositor,
                    block.chainid,
                    address(this)
                )
            );

            depositor = ECDSA.recover(hash, params.signatureParams.eip2612Signature);
            // Here we check the intended depositor for a better revert message. If we didn't do this, an incorrect
            // signature would error on the attempt to transfer assets from a nonsense depositor. This error is more
            // descriptive
            if (depositor != params.intendedDepositor) {
                revert InvalidEip2612Signature(params.intendedDepositor, depositor);
            }
        } else {
            depositor = msg.sender;
            if (depositor != params.intendedDepositor) revert InvalidDepositor(params.intendedDepositor, depositor);
        }

        // Do nothing if using standard ERC20 approve
        if (params.signatureParams.approvalMethod == ApprovalMethod.EIP2612_PERMIT) {
            try IERC20Permit(address(offerAsset))
                .permit(
                    depositor,
                    address(this),
                    params.amountOffer,
                    params.signatureParams.deadline,
                    params.signatureParams.approvalV,
                    params.signatureParams.approvalR,
                    params.signatureParams.approvalS
                ) { }
            catch {
                if (offerAsset.allowance(depositor, address(this)) < params.amountOffer) {
                    revert PermitFailedAndAllowanceTooLow();
                }
            }
        }
    }

    /// @notice helper function to mark an order for refund
    function _markOrderForRefund(uint256 orderIndex, bool isMarkedByUser) internal {
        Order memory order = _getOrderEnsureDefault(orderIndex);
        orderAtQueueIndex[orderIndex].orderType = OrderType.REFUND;
        emit OrderMarkedForRefund(orderIndex, isMarkedByUser);
    }

    /// @notice force process an order in the queue even if it's not at the front
    function _forceProcess(uint256 orderIndex) internal {
        Order memory order = _getOrderEnsureDefault(orderIndex);

        // Mark as pre-filled
        orderAtQueueIndex[orderIndex].orderType = OrderType.PRE_FILLED;

        address receiver = ownerOf(orderIndex);
        _burn(orderIndex);

        uint256 feeAmount = feeModule.calculateOfferFees(order.amountOffer, offerAsset, order.wantAsset, receiver);
        uint256 assetsOut = tellerWithMultiAssetSupport.bulkWithdraw(
            ERC20(address(order.wantAsset)), order.amountOffer - feeAmount, 0, receiver
        );

        offerAsset.safeTransfer(feeRecipient, feeAmount);

        emit OrderProcessed(orderIndex, orderAtQueueIndex[orderIndex], receiver, true, feeAmount, assetsOut);
    }

    /// @return order after checking index is a real order and is DEFAULT status
    function _getOrderEnsureDefault(uint256 orderIndex) internal view returns (Order memory order) {
        // The orderIndex != 0 check is redundant and checked below but more accurate description in the error
        // InvalidOrderIndex
        if (orderIndex > latestOrder || orderIndex == 0) revert InvalidOrderIndex(orderIndex);
        if (orderIndex <= lastProcessedOrder) revert OrderAlreadyProcessed(orderIndex);

        order = orderAtQueueIndex[orderIndex];

        // require order is set to DEFAULT type
        if (order.orderType != OrderType.DEFAULT) revert InvalidOrderType(orderIndex, order.orderType);
    }

    /**
     * @notice Helper function to refund an order
     * @dev We do not check for failed transfers here. As in the case of the share token, we have built this token and
     * know it does not revert due to blacklists or ERC777 hooks. So we do not need special handling here
     */
    function _refundOrder(Order memory order, uint256 orderIndex) internal {
        offerAsset.safeTransfer(order.refundReceiver, order.amountOffer);
        emit OrderRefunded(orderIndex, order);
    }

}
