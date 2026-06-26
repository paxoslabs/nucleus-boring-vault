// SPDX-License-Identifier: Apache-2.0
pragma solidity =0.8.21;

import { console } from "forge-std/console.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { ManagerWithMerkleVerification } from "src/base/Roles/ManagerWithMerkleVerification.sol";
import { RolesAuthority, Authority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { TransitStation } from "src/transit/TransitStation.sol";
import { BaseScript } from "script/Base.s.sol";
import { ILayerZeroEndpointV2 } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { SetConfigParam } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";
import "src/helper/Constants.sol";

/// @notice Production deployment for a Transit Station, with its BoringVault + Manager combo.
/// @dev IMPORTANT — if you reuse a `RolesAuthority` that has ALREADY been transferred to the multisig, the
///      broadcaster no longer owns it, so the station role wiring (`setRoleCapability` / `setUserRole` /
///      `setPublicCapability`) and `setRouteApprovals` below will revert. In that case run those steps as a multisig
///      transaction instead of from this EOA broadcast.
contract DeployTransitStation is BaseScript {

    // ============================== FILL PER DEPLOYMENT ==============================

    // Backend quote signer (zero-checked in the constructor, so a fresh deploy reverts until set).
    address constant QUOTE_SIGNER = address(0xE4a40e9E04eb7F33368D998FD423073b778Ce420);
    // Executor granted TRANSIT_EXECUTOR_ROLE (fulfills orders).
    address constant EXECUTOR = EXISTING_BORING_VAULT; // this should be the vault

    // Reuse an existing vault/manager combo by setting these and commenting out the deploy block in run().
    address constant EXISTING_ROLES_AUTHORITY = address(0x94dF457c3628233E2FD1B62FcfaA2A5a529644a4);
    address constant EXISTING_BORING_VAULT = address(0x91FE06C6E9F97E7DE4580A280E03046155f8e1e3);
    address constant EXISTING_MANAGER = address(0x289Ea9326f2f8b99E18F7980de3b4AfDc7f9Bbb0);

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

    // LayerZero config type id for the ULN (DVNs + confirmations) config.
    uint32 constant CONFIG_TYPE_ULN = 2;

    struct UlnConfig {
        uint64 confirmations;
        uint8 requiredDVNCount;
        uint8 optionalDVNCount;
        uint8 optionalDVNThreshold;
        address[] requiredDVNs;
        address[] optionalDVNs;
    }

    RolesAuthority public rolesAuthority;
    BoringVault public boringVault;
    ManagerWithMerkleVerification public manager;
    TransitStation public transitStation;

    function run() public broadcast {
        rolesAuthority = RolesAuthority(EXISTING_ROLES_AUTHORITY);
        boringVault = BoringVault(payable(EXISTING_BORING_VAULT));
        manager = ManagerWithMerkleVerification(EXISTING_MANAGER);
        // Commented out because we are connecting to previously deployed vaults
        // ==================== DEPLOY VAULT / MANAGER COMBO ====================
        // rolesAuthority = RolesAuthority(
        //     CREATEX.deployCreate3(
        //         SALT_ROLES_AUTHORITY,
        //         abi.encodePacked(type(RolesAuthority).creationCode, abi.encode(broadcaster, Authority(address(0))))
        //     )
        // );
        // boringVault = BoringVault(
        //     payable(CREATEX.deployCreate3(
        //             SALT_BORING_VAULT,
        //             abi.encodePacked(type(BoringVault).creationCode, abi.encode(broadcaster, NAME, SYMBOL, DECIMALS))
        //         ))
        // );
        // manager = ManagerWithMerkleVerification(
        //     CREATEX.deployCreate3(
        //         SALT_MANAGER,
        //         abi.encodePacked(
        //             type(ManagerWithMerkleVerification).creationCode,
        //             abi.encode(broadcaster, address(boringVault), BALANCER_VAULT)
        //         )
        //     )
        // );
        // boringVault.setAuthority(rolesAuthority);
        // manager.setAuthority(rolesAuthority);
        // rolesAuthority.setRoleCapability(
        //     MANAGER_ROLE, address(boringVault), bytes4(keccak256("manage(address,bytes,uint256)")), true
        // );
        // rolesAuthority.setRoleCapability(
        //     MANAGER_ROLE, address(boringVault), bytes4(keccak256("manage(address[],bytes[],uint256[])")), true
        // );
        // rolesAuthority.setRoleCapability(
        //     STRATEGIST_ROLE,
        //     address(manager),
        //     ManagerWithMerkleVerification.manageVaultWithMerkleVerification.selector,
        //     true
        // );
        // rolesAuthority.setUserRole(address(manager), MANAGER_ROLE, true);

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
        // rolesAuthority.setRoleCapability(
        //     TRANSIT_EXECUTOR_ROLE, address(transitStation), TransitStation.executePendingOrders.selector, true
        // );
        // rolesAuthority.setRoleCapability(PAUSER_ROLE, address(transitStation), TransitStation.pause.selector, true);
        // rolesAuthority.setUserRole(EXECUTOR, TRANSIT_EXECUTOR_ROLE, true);
        // rolesAuthority.setUserRole(PAUSER_EOA, PAUSER_ROLE, true);
        // rolesAuthority.setPublicCapability(address(transitStation), TransitStation.submitOrder.selector, true);
        // rolesAuthority.setPublicCapability(address(transitStation), TransitStation.submitOrderWithPermit.selector,
        // true);

        // ==================== CROSS-CHAIN (LayerZero) ====================
        // CREATE3 gives the station the same address on every chain, so its peer is itself.
        uint32 peerEid = _peerEid();
        if (peerEid != 0) {
            transitStation.setPeer(peerEid, bytes32(uint256(uint160(address(transitStation)))));
            transitStation.setMessageGasLimit(peerEid, MESSAGE_GAS_LIMIT);
            // Set DVNs + confirmations while the broadcaster is still the LZ delegate (before the setDelegate below).
            _configureLZ(peerEid);
        } else {
            console.log("WARNING: no peer EID set; configure the LZ peer + gas limit + DVNs post-deploy");
        }
        transitStation.setDelegate(getMultisig());

        // ==================== ROUTE APPROVALS ====================
        _approveRoutes();

        // ==================== OWNERSHIP ====================
        // When reusing an existing combo, drop the vault/manager/authority transfers (already multisig-owned).
        // rolesAuthority.transferOwnership(getMultisig());
        // boringVault.transferOwnership(getMultisig());
        // manager.transferOwnership(getMultisig());
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
        if (block.chainid == 1) return 30_416; // Ethereum mainnet — peer is RH
        if (block.chainid == 4663) return 30_101; // RH mainnet — peer is Ethereum
        return 0;
    }

    function _lzEndpoint() internal view returns (address) {
        if (block.chainid == 1) return 0x1a44076050125825900e736c501f859c50fE728c; // Ethereum mainnet (LZ V2)
        if (block.chainid == 4663) return 0xAaB5A48CFC03Efa9cC34A2C1aAcCCB84b4b770e4; // RH mainnet
        revert("DeployTransitStation: no LZ endpoint for this chain");
    }

    /// @notice Pushes the station's ULN security config (required DVNs + block confirmations) onto the
    ///         default send and receive libraries for `peerEid`.
    /// @dev Must run while the broadcaster is still the LZ delegate (before `setDelegate(getMultisig())`). The
    ///      OAppAuth constructor sets the delegate to the owner — the broadcaster — at deploy, so this is the
    /// window.
    function _configureLZ(uint32 peerEid) internal {
        ILayerZeroEndpointV2 endpoint = ILayerZeroEndpointV2(_lzEndpoint());

        address sendLib = endpoint.defaultSendLibrary(peerEid);
        address receiveLib = endpoint.defaultReceiveLibrary(peerEid);
        require(sendLib != address(0), "DeployTransitStation: no default sendLib for peerEid");
        require(receiveLib != address(0), "DeployTransitStation: no default receiveLib for peerEid");

        address[] memory requiredDVNs = sortAddresses(_requiredDVNs());
        uint64 confirmations = _dvnConfirmations();
        require(confirmations != 0, "DeployTransitStation: confirmations is 0");
        require(requiredDVNs.length != 0, "DeployTransitStation: no required DVNs");

        // Optional DVNs are intentionally unused: count and threshold 0, empty array.
        bytes memory ulnConfigBytes = abi.encode(
            UlnConfig({
                confirmations: confirmations,
                requiredDVNCount: uint8(requiredDVNs.length),
                optionalDVNCount: 0,
                optionalDVNThreshold: 0,
                requiredDVNs: requiredDVNs,
                optionalDVNs: new address[](0)
            })
        );

        SetConfigParam[] memory setConfigParams = new SetConfigParam[](1);
        setConfigParams[0] = SetConfigParam(peerEid, CONFIG_TYPE_ULN, ulnConfigBytes);

        endpoint.setConfig(address(transitStation), sendLib, setConfigParams);
        endpoint.setConfig(address(transitStation), receiveLib, setConfigParams);

        console.log("LZ ULN config set for peer EID:", peerEid);
    }

    function _requiredDVNs() internal view returns (address[] memory dvns) {
        dvns = new address[](3);
        if (block.chainid == 1) {
            dvns[0] = 0x589dEDbD617e0CBcB916A9223F4d1300c294236b; // LZ labs
            dvns[1] = 0xa59BA433ac34D2927232918Ef5B2eaAfcF130BA5; // Nethermind
            dvns[2] = 0x380275805876Ff19055EA900CDb2B46a94ecF20D; // Horizen
        }
        if (block.chainid == 4663) {
            dvns[0] = 0xd01ae6905d48315f7bE10C7330aeCF8360Ef5b12; // LZ labs
            dvns[1] = 0x0Ffe02DF012299A370D5dd69298A5826EAcaFdF8; // Nethermind
            dvns[2] = 0x1258A278519c7f4bd997a9c3BFd4Aa802a028D89; // Horizen
        }
    }

    function _dvnConfirmations() internal view returns (uint64) {
        if (block.chainid == 1) return 15; // Ethereum mainnet
        if (block.chainid == 4663) return 20; // RH mainnet
        return 0;
    }

    /// @dev LayerZero requires the DVN array sorted ascending with no duplicates.
    function sortAddresses(address[] memory addresses) internal pure returns (address[] memory) {
        uint256 length = addresses.length;
        if (length < 2) return addresses;
        for (uint256 i; i < length - 1; ++i) {
            for (uint256 j; j < length - i - 1; ++j) {
                if (addresses[j] > addresses[j + 1]) {
                    address temp = addresses[j];
                    addresses[j] = addresses[j + 1];
                    addresses[j + 1] = temp;
                }
            }
        }
        return addresses;
    }

}
