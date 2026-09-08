// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

// Solmate Imports
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { WETH } from "@solmate/tokens/WETH.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol"; // Import SafeTransferLib
import { ReentrancyGuard } from "@solmate/utils/ReentrancyGuard.sol";

// Interface Imports
import { AggregationRouterV6 } from "src/interfaces/AggregationRouterV6.sol";
import { IOKXRouter } from "src/interfaces/IOKXRouter.sol";

// Base Contract Imports (Assuming paths are correct)
import { CrossChainTellerBase, BridgeData } from "src/base/Roles/CrossChain/CrossChainTellerBase.sol";
import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";

/**
 * @custom:security-contact security@paxoslabs.com
 */
contract DexAggregatorWrapper is ReentrancyGuard {

    // Apply SafeTransferLib only to ERC20 (WETH inherits from ERC20)
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    // --- State Variables ---
    AggregationRouterV6 immutable aggregator;
    IOKXRouter immutable okxRouter;
    address immutable okxApprover;
    WETH immutable canonicalWrapToken;

    // --- OKX Function Selectors ---
    bytes4 private constant SMART_SWAP_BY_ORDER_ID_SELECTOR = 0xb80c2f09;
    bytes4 private constant SMART_SWAP_TO_SELECTOR = 0x03b87e5f;
    bytes4 private constant UNISWAP_V3_SWAP_TO_SELECTOR = 0x0d5f0e3b;
    bytes4 private constant UNISWAP_V3_SWAP_TO_WITH_PERMIT_SELECTOR = 0xf3e144b6;
    bytes4 private constant UNXSWAP_BY_ORDER_ID_SELECTOR = 0x9871efa4;
    bytes4 private constant UNXSWAP_TO_SELECTOR = 0x08298b5a;

    // --- Errors ---
    error DexAggregatorWrapper__InvalidSwapDescription();
    error DexAggregatorWrapper__InvalidOkxSwapDescription();
    error DexAggregatorWrapper__UnsupportedOkxFunction();
    error DexAggregatorWrapper__OkxSwapFailed();
    error DexAggregatorWrapper__InvalidFromToken();
    error DexAggregatorWrapper__InsufficientEthForSwap();
    error DexAggregatorWrapper__EthRefundFailed();

    event Deposit(
        address indexed depositAsset,
        address indexed receiver,
        address indexed supportedAsset,
        uint256 depositAmount,
        uint256 supportedAssetAmount,
        uint256 shareAmount
    );

    // --- Constructor ---
    constructor(
        AggregationRouterV6 _aggregator,
        IOKXRouter _okxRouter,
        address _okxApprover,
        WETH _canonicalWrapToken
    ) {
        aggregator = _aggregator;
        okxRouter = _okxRouter;
        okxApprover = _okxApprover;
        canonicalWrapToken = _canonicalWrapToken;
    }

    // --- Public Functions ---

    function depositOneInch(
        ERC20 supportedAsset,
        TellerWithMultiAssetSupport teller,
        uint256 minimumMint,
        address executor,
        AggregationRouterV6.SwapDescription calldata desc,
        bytes calldata data,
        uint256 nativeValueToWrap
    )
        external
        payable
        nonReentrant
        returns (uint256 shares)
    {
        uint256 supportedAssetAmount =
            _oneInchHelper(supportedAsset, address(teller), executor, desc, data, nativeValueToWrap);

        // Deposit into the vault
        shares = teller.deposit(supportedAsset, supportedAssetAmount, minimumMint);

        // Get vault address
        address vaultAddress = address(teller.vault());
        if (vaultAddress == address(0)) {
            // Handle error: Vault address cannot be zero if we need to transfer shares
            revert("DexAggregatorWrapper: Invalid vault address");
        }
        // Use safeTransfer to send shares to msg.sender
        ERC20(vaultAddress).safeTransfer(msg.sender, shares);
        emit Deposit(
            address(desc.srcToken), msg.sender, address(supportedAsset), desc.amount, supportedAssetAmount, shares
        );
    }

    function depositAndBridgeOneInch(
        ERC20 supportedAsset,
        CrossChainTellerBase teller,
        uint256 minimumMint,
        BridgeData calldata bridgeData,
        address executor,
        AggregationRouterV6.SwapDescription calldata desc,
        bytes calldata data,
        uint256 nativeValueToWrap
    )
        external
        payable
        nonReentrant
    {
        uint256 supportedAssetAmount =
            _oneInchHelper(supportedAsset, address(teller), executor, desc, data, nativeValueToWrap);

        // Deposit and bridge assets
        teller.depositAndBridge{ value: msg.value - nativeValueToWrap }(
            supportedAsset, supportedAssetAmount, minimumMint, bridgeData
        );

        // Refund any excess ETH
        _refundExcessEth(payable(msg.sender));

        uint256 shares = supportedAssetAmount.mulDivDown(
            10 ** teller.vault().decimals(),
            AccountantWithRateProviders(teller.accountant()).getRateInQuoteSafe(supportedAsset)
        );
        emit Deposit(
            address(desc.srcToken), msg.sender, address(supportedAsset), desc.amount, supportedAssetAmount, shares
        );
    }

    function depositOkxUniversal(
        ERC20 supportedAsset,
        TellerWithMultiAssetSupport teller,
        uint256 minimumMint,
        address fromToken,
        uint256 fromTokenAmount,
        bytes calldata okxCallData,
        uint256 nativeValueToWrap
    )
        external
        payable
        nonReentrant
        returns (uint256 shares)
    {
        uint256 supportedAssetAmount =
            _okxHelper(supportedAsset, address(teller), fromToken, fromTokenAmount, okxCallData, nativeValueToWrap);

        // Deposit assets
        shares = teller.deposit(supportedAsset, supportedAssetAmount, minimumMint);

        // Get vault address
        address vaultAddress = address(teller.vault());
        if (vaultAddress == address(0)) {
            revert("DexAggregatorWrapper: Invalid vault address");
        }
        // Use safeTransfer to send shares to msg.sender
        ERC20(vaultAddress).safeTransfer(msg.sender, shares);
        emit Deposit(fromToken, msg.sender, address(supportedAsset), fromTokenAmount, supportedAssetAmount, shares);
    }

    function depositAndBridgeOkxUniversal(
        ERC20 supportedAsset,
        CrossChainTellerBase teller,
        uint256 minimumMint,
        BridgeData calldata bridgeData,
        address fromToken,
        uint256 fromTokenAmount,
        bytes calldata okxCallData,
        uint256 nativeValueToWrap
    )
        external
        payable
        nonReentrant
    {
        uint256 supportedAssetAmount =
            _okxHelper(supportedAsset, address(teller), fromToken, fromTokenAmount, okxCallData, nativeValueToWrap);

        // Deposit and bridge the assets
        teller.depositAndBridge{ value: msg.value - nativeValueToWrap }(
            supportedAsset, supportedAssetAmount, minimumMint, bridgeData
        );

        // Refund any excess ETH
        _refundExcessEth(payable(msg.sender));

        //get the share amount
        uint256 shares = supportedAssetAmount.mulDivDown(
            10 ** teller.vault().decimals(),
            AccountantWithRateProviders(teller.accountant()).getRateInQuoteSafe(supportedAsset)
        );
        emit Deposit(fromToken, msg.sender, address(supportedAsset), fromTokenAmount, supportedAssetAmount, shares);
    }

    // --- Internal Helper Functions ---

    function _oneInchHelper(
        ERC20 supportedAsset,
        address teller,
        address executor,
        AggregationRouterV6.SwapDescription calldata desc,
        bytes calldata data,
        uint256 nativeValueToWrap
    )
        internal
        returns (uint256 supportedAssetAmount)
    {
        bool useNative = _checkAndMintNativeAmount(nativeValueToWrap);
        // Assume desc.dstToken is ERC20 type as per original code structure
        if (desc.dstToken != supportedAsset || desc.dstReceiver != address(this)) {
            revert DexAggregatorWrapper__InvalidSwapDescription();
        }

        if (useNative) {
            // Ensure desc.srcToken matches canonicalWrapToken address
            if (address(desc.srcToken) != address(canonicalWrapToken) || desc.amount != nativeValueToWrap) {
                revert DexAggregatorWrapper__InvalidSwapDescription();
            }
            // Use standard approve (as requested) - potential risk if WETH impl changes non-standardly
            canonicalWrapToken.approve(address(aggregator), nativeValueToWrap);
        } else {
            ERC20 depositAsset = desc.srcToken; // Assumes desc.srcToken is ERC20 type
            uint256 depositAmount = desc.amount;

            // Use safeTransferFrom
            depositAsset.safeTransferFrom(msg.sender, address(this), depositAmount);

            // Approve aggregator to take tokens from this contract
            depositAsset.safeApprove(address(aggregator), depositAmount);
        }

        // Perform swap
        (supportedAssetAmount,) = aggregator.swap(executor, desc, data);

        // Approve teller's vault to spend the supported asset
        // Cast teller address to TellerWithMultiAssetSupport to call vault()
        // payable cast might be needed depending on Teller interface
        address vaultAddress = address(TellerWithMultiAssetSupport(payable(teller)).vault()); // Example cast, adjust if
        // needed
        if (vaultAddress == address(0)) {
            revert("DexAggregatorWrapper: Invalid vault address for approval");
        }
        // Use standard approve (as requested)
        supportedAsset.safeApprove(vaultAddress, supportedAssetAmount);

        return supportedAssetAmount;
    }

    function _okxHelper(
        ERC20 supportedAsset,
        address teller,
        address fromToken,
        uint256 fromTokenAmount,
        bytes calldata okxCallData,
        uint256 nativeValueToWrap
    )
        internal
        returns (uint256 supportedAssetAmount)
    {
        bytes4 selector;
        /// @solidity memory-safe-assembly
        assembly {
            selector := calldataload(okxCallData.offset)
        }

        if (
            selector == SMART_SWAP_BY_ORDER_ID_SELECTOR || selector == SMART_SWAP_TO_SELECTOR
                || selector == UNISWAP_V3_SWAP_TO_SELECTOR || selector == UNISWAP_V3_SWAP_TO_WITH_PERMIT_SELECTOR
                || selector == UNXSWAP_BY_ORDER_ID_SELECTOR || selector == UNXSWAP_TO_SELECTOR
        ) {
            bool useNative = _checkAndMintNativeAmount(nativeValueToWrap);
            if (useNative) {
                if (fromToken != address(canonicalWrapToken) || fromTokenAmount != nativeValueToWrap) {
                    revert DexAggregatorWrapper__OkxSwapFailed();
                }
                // Use standard approve (as requested)
                canonicalWrapToken.approve(okxApprover, nativeValueToWrap);
            } else {
                // Cast fromToken address to ERC20 to use the library
                ERC20 depositAsset = ERC20(fromToken);

                // Use safeTransferFrom
                depositAsset.safeTransferFrom(msg.sender, address(this), fromTokenAmount);

                // Use standard approve (as requested) for the OKX approver
                depositAsset.safeApprove(okxApprover, fromTokenAmount);
            }

            // Execute the swap with the provided calldata
            (bool success, bytes memory result) = address(okxRouter).call(okxCallData);
            if (!success) {
                /// @solidity memory-safe-assembly
                assembly {
                    revert(add(result, 32), mload(result))
                }
            }

            // Decode the return value
            supportedAssetAmount = abi.decode(result, (uint256));

            // Approve teller's vault to spend the supported asset
            // Cast teller address to TellerWithMultiAssetSupport to call vault()
            // payable cast might be needed depending on Teller interface
            address vaultAddress = address(TellerWithMultiAssetSupport(payable(teller)).vault()); // Example cast,
            // adjust if needed
            if (vaultAddress == address(0)) {
                revert("DexAggregatorWrapper: Invalid vault address for approval");
            }
            // Use standard approve (as requested)
            supportedAsset.safeApprove(vaultAddress, supportedAssetAmount);

            // Return value needs to be here since it's declared in the function signature
            return supportedAssetAmount;
        } else {
            revert DexAggregatorWrapper__UnsupportedOkxFunction();
        }
        // Note: If the selector doesn't match, the function will revert above, so no explicit return needed here.
    }

    function _checkAndMintNativeAmount(uint256 nativeAmount) internal returns (bool useNative) {
        if (nativeAmount > msg.value) {
            revert DexAggregatorWrapper__InsufficientEthForSwap();
        }
        if (nativeAmount > 0) {
            // Direct WETH call, no SafeTransferLib needed here
            canonicalWrapToken.deposit{ value: nativeAmount }();
            useNative = true;
        }
        // Implicitly returns false if nativeAmount is 0
    }

    /**
     * @notice Transfers the entire current ETH balance of this contract to the specified recipient.
     * @param _recipient The address to receive the ETH refund.
     * @dev Uses a low-level call and reverts if the transfer fails. This ensures atomicity,
     *      either the whole operation succeeds including refund, or it fails.
     */
    function _refundExcessEth(address payable _recipient) internal {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool success,) = _recipient.call{ value: balance }("");
            if (!success) {
                revert DexAggregatorWrapper__EthRefundFailed();
            }
        }
        // If balance is 0, do nothing.
    }

    receive() external payable { }

}
