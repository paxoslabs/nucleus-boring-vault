// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { Test } from "@forge-std/Test.sol";
import { MockERC20 } from "@solmate/test/utils/mocks/MockERC20.sol";
import { RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";
import {
    MessagingParams,
    MessagingReceipt
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import { DeployTransitStation } from "script/deploy/DeployTransitStation.s.sol";
import { TransitStation } from "src/transit/TransitStation.sol";
import { BoringVault } from "src/base/BoringVault.sol";

contract MockCreateX {

    function deployCreate3(bytes32, bytes memory initCode) external returns (address addr) {
        assembly {
            addr := create(0, add(initCode, 0x20), mload(initCode))
        }
        require(addr != address(0), "deploy failed");
    }

}

contract MockLZEndpoint {

    uint32 internal immutable _eid;
    bool public sendCalled;

    constructor(uint32 eid_) {
        _eid = eid_;
    }

    function eid() external view returns (uint32) {
        return _eid;
    }

    function setDelegate(address) external { }

    function send(MessagingParams calldata, address) external payable returns (MessagingReceipt memory) {
        sendCalled = true;
    }

}

contract DeployTransitStationTest is Test {

    address constant LZ_ENDPOINT = 0x6EDCE65403992e310A62460808c4b910D972f10f;
    address constant EXECUTOR = 0xFb7dad16c87910065859824fD53fef0f2705E91b;
    address constant PAUSER_EOA = 0xe5CcB29Cb9C886da329098A184302E2D5Ff0cD9E;
    address constant MULTISIG = 0xdEADdE9539A00Bbd9A8494f45EB38aEe89d7C001; // Sepolia getMultisig() (test wallet)
    uint32 constant PEER_EID = 40_451; // Robinhood (peer when deploying on Sepolia)
    uint32 constant THIS_EID = 40_161; // Sepolia
    uint64 constant MESSAGE_GAS_LIMIT = 400_000;

    uint256 constant SIGNER_PK = 0xA11CE;
    uint256 constant AMOUNT = 1e18;
    address constant RECEIVER = address(0xDEaD);

    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 constant ROUTE_TYPEHASH = keccak256("Route(uint32 destEID,address offerAsset,address wantAsset)");
    bytes32 constant QUOTE_TYPEHASH = keccak256(
        "Quote(Route route,uint256 offerAmountNormalized18,address receiver,uint256 protocolFeeNormalized18,uint256 integratorFeeNormalized18,address integratorFeeReceiver,uint256 deadline,bytes32 salt)Route(uint32 destEID,address offerAsset,address wantAsset)"
    );

    DeployTransitStation deployer;
    TransitStation station;
    BoringVault vault;
    RolesAuthority authority;
    MockERC20 offer;
    MockERC20 want;
    uint256 saltCounter;

    function setUp() public {
        vm.chainId(11_155_111); // Sepolia, so getMultisig() resolves

        MockCreateX createX = new MockCreateX();
        vm.setEnv("CREATEX", vm.toString(address(createX)));

        MockLZEndpoint ep = new MockLZEndpoint(THIS_EID);
        vm.etch(LZ_ENDPOINT, address(ep).code);

        deployer = new DeployTransitStation();
        deployer.run();

        station = deployer.transitStation();
        vault = deployer.boringVault();
        authority = deployer.rolesAuthority();

        offer = new MockERC20("Offer", "OFR", 18);
        want = new MockERC20("Want", "WNT", 18);
    }

    function test_deployment() public view {
        assertGt(address(station).code.length, 0, "station not deployed");
        assertEq(station.thisChainEID(), THIS_EID, "eid");
        assertEq(address(station.authority()), address(authority), "authority");
        assertEq(station.offerReceiver(), address(vault), "offerReceiver");
        assertEq(station.wantAssetSource(), address(vault), "wantAssetSource");
        assertEq(station.owner(), MULTISIG, "owner -> multisig");
        assertEq(station.quoteSigner(), 0x9d08cC364da8Be1d5C54d05A0F8dc3b2046C5FdE, "quoteSigner constant");

        assertTrue(
            authority.canCall(EXECUTOR, address(station), TransitStation.executePendingOrders.selector), "executor role"
        );
        assertTrue(authority.canCall(PAUSER_EOA, address(station), TransitStation.pause.selector), "pauser role");

        assertEq(station.peers(PEER_EID), bytes32(uint256(uint160(address(station)))), "peer == self");
        assertEq(station.messageGasLimit(PEER_EID), MESSAGE_GAS_LIMIT, "gas limit");
    }

    function test_singleChainSubmitAndExecute() public {
        uint32 destEid = station.thisChainEID();
        _ownerSetup(destEid, address(offer), address(want));

        offer.mint(address(this), AMOUNT);
        offer.approve(address(station), AMOUNT);

        TransitStation.Quote memory q = _quote(destEid, address(offer), address(want), AMOUNT);
        bytes32 uuid = station.submitOrder(q, _sign(q));

        assertEq(station.pendingOrderCount(), 1, "queued");
        assertEq(offer.balanceOf(address(vault)), AMOUNT, "offer -> vault");

        // vault holds want liquidity and approves the station for exactly this fill (KDD 26)
        want.mint(address(vault), AMOUNT);
        vm.prank(MULTISIG);
        vault.manage(address(want), abi.encodeWithSignature("approve(address,uint256)", address(station), AMOUNT), 0);

        bytes32[] memory uuids = new bytes32[](1);
        uuids[0] = uuid;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = AMOUNT;

        vm.prank(EXECUTOR);
        station.executePendingOrders(uuids, amounts);

        assertEq(want.balanceOf(RECEIVER), AMOUNT, "want -> receiver");
        assertEq(station.pendingOrderCount(), 0, "cleared");
        assertEq(want.allowance(address(vault), address(station)), 0, "no residual approval");
    }

    function test_crossChainSubmitAttemptsBridge() public {
        _ownerSetup(PEER_EID, address(offer), address(want));

        offer.mint(address(this), AMOUNT);
        offer.approve(address(station), AMOUNT);

        TransitStation.Quote memory q = _quote(PEER_EID, address(offer), address(want), AMOUNT);
        station.submitOrder(q, _sign(q));

        assertTrue(MockLZEndpoint(LZ_ENDPOINT).sendCalled(), "bridge send attempted");
        assertEq(station.pendingOrderCount(), 0, "cross-chain order not queued locally");
    }

    function test_decimalsScaling_6decOffer_18decWant() public {
        MockERC20 offer6 = new MockERC20("Offer6", "OFR6", 6);
        uint32 destEid = station.thisChainEID();
        _ownerSetup(destEid, address(offer6), address(want));

        // 5 whole tokens, quoted in normalized 18-decimal units; only 5e6 token units actually move
        offer6.mint(address(this), 5e6);
        offer6.approve(address(station), 5e6);

        TransitStation.Quote memory q = _quote(destEid, address(offer6), address(want), 5e18);
        bytes32 uuid = station.submitOrder(q, _sign(q));

        assertEq(offer6.balanceOf(address(vault)), 5e6, "offer pulled in token units");
        assertEq(offer6.balanceOf(address(this)), 0, "submitter charged exactly the truncated amount");
        (TransitStation.OrderTerms memory terms, uint256 amountDue,) = station.pendingOrders(uuid);
        assertEq(terms.offerAmountNormalized18AfterFees, 5e18, "collected net re-normalized");
        assertEq(amountDue, 5e18, "amountDue derived in 18-dec want units");
    }

    function test_decimalsScaling_18decOffer_6decWant() public {
        MockERC20 want6 = new MockERC20("Want6", "WNT6", 6);
        uint32 destEid = station.thisChainEID();
        _ownerSetup(destEid, address(offer), address(want6));

        offer.mint(address(this), 5e18);
        offer.approve(address(station), 5e18);

        TransitStation.Quote memory q = _quote(destEid, address(offer), address(want6), 5e18);
        bytes32 uuid = station.submitOrder(q, _sign(q));

        (, uint256 amountDue,) = station.pendingOrders(uuid);
        assertEq(amountDue, 5e6, "amountDue derived in 6-dec want units");

        want6.mint(address(vault), 5e6);
        vm.prank(MULTISIG);
        vault.manage(address(want6), abi.encodeWithSignature("approve(address,uint256)", address(station), 5e6), 0);

        bytes32[] memory uuids = new bytes32[](1);
        uuids[0] = uuid;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 5e6;

        vm.prank(EXECUTOR);
        station.executePendingOrders(uuids, amounts);

        assertEq(want6.balanceOf(RECEIVER), 5e6, "receiver paid in want token units");
        assertEq(station.pendingOrderCount(), 0, "cleared");
    }

    function test_subDustNetTruncatesToZeroReverts() public {
        MockERC20 offer6 = new MockERC20("Offer6", "OFR6", 6);
        uint32 destEid = station.thisChainEID();
        _ownerSetup(destEid, address(offer6), address(want));

        // anything below 1e12 normalized is less than one token unit of a 6-decimal asset
        TransitStation.Quote memory q = _quote(destEid, address(offer6), address(want), 1e12 - 1);
        bytes memory sig = _sign(q);

        vm.expectRevert(abi.encodeWithSelector(TransitStation.NetTruncatesToZero.selector, 1e12 - 1, 6));
        station.submitOrder(q, sig);
    }

    function test_subDustAmountDueReverts() public {
        MockERC20 want6 = new MockERC20("Want6", "WNT6", 6);
        uint32 destEid = station.thisChainEID();
        _ownerSetup(destEid, address(offer), address(want6));

        // collectible from an 18-dec offer (1e11 wei) but truncates to zero 6-dec want units
        offer.mint(address(this), 1e11);
        offer.approve(address(station), 1e11);

        TransitStation.Quote memory q = _quote(destEid, address(offer), address(want6), 1e11);
        bytes memory sig = _sign(q);

        vm.expectRevert(TransitStation.ZeroAmountDue.selector);
        station.submitOrder(q, sig);
    }

    function test_feeDustFoldsIntoNet() public {
        MockERC20 offer6 = new MockERC20("Offer6", "OFR6", 6);
        uint32 destEid = station.thisChainEID();
        _ownerSetup(destEid, address(offer6), address(want));

        offer6.mint(address(this), 5e6);
        offer6.approve(address(station), 5e6);

        // a protocol fee below one token unit of the offer asset is not separately collectible; the exact-partition
        // collection sweeps it into the net (the vault) instead of leaving it with the submitter
        TransitStation.Quote memory q = _quote(destEid, address(offer6), address(want), 5e18);
        q.protocolFeeNormalized18 = 1e11;
        station.submitOrder(q, _sign(q));

        assertEq(offer6.balanceOf(station.protocolFeeRecipient()), 0, "sub-unit fee not collected");
        assertEq(offer6.balanceOf(address(vault)), 5e6, "fee dust folded into net");
    }

    function _ownerSetup(uint32 destEid, address offerAsset, address wantAsset) internal {
        TransitStation.Route[] memory routes = new TransitStation.Route[](1);
        routes[0] = TransitStation.Route({ destEID: destEid, offerAsset: offerAsset, wantAsset: wantAsset });
        bool[] memory approved = new bool[](1);
        approved[0] = true;

        vm.startPrank(MULTISIG);
        station.setQuoteSigner(vm.addr(SIGNER_PK));
        station.setRouteApprovals(routes, approved);
        vm.stopPrank();
    }

    function _quote(
        uint32 destEid,
        address offerAsset,
        address wantAsset,
        uint256 offerAmountNormalized18
    )
        internal
        returns (TransitStation.Quote memory)
    {
        return TransitStation.Quote({
            route: TransitStation.Route({ destEID: destEid, offerAsset: offerAsset, wantAsset: wantAsset }),
            offerAmountNormalized18: offerAmountNormalized18,
            receiver: RECEIVER,
            protocolFeeNormalized18: 0,
            integratorFeeNormalized18: 0,
            integratorFeeReceiver: address(0),
            deadline: block.timestamp + 1 days,
            salt: bytes32(++saltCounter)
        });
    }

    function _sign(TransitStation.Quote memory q) internal view returns (bytes memory) {
        bytes32 routeHash =
            keccak256(abi.encode(ROUTE_TYPEHASH, q.route.destEID, q.route.offerAsset, q.route.wantAsset));
        bytes32 structHash = keccak256(
            abi.encode(
                QUOTE_TYPEHASH,
                routeHash,
                q.offerAmountNormalized18,
                q.receiver,
                q.protocolFeeNormalized18,
                q.integratorFeeNormalized18,
                q.integratorFeeReceiver,
                q.deadline,
                q.salt
            )
        );
        bytes32 domainSep = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("TransitStation"), keccak256("1"), block.chainid, address(station))
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, digest);
        return abi.encodePacked(r, s, v);
    }

}
