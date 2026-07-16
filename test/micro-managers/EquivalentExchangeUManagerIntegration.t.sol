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

    /// @notice Non-standard-but-common allowance bump; solmate's ERC20 omits it, so the mock adds it.
    function increaseAllowance(address spender, uint256 addedValue) external returns (bool) {
        allowance[msg.sender][spender] += addedValue;
        return true;
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

    function increaseAllowance(address spender, uint256) external pure returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(spender);
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

        // Deltas bind to basket tokens by position, so every test's bounds are written against this exact
        // order. Pin it here: if the basket ever changes, these assertions fail loudly rather than letting
        // the suite silently apply USDC bounds to DAI and vice versa.
        address[] memory storedBasket = uManager.getBasketTokens();
        assertEq(storedBasket.length, 2, "basket size");
        assertEq(storedBasket[0], address(usdc), "basket[0] is USDC");
        assertEq(storedBasket[1], address(dai), "basket[1] is DAI");

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

        uManager.execute(calls, payer, dai, _wideMaxDeltas());

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

        uManager.execute(calls, payer, dai, _wideMaxDeltas());

        assertEq(dai.balanceOf(address(boringVault)), 1000e18, "vault made whole (999 swap + 1 subsidy)");
        assertEq(dai.balanceOf(payer), 999e18, "payer covered exactly the 1 DAI shortfall");
    }

    function test_Execute_SubsidyRoundsUpAndIsUncapped() external {
        // Subsidize with a 6-decimal token so _denormalize's round-up is observable. Nothing caps the
        // subsidy beyond the shortfall it covers, so the rounded-up over-pull is accepted, not rejected.
        usdc.mint(payer, 1000e6);
        vm.prank(payer);
        usdc.approve(address(uManager), type(uint256).max);

        // Engineer a shortfall of exactly 1e12 + 1 normalized units. It is NOT a multiple of the USDC
        // 1e12 scale, so _denormalize rounds it up from ~1 native unit to 2 (= 2e12 normalized).
        uint256 shortfall = 1e12 + 1;
        uint256 amountOut = 1000e18 - shortfall; // vault ends 1e12+1 short of value-neutral
        EquivalentExchangeUManager.ManageCall[] memory calls = _approveAndSwapCalls(1000e6, 1000e6, amountOut);

        // The batch spends all 1000e6 USDC (a 1000e6 decrease) and receives DAI; the subsidy is pulled in
        // USDC AFTER the snapshot, so it is not counted against USDC's batch bound.
        EquivalentExchangeUManager.TokenDelta[] memory maxDeltas = _maxDeltas(1000e6, 0, 0, type(uint256).max);

        uManager.execute(calls, payer, usdc, maxDeltas);

        // 2 native USDC units (2e12 normalized) were pulled to cover a 1e12+1 shortfall: rounding up.
        assertEq(usdc.balanceOf(address(boringVault)), 2, "vault received 2 native USDC subsidy units");
        assertEq(usdc.balanceOf(payer), 1000e6 - 2, "payer over-pulled by rounding, uncapped");
    }

    // ============================== subsidy guards ==============================

    function test_Execute_RevertWhen_SubsidyAllowanceInsufficient() external {
        // Payer revokes approval, so the shortfall cannot be covered.
        vm.prank(payer);
        dai.approve(address(uManager), 0);

        EquivalentExchangeUManager.ManageCall[] memory calls = _approveAndSwapCalls(1000e6, 1000e6, 999e18);

        vm.expectRevert(EquivalentExchangeUManager.EquivalentExchangeUManager__InsufficientSubsidy.selector);
        uManager.execute(calls, payer, dai, _wideMaxDeltas());
    }

    function test_Execute_RevertWhen_SubsidyBalanceInsufficient() external {
        // Payer keeps the (max) approval but has no DAI, so available = min(balance, allowance) = 0.
        // Read the balance before pranking; otherwise the balanceOf call would consume the prank.
        uint256 payerBalance = dai.balanceOf(payer);
        vm.prank(payer);
        dai.transfer(address(0xdead), payerBalance);

        EquivalentExchangeUManager.ManageCall[] memory calls = _approveAndSwapCalls(1000e6, 1000e6, 999e18);

        vm.expectRevert(EquivalentExchangeUManager.EquivalentExchangeUManager__InsufficientSubsidy.selector);
        uManager.execute(calls, payer, dai, _wideMaxDeltas());
    }

    // ============================== per-token delta bounds ==============================

    function test_Execute_TightDeltaBounds_Passes() external {
        // Value-neutral swap: USDC falls by exactly 1000e6, DAI rises by exactly 1000e18. Bounds set to
        // the exact inclusive edges must still pass.
        EquivalentExchangeUManager.ManageCall[] memory calls = _approveAndSwapCalls(1000e6, 1000e6, 1000e18);

        EquivalentExchangeUManager.TokenDelta[] memory maxDeltas = _maxDeltas(1000e6, 0, 0, 1000e18);

        vm.expectEmit(true, true, true, true, address(uManager));
        emit Executed(address(this), dai, 1000e18, 1000e18, 0);

        uManager.execute(calls, payer, dai, maxDeltas);

        assertEq(usdc.balanceOf(address(boringVault)), 0, "vault USDC spent");
        assertEq(dai.balanceOf(address(boringVault)), 1000e18, "vault received DAI");
    }

    function test_Execute_UnmovedTokenPassesZeroBounds() external {
        // Swap consumes the USDC but returns no DAI, so one basket token moves and the other does not.
        // DAI is pinned at {0, 0}: an unmoved token must pass even when both its bounds are zero, and
        // must not inherit the moving token's delta.
        EquivalentExchangeUManager.ManageCall[] memory calls = _approveAndSwapCalls(1000e6, 1000e6, 0);

        EquivalentExchangeUManager.TokenDelta[] memory maxDeltas = _maxDeltas(1000e6, 0, 0, 0);

        // The whole 1000e18 of value is recovered from the payer. The subsidy lands in DAI after the
        // bounds are checked, so it does not violate DAI's zero positiveDelta.
        vm.expectEmit(true, true, true, true, address(uManager));
        emit Executed(address(this), dai, 1000e18, 1000e18, 1000e18);

        uManager.execute(calls, payer, dai, maxDeltas);

        assertEq(usdc.balanceOf(address(boringVault)), 0, "vault USDC spent");
        assertEq(dai.balanceOf(address(boringVault)), 1000e18, "vault made whole entirely by subsidy");
        assertEq(dai.balanceOf(payer), 0, "payer covered the full shortfall");
    }

    function test_Execute_RevertWhen_DecreaseExceedsNegativeDelta() external {
        // USDC drops by 1000e6, but the caller only tolerates a 999e6 decrease.
        EquivalentExchangeUManager.ManageCall[] memory calls = _approveAndSwapCalls(1000e6, 1000e6, 1000e18);

        EquivalentExchangeUManager.TokenDelta[] memory maxDeltas = _maxDeltas(999e6, 0, 0, type(uint256).max);

        vm.expectRevert(
            abi.encodeWithSelector(
                EquivalentExchangeUManager.EquivalentExchangeUManager__TokenDeltaOutOfBounds.selector, address(usdc)
            )
        );
        uManager.execute(calls, payer, dai, maxDeltas);
    }

    function test_Execute_RevertWhen_IncreaseExceedsPositiveDelta() external {
        // DAI rises by 1000e18, but the caller only tolerates a 999e18 increase.
        EquivalentExchangeUManager.ManageCall[] memory calls = _approveAndSwapCalls(1000e6, 1000e6, 1000e18);

        EquivalentExchangeUManager.TokenDelta[] memory maxDeltas = _maxDeltas(type(uint256).max, 0, 0, 999e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                EquivalentExchangeUManager.EquivalentExchangeUManager__TokenDeltaOutOfBounds.selector, address(dai)
            )
        );
        uManager.execute(calls, payer, dai, maxDeltas);
    }

    function test_Execute_RevertWhen_ZeroDeltaForbidsMovement() external {
        // Both directions zeroed for USDC: the token is pinned, so any movement at all is rejected. This
        // is the band that a signed [min, max] pair could only express as [0, 0].
        EquivalentExchangeUManager.ManageCall[] memory calls = _approveAndSwapCalls(1000e6, 1000e6, 1000e18);

        EquivalentExchangeUManager.TokenDelta[] memory maxDeltas = _maxDeltas(0, 0, 0, type(uint256).max);

        vm.expectRevert(
            abi.encodeWithSelector(
                EquivalentExchangeUManager.EquivalentExchangeUManager__TokenDeltaOutOfBounds.selector, address(usdc)
            )
        );
        uManager.execute(calls, payer, dai, maxDeltas);
    }

    // ============================== dangling approval ==============================

    function test_Execute_RevertWhen_DanglingApprovalLeft() external {
        // Approve more USDC than the swap consumes, leaving a non-zero allowance to the swap route.
        EquivalentExchangeUManager.ManageCall[] memory calls = _approveAndSwapCalls(2000e6, 1000e6, 1000e18);

        vm.expectRevert(EquivalentExchangeUManager.EquivalentExchangeUManager__DanglingApproval.selector);
        uManager.execute(calls, payer, dai, _wideMaxDeltas());
    }

    function test_Execute_ApprovalResetToZero_Passes() external {
        // Approve the swap, then explicitly reset the same allowance to zero in the same batch.
        (bytes32[] memory approveProof, bytes32[] memory increaseProof) = _setApprovalTestRoot();

        EquivalentExchangeUManager.ManageCall[] memory calls = new EquivalentExchangeUManager.ManageCall[](2);
        calls[0] =
            _mc(approveProof, address(usdc), abi.encodeWithSelector(ERC20.approve.selector, address(mockSwap), 500e6));
        calls[1] =
            _mc(approveProof, address(usdc), abi.encodeWithSelector(ERC20.approve.selector, address(mockSwap), 0));
        increaseProof; // unused in this case

        // No tokens move, so the value invariant holds and the reset clears the allowance: no revert.
        uManager.execute(calls, payer, dai, _wideMaxDeltas());
        assertEq(usdc.allowance(address(boringVault), address(mockSwap)), 0, "allowance fully reset");
    }

    function test_Execute_RevertWhen_DanglingApprovalViaIncreaseAllowance() external {
        // A non-zero increaseAllowance that is never reset must be caught as a dangling approval.
        (, bytes32[] memory increaseProof) = _setApprovalTestRoot();

        EquivalentExchangeUManager.ManageCall[] memory calls = new EquivalentExchangeUManager.ManageCall[](1);
        calls[0] = _mc(
            increaseProof,
            address(usdc),
            abi.encodeWithSignature("increaseAllowance(address,uint256)", address(mockSwap), 500e6)
        );

        vm.expectRevert(EquivalentExchangeUManager.EquivalentExchangeUManager__DanglingApproval.selector);
        uManager.execute(calls, payer, dai, _wideMaxDeltas());
    }

    function test_Execute_IncreaseAllowanceResetToZero_Passes() external {
        // increaseAllowance then reset to zero via approve(spender, 0) in the same batch.
        (bytes32[] memory approveProof, bytes32[] memory increaseProof) = _setApprovalTestRoot();

        EquivalentExchangeUManager.ManageCall[] memory calls = new EquivalentExchangeUManager.ManageCall[](2);
        calls[0] = _mc(
            increaseProof,
            address(usdc),
            abi.encodeWithSignature("increaseAllowance(address,uint256)", address(mockSwap), 500e6)
        );
        calls[1] =
            _mc(approveProof, address(usdc), abi.encodeWithSelector(ERC20.approve.selector, address(mockSwap), 0));

        uManager.execute(calls, payer, dai, _wideMaxDeltas());
        assertEq(usdc.allowance(address(boringVault), address(mockSwap)), 0, "allowance fully reset");
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
        uManager.execute(calls, payer, dai, _wideMaxDeltas());
    }

    // ============================== helpers ==============================

    /// @notice Builds a bound set for the { USDC, DAI } basket from per-direction native-unit magnitudes.
    /// @dev Bounds attach to basket tokens by position, so the USDC pair lands at index 0 and the DAI pair
    ///      at index 1. setUp asserts the live basket matches that layout. Every argument is an unsigned
    ///      magnitude: `usdcNeg` is how far USDC may fall, `usdcPos` how far it may rise.
    function _maxDeltas(
        uint256 usdcNeg,
        uint256 usdcPos,
        uint256 daiNeg,
        uint256 daiPos
    )
        internal
        pure
        returns (EquivalentExchangeUManager.TokenDelta[] memory maxDeltas)
    {
        maxDeltas = new EquivalentExchangeUManager.TokenDelta[](2);
        maxDeltas[0] = EquivalentExchangeUManager.TokenDelta({ negativeDelta: usdcNeg, positiveDelta: usdcPos });
        maxDeltas[1] = EquivalentExchangeUManager.TokenDelta({ negativeDelta: daiNeg, positiveDelta: daiPos });
    }

    /// @notice Bounds that cannot bind, so tests can isolate other behavior.
    function _wideMaxDeltas() internal pure returns (EquivalentExchangeUManager.TokenDelta[] memory) {
        return _maxDeltas(type(uint256).max, type(uint256).max, type(uint256).max, type(uint256).max);
    }

    /// @notice Wraps calldata into a merkle-verified ManageCall against the shared decoder.
    function _mc(
        bytes32[] memory proof,
        address target,
        bytes memory data
    )
        internal
        view
        returns (EquivalentExchangeUManager.ManageCall memory)
    {
        return EquivalentExchangeUManager.ManageCall({
            manageProofs: proof,
            decodersAndSanitizers: rawDataDecoderAndSanitizer,
            target: target,
            targetData: data,
            value: 0
        });
    }

    /// @notice Gates approve(USDC -> swap) and increaseAllowance(USDC -> swap) under one root, returning
    ///         each leaf's proof. Two leaves keep the tree even, as the builder requires.
    function _setApprovalTestRoot() internal returns (bytes32[] memory approveProof, bytes32[] memory increaseProof) {
        ManageLeaf[] memory leafs = new ManageLeaf[](2);

        leafs[0] = ManageLeaf(address(usdc), false, "approve(address,uint256)", new address[](1));
        leafs[0].argumentAddresses[0] = address(mockSwap);

        leafs[1] = ManageLeaf(address(usdc), false, "increaseAllowance(address,uint256)", new address[](1));
        leafs[1].argumentAddresses[0] = address(mockSwap);

        bytes32[][] memory tree = _generateMerkleTree(leafs);
        manager.setManageRoot(address(uManager), tree[tree.length - 1][0]);
        bytes32[][] memory proofs = _getProofsUsingTree(leafs, tree);

        approveProof = proofs[0];
        increaseProof = proofs[1];
    }

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
