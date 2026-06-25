// SPDX-License-Identifier: Apache-2.0
pragma solidity =0.8.21;

import { console } from "forge-std/console.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { ManagerWithMerkleVerification } from "src/base/Roles/ManagerWithMerkleVerification.sol";
import { RolesAuthority, Authority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { TransitStation } from "src/transit/TransitStation.sol";
import { BaseScript } from "script/Base.s.sol";
import "src/helper/Constants.sol";

/// @notice Production deployment for a Transit Station, with its BoringVault + Manager combo.
/// @dev IMPORTANT — if you reuse a `RolesAuthority` that has ALREADY been transferred to the multisig, the
///      broadcaster no longer owns it, so the station role wiring (`setRoleCapability` / `setUserRole` /
///      `setPublicCapability`) and `setRouteApprovals` below will revert. In that case run those steps as a multisig
///      transaction instead of from this EOA broadcast.
contract DeployTransitStation is BaseScript {

    // ============================== FILL PER DEPLOYMENT ==============================

    // Backend quote signer (zero-checked in the constructor, so a fresh deploy reverts until set).
    address constant QUOTE_SIGNER = address(0); // TODO: production quote signer
    // Executor granted TRANSIT_EXECUTOR_ROLE (fulfills orders).
    address constant EXECUTOR = address(0); // TODO: production executor

    // Reuse an existing vault/manager combo by setting these and commenting out the deploy block in run().
    address constant EXISTING_ROLES_AUTHORITY = address(0);
    address constant EXISTING_BORING_VAULT = address(0);
    address constant EXISTING_MANAGER = address(0);

    // BoringVault metadata (only used when deploying fresh).
    string constant NAME = "Transit Vault";
    string constant SYMBOL = "TRANSIT";
    uint8 constant DECIMALS = 6;

    uint64 constant MESSAGE_GAS_LIMIT = 400_000;
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    // ============================== SALTS ==============================

    bytes32 SALT_ROLES_AUTHORITY = makeSalt(broadcaster, false, "Transit: RolesAuthority");
    bytes32 SALT_BORING_VAULT = makeSalt(broadcaster, false, "Transit: BoringVault");
    bytes32 SALT_MANAGER = makeSalt(broadcaster, false, "Transit: ManagerWithMerkleVerification");
    bytes32 SALT_STATION = makeSalt(broadcaster, false, "Transit: TransitStation");

    RolesAuthority public rolesAuthority;
    BoringVault public boringVault;
    ManagerWithMerkleVerification public manager;
    TransitStation public transitStation;

    function run() public broadcast {
        // ==================== DEPLOY VAULT / MANAGER COMBO ====================
        rolesAuthority = RolesAuthority(
            CREATEX.deployCreate3(
                SALT_ROLES_AUTHORITY,
                abi.encodePacked(type(RolesAuthority).creationCode, abi.encode(broadcaster, Authority(address(0))))
            )
        );
        boringVault = BoringVault(
            payable(CREATEX.deployCreate3(
                    SALT_BORING_VAULT,
                    abi.encodePacked(type(BoringVault).creationCode, abi.encode(broadcaster, NAME, SYMBOL, DECIMALS))
                ))
        );
        manager = ManagerWithMerkleVerification(
            CREATEX.deployCreate3(
                SALT_MANAGER,
                abi.encodePacked(
                    type(ManagerWithMerkleVerification).creationCode,
                    abi.encode(broadcaster, address(boringVault), BALANCER_VAULT)
                )
            )
        );
        boringVault.setAuthority(rolesAuthority);
        manager.setAuthority(rolesAuthority);
        rolesAuthority.setRoleCapability(
            MANAGER_ROLE, address(boringVault), bytes4(keccak256("manage(address,bytes,uint256)")), true
        );
        rolesAuthority.setRoleCapability(
            MANAGER_ROLE, address(boringVault), bytes4(keccak256("manage(address[],bytes[],uint256[])")), true
        );
        rolesAuthority.setRoleCapability(
            STRATEGIST_ROLE,
            address(manager),
            ManagerWithMerkleVerification.manageVaultWithMerkleVerification.selector,
            true
        );
        rolesAuthority.setUserRole(address(manager), MANAGER_ROLE, true);

        // ==================== DEPLOY STATION ====================
        transitStation = TransitStation(
            payable(CREATEX.deployCreate3(
                    SALT_STATION,
                    abi.encodePacked(
                        type(TransitStation).creationCode,
                        abi.encode(
                            broadcaster,
                            Authority(address(rolesAuthority)),
                            _lzEndpoint(),
                            getMultisig(), // protocolFeeRecipient
                            QUOTE_SIGNER,
                            address(boringVault), // offerReceiver
                            address(boringVault) // wantAssetSource
                        )
                    )
                ))
        );

        // ==================== STATION ROLE WIRING ====================
        rolesAuthority.setRoleCapability(
            TRANSIT_EXECUTOR_ROLE, address(transitStation), TransitStation.executePendingOrders.selector, true
        );
        rolesAuthority.setRoleCapability(PAUSER_ROLE, address(transitStation), TransitStation.pause.selector, true);
        rolesAuthority.setUserRole(EXECUTOR, TRANSIT_EXECUTOR_ROLE, true);
        rolesAuthority.setUserRole(PAUSER_EOA, PAUSER_ROLE, true);
        rolesAuthority.setPublicCapability(address(transitStation), TransitStation.submitOrder.selector, true);
        rolesAuthority.setPublicCapability(address(transitStation), TransitStation.submitOrderWithPermit.selector, true);

        // ==================== CROSS-CHAIN (LayerZero) ====================
        // CREATE3 gives the station the same address on every chain, so its peer is itself.
        uint32 peerEid = _peerEid();
        if (peerEid != 0) {
            transitStation.setPeer(peerEid, bytes32(uint256(uint160(address(transitStation)))));
            transitStation.setMessageGasLimit(peerEid, MESSAGE_GAS_LIMIT);
        } else {
            console.log("WARNING: no peer EID set; configure the LZ peer + gas limit post-deploy");
        }
        transitStation.setDelegate(getMultisig());

        // ==================== ROUTE APPROVALS ====================
        _approveRoutes();

        // ==================== OWNERSHIP ====================
        // When reusing an existing combo, drop the vault/manager/authority transfers (already multisig-owned).
        rolesAuthority.transferOwnership(getMultisig());
        boringVault.transferOwnership(getMultisig());
        manager.transferOwnership(getMultisig());
        transitStation.transferOwnership(getMultisig());

        console.log("RolesAuthority:", address(rolesAuthority));
        console.log("BoringVault:", address(boringVault));
        console.log("Manager:", address(manager));
        console.log("TransitStation:", address(transitStation));
    }

    /// TODO: Fill with this chain's production routes: {destEID, offerAsset, wantAsset}. `destEID` is the station's
    ///      own EID (`transitStation.thisChainEID()`) for a same-chain swap, or the peer EID for cross-chain. Resize
    ///      the array and set each entry. Left empty by default; if so, configure post-deploy via setRouteApprovals.
    function _approveRoutes() internal {
        TransitStation.Route[] memory routes = new TransitStation.Route[](0);
        bool[] memory approved = new bool[](0);
        // Example (resize the arrays above to match):
        // routes[0] = TransitStation.Route({ destEID: _peerEid(), offerAsset: 0x..., wantAsset: 0x... });
        // approved[0] = true;
        if (routes.length == 0) {
            console.log("WARNING: no routes approved in-script; configure via setRouteApprovals");
            return;
        }
        transitStation.setRouteApprovals(routes, approved);
    }

    function _peerEid() internal view returns (uint32) {
        // TODO: return the production peer EID for each chain this station bridges with. 0 skips LZ peer wiring
        // (configure it post-deploy once the peer station exists).
        if (block.chainid == 1) return 0; // Ethereum mainnet — set the peer EID here
        return 0;
    }

    function _lzEndpoint() internal view returns (address) {
        if (block.chainid == 1) return 0x1a44076050125825900e736c501f859c50fE728c; // Ethereum mainnet (LZ V2)
        revert("DeployTransitStation: no LZ endpoint for this chain");
    }

}
