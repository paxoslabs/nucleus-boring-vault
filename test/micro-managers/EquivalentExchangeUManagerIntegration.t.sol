// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { Test } from "@forge-std/Test.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { RolesAuthority, Authority } from "@solmate/auth/authorities/RolesAuthority.sol";

import { BoringVault } from "src/base/BoringVault.sol";
import { ManagerWithMerkleVerification } from "src/base/Roles/ManagerWithMerkleVerification.sol";
import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";
import { EquivalentExchangeUManager } from "src/micro-managers/EquivalentExchangeUManager.sol";

/// @notice Minimal mintable ERC20 used to stand up baskets at arbitrary decimals.
contract MockERC20 is ERC20 {

    constructor(string memory name, string memory symbol, uint8 decimals) ERC20(name, symbol, decimals) { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

}

/// @notice Stand-in swap route: pulls `amountIn` of `tokenIn` from the caller (the vault) and sends
///         `amountOut` of `tokenOut` to `recipient`. Setting amountOut < amountIn simulates slippage.
contract MockSwap {

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, address recipient) external {
        ERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        ERC20(tokenOut).transfer(recipient, amountOut);
    }

}

/// @notice Decoder/sanitizer that recognizes the basket-token approve (from the base) plus the mock
///         swap route, extracting the address arguments the merkle tree gates on.
contract MockDecoderAndSanitizer is BaseDecoderAndSanitizer {

    constructor(address _boringVault) BaseDecoderAndSanitizer(_boringVault) { }

    function swap(
        address tokenIn,
        address tokenOut,
        uint256,
        uint256,
        address recipient
    )
        external
        pure
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(tokenIn, tokenOut, recipient);
    }

}

/// @notice End-to-end tests for EquivalentExchangeUManager.execute against a real BoringVault +
///         ManagerWithMerkleVerification + merkle-gated decoder. No mainnet fork required.
contract EquivalentExchangeUManagerIntegrationTest is Test {

    // Mirror of the contract's event for vm.expectEmit.
    event Executed(
        address indexed caller,
        ERC20 indexed subsidyToken,
        uint256 totalBeforeNormalized,
        uint256 totalAfterNormalized,
        uint256 subsidyNormalized
    );

    uint8 internal constant MANAGER_ROLE = 1;
    uint8 internal constant STRATEGIST_ROLE = 2;

    BoringVault internal boringVault;
    ManagerWithMerkleVerification internal manager;
    RolesAuthority internal rolesAuthority;
    EquivalentExchangeUManager internal uManager;
    address internal rawDataDecoderAndSanitizer;
    MockSwap internal mockSwap;

    MockERC20 internal usdc; // 6 decimals
    MockERC20 internal dai; //  18 decimals

    address internal payer = makeAddr("subsidyPayer");

    function setUp() external {
        boringVault = new BoringVault(address(this), "Boring Vault", "BV", 18);
        manager = new ManagerWithMerkleVerification(address(this), address(boringVault), address(0));
        uManager = new EquivalentExchangeUManager(address(this), address(manager), address(boringVault));
        rawDataDecoderAndSanitizer = address(new MockDecoderAndSanitizer(address(boringVault)));
        mockSwap = new MockSwap();

        usdc = new MockERC20("USD Coin", "USDC", 6);
        dai = new MockERC20("Dai", "DAI", 18);

        // Wire up auth: the manager may manage the vault, and the uManager may drive the manager.
        rolesAuthority = new RolesAuthority(address(this), Authority(address(0)));
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
        rolesAuthority.setUserRole(address(uManager), STRATEGIST_ROLE, true);

        // Basket = { USDC, DAI }, treated 1:1 after decimal normalization.
        ERC20[] memory basket = new ERC20[](2);
        basket[0] = usdc;
        basket[1] = dai;
        uManager.setBasketTokens(basket);

        // Seed the vault with USDC to spend, and the swap route with DAI liquidity to hand back.
        usdc.mint(address(boringVault), 1000e6);
        dai.mint(address(mockSwap), 1_000_000e18);

        // Fund the subsidy payer and approve the uManager to pull DAI subsidy.
        dai.mint(payer, 1000e18);
        vm.prank(payer);
        dai.approve(address(uManager), type(uint256).max);
    }

    // ============================== happy paths ==============================

    function test_Execute_ValueNeutralSwap_NoSubsidy() external {
        // Approve exactly what the swap consumes, and receive an equal-normalized amount of DAI back.
        EquivalentExchangeUManager.ManageCall[] memory calls = _approveAndSwapCalls(1000e6, 1000e6, 1000e18);

        vm.expectEmit(true, true, true, true, address(uManager));
        emit Executed(address(this), dai, 1000e18, 1000e18, 0);

        uManager.execute(calls, payer, dai, 0);

        assertEq(usdc.balanceOf(address(boringVault)), 0, "vault USDC spent");
        assertEq(dai.balanceOf(address(boringVault)), 1000e18, "vault received DAI");
        assertEq(usdc.allowance(address(boringVault), address(mockSwap)), 0, "no dangling approval");
        assertEq(dai.balanceOf(payer), 1000e18, "payer untouched when no subsidy needed");
    }

    function test_Execute_SlippageCoveredBySubsidy() external {
        // Swap returns 1 DAI less than value-neutral -> 1e18 normalized shortfall, covered by the payer.
        EquivalentExchangeUManager.ManageCall[] memory calls = _approveAndSwapCalls(1000e6, 1000e6, 999e18);

        vm.expectEmit(true, true, true, true, address(uManager));
        emit Executed(address(this), dai, 1000e18, 1000e18, 1e18);

        uManager.execute(calls, payer, dai, 1e18);

        assertEq(dai.balanceOf(address(boringVault)), 1000e18, "vault made whole (999 swap + 1 subsidy)");
        assertEq(dai.balanceOf(payer), 999e18, "payer covered exactly the 1 DAI shortfall");
    }

    // ============================== subsidy cap / guards ==============================

    function test_Execute_RevertWhen_ShortfallExceedsMaxSubsidy() external {
        // 1e18 shortfall but caller only tolerates 0.5e18.
        EquivalentExchangeUManager.ManageCall[] memory calls = _approveAndSwapCalls(1000e6, 1000e6, 999e18);

        vm.expectRevert(EquivalentExchangeUManager.EquivalentExchangeUManager__MaxSubsidyExceeded.selector);
        uManager.execute(calls, payer, dai, 0.5e18);
    }

    function test_Execute_RevertWhen_SubsidyAllowanceInsufficient() external {
        // Payer revokes approval, so the shortfall cannot be covered.
        vm.prank(payer);
        dai.approve(address(uManager), 0);

        EquivalentExchangeUManager.ManageCall[] memory calls = _approveAndSwapCalls(1000e6, 1000e6, 999e18);

        vm.expectRevert(EquivalentExchangeUManager.EquivalentExchangeUManager__InsufficientSubsidy.selector);
        uManager.execute(calls, payer, dai, 1e18);
    }

    function test_Execute_RevertWhen_SubsidyBalanceInsufficient() external {
        // Payer keeps the (max) approval but has no DAI, so available = min(balance, allowance) = 0.
        // Read the balance before pranking; otherwise the balanceOf call would consume the prank.
        uint256 payerBalance = dai.balanceOf(payer);
        vm.prank(payer);
        dai.transfer(address(0xdead), payerBalance);

        EquivalentExchangeUManager.ManageCall[] memory calls = _approveAndSwapCalls(1000e6, 1000e6, 999e18);

        vm.expectRevert(EquivalentExchangeUManager.EquivalentExchangeUManager__InsufficientSubsidy.selector);
        uManager.execute(calls, payer, dai, 1e18);
    }

    // ============================== dangling approval ==============================

    function test_Execute_RevertWhen_DanglingApprovalLeft() external {
        // Approve more USDC than the swap consumes, leaving a non-zero allowance to the swap route.
        EquivalentExchangeUManager.ManageCall[] memory calls = _approveAndSwapCalls(2000e6, 1000e6, 1000e18);

        vm.expectRevert(EquivalentExchangeUManager.EquivalentExchangeUManager__DanglingApproval.selector);
        uManager.execute(calls, payer, dai, 0);
    }

    // ============================== merkle gating ==============================

    function test_Execute_RevertWhen_ProofInvalid() external {
        // Build a legitimate route, then tamper with the swap target so its proof no longer verifies.
        EquivalentExchangeUManager.ManageCall[] memory calls = _approveAndSwapCalls(1000e6, 1000e6, 1000e18);
        calls[1].target = address(dai); // not the gated swap target

        vm.expectRevert(
            abi.encodeWithSelector(
                ManagerWithMerkleVerification.ManagerWithMerkleVerification__FailedToVerifyManageProof.selector,
                calls[1].target,
                calls[1].targetData,
                calls[1].value
            )
        );
        uManager.execute(calls, payer, dai, 0);
    }

    // ============================== helpers ==============================

    /// @notice Builds the two-call route (approve USDC -> swap, then swap USDC->DAI to the vault),
    ///         sets the corresponding merkle root on the manager, and returns the ManageCall batch.
    function _approveAndSwapCalls(
        uint256 approveAmount,
        uint256 amountIn,
        uint256 amountOut
    )
        internal
        returns (EquivalentExchangeUManager.ManageCall[] memory calls)
    {
        ManageLeaf[] memory leafs = new ManageLeaf[](2);

        leafs[0] = ManageLeaf(address(usdc), false, "approve(address,uint256)", new address[](1));
        leafs[0].argumentAddresses[0] = address(mockSwap);

        leafs[1] =
            ManageLeaf(address(mockSwap), false, "swap(address,address,uint256,uint256,address)", new address[](3));
        leafs[1].argumentAddresses[0] = address(usdc);
        leafs[1].argumentAddresses[1] = address(dai);
        leafs[1].argumentAddresses[2] = address(boringVault);

        bytes32[][] memory tree = _generateMerkleTree(leafs);
        manager.setManageRoot(address(uManager), tree[tree.length - 1][0]);
        bytes32[][] memory proofs = _getProofsUsingTree(leafs, tree);

        calls = new EquivalentExchangeUManager.ManageCall[](2);
        calls[0] = EquivalentExchangeUManager.ManageCall({
            manageProofs: proofs[0],
            decodersAndSanitizers: rawDataDecoderAndSanitizer,
            target: address(usdc),
            targetData: abi.encodeWithSelector(ERC20.approve.selector, address(mockSwap), approveAmount),
            value: 0
        });
        calls[1] = EquivalentExchangeUManager.ManageCall({
            manageProofs: proofs[1],
            decodersAndSanitizers: rawDataDecoderAndSanitizer,
            target: address(mockSwap),
            targetData: abi.encodeWithSelector(
                MockSwap.swap.selector, address(usdc), address(dai), amountIn, amountOut, address(boringVault)
            ),
            value: 0
        });
    }

    // ---- merkle tree helpers (same construction as the other UManager integration tests) ----

    struct ManageLeaf {
        address target;
        bool canSendValue;
        string signature;
        address[] argumentAddresses;
    }

    function _generateMerkleTree(ManageLeaf[] memory manageLeafs) internal view returns (bytes32[][] memory tree) {
        uint256 leafsLength = manageLeafs.length;
        bytes32[][] memory leafs = new bytes32[][](1);
        leafs[0] = new bytes32[](leafsLength);
        for (uint256 i; i < leafsLength; ++i) {
            bytes4 selector = bytes4(keccak256(abi.encodePacked(manageLeafs[i].signature)));
            bytes memory rawDigest = abi.encodePacked(
                rawDataDecoderAndSanitizer, manageLeafs[i].target, manageLeafs[i].canSendValue, selector
            );
            uint256 argumentAddressesLength = manageLeafs[i].argumentAddresses.length;
            for (uint256 j; j < argumentAddressesLength; ++j) {
                rawDigest = abi.encodePacked(rawDigest, manageLeafs[i].argumentAddresses[j]);
            }
            leafs[0][i] = keccak256(rawDigest);
        }
        tree = _buildTrees(leafs);
    }

    function _getProofsUsingTree(
        ManageLeaf[] memory manageLeafs,
        bytes32[][] memory tree
    )
        internal
        view
        returns (bytes32[][] memory proofs)
    {
        proofs = new bytes32[][](manageLeafs.length);
        for (uint256 i; i < manageLeafs.length; ++i) {
            bytes4 selector = bytes4(keccak256(abi.encodePacked(manageLeafs[i].signature)));
            bytes memory rawDigest = abi.encodePacked(
                rawDataDecoderAndSanitizer, manageLeafs[i].target, manageLeafs[i].canSendValue, selector
            );
            uint256 argumentAddressesLength = manageLeafs[i].argumentAddresses.length;
            for (uint256 j; j < argumentAddressesLength; ++j) {
                rawDigest = abi.encodePacked(rawDigest, manageLeafs[i].argumentAddresses[j]);
            }
            proofs[i] = _generateProof(keccak256(rawDigest), tree);
        }
    }

    function _generateProof(bytes32 leaf, bytes32[][] memory tree) internal pure returns (bytes32[] memory proof) {
        uint256 treeLength = tree.length;
        proof = new bytes32[](treeLength - 1);
        for (uint256 i; i < treeLength - 1; ++i) {
            for (uint256 j; j < tree[i].length; ++j) {
                if (leaf == tree[i][j]) {
                    proof[i] = j % 2 == 0 ? tree[i][j + 1] : tree[i][j - 1];
                    leaf = _hashPair(leaf, proof[i]);
                    break;
                }
            }
        }
    }

    function _buildTrees(bytes32[][] memory merkleTreeIn) internal pure returns (bytes32[][] memory merkleTreeOut) {
        uint256 merkleTreeInLength = merkleTreeIn.length;
        merkleTreeOut = new bytes32[][](merkleTreeInLength + 1);
        uint256 layerLength;
        for (uint256 i; i < merkleTreeInLength; ++i) {
            layerLength = merkleTreeIn[i].length;
            merkleTreeOut[i] = new bytes32[](layerLength);
            for (uint256 j; j < layerLength; ++j) {
                merkleTreeOut[i][j] = merkleTreeIn[i][j];
            }
        }

        uint256 nextLayerLength = layerLength % 2 != 0 ? (layerLength + 1) / 2 : layerLength / 2;
        merkleTreeOut[merkleTreeInLength] = new bytes32[](nextLayerLength);
        uint256 count;
        for (uint256 i; i < layerLength; i += 2) {
            merkleTreeOut[merkleTreeInLength][count] =
                _hashPair(merkleTreeIn[merkleTreeInLength - 1][i], merkleTreeIn[merkleTreeInLength - 1][i + 1]);
            count++;
        }

        if (nextLayerLength > 1) {
            merkleTreeOut = _buildTrees(merkleTreeOut);
        }
    }

    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? _efficientHash(a, b) : _efficientHash(b, a);
    }

    function _efficientHash(bytes32 a, bytes32 b) private pure returns (bytes32 value) {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, a)
            mstore(0x20, b)
            value := keccak256(0x00, 0x40)
        }
    }

}
