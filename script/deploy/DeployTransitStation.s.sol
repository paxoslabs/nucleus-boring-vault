// SPDX-License-Identifier: Apache-2.0
pragma solidity =0.8.21;

import { console } from "forge-std/console.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { ManagerWithMerkleVerification } from "src/base/Roles/ManagerWithMerkleVerification.sol";
import { RolesAuthority, Authority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { TransitStation } from "src/transit/TransitStation.sol";
import { BaseScript } from "script/Base.s.sol";
import "src/helper/Constants.sol";

contract DeployTransitStation is BaseScript {

    // ---- fill these per testnet deployment ----
    address constant QUOTE_SIGNER = 0x9d08cC364da8Be1d5C54d05A0F8dc3b2046C5FdE; // staging
    address constant EXECUTOR = 0xFb7dad16c87910065859824fD53fef0f2705E91b;
    uint64 constant MESSAGE_GAS_LIMIT = 100_000;

    string constant NAME = "PXL Test Transit Vault";
    string constant SYMBOL = "TRANSIT";
    uint8 constant DECIMALS = 6;
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    uint8 constant MOCK_DECIMALS = 6;
    uint256 constant MOCK_MINT = 10_000_000 * 10 ** MOCK_DECIMALS;

    bytes32 SALT_ROLES_AUTHORITY = makeSalt(broadcaster, false, "Transit: RolesAuthority3");
    bytes32 SALT_BORING_VAULT = makeSalt(broadcaster, false, "Transit: BoringVault3");
    bytes32 SALT_MANAGER = makeSalt(broadcaster, false, "Transit: ManagerWithMerkleVerification3");
    bytes32 SALT_STATION = makeSalt(broadcaster, false, "Transit: TransitStation3");
    bytes32 SALT_MOCK_TOKEN = makeSalt(broadcaster, false, "Transit: MockToken3");

    RolesAuthority public rolesAuthority;
    BoringVault public boringVault;
    ManagerWithMerkleVerification public manager;
    TransitStation public transitStation;
    BoringVault public mockToken;

    function run() public broadcast {
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

        transitStation = TransitStation(
            payable(CREATEX.deployCreate3(
                    SALT_STATION,
                    abi.encodePacked(
                        type(TransitStation).creationCode,
                        abi.encode(
                            broadcaster,
                            Authority(address(rolesAuthority)),
                            _lzEndpoint(),
                            getMultisig(),
                            QUOTE_SIGNER,
                            address(boringVault),
                            address(boringVault)
                        )
                    )
                ))
        );

        rolesAuthority.setRoleCapability(
            TRANSIT_EXECUTOR_ROLE, address(transitStation), TransitStation.executePendingOrders.selector, true
        );
        rolesAuthority.setRoleCapability(PAUSER_ROLE, address(transitStation), TransitStation.pause.selector, true);
        rolesAuthority.setUserRole(EXECUTOR, TRANSIT_EXECUTOR_ROLE, true);
        rolesAuthority.setUserRole(PAUSER_EOA, PAUSER_ROLE, true);

        rolesAuthority.setPublicCapability(address(transitStation), TransitStation.submitOrder.selector, true);
        rolesAuthority.setPublicCapability(address(transitStation), TransitStation.submitOrderWithPermit.selector, true);

        transitStation.setPeer(_peerEid(), bytes32(uint256(uint160(address(transitStation)))));
        transitStation.setMessageGasLimit(_peerEid(), MESSAGE_GAS_LIMIT);
        transitStation.setDelegate(getMultisig());

        // Mock token: a BoringVault used as a test ERC20. Deterministic address across chains; named per chain
        // (mockUSDC on Sepolia, mockUSDG on Robinhood). Mints 10M to the owner via enter (no asset deposit).
        (string memory mockName, string memory mockSymbol) = _mockTokenMeta();
        mockToken = BoringVault(
            payable(CREATEX.deployCreate3(
                    SALT_MOCK_TOKEN,
                    abi.encodePacked(
                        type(BoringVault).creationCode, abi.encode(broadcaster, mockName, mockSymbol, MOCK_DECIMALS)
                    )
                ))
        );
        mockToken.enter(broadcaster, ERC20(address(0)), 0, getMultisig(), MOCK_MINT);
        mockToken.transferOwnership(getMultisig());

        rolesAuthority.transferOwnership(getMultisig());
        boringVault.transferOwnership(getMultisig());
        manager.transferOwnership(getMultisig());
        transitStation.transferOwnership(getMultisig());

        console.log("RolesAuthority:", address(rolesAuthority));
        console.log("BoringVault:", address(boringVault));
        console.log("Manager:", address(manager));
        console.log("TransitStation:", address(transitStation));
        console.log("MockToken:", address(mockToken));
    }

    function _peerEid() internal view returns (uint32) {
        if (block.chainid == 11_155_111) return 40_451; // peer = Robinhood
        if (block.chainid == 46_630) return 40_161; // peer = Sepolia
        revert("DeployTransitStation: no peer EID for this chain");
    }

    function _lzEndpoint() internal view returns (address) {
        if (block.chainid == 11_155_111) return 0x6EDCE65403992e310A62460808c4b910D972f10f; // Sepolia
        if (block.chainid == 46_630) return 0x3aCAAf60502791D199a5a5F0B173D78229eBFe32; // Robinhood
        revert("DeployTransitStation: no LZ endpoint for this chain");
    }

    function _mockTokenMeta() internal view returns (string memory name, string memory symbol) {
        if (block.chainid == 11_155_111) return ("mockUSDC -- Owner may mint/burn with enter/exit", "mockUSDC");
        if (block.chainid == 46_630) return ("mockUSDG -- Owner may mint/burn with enter/exit", "mockUSDG");
        revert("DeployTransitStation: no mock token name for this chain");
    }

}
