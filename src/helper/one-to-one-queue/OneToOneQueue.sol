// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { ERC721Enumerable, ERC721 } from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IFeeModule } from "src/interfaces/IFeeModule.sol";
import { VerboseAuth, Authority } from "./access/VerboseAuth.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @title OneToOneQueue
 * @notice A FIFO queue system for processing withdrawal requests with tokenized receipts
 * @dev Implements ERC721Enumerable for tokenized order receipts
 */
contract OneToOneQueue is ERC721Enumerable, VerboseAuth {

    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice Type for internal order handling
    /// @dev all but default orders are skipped on solve, as refunds and pre-fills are handled at the time they are
    /// marked
    enum OrderType {
        DEFAULT, // Normal order in queue
        PRE_FILLED, // Order filled out of order, skip on process
        REFUND // Order refunded, skip on process
    }

    /// @notice Return type of a user's order status in the queue
    enum OrderStatus {
        NOT_FOUND,
        PENDING,
        COMPLETE,
        COMPLETE_PRE_FILLED,
        COMPLETE_REFUNDED,
        FAILED_TRANSFER,
        FAILED_REFUND
    }

    /// @notice Approval method for submitting an order
    enum ApprovalMethod {
        EIP20_APROVE,
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
        uint256 nonce;
    }

    /// @notice Parameters for submitting an order
    struct SubmitOrderParams {
        uint256 amountOffer;
        IERC20 offerAsset;
        IERC20 wantAsset;
        address intendedDepositor;
        address receiver;
        address refundReceiver;
        SignatureParams signatureParams;
    }

    /// @notice Represents a withdrawal order in the queue
    struct Order {
        uint128 amountOffer; // Amount of offer asset in offer decimals to exchange for the same amount of want asset
        // minus fees.
        uint128 amountWant; // Amount of want asset to give the user in want decimals. This is not inclusive of fees.
        IERC20 offerAsset; // Asset being offered
        IERC20 wantAsset; // Asset being requested
        address refundReceiver; // Address to receive refunds
        OrderType orderType; // Current status of the order
        bool didOrderFailTransfer; // Whether the order failed to transfer on process or refund
    }

    /// @notice Mapping of hashes that have been used for signatures to prevent replays
    mapping(bytes32 => bool) public usedSignatureHashes;

    /// @notice Mapping of supported offer assets
    mapping(address => bool) public supportedOfferAssets;

    /// @notice Mapping of supported want assets
    mapping(address => bool) public supportedWantAssets;

    /// @notice Minimum order size per offer asset
    mapping(address => uint256) public minimumOrderSizePerAsset;

    /// @notice Address of the fee module for calculating fees
    IFeeModule public feeModule;

    /// @notice Address of the offerAssetRecipient
    address public offerAssetRecipient;

    /// @notice recipient of queue fees
    address public feeRecipient;

    /// @notice Address to hold funds for failed transfers
    address public recoveryAddress;

    /// @notice Mapping of order index to Order struct
    mapping(uint256 => Order) public queue;

    /// @notice The index of the last order that was processed
    /// @dev Initialized to 0, meaining the queue starts at 1.
    uint256 public lastProcessedOrder;

    /// @notice represents the back of the queue, incremented on sumbiting orders
    uint256 public latestOrder;

    event FeeModuleUpdated(IFeeModule indexed oldFeeModule, IFeeModule indexed newFeeModule);
    event OfferAssetAdded(address indexed asset, uint256 minimumOrderSize);
    event OfferAssetRemoved(address indexed asset);
    event WantAssetAdded(address indexed asset);
    event WantAssetRemoved(address indexed asset);
    event MinimumOrderSizeUpdated(address indexed asset, uint256 oldMinimum, uint256 newMinimum);
    event OfferAssetRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
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
        uint256 indexed orderIndex, Order order, address indexed receiver, bool indexed isForceProcessed
    );
    event OrderRefunded(uint256 indexed orderIndex, Order order);
    event OrderFailedTransfer(
        uint256 indexed orderIndex, address indexed recoveryAddress, address indexed originalReceiver, Order order
    );
    event RecoveryAddressUpdated(address indexed oldRecoveryAddress, address indexed newRecoveryAddress);

    error ZeroAddress();
    error AssetAlreadySupported(address asset);
    error AssetNotSupported(address asset);
    error OrderAlreadyProcessed(uint256 orderIndex);
    error InvalidOrderStatus(uint256 orderIndex, OrderType currentStatus);
    error InvalidOrderIndex(uint256 orderIndex);
    error AmountBelowMinimum(uint256 amount, uint256 minimum);
    error SignatureExpired(uint256 deadline, uint256 currentTimestamp);
    error SignatureHashAlreadyUsed(bytes32 hash);
    error NotEnoughOrdersToProcess(uint256 ordersToProcess, uint256 latestOrder);
    error InsufficientBalanceInQueue(uint256 orderIndex, address asset, uint256 required, uint256 available);
    error InvalidOrdersCount(uint256 ordersToProcess);
    error InvalidEip2612Signature(address intendedDepositor, address depositor);
    error InvalidDepositor(address intendedDepositor, address depositor);
    error PermitFailedAndAllowanceTooLow();

    /**
     * @notice Initialize the contract
     * @param _name Name for the ERC721 receipt tokens
     * @param _symbol Symbol for the ERC721 receipt tokens
     * @param _offerAssetRecipient Address of the boring vault
     * @param _feeRecipient Address of the fee recipient
     * @param _feeModule Address of fee module contract
     * @param _owner Address of the initial owner
     */
    constructor(
        string memory _name,
        string memory _symbol,
        address _offerAssetRecipient,
        address _feeRecipient,
        IFeeModule _feeModule,
        address _recoveryAddress,
        address _owner
    )
        ERC721(_name, _symbol)
        VerboseAuth(_owner, Authority(address(0)))
    {
        // no zero check on owner in Auth Contract
        if (_owner == address(0)) revert ZeroAddress();
        if (_offerAssetRecipient == address(0)) revert ZeroAddress();
        if (_feeRecipient == address(0)) revert ZeroAddress();
        if (_recoveryAddress == address(0)) revert ZeroAddress();
        if (address(_feeModule) == address(0)) revert ZeroAddress();

        offerAssetRecipient = _offerAssetRecipient;
        recoveryAddress = _recoveryAddress;
        feeRecipient = _feeRecipient;
        feeModule = _feeModule;
    }

    /**
     * @notice Set the fee module address
     * @param _feeModule Address of the new fee module
     */
    function setFeeModule(IFeeModule _feeModule) external requiresAuthVerbose {
        if (address(_feeModule) == address(0)) revert ZeroAddress();

        IFeeModule oldFeeModule = feeModule;
        feeModule = _feeModule;
        emit FeeModuleUpdated(oldFeeModule, _feeModule);
    }

    /**
     * @notice Set the fee recipient address
     * @param _feeRecipient Address of the new fee module
     */
    function setFeeRecipient(address _feeRecipient) external requiresAuthVerbose {
        if (_feeRecipient == address(0)) revert ZeroAddress();

        address oldFeeRecipient = feeRecipient;
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(oldFeeRecipient, _feeRecipient);
    }

    /**
     * @notice Set the recovery address
     * @param _recoveryAddress Address of the new recovery address
     */
    function setRecoveryAddress(address _recoveryAddress) external requiresAuthVerbose {
        if (_recoveryAddress == address(0)) revert ZeroAddress();
        address oldRecoveryAddress = recoveryAddress;
        recoveryAddress = _recoveryAddress;
        emit RecoveryAddressUpdated(oldRecoveryAddress, _recoveryAddress);
    }

    /**
     * @notice Add a supported offer asset
     * @param _asset Address of the offer asset to add
     * @param _minimumOrderSize Minimum order size for this asset
     */
    function addOfferAsset(address _asset, uint256 _minimumOrderSize) external requiresAuthVerbose {
        if (_asset == address(0)) revert ZeroAddress();
        if (supportedOfferAssets[_asset]) revert AssetAlreadySupported(_asset);

        supportedOfferAssets[_asset] = true;
        minimumOrderSizePerAsset[_asset] = _minimumOrderSize;

        emit OfferAssetAdded(_asset, _minimumOrderSize);
    }

    /**
     * @notice Update an assets minimum order size
     * @param _asset Address of asset
     * @param _newMinimum for this asset to update to
     */
    function updateAssetMinimumOrderSize(address _asset, uint256 _newMinimum) external requiresAuthVerbose {
        if (!supportedOfferAssets[_asset]) revert AssetNotSupported(_asset);

        uint256 oldMinimum = minimumOrderSizePerAsset[_asset];
        minimumOrderSizePerAsset[_asset] = _newMinimum;

        emit MinimumOrderSizeUpdated(_asset, oldMinimum, _newMinimum);
    }

    /**
     * @notice Remove a supported offer asset
     * @param _asset Address of the offer asset to remove
     */
    function removeOfferAsset(address _asset) external requiresAuthVerbose {
        if (!supportedOfferAssets[_asset]) revert AssetNotSupported(_asset);

        supportedOfferAssets[_asset] = false;

        emit OfferAssetRemoved(_asset);
    }

    /**
     * @notice Add a supported want asset
     * @param _asset Address of the want asset to add
     */
    function addWantAsset(address _asset) external requiresAuthVerbose {
        if (_asset == address(0)) revert ZeroAddress();
        if (supportedWantAssets[_asset]) revert AssetAlreadySupported(_asset);

        supportedWantAssets[_asset] = true;

        emit WantAssetAdded(_asset);
    }

    /**
     * @notice Remove a supported want asset
     * @param _asset Address of the want asset to remove
     */
    function removeWantAsset(address _asset) external requiresAuthVerbose {
        if (!supportedWantAssets[_asset]) revert AssetNotSupported(_asset);

        supportedWantAssets[_asset] = false;

        emit WantAssetRemoved(_asset);
    }

    /**
     * @notice Update offer asset recipient address
     * @param _newAddress Address of the new recipient
     */
    function updateOfferAssetRecipient(address _newAddress) external requiresAuthVerbose {
        if (_newAddress == address(0)) revert ZeroAddress();

        address oldVal = offerAssetRecipient;
        offerAssetRecipient = _newAddress;

        emit OfferAssetRecipientUpdated(oldVal, _newAddress);
    }

    /**
     * @dev Allows owner to manage ERC20 tokens in the contract to prevent stuck funds
     */
    function manageERC20(IERC20 token, uint256 amount, address receiver) external requiresAuthVerbose {
        if (address(token) == address(0)) revert ZeroAddress();
        if (receiver == address(0)) revert ZeroAddress();

        token.safeTransfer(receiver, amount);
    }

    /**
     * @notice Force refund multiple orders
     * @param orderIndices Array of order indices to refund
     */
    function forceRefundOrders(uint256[] calldata orderIndices) external requiresAuthVerbose {
        uint256 length = orderIndices.length;
        for (uint256 i; i < length; ++i) {
            _forceRefund(orderIndices[i]);
        }
    }

    /**
     * @notice Force process multiple orders
     * @param orderIndices Array of order indices to process
     */
    function forceProcessOrders(uint256[] calldata orderIndices) external requiresAuthVerbose {
        uint256 length = orderIndices.length;
        for (uint256 i; i < length; ++i) {
            _forceProcess(orderIndices[i]);
        }
    }

    /**
     * @notice refund an order and force process it
     * @param orderIndex Index of the order to refund
     */
    function forceRefund(uint256 orderIndex) external requiresAuthVerbose {
        _forceRefund(orderIndex);
    }

    /**
     * @notice Force process an order out of sequence
     * @param orderIndex Index of the order to force process
     */
    function forceProcess(uint256 orderIndex) external requiresAuthVerbose {
        _forceProcess(orderIndex);
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
        requiresAuthVerbose
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
        requiresAuthVerbose
        returns (uint256 orderIndex)
    {
        orderIndex = submitOrder(params);
        // This is = getPendingOrderCount(). OrderIndex = latestOrder but does not require a cold storage read
        processOrders(orderIndex - lastProcessedOrder);
    }

    /**
     * @notice A user facing function to return an order's status
     */
    function getOrderStatus(uint256 orderIndex) external view returns (OrderStatus) {
        if (orderIndex == 0) return OrderStatus.NOT_FOUND;
        Order memory order = queue[orderIndex];

        if (order.orderType == OrderType.PRE_FILLED) {
            return OrderStatus.COMPLETE_PRE_FILLED;
        }

        if (order.orderType == OrderType.REFUND) {
            if (order.didOrderFailTransfer) {
                return OrderStatus.FAILED_REFUND;
            }
            return OrderStatus.COMPLETE_REFUNDED;
        }

        if (order.didOrderFailTransfer) {
            return OrderStatus.FAILED_TRANSFER;
        }

        if (orderIndex > lastProcessedOrder) {
            if (orderIndex > latestOrder) {
                return OrderStatus.NOT_FOUND;
            } else {
                return OrderStatus.PENDING;
            }
        } else {
            return OrderStatus.COMPLETE;
        }
    }

    /**
     * @notice Submit an order at the back of the queue
     * @param params SubmitOrderParams struct containing all order parameters
     */
    function submitOrder(SubmitOrderParams calldata params) public requiresAuthVerbose returns (uint256 orderIndex) {
        {
            if (!supportedOfferAssets[address(params.offerAsset)]) {
                revert AssetNotSupported(address(params.offerAsset));
            }
            if (!supportedWantAssets[address(params.wantAsset)]) revert AssetNotSupported(address(params.wantAsset));
            uint256 minimumOrderSize = minimumOrderSizePerAsset[address(params.offerAsset)];
            if (params.amountOffer < minimumOrderSize) revert AmountBelowMinimum(params.amountOffer, minimumOrderSize);
            if (params.receiver == address(0)) revert ZeroAddress();
            if (params.refundReceiver == address(0)) revert ZeroAddress();
        }

        address depositor = _verifyDepositor(params);

        uint256 feeAmount =
            feeModule.calculateOfferFees(params.amountOffer, params.offerAsset, params.wantAsset, params.receiver);
        uint256 newAmountForReceiver = params.amountOffer - feeAmount;

        // Increment the latestOrder as this one is being minted
        unchecked {
            orderIndex = ++latestOrder;
        }

        // Create order
        // Since newAmountForReceiver is in offer decimals, we need to calculate the amountWant in want decimals
        Order memory order = Order({
            amountOffer: params.amountOffer.toUint128(),
            amountWant: _getWantAmountInWantDecimals(
                newAmountForReceiver.toUint128(), params.offerAsset, params.wantAsset
            ),
            offerAsset: params.offerAsset,
            wantAsset: params.wantAsset,
            refundReceiver: params.refundReceiver,
            orderType: OrderType.DEFAULT,
            didOrderFailTransfer: false
        });
        queue[orderIndex] = order;

        // Transfer the offer assets to the offerAssetRecipient and feeRecipient
        params.offerAsset.safeTransferFrom(depositor, offerAssetRecipient, newAmountForReceiver);
        params.offerAsset.safeTransferFrom(depositor, feeRecipient, feeAmount);

        // Mint NFT receipt to receiver
        _safeMint(params.receiver, orderIndex);

        emit OrderSubmitted(
            orderIndex, queue[orderIndex], params.receiver, depositor, params.signatureParams.submitWithSignature
        );
    }

    /**
     * @notice Process orders sequentially from the queue
     * @param ordersToProcess Number of orders to attempt processing
     * @dev Processes orders starting from lastProcessedOrder + 1
     *      Skips PRE_FILLED orders and REFUND orders
     *      Requires sufficient want asset balance in contract
     */
    function processOrders(uint256 ordersToProcess) public requiresAuthVerbose {
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
        for (uint256 i; i < ordersToProcess; ++i) {
            uint256 orderIndex = startIndex + i;

            Order memory order = queue[orderIndex];

            if (order.orderType != OrderType.DEFAULT) {
                unchecked {
                    ++lastProcessedOrder;
                }
                // ignore
                continue;
            }

            // receiver is the owner of the receipt token
            address receiver = ownerOf(orderIndex);
            _checkBalanceQueue(order.wantAsset, order.amountWant, orderIndex);

            // Burn the order after noting the receiver, but before the transfer.
            _burn(orderIndex);

            // From SafeERC20 library to perform a safeERC20 transfer and return a bool on success. Implemented here
            // since it's private and we cannot call it directly It's worth noting that there are some tokens like
            // Tether Gold that return false while succeeding.
            // This situation would result success in being false even though the transfer did not revert.
            bool success = _callOptionalReturnBool(order.wantAsset, receiver, order.amountWant);

            // If the transfer to the receiver fails, we mark the order as FAILED_TRANSFER and transfer the tokens to a
            // recoveryAddress. This is because the queue could possibly be griefed by setting blacklisted addresses as
            // the receivers and causing the queue to clog up on process. We handle this by taking the funds to the
            // recoveryAddress to distribute to the user once they become un-blacklisted or otherwise determine a scheme
            // for distribution
            if (!success) {
                // Set the type for the storage and memory as we will emit the memory order
                order.didOrderFailTransfer = true;
                queue[orderIndex].didOrderFailTransfer = true;
                order.wantAsset.safeTransfer(recoveryAddress, order.amountWant);
                emit OrderFailedTransfer(orderIndex, recoveryAddress, receiver, order);
            }

            unchecked {
                ++lastProcessedOrder;
            }

            emit OrderProcessed(orderIndex, order, receiver, false);
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
                    params.offerAsset,
                    params.wantAsset,
                    params.receiver,
                    params.refundReceiver,
                    params.signatureParams.deadline,
                    params.signatureParams.approvalMethod,
                    params.signatureParams.nonce,
                    address(feeModule),
                    block.chainid,
                    address(this)
                )
            );
            if (usedSignatureHashes[hash]) revert SignatureHashAlreadyUsed(hash);
            usedSignatureHashes[hash] = true;

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
            try IERC20Permit(address(params.offerAsset))
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
                if (params.offerAsset.allowance(depositor, address(this)) < params.amountOffer) {
                    revert PermitFailedAndAllowanceTooLow();
                }
            }
        }
    }

    /**
     * @notice helper to get want amount in want decimals from an amount of offer asset
     */
    function _getWantAmountInWantDecimals(
        uint128 amountOfferAfterFees,
        IERC20 offerAsset,
        IERC20 wantAsset
    )
        internal
        view
        returns (uint128 amountWant)
    {
        uint8 offerDecimals = IERC20Metadata(address(offerAsset)).decimals();
        uint8 wantDecimals = IERC20Metadata(address(wantAsset)).decimals();

        if (offerDecimals == wantDecimals) {
            return amountOfferAfterFees;
        }

        if (offerDecimals > wantDecimals) {
            uint8 difference = offerDecimals - wantDecimals;
            return amountOfferAfterFees / uint128(10 ** difference);
        }

        uint8 difference = wantDecimals - offerDecimals;
        return amountOfferAfterFees * uint128(10 ** difference);
    }

    /// @notice helper to revert with a specific orderIndex when the queue runs out of balance
    function _checkBalanceQueue(IERC20 asset, uint256 amount, uint256 orderIndex) internal view {
        uint256 balance = asset.balanceOf(address(this));
        if (balance < amount) {
            revert InsufficientBalanceInQueue(orderIndex, address(asset), amount, balance);
        }
    }

    /**
     * @dev From SafeERC20 library: _callOptionalReturnBool(): Do a safe transfer and return a bool instead of reverting
     * This is a function in SafeERC20 but is private so we need to replicate it here
     */
    function _callOptionalReturnBool(IERC20 token, address receiver, uint256 amount) internal returns (bool success) {
        bytes memory data = abi.encodeWithSelector(token.transfer.selector, receiver, amount);

        uint256 returnSize;
        uint256 returnValue;
        assembly ("memory-safe") {
            success := call(gas(), token, 0, add(data, 0x20), mload(data), 0, 0x20)
            returnSize := returndatasize()
            returnValue := mload(0)
        }
        success = success && (returnSize == 0 ? address(token).code.length > 0 : returnValue == 1);
    }

    /// @notice force refund an order in the queue even if it's not at the front. Users will be refunded the offer
    /// asset. Refund is inclusive of fees paid
    function _forceRefund(uint256 orderIndex) internal {
        Order memory order = _getOrderEnsureDefault(orderIndex);

        // Mark as refunded
        queue[orderIndex].orderType = OrderType.REFUND;

        _checkBalanceQueue(order.offerAsset, order.amountOffer, orderIndex);
        _burn(orderIndex);

        // From SafeERC20 library to perform a safeERC20 transfer and return a bool on success. Implemented here
        // since it's private and we cannot call it directly It's worth noting that there are some tokens like
        // Tether Gold that return false while succeeding.
        // This situation would result success in being false even though the transfer did not revert.
        bool success = _callOptionalReturnBool(order.offerAsset, order.refundReceiver, order.amountOffer);

        // If the transfer to the receiver fails, we mark the order as FAILED_TRANSFER and transfer the tokens to a
        // recoveryAddress. This is because the queue could possibly be greifed by setting a blacklisted addresses as
        // the refund receiver and block the refund ability. We handle this by taking the funds to the
        // recoveryAddress to distribute to the user once they become un-blacklisted or otherwise determine a scheme
        // for distribution
        if (!success) {
            // Set the type for the storage and memory as we will emit the memory order. The only difference is the
            // REFUND status which we override as FAILED_TRANSFER
            order.didOrderFailTransfer = true;
            queue[orderIndex].didOrderFailTransfer = true;
            order.offerAsset.safeTransfer(recoveryAddress, order.amountOffer);
            emit OrderFailedTransfer(orderIndex, recoveryAddress, order.refundReceiver, order);
        }

        emit OrderRefunded(orderIndex, queue[orderIndex]);
    }

    /// @notice force process an order in the queue even if it's not at the front
    function _forceProcess(uint256 orderIndex) internal {
        Order memory order = _getOrderEnsureDefault(orderIndex);

        // Mark as pre-filled
        queue[orderIndex].orderType = OrderType.PRE_FILLED;

        address receiver = ownerOf(orderIndex);
        _checkBalanceQueue(order.wantAsset, order.amountWant, orderIndex);
        _burn(orderIndex);
        order.wantAsset.safeTransfer(receiver, order.amountWant);

        emit OrderProcessed(orderIndex, queue[orderIndex], receiver, true);
    }

    /// @return order after checking index is a real order and is DEFAULT status
    function _getOrderEnsureDefault(uint256 orderIndex) internal returns (Order memory order) {
        // The orderIndex != 0 check is redundant and checked below but more accurate description in the error
        // InvalidOrderIndex
        if (orderIndex > latestOrder || orderIndex == 0) revert InvalidOrderIndex(orderIndex);
        if (orderIndex <= lastProcessedOrder) revert OrderAlreadyProcessed(orderIndex);

        order = queue[orderIndex];

        // require order is set to DEFAULT status
        if (order.orderType != OrderType.DEFAULT) revert InvalidOrderStatus(orderIndex, order.orderType);
    }

}
