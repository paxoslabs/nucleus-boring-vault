// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { RolesAuthority, Authority } from "@solmate/auth/authorities/RolesAuthority.sol";

import { TransitStation } from "src/transit/TransitStation.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { ManagerWithMerkleVerification } from "src/base/Roles/ManagerWithMerkleVerification.sol";
import { GenericDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/GenericDecoderAndSanitizer.sol";
import { MainnetAddresses } from "test/resources/MainnetAddresses.sol";

/// @notice Forked-mainnet integration test: an EOA submits a same-chain TransitStation order that pays out to a
///         BoringVault receiver, then the vault settles the order through its merkle-gated manager.
/// @dev Uses real mainnet USDC (offer, 6 dec) and DAI (want, 18 dec) plus the real LayerZero v2 endpoint (only used for
///      construction; a same-chain order sends no LZ message). `submitOrder` is a public capability; settlement is
///      performed by the vault via `ManagerWithMerkleVerification`.
contract TransitStationBoringVaultForkTest is Test, MainnetAddresses {

    // LayerZero EndpointV2 on Ethereum mainnet (eid 30101). Not present in MainnetAddresses.
    address internal constant LZ_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;

    uint8 internal constant MANAGER_ROLE = 1;
    uint8 internal constant STRATEGIST_ROLE = 2;
    uint8 internal constant MANGER_INTERNAL_ROLE = 3;
    uint8 internal constant ADMIN_ROLE = 4;

    uint256 internal constant OFFER_AMOUNT = 1000e6; // USDC (6 dec)
    uint256 internal constant PROTOCOL_FEE = 5e6; // 0.5% == MAX_PROTOCOL_FEE_BPS
    uint256 internal constant INTEGRATOR_FEE = 10e6; // 1%
    uint256 internal constant NET = OFFER_AMOUNT - PROTOCOL_FEE - INTEGRATOR_FEE; // 985e6 USDC
    uint256 internal constant NET_18 = NET * 1e12; // 985e18 DAI (want is 18 dec)

    RolesAuthority internal rolesAuthority;
    BoringVault internal boringVault;
    ManagerWithMerkleVerification internal manager;
    GenericDecoderAndSanitizer internal decoder;
    TransitStation internal station;

    address internal quoteSigner;
    uint256 internal quoteSignerPk;
    address internal protocolFeeRecipient = makeAddr("protocolFeeRecipient");
    address internal offerReceiver = makeAddr("offerReceiver");
    address internal wantAssetSource = makeAddr("wantAssetSource");
    address internal integratorFeeReceiver = makeAddr("integratorFeeReceiver");
    address internal submitter = makeAddr("submitter");

    function setUp() external {
        vm.selectFork(vm.createFork(vm.envString("MAINNET_RPC_URL"), 19_826_676));

        (quoteSigner, quoteSignerPk) = makeAddrAndKey("quoteSigner");

        rolesAuthority = new RolesAuthority(address(this), Authority(address(0)));
        boringVault = new BoringVault(address(this), "Boring Vault", "BV", 18);
        manager = new ManagerWithMerkleVerification(address(this), address(boringVault), address(0));
        decoder = new GenericDecoderAndSanitizer(address(boringVault), uniswapV3NonFungiblePositionManager);
        station = new TransitStation(
            address(this),
            rolesAuthority,
            LZ_ENDPOINT,
            protocolFeeRecipient,
            quoteSigner,
            offerReceiver,
            wantAssetSource
        );

        boringVault.setAuthority(rolesAuthority);
        manager.setAuthority(rolesAuthority);

        // Vault/manager wiring (mirrors test/ManagerWithMerkleVerification.t.sol).
        rolesAuthority.setRoleCapability(
            MANAGER_ROLE, address(boringVault), bytes4(keccak256("manage(address,bytes,uint256)")), true
        );
        rolesAuthority.setRoleCapability(
            STRATEGIST_ROLE,
            address(manager),
            ManagerWithMerkleVerification.manageVaultWithMerkleVerification.selector,
            true
        );
        rolesAuthority.setRoleCapability(
            MANGER_INTERNAL_ROLE,
            address(manager),
            ManagerWithMerkleVerification.manageVaultWithMerkleVerification.selector,
            true
        );
        rolesAuthority.setRoleCapability(
            ADMIN_ROLE, address(manager), ManagerWithMerkleVerification.setManageRoot.selector, true
        );
        rolesAuthority.setUserRole(address(this), STRATEGIST_ROLE, true);
        rolesAuthority.setUserRole(address(this), ADMIN_ROLE, true);
        rolesAuthority.setUserRole(address(manager), MANGER_INTERNAL_ROLE, true);
        rolesAuthority.setUserRole(address(manager), MANAGER_ROLE, true);

        // `submitOrder` is a public capability on the station; any EOA can submit a signed quote.
        // Settlement (`executePendingOrders`) is performed by the vault through its merkle-gated manager:
        // manager -> vault.manage(station, data, 0) -> station.executePendingOrders(...).
        // The vault itself therefore needs MANAGER_ROLE on the station for executePendingOrders.
        rolesAuthority.setPublicCapability(address(station), TransitStation.submitOrder.selector, true);
        rolesAuthority.setRoleCapability(
            MANAGER_ROLE, address(station), TransitStation.executePendingOrders.selector, true
        );
        rolesAuthority.setUserRole(address(boringVault), MANAGER_ROLE, true);

        // Approve the same-chain USDC -> DAI route.
        TransitStation.Route[] memory routes = new TransitStation.Route[](1);
        routes[0] = TransitStation.Route({
            destEID: station.thisChainEID(), offerAsset: address(USDC), wantAsset: address(DAI)
        });
        bool[] memory approved = new bool[](1);
        approved[0] = true;
        station.setRouteApprovals(routes, approved);
    }

    // ========================================= HELPERS =========================================

    function _canonicalQuote() internal view returns (TransitStation.Quote memory q) {
        q = TransitStation.Quote({
            route: TransitStation.Route({
                destEID: station.thisChainEID(), offerAsset: address(USDC), wantAsset: address(DAI)
            }),
            offerAmount: OFFER_AMOUNT,
            receiver: address(boringVault),
            protocolFee: PROTOCOL_FEE,
            integratorFee: INTEGRATOR_FEE,
            integratorFeeReceiver: integratorFeeReceiver,
            distributorCode: bytes32(0),
            deadline: block.timestamp + 1 hours,
            salt: bytes32(0)
        });
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("TransitStation")),
                keccak256(bytes("1")),
                block.chainid,
                address(station)
            )
        );
    }

    function _signQuote(TransitStation.Quote memory quote) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", _domainSeparator(), station.hashQuote(quote)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(quoteSignerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Reconstruct a manage leaf exactly as `ManagerWithMerkleVerification._verifyManageProof` does: staticcall
    /// the decoder with the real calldata to get the packed argument addresses, then hash the leaf tuple.
    function _leaf(
        address target,
        bool valueNonZero,
        bytes4 selector,
        bytes memory data
    )
        internal
        view
        returns (bytes32)
    {
        (bool ok, bytes memory ret) = address(decoder).staticcall(data);
        require(ok, "decoder staticcall failed");
        bytes memory packed = abi.decode(ret, (bytes));
        return keccak256(abi.encodePacked(address(decoder), target, valueNonZero, selector, packed));
    }

    /// @dev An EOA submits the canonical order to the station. The quote's `receiver` is the BoringVault,
    ///      and the EOA pays the offer asset. Returns the queued order's UUID.
    function _submitCanonicalOrder() internal returns (bytes32 uuid) {
        TransitStation.Quote memory quote = _canonicalQuote();
        bytes memory signature = _signQuote(quote);

        // `submitOrder` is a public capability on `TransitStation`; the EOA only needs USDC balance+approval.
        vm.prank(submitter);
        USDC.approve(address(station), OFFER_AMOUNT);
        vm.prank(submitter);
        station.submitOrder(quote, signature);

        TransitStation.Order[] memory orders = station.getPendingOrders();
        uuid = orders[0].terms.uuid;
    }

    /// @dev Build the calldata and merkle proof for the vault's manager to call `executePendingOrders`.
    function _buildExecuteLeaf(TransitStation.FillBatch[] memory batches)
        internal
        view
        returns (bytes32 leaf, bytes memory data)
    {
        data = abi.encodeWithSelector(TransitStation.executePendingOrders.selector, batches);
        leaf = _leaf(address(station), false, TransitStation.executePendingOrders.selector, data);
    }

    // ========================================= TESTS =========================================

    function testSubmitterPaysOfferAndVaultReceivesWant() external {
        deal(address(USDC), submitter, OFFER_AMOUNT * 10);

        uint256 submitterUsdcBefore = USDC.balanceOf(submitter);
        uint256 protoBefore = USDC.balanceOf(protocolFeeRecipient);
        uint256 integratorBefore = USDC.balanceOf(integratorFeeReceiver);
        uint256 offerReceiverBefore = USDC.balanceOf(offerReceiver);
        uint256 vaultDaiBefore = DAI.balanceOf(address(boringVault));

        bytes32 uuid = _submitCanonicalOrder();

        // Offer (USDC) paid by the submitter and partitioned between fees and the offer receiver.
        assertEq(USDC.balanceOf(submitter), submitterUsdcBefore - OFFER_AMOUNT, "submitter paid offer");
        assertEq(USDC.balanceOf(protocolFeeRecipient) - protoBefore, PROTOCOL_FEE, "protocol fee");
        assertEq(USDC.balanceOf(integratorFeeReceiver) - integratorBefore, INTEGRATOR_FEE, "integrator fee");
        assertEq(USDC.balanceOf(offerReceiver) - offerReceiverBefore, NET, "net to offer receiver");

        // Order queued locally with the vault as receiver; amountDue normalized into 18-dec DAI units.
        assertEq(station.pendingOrderCount(), 1, "one pending order");
        TransitStation.Order[] memory orders = station.getPendingOrders();
        assertEq(orders[0].terms.uuid, uuid, "uuid matches");
        assertEq(orders[0].terms.receiver, address(boringVault), "receiver is the vault");
        assertEq(orders[0].terms.wantAsset, address(DAI), "want asset is DAI");
        assertEq(orders[0].amountDue, NET_18, "amountDue in DAI units");

        // Executor fills the order: want (DAI) pulled from wantAssetSource to the vault.
        deal(address(DAI), wantAssetSource, NET_18);
        vm.prank(wantAssetSource);
        DAI.approve(address(station), NET_18);

        TransitStation.FillBatch[] memory batches = new TransitStation.FillBatch[](1);
        bytes32[] memory uuids = new bytes32[](1);
        uuids[0] = uuid;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = NET_18;
        batches[0] = TransitStation.FillBatch({ wantAsset: address(DAI), uuids: uuids, amounts: amounts });

        (bytes32 leaf, bytes memory data) = _buildExecuteLeaf(batches);
        manager.setManageRoot(address(this), leaf);

        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0); // single-leaf tree
        address[] memory decoders = new address[](1);
        decoders[0] = address(decoder);
        address[] memory targets = new address[](1);
        targets[0] = address(station);
        bytes[] memory targetData = new bytes[](1);
        targetData[0] = data;
        uint256[] memory values = new uint256[](1); // zero value

        manager.manageVaultWithMerkleVerification(proofs, decoders, targets, targetData, values);

        assertEq(DAI.balanceOf(address(boringVault)) - vaultDaiBefore, NET_18, "vault received want");
        assertEq(station.pendingOrderCount(), 0, "order settled");
    }

    /// @notice `executePendingOrders` must be authorized by the vault's merkle-gated manager:
    ///         an unsigned call (no proof) from an arbitrary caller reverts.
    function testExecutePendingOrdersRevertsWithoutMerkleProof() external {
        deal(address(USDC), submitter, OFFER_AMOUNT * 10);

        bytes32 uuid = _submitCanonicalOrder();

        TransitStation.FillBatch[] memory batches = new TransitStation.FillBatch[](1);
        bytes32[] memory uuids = new bytes32[](1);
        uuids[0] = uuid;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = NET_18;
        batches[0] = TransitStation.FillBatch({ wantAsset: address(DAI), uuids: uuids, amounts: amounts });

        address unauthorized = makeAddr("unauthorized");
        vm.prank(unauthorized);
        vm.expectRevert("UNAUTHORIZED");
        station.executePendingOrders(batches);
    }

}
