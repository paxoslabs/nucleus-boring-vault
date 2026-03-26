// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { MainnetAddresses } from "test/resources/MainnetAddresses.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { RolesAuthority, Authority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { TELLER_ROLE } from "src/helper/Constants.sol";
import { Statement, Attestation } from "@predicate/interfaces/IPredicateRegistry.sol";

import { Test, stdStorage, StdStorage, stdError } from "@forge-std/Test.sol";

import { console } from "forge-std/console.sol";

interface IPredicateRegistry {

    function owner() external view returns (address);
    function registerAttester(address _attester) external;
    function hashStatementWithExpiry(Statement memory statement) external view returns (bytes32);

}

abstract contract VaultArchitectureSharedSetup is Test, MainnetAddresses {

    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;
    using stdStorage for StdStorage;

    StdStorage stdstore1;

    // Core vault components
    BoringVault internal boringVault;
    TellerWithMultiAssetSupport internal teller;
    AccountantWithRateProviders internal accountant;
    RolesAuthority internal rolesAuthority;

    address internal payout_address = vm.addr(7_777_777);
    address internal constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    ERC20 internal constant NATIVE_ERC20 = ERC20(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    uint256 internal ONE_SHARE;

    // Predicate-related state variables
    IPredicateRegistry internal predicateRegistry;
    address internal attesterOne;
    uint256 internal attesterOnePk;
    string internal policyOne;

    /**
     * @notice Start a forked environment for testing.}
     * @param rpcKey The RPC URL key
     * @param blockNumber The block number to fork from
     * @return forkId The fork ID
     */
    function _startFork(string memory rpcKey, uint256 blockNumber) internal returns (uint256 forkId) {
        forkId = vm.createFork(vm.envString(rpcKey), blockNumber);
        vm.selectFork(forkId);
    }

    function _setERC20Balance(address token, address usr, uint256 amt) internal {
        stdstore1.target(token).sig(ERC20(token).balanceOf.selector).with_key(usr).checked_write(amt);
        require(ERC20(token).balanceOf(usr) == amt, "balance not set");
    }

    /**
     * @notice Deploy a complete vault architecture with the given parameters
     * @param name Vault name
     * @param symbol Vault symbol
     * @param decimals Vault decimals
     * @param assets Array of depositable asset addresses. Pegged by default.
     * @param exchangeRate Starting exchange rate
     * @return boringVault The deployed BoringVault
     * @return teller The deployed TellerWithMultiAssetSupport
     * @return accountant The deployed AccountantWithRateProviders
     */
    function _deployVaultArchitecture(
        string memory name,
        string memory symbol,
        uint8 decimals,
        address base,
        address[] memory assets,
        uint256 exchangeRate
    )
        internal
        returns (BoringVault boringVault, TellerWithMultiAssetSupport teller, AccountantWithRateProviders accountant)
    {
        ONE_SHARE = 10 ** decimals;

        // Deploy BoringVault
        boringVault = new BoringVault(address(this), name, symbol, decimals);

        // Deploy AccountantWithRateProviders
        accountant = new AccountantWithRateProviders(
            address(this), address(boringVault), payout_address, uint96(exchangeRate), base, 1.001e4, 0.999e4, 1, 0, 0
        );

        // Deploy TellerWithMultiAssetSupport
        teller = new TellerWithMultiAssetSupport(address(this), address(boringVault), address(accountant));

        // Deploy RolesAuthority
        rolesAuthority = new RolesAuthority(address(this), Authority(address(0)));

        boringVault.setAuthority(rolesAuthority);
        accountant.setAuthority(rolesAuthority);
        teller.setAuthority(rolesAuthority);

        // Set public capabilities for teller
        rolesAuthority.setPublicCapability(address(teller), TellerWithMultiAssetSupport.deposit.selector, true);
        rolesAuthority.setPublicCapability(
            address(teller), TellerWithMultiAssetSupport.depositWithPermit.selector, true
        );

        // Configure roles
        rolesAuthority.setRoleCapability(TELLER_ROLE, address(boringVault), BoringVault.enter.selector, true);
        rolesAuthority.setRoleCapability(TELLER_ROLE, address(boringVault), BoringVault.exit.selector, true);

        // Set user roles
        rolesAuthority.setUserRole(address(teller), TELLER_ROLE, true);

        // Add assets to teller
        // NOTE assets are pegged by default
        for (uint256 i = 0; i < assets.length; i++) {
            console.logUint(i);
            console.log("assets[i]", assets[i]);
            if (assets[i] != address(0)) {
                teller.addDepositAsset(ERC20(assets[i]));
                teller.addWithdrawAsset(ERC20(assets[i]));
                accountant.setRateProviderData(ERC20(assets[i]), true, address(0));
            }
        }
    }

    function _createAttestation(
        string memory uuid,
        address msgSender,
        address target,
        uint256 msgValue,
        bytes memory encodedSigAndArgs
    )
        internal
        view
        returns (Attestation memory attestation)
    {
        uint256 expireTime = block.timestamp + 1000;

        bytes32 messageHash = predicateRegistry.hashStatementWithExpiry(
            Statement({
                uuid: uuid,
                msgSender: msgSender,
                target: target,
                msgValue: msgValue,
                encodedSigAndArgs: encodedSigAndArgs,
                policy: policyOne,
                expiration: expireTime
            })
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attesterOnePk, messageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        attestation = Attestation({ uuid: uuid, expiration: expireTime, attester: attesterOne, signature: signature });
    }

    function _createAttestationForDeposit(
        string memory uuid,
        address msgSender,
        address target,
        address depositAsset,
        uint256 depositAmount,
        uint256 minimumMint,
        address recipient,
        bytes memory distributorCode
    )
        internal
        view
        returns (Attestation memory attestation)
    {
        bytes memory encodedSigAndArgs = abi.encodeWithSignature(
            "deposit(address,uint256,uint256,address,bytes)",
            depositAsset,
            depositAmount,
            minimumMint,
            recipient,
            distributorCode
        );

        return _createAttestation(uuid, msgSender, target, 0, encodedSigAndArgs);
    }

}
