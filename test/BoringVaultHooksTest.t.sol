// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { VaultArchitectureSharedSetup } from "test/shared-setup/VaultArchitectureSharedSetup.t.sol";
import { FreezeListBeforeTransferHook } from "src/helper/FreezeListBeforeTransferHook.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { IFallbackHook } from "src/interfaces/IFallbackHook.sol";
import { console } from "forge-std/console.sol";

contract MockFallbackHook is IFallbackHook {

    struct MyStruct {
        uint256 a;
        uint256 b;
    }

    function onFallback(address sender, bytes calldata data) external payable returns (bytes memory) {
        if (bytes4(data[0:4]) == this.foo.selector) return abi.encode(foo());
    }

    function foo() public pure returns (MyStruct memory a) {
        return MyStruct({ a: 4, b: 2 });
    }

}

contract FreezeListTest is VaultArchitectureSharedSetup {

    FreezeListBeforeTransferHook public freezeHook;

    address public frozenUser = vm.addr(1);
    address public normalUser = vm.addr(2);

    function setUp() public {
        _startFork("MAINNET_RPC_URL", 24_485_295);
        // Deploy a basic vault architecture
        address[] memory assets = new address[](1);
        assets[0] = address(WETH);

        (boringVault, teller, accountant) =
            _deployVaultArchitecture("Test Vault", "TEST", 18, address(WETH), assets, 1e18);

        // Deploy and set up the freeze hook
        freezeHook = new FreezeListBeforeTransferHook(address(this));
        boringVault.setBeforeTransferHook(address(freezeHook));

        // Give both users some vault shares
        deal(address(boringVault), frozenUser, 1000e18);
        deal(address(boringVault), normalUser, 1000e18);
    }

    function testFrozenAddressCannotTransfer() public {
        // Freeze the frozenUser address
        address[] memory addressesToFreeze = new address[](1);
        addressesToFreeze[0] = frozenUser;
        freezeHook.setFreezeList(addressesToFreeze, new address[](0));

        // Verify the frozen user cannot transfer
        vm.prank(frozenUser);
        vm.expectRevert(abi.encodeWithSelector(FreezeListBeforeTransferHook.FrozenAddress.selector, frozenUser));
        boringVault.transfer(normalUser, 100e18);

        // Verify the frozen user cannot transferFrom
        vm.prank(frozenUser);
        boringVault.approve(normalUser, 100e18);
        vm.prank(normalUser);
        vm.expectRevert(abi.encodeWithSelector(FreezeListBeforeTransferHook.FrozenAddress.selector, frozenUser));
        boringVault.transferFrom(frozenUser, normalUser, 100e18);

        // Verify normal user can not transfer to the frozen user
        vm.prank(normalUser);
        vm.expectRevert(abi.encodeWithSelector(FreezeListBeforeTransferHook.FrozenAddress.selector, frozenUser));
        boringVault.transfer(frozenUser, 100e18);

        // normal user can transfer to another normal user
        vm.prank(normalUser);
        boringVault.transfer(vm.addr(3), 100e18);
    }

    function testFallbackHook() public {
        vm.prank(normalUser);
        vm.expectRevert(address(boringVault));
        address(boringVault).call(abi.encodeWithSignature("foo()"));

        MockFallbackHook fallbackHook = new MockFallbackHook();

        vm.prank(boringVault.owner());
        boringVault.setFallbackHook(address(fallbackHook));

        vm.prank(normalUser);
        (bool success, bytes memory result) = address(boringVault).call(abi.encodeWithSignature("foo()"));
        MockFallbackHook.MyStruct memory s = abi.decode(result, (MockFallbackHook.MyStruct));
        assertEq(s.a, 4);
        assertEq(s.b, 2);
    }

    function testFallbackHookReceivesValue() public {
        MockFallbackHook fallbackHook = new MockFallbackHook();

        vm.prank(boringVault.owner());
        boringVault.setFallbackHook(address(fallbackHook));

        uint256 sendAmount = 1 ether;
        vm.deal(normalUser, sendAmount);

        uint256 vaultBalanceBefore = address(boringVault).balance;

        vm.prank(normalUser);
        (bool success,) = address(boringVault).call{ value: sendAmount }(abi.encodeWithSignature("foo()"));
        assertTrue(success);
        // ETH is forwarded to the hook — hook gained sendAmount, vault balance unchanged
        assertEq(address(fallbackHook).balance, sendAmount);
        assertEq(address(boringVault).balance, vaultBalanceBefore);
    }

}
