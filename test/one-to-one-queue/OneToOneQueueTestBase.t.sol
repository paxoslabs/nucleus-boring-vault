// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { OneToOneQueue } from "src/helper/one-to-one-queue/OneToOneQueue.sol";
import { SimpleFeeModule } from "src/helper/SimpleFeeModule.sol";
import { QueueAccessAuthority } from "src/helper/one-to-one-queue/QueueAccessAuthority.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { Test, stdStorage, StdStorage, stdError, console } from "@forge-std/Test.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// NOTE: We need to deploy the Solmate ERC20 since the OZ ERC20Permit has a dependency with solidity version 0.8.24 and
/// cannot be used with our contracts
import { ERC20 } from "@solmate/tokens/ERC20.sol";

contract tERC20 is ERC20 {

    constructor(uint8 _decimalsInput) ERC20("test name", "test", _decimalsInput) { }

}

abstract contract OneToOneQueueTestBase is Test {

    // Configuration Events
    /// @notice Emitted when a new fee module is set
    /// @param oldFeeModule Previous fee module address
    /// @param newFeeModule New fee module address
    event FeeModuleUpdated(address indexed oldFeeModule, address indexed newFeeModule);

    /// @notice Emitted when a new offer asset is added
    /// @param asset Address of the offer asset
    /// @param minimumOrderSize Minimum order size for this asset
    event OfferAssetAdded(address indexed asset, uint256 minimumOrderSize);

    /// @notice Emitted when an offer asset is removed
    /// @param asset Address of the offer asset
    event OfferAssetRemoved(address indexed asset);

    /// @notice Emitted when a new want asset is added
    /// @param asset Address of the want asset
    event WantAssetAdded(address indexed asset);

    /// @notice Emitted when a want asset is removed
    /// @param asset Address of the want asset
    event WantAssetRemoved(address indexed asset);

    /// @notice Emitted when minimum order size is updated
    /// @param asset who's order size was updated
    /// @param oldMinimum Previous minimum order size
    /// @param newMinimum New minimum order size
    event MinimumOrderSizeUpdated(address asset, uint256 oldMinimum, uint256 newMinimum);

    /// @notice Emitted when boring vault address is updated
    /// @param oldVault Previous boring vault address
    /// @param newVault New boring vault address
    event OfferAssetRecipientUpdated(address indexed oldVault, address indexed newVault);

    // Order Events
    /// @notice Emitted when a new order is submitted
    /// @param orderIndex Index of the order in the queue (also the NFT token ID)
    /// @param order The order details
    /// @param receiver Address receiving the NFT receipt
    /// @param isSubmittedViaSignature True if order was submitted via signature
    event OrderSubmitted(
        uint256 indexed orderIndex,
        OneToOneQueue.Order order,
        address indexed receiver,
        address indexed depositor,
        bool isSubmittedViaSignature
    );

    /// @notice Emitted when orders are processed
    /// @param startIndex Starting order index (inclusive)
    /// @param endIndex Ending order index (inclusive)
    event OrdersProcessedInRange(uint256 indexed startIndex, uint256 indexed endIndex);

    /// @notice Emitted when an order is refunded
    /// @param orderIndex Index of the order
    /// @param order The order details
    event OrderRefunded(uint256 indexed orderIndex, OneToOneQueue.Order order);

    /// @notice Emitted when an order is force processed
    /// @param orderIndex Index of the order
    /// @param order The order details
    /// @param receiver Address receiving the assets
    event OrderProcessed(
        uint256 indexed orderIndex, OneToOneQueue.Order order, address indexed receiver, bool isForceProcessed
    );

    /// @notice Emitted when the fee recipient is updated
    /// @param oldFeeRecipient address
    /// @param newFeeRecipient address
    event FeeRecipientUpdated(address indexed oldFeeRecipient, address indexed newFeeRecipient);

    /**
     * @dev Emitted when the pause is triggered by `account`.
     */
    event Paused(address account);

    /**
     * @dev Emitted when the pause is lifted by `account`.
     */
    event Unpaused(address account);

    event OrderFailedTransfer(
        uint256 indexed orderIndex,
        address indexed recoveryAddress,
        address indexed originalReceiver,
        OneToOneQueue.Order order
    );
    event RecoveryAddressUpdated(address indexed oldRecoveryAddress, address indexed newRecoveryAddress);
    event AuthorityUpdated(address indexed user, address indexed newAuthority);

    OneToOneQueue queue;
    SimpleFeeModule feeModule;
    QueueAccessAuthority rolesAuthority;

    IERC20 public USDC;
    IERC20 public USDG0;
    IERC20 public DAI;

    uint256 TEST_OFFER_FEE_PERCENTAGE = 10; // 0.1% fee

    address mockBoringVaultAddress = makeAddr("boring vault");
    address owner = makeAddr("owner");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address user3 = makeAddr("user3");
    address solver = makeAddr("solver");
    address pauser1 = makeAddr("pauser1");
    address pauser2 = makeAddr("pauser2");
    address feeRecipient = makeAddr("fee recipient");
    address recoveryAddress = makeAddr("recovery address");
    address alice;
    uint256 alicePk;

    // A simple params struct used in most tests
    OneToOneQueue.SignatureParams defaultParams = OneToOneQueue.SignatureParams({
        approvalMethod: OneToOneQueue.ApprovalMethod.EIP20_APROVE,
        approvalV: 0,
        approvalR: bytes32(0),
        approvalS: bytes32(0),
        submitWithSignature: false,
        deadline: block.timestamp + 1000,
        eip2612Signature: "",
        nonce: 0
    });

    function setUp() public virtual {
        vm.startPrank(owner);
        feeModule = new SimpleFeeModule(TEST_OFFER_FEE_PERCENTAGE);
        queue = new OneToOneQueue(
            "name", "symbol", mockBoringVaultAddress, feeRecipient, feeModule, recoveryAddress, owner
        );

        address[] memory pausers = new address[](2);
        pausers[0] = pauser1;
        pausers[1] = pauser2;
        rolesAuthority = new QueueAccessAuthority(owner, address(queue), pausers);

        (alice, alicePk) = makeAddrAndKey("alice");

        queue.setAuthority(rolesAuthority);

        USDC = IERC20(address(new tERC20(6)));
        USDG0 = IERC20(address(new tERC20(6)));
        DAI = IERC20(address(new tERC20(18)));

        queue.addOfferAsset(address(USDC), 0);
        queue.addWantAsset(address(USDG0));
        vm.stopPrank();
    }

    // Helper function to create SubmitOrderParams struct
    function _createSubmitOrderParams(
        uint256 amountOffer,
        IERC20 offerAsset,
        IERC20 wantAsset,
        address intendedDepositor,
        address receiver,
        address refundReceiver,
        OneToOneQueue.SignatureParams memory signatureParams
    )
        internal
        pure
        returns (OneToOneQueue.SubmitOrderParams memory)
    {
        return OneToOneQueue.SubmitOrderParams({
            amountOffer: amountOffer,
            offerAsset: offerAsset,
            wantAsset: wantAsset,
            intendedDepositor: intendedDepositor,
            receiver: receiver,
            refundReceiver: refundReceiver,
            signatureParams: signatureParams
        });
    }

    function _submitAnOrder() internal {
        deal(address(USDC), user1, 1e6);
        vm.startPrank(user1);
        USDC.approve(address(queue), 1e6);
        _expectOrderSubmittedEvent(1e6, USDC, USDG0, user1, user1, user1, defaultParams, user1, false);
        OneToOneQueue.SubmitOrderParams memory params =
            _createSubmitOrderParams(1e6, USDC, USDG0, user1, user1, user1, defaultParams);
        uint256 orderIndex = queue.submitOrder(params);
        vm.stopPrank();

        assertTrue(queue.ownerOf(orderIndex) == user1, "_sumbitAnOrder: user1 should be the owner of the order");
    }

    function _expectOrderSubmittedEvent(
        uint256 amountOffer,
        IERC20 offerAsset,
        IERC20 wantAsset,
        address intendedDepositor,
        address receiver,
        address refundReceiver,
        OneToOneQueue.SignatureParams memory params,
        address depositor,
        bool isSubmittedViaSignature
    )
        internal
    {
        OneToOneQueue.Order memory expectedOrder = OneToOneQueue.Order({
            amountOffer: uint128(amountOffer),
            amountWant: uint128(
                _getWantAmountInWantDecimals(uint128(amountOffer), offerAsset, wantAsset)
                    * (10_000 - TEST_OFFER_FEE_PERCENTAGE) / 10_000
            ),
            offerAsset: offerAsset,
            wantAsset: wantAsset,
            refundReceiver: refundReceiver,
            orderType: OneToOneQueue.OrderType.DEFAULT,
            didOrderFailTransfer: false
        });
        vm.expectEmit(true, true, true, true);
        emit OneToOneQueue.OrderSubmitted(
            queue.latestOrder() + 1, expectedOrder, receiver, depositor, isSubmittedViaSignature
        );
    }

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

    function _expectOrderProcessedEvent(
        uint256 orderIndex,
        OneToOneQueue.OrderType orderType,
        bool isForceProcessed,
        bool didOrderFailTransfer
    )
        internal
    {
        (
            uint128 amountOffer,
            uint128 amountWant,
            IERC20 offerAsset,
            IERC20 wantAsset,
            address refundReceiver,
            // old order type
            ,
            // old did order fail transfer value
        ) = queue.queue(orderIndex);

        address receiver = queue.ownerOf(orderIndex);

        OneToOneQueue.Order memory order = OneToOneQueue.Order({
            offerAsset: offerAsset,
            wantAsset: wantAsset,
            amountOffer: amountOffer,
            amountWant: amountWant,
            refundReceiver: refundReceiver,
            orderType: orderType,
            didOrderFailTransfer: didOrderFailTransfer
        });

        vm.expectEmit(true, true, true, true);
        emit OneToOneQueue.OrderProcessed(orderIndex, order, receiver, isForceProcessed);
    }

    function _getPermitSignature(
        IERC20 token,
        address owner,
        uint256 ownerPk,
        address spender,
        uint256 value,
        uint256 deadline
    )
        internal
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 permitHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                IERC20Permit(address(token)).DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        owner,
                        spender,
                        value,
                        IERC20Permit(address(token)).nonces(owner),
                        deadline
                    )
                )
            )
        );
        (v, r, s) = vm.sign(ownerPk, permitHash);
    }

}
