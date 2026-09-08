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

    // Backend quote signer
    address constant QUOTE_SIGNER = address(0xE4a40e9E04eb7F33368D998FD423073b778Ce420);
    // Executor granted TRANSIT_EXECUTOR_ROLE (fulfills orders). Assigned in run(); when reusing an existing combo
    // set it to EXISTING_BORING_VAULT instead.
    address EXECUTOR;

    // Reuse an existing vault/manager combo by setting these and commenting out the deploy block in run().
    // address constant EXISTING_ROLES_AUTHORITY = address(0x3B4decc43d2173280198B46532Ef570062FCc8f5);
    // address constant EXISTING_BORING_VAULT = address(0x91FE06C6E9F97E7DE4580A280E03046155f8e1e3);
    // address constant EXISTING_MANAGER = address(0x666156ab52bb9984F5c3985726f048Dd4A73887a);

    // BoringVault metadata (only used when deploying fresh).
    string constant NAME = "Transit Vault";
    string constant SYMBOL = "TRANSIT";
    uint8 constant DECIMALS = 6;

    uint64 constant MESSAGE_GAS_LIMIT = 400_000;
    address constant BALANCER_VAULT = 0x0000000000000000000000000000000000000000;

    // ---- Route assets (offerAsset/wantAsset for setRouteApprovals) ----
    address constant USDC_ETH = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant PYUSD_ETH = 0x6c3ea9036406852006290770BEdFcAbA0e23A0e8;
    address constant USDT_ETH = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant USDG_ETH = 0xe343167631d89B6Ffc58B88d6b7fB0228795491D;
    address constant USDG_RH = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant USDC_ARB = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant USDT_ARB = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    address constant USDG_ARB = 0x004B506865409877C9fA29bfb1ebA929984B9bbC;

    // ---- LayerZero endpoint ids, one per chain in the mesh ----
    uint32 constant EID_ETH = 30_101;
    uint32 constant EID_RH = 30_416;
    uint32 constant EID_ARB = 30_110;

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

    // Intentionally moved outside of the `run` function in order to keep consistent with past Transit
    bytes32 SALT_ROLES_AUTHORITY = makeSalt(broadcaster, false, "Transit: RolesAuthority");
    bytes32 SALT_BORING_VAULT = makeSalt(broadcaster, false, "Transit: BoringVault");
    bytes32 SALT_MANAGER = makeSalt(broadcaster, false, "Transit: ManagerWithMerkleVerification");
    bytes32 SALT_STATION = makeSalt(broadcaster, false, "Transit: TransitStation");

    function run() public broadcast {
        // ============================== SALTS ==============================
        // rolesAuthority = RolesAuthority(EXISTING_ROLES_AUTHORITY);
        // boringVault = BoringVault(payable(EXISTING_BORING_VAULT));
        // manager = ManagerWithMerkleVerification(EXISTING_MANAGER);

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
        EXECUTOR = address(boringVault);

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
                            boringVault, // protocolFeeRecipient
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
        // CREATE3 gives the station the same address on every chain, so every peer is itself.
        bytes32 peer = bytes32(uint256(uint160(address(transitStation))));
        uint32[] memory peerEids = _peerEids();
        if (peerEids.length == 0) {
            console.log("WARNING: no peer EIDs set; configure the LZ peers + gas limits + DVNs post-deploy");
        }
        for (uint256 i; i < peerEids.length; ++i) {
            transitStation.setPeer(peerEids[i], peer);
            transitStation.setMessageGasLimit(peerEids[i], MESSAGE_GAS_LIMIT);
            // Set DVNs + confirmations while the broadcaster is still the LZ delegate (before the setDelegate below).
            _configureLZ(peerEids[i]);
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

    /// @dev Only the legs this broadcast owns. The ETH/RH blocks are the historical pairwise config; their new legs to
    ///      Arbitrum are multisig transactions, not part of any script run.
    function _approveRoutes() internal {
        TransitStation.Route[] memory routes = new TransitStation.Route[](0);

        if (block.chainid == 1) {
            // Ethereum source: offer an ETH stablecoin, receive USDG on RH.
            routes = new TransitStation.Route[](4);
            routes[0] = TransitStation.Route({ destEID: EID_RH, offerAsset: USDC_ETH, wantAsset: USDG_RH });
            routes[1] = TransitStation.Route({ destEID: EID_RH, offerAsset: PYUSD_ETH, wantAsset: USDG_RH });
            routes[2] = TransitStation.Route({ destEID: EID_RH, offerAsset: USDT_ETH, wantAsset: USDG_RH });
            routes[3] = TransitStation.Route({ destEID: EID_RH, offerAsset: USDG_ETH, wantAsset: USDG_RH });
        } else if (block.chainid == 4663) {
            // Robinhood source: offer USDG on RH, receive an ETH stablecoin. No PYUSD return route.
            routes = new TransitStation.Route[](3);
            routes[0] = TransitStation.Route({ destEID: EID_ETH, offerAsset: USDG_RH, wantAsset: USDC_ETH });
            routes[1] = TransitStation.Route({ destEID: EID_ETH, offerAsset: USDG_RH, wantAsset: USDT_ETH });
            routes[2] = TransitStation.Route({ destEID: EID_ETH, offerAsset: USDG_RH, wantAsset: USDG_ETH });
        } else if (block.chainid == 42_161) {
            // Arbitrum source: USDG out to either peer, plus the local USDC<>USDG pair. A route whose destEID is this
            // chain's own EID is a same-chain swap — the station queues it locally instead of bridging.
            routes = new TransitStation.Route[](7);
            routes[0] = TransitStation.Route({ destEID: EID_RH, offerAsset: USDC_ARB, wantAsset: USDG_RH });
            routes[1] = TransitStation.Route({ destEID: EID_ETH, offerAsset: USDG_ARB, wantAsset: USDG_ETH });
            routes[2] = TransitStation.Route({ destEID: EID_ETH, offerAsset: USDG_ARB, wantAsset: USDC_ETH });
            routes[3] = TransitStation.Route({ destEID: EID_RH, offerAsset: USDG_ARB, wantAsset: USDG_RH });
            routes[4] = TransitStation.Route({ destEID: EID_ETH, offerAsset: USDC_ARB, wantAsset: USDG_ETH });
            routes[5] = TransitStation.Route({ destEID: EID_ARB, offerAsset: USDC_ARB, wantAsset: USDG_ARB });
            routes[6] = TransitStation.Route({ destEID: EID_ARB, offerAsset: USDG_ARB, wantAsset: USDC_ARB });
        }

        if (routes.length == 0) {
            console.log("WARNING: no routes approved in-script; configure via setRouteApprovals");
            return;
        }

        bool[] memory approved = new bool[](routes.length);
        for (uint256 i; i < routes.length; ++i) {
            approved[i] = true;
        }
        transitStation.setRouteApprovals(routes, approved);
    }

    function _peerEids() internal view returns (uint32[] memory peerEids) {
        if (block.chainid == 1) {
            peerEids = new uint32[](1);
            peerEids[0] = EID_RH;
        } else if (block.chainid == 4663) {
            peerEids = new uint32[](1);
            peerEids[0] = EID_ETH;
        } else if (block.chainid == 42_161) {
            peerEids = new uint32[](2);
            peerEids[0] = EID_ETH;
            peerEids[1] = EID_RH;
        }
    }

    function _lzEndpoint() internal view returns (address) {
        if (block.chainid == 1) return 0x1a44076050125825900e736c501f859c50fE728c; // Ethereum mainnet (LZ V2)
        if (block.chainid == 4663) return 0x6F475642a6e85809B1c36Fa62763669b1b48DD5B; // RH mainnet
        if (block.chainid == 42_161) return 0x1a44076050125825900e736c501f859c50fE728c; // Arbitrum mainnet
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
        } else if (block.chainid == 4663) {
            dvns[0] = 0xd01ae6905d48315f7bE10C7330aeCF8360Ef5b12; // LZ labs
            dvns[1] = 0x0Ffe02DF012299A370D5dd69298A5826EAcaFdF8; // Nethermind
            dvns[2] = 0x1258A278519c7f4bd997a9c3BFd4Aa802a028D89; // Horizen
        } else if (block.chainid == 42_161) {
            dvns[0] = 0x2f55C492897526677C5B68fb199ea31E2c126416; // LZ labs
            dvns[1] = 0xa7b5189bcA84Cd304D8553977c7C614329750d99; // Nethermind
            dvns[2] = 0x19670Df5E16bEa2ba9b9e68b48C054C5bAEa06B8; // Horizen
        }
    }

    function _dvnConfirmations() internal view returns (uint64) {
        if (block.chainid == 1) return 15; // Ethereum mainnet
        if (block.chainid == 4663) return 20; // RH mainnet
        if (block.chainid == 42_161) return 20; // Arbitrum mainnet
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
