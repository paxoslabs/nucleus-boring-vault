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
        "Quote(Route route,uint256 offerAmount,uint256 amountDue,address receiver,uint256 protocolFee,uint256 integratorFee,address integratorFeeReceiver,uint256 deadline,bytes32 salt)Route(uint32 destEID,address offerAsset,address wantAsset)"
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
        _ownerSetup(destEid);

        offer.mint(address(this), AMOUNT);
        offer.approve(address(station), AMOUNT);

        TransitStation.Quote memory q = _quote(destEid);
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
        _ownerSetup(PEER_EID);

        offer.mint(address(this), AMOUNT);
        offer.approve(address(station), AMOUNT);

        TransitStation.Quote memory q = _quote(PEER_EID);
        station.submitOrder(q, _sign(q));

        assertTrue(MockLZEndpoint(LZ_ENDPOINT).sendCalled(), "bridge send attempted");
        assertEq(station.pendingOrderCount(), 0, "cross-chain order not queued locally");
    }

    function _ownerSetup(uint32 destEid) internal {
        TransitStation.Route[] memory routes = new TransitStation.Route[](1);
        routes[0] = TransitStation.Route({ destEID: destEid, offerAsset: address(offer), wantAsset: address(want) });
        bool[] memory approved = new bool[](1);
        approved[0] = true;

        vm.startPrank(MULTISIG);
        station.setQuoteSigner(vm.addr(SIGNER_PK));
        station.setRouteApprovals(routes, approved);
        vm.stopPrank();
    }

    function _quote(uint32 destEid) internal returns (TransitStation.Quote memory) {
        return TransitStation.Quote({
            route: TransitStation.Route({ destEID: destEid, offerAsset: address(offer), wantAsset: address(want) }),
            offerAmount: AMOUNT,
            amountDue: AMOUNT,
            receiver: RECEIVER,
            protocolFee: 0,
            integratorFee: 0,
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
                q.offerAmount,
                q.amountDue,
                q.receiver,
                q.protocolFee,
                q.integratorFee,
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
