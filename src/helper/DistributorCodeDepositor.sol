// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { TellerWithMultiAssetSupport } from "../base/Roles/TellerWithMultiAssetSupport.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { Auth, Authority } from "solmate/auth/Auth.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { IFeeModule, IERC20 } from "src/interfaces/IFeeModule.sol";
import { Attestation } from "@predicate/interfaces/IPredicateRegistry.sol";
import { PredicateClient } from "@predicate/mixins/PredicateClient.sol";

interface INativeWrapper {

    function balanceOf(address account) external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function deposit() external payable;

    function withdraw(uint256 wad) external;

    function decimals() external view returns (uint8);

}

contract DistributorCodeDepositor is Auth, PredicateClient {

    using SafeTransferLib for ERC20;

    error ZeroAddress();
    error IncorrectNativeDepositAmount();
    error NativeWrapperAccountantDecimalsMismatch();
    error NativeDepositNotSupported();
    error PermitFailedAndAllowanceTooLow();
    error FeesExceedOrEqualShares();

    INativeWrapper public immutable nativeWrapper;

    TellerWithMultiAssetSupport public immutable teller;
    address public immutable boringVault;
    bool public immutable isNativeDepositSupported;

    uint256 public depositNonce;

    uint256 public supplyCap;
    address public feeRecipient;
    IFeeModule public feeModule;

    mapping(ERC20 => bool) public kytEnabled;

    // more details on the deposit also exists on the Teller event
    event DepositWithDistributorCode(
        address indexed depositor,
        ERC20 indexed depositAsset,
        uint256 depositAmount,
        uint256 minimumMint,
        address to,
        bytes32 depositHash,
        bytes indexed distributorCode
    );

    event SupplyCapUpdated(uint256 newSupplyCap);
    event FeeModuleUpdated(IFeeModule indexed newFeeModule);
    event FeeRecipientUpdated(address indexed newFeeRecipient);
    event KytStatusUpdated(ERC20 indexed depositAsset, bool enabled);

    error SupplyCapError(uint256 resultingSupply, uint256 supplyCap);
    error NoCode(address addressEmptyCode);
    error UnauthorizedTransaction();

    constructor(
        TellerWithMultiAssetSupport _teller,
        INativeWrapper _nativeWrapper,
        Authority _rolesAuthority,
        bool _isNativeDepositSupported,
        uint256 _supplyCap,
        IFeeModule _feeModule,
        address _feeRecipient,
        address _registry,
        string memory _policyID,
        address _owner
    )
        Auth(_owner, _rolesAuthority)
    {
        if (address(_teller) == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();

        // check that if we're depositing native asset, the accountant decimals is equal to base decimals
        if (_isNativeDepositSupported) {
            if (address(_nativeWrapper) == address(0)) revert ZeroAddress();
            if (_teller.accountant().decimals() != _nativeWrapper.decimals()) {
                revert NativeWrapperAccountantDecimalsMismatch();
            }
        } else {
            if (address(_nativeWrapper) != address(0)) {
                if (_teller.accountant().decimals() != _nativeWrapper.decimals()) {
                    revert NativeWrapperAccountantDecimalsMismatch();
                }
            }
        }

        address newFeeModuleAddress = address(_feeModule);
        if (newFeeModuleAddress != address(0) && newFeeModuleAddress.code.length == 0) {
            revert NoCode(newFeeModuleAddress);
        }

        if (_feeRecipient == address(0)) revert ZeroAddress();

        teller = _teller;
        boringVault = address(_teller.vault());
        nativeWrapper = _nativeWrapper;
        isNativeDepositSupported = _isNativeDepositSupported;
        supplyCap = _supplyCap;
        feeModule = _feeModule;
        feeRecipient = _feeRecipient;
        _initPredicateClient(_registry, _policyID);

        if (boringVault == address(0)) revert ZeroAddress();
    }

    function setPolicyID(string memory _policyID) external requiresAuth {
        _setPolicyID(_policyID);
    }

    function setRegistry(address _registry) external requiresAuth {
        _setRegistry(_registry);
    }

    /**
     * @dev OWNER function to update the supply cap. We allow setting the cap to anything. Including values < current
     * supply and a value = 0
     */
    function updateSupplyCap(uint256 newSupplyCap) external requiresAuth {
        supplyCap = newSupplyCap;
        emit SupplyCapUpdated(newSupplyCap);
    }

    /**
     * @dev OWNER function to update the fee module. We allow setting the fee module to the zero address as we handle
     * this as no fees.
     */
    function updateFeeModule(IFeeModule newFeeModule) external requiresAuth {
        address newFeeModuleAddress = address(newFeeModule);
        if (newFeeModuleAddress != address(0) && newFeeModuleAddress.code.length == 0) {
            revert NoCode(newFeeModuleAddress);
        }
        feeModule = newFeeModule;
        emit FeeModuleUpdated(newFeeModule);
    }

    /**
     * @dev OWNER function to update the fee recipient.
     */
    function updateFeeRecipient(address newFeeRecipient) external requiresAuth {
        if (newFeeRecipient == address(0)) revert ZeroAddress();
        feeRecipient = newFeeRecipient;
        emit FeeRecipientUpdated(newFeeRecipient);
    }

    /**
     * @dev OWNER function to update the KYT status of an asset
     */
    function updateKytStatus(ERC20 depositAsset, bool enabled) external requiresAuth {
        kytEnabled[depositAsset] = enabled;
        emit KytStatusUpdated(depositAsset, enabled);
    }

    /**
     * @notice For depositing the native asset of the chain
     * @param depositAmount The amount to deposit
     * @param minimumMint Minimum amount of shares to mint. Reverts otherwise
     * @param to The recipient of the shares
     * @param distributorCode Indicator for which operator the token gets staked to
     */
    function depositNative(
        uint256 depositAmount,
        uint256 minimumMint,
        address to,
        bytes calldata distributorCode,
        Attestation calldata _attestation
    )
        external
        payable
        requiresAuth
        returns (uint256 shares)
    {
        if (!isNativeDepositSupported) revert NativeDepositNotSupported();
        if (msg.value != depositAmount) revert IncorrectNativeDepositAmount();
        _authorizeKyt(_attestation, ERC20(address(nativeWrapper)), depositAmount, minimumMint, to, distributorCode);
        nativeWrapper.deposit{ value: msg.value }();
        return _deposit(ERC20(address(nativeWrapper)), depositAmount, minimumMint, to, distributorCode);
    }

    /**
     * @notice Deposits tokens and emits an event with a unique hash
     * @param depositAsset The ERC20 token to deposit
     * @param depositAmount The amount to deposit
     * @param minimumMint Minimum amount of shares to mint. Reverts otherwise
     * @param to The recipient of the shares
     * @param distributorCode Indicator for which operator the token gets staked to
     */
    function deposit(
        ERC20 depositAsset,
        uint256 depositAmount,
        uint256 minimumMint,
        address to,
        bytes calldata distributorCode,
        Attestation calldata _attestation
    )
        external
        requiresAuth
        returns (uint256 shares)
    {
        _authorizeKyt(_attestation, depositAsset, depositAmount, minimumMint, to, distributorCode);
        depositAsset.safeTransferFrom(msg.sender, address(this), depositAmount);
        return _deposit(depositAsset, depositAmount, minimumMint, to, distributorCode);
    }

    function depositWithPermit(
        ERC20 depositAsset,
        uint256 depositAmount,
        uint256 minimumMint,
        address to,
        bytes calldata distributorCode,
        Attestation calldata _attestation,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
        requiresAuth
        returns (uint256 shares)
    {
        _authorizeKyt(_attestation, depositAsset, depositAmount, minimumMint, to, distributorCode);
        // cannot just wrap the teller.depositWithPermit because
        // we need to use permit to process approval on this contract before making a deposit.

        // solhint-disable-next-line no-empty-blocks
        try depositAsset.permit(msg.sender, address(this), depositAmount, deadline, v, r, s) { }
        catch {
            if (depositAsset.allowance(msg.sender, address(this)) < depositAmount) {
                revert PermitFailedAndAllowanceTooLow();
            }
        }

        depositAsset.safeTransferFrom(msg.sender, address(this), depositAmount);

        return _deposit(depositAsset, depositAmount, minimumMint, to, distributorCode);
    }

    /**
     * Always assumes that the `depositAsset` is on this contract's balance.
     */
    function _deposit(
        ERC20 depositAsset,
        uint256 depositAmount,
        uint256 minimumMint,
        address to,
        bytes calldata distributorCode
    )
        internal
        returns (uint256 shares)
    {
        if (to == address(0)) revert ZeroAddress();
        bytes32 depositHash;
        unchecked {
            depositHash = keccak256(abi.encodePacked(address(this), ++depositNonce, block.chainid));
        }

        // Clear leftover allowance for non-standard ERC20
        _tryClearApproval(depositAsset);
        depositAsset.safeApprove(boringVault, depositAmount);

        shares = teller.deposit(depositAsset, depositAmount, minimumMint);

        uint256 feeAmount;

        // if fee module is zero, no fees
        if (address(feeModule) != address(0)) {
            feeAmount = feeModule.calculateOfferFees(shares, IERC20(address(depositAsset)), IERC20(boringVault), to);
            if (feeAmount >= shares) revert FeesExceedOrEqualShares();

            // Send the fees to the fee recipient if fees are taken
            if (feeAmount > 0) {
                ERC20(boringVault).safeTransfer(feeRecipient, feeAmount);
            }
        }

        // Send "to" the shares - fees
        ERC20(boringVault).safeTransfer(to, shares - feeAmount);
        uint256 totalSupply = ERC20(boringVault).totalSupply();

        // Enforce the supply cap
        if (totalSupply > supplyCap) revert SupplyCapError(totalSupply, supplyCap);

        // Clear leftover allowance
        _tryClearApproval(depositAsset);

        emit DepositWithDistributorCode(
            msg.sender, depositAsset, depositAmount, minimumMint, to, depositHash, distributorCode
        );
    }

    /**
     * @dev Helper function to only perform Predicate authorization if the KYT status is enabled for the asset
     */
    function _authorizeKyt(
        Attestation calldata _attestation,
        ERC20 depositAsset,
        uint256 depositAmount,
        uint256 minimumMint,
        address to,
        bytes calldata distributorCode
    )
        internal
    {
        if (kytEnabled[depositAsset]) {
            bytes memory encodedSigAndArgs = abi.encodeWithSignature(
                "_deposit(address,uint256,uint256,address,bytes)",
                depositAsset,
                depositAmount,
                minimumMint,
                to,
                distributorCode
            );
            if (!_authorizeTransaction(_attestation, encodedSigAndArgs, msg.sender, msg.value)) {
                revert UnauthorizedTransaction();
            }
        }
    }

    /**
     * @notice Helper function to clear allowance. Helps with weird ERC20s that require a 0 approval before a new one.
     * And also this does not revert on failure in order to also handle ERC20s that revert on a zero approval.
     * @dev In the case of a token that reverts on a zero approval AND requires approval set to 0 before a new approval
     * this will of course fail. But we would consider this a critical flaw of the token itself.
     */
    function _tryClearApproval(ERC20 depositAsset) internal {
        address(depositAsset).call(abi.encodeWithSelector(depositAsset.approve.selector, boringVault, 0));
    }

}
