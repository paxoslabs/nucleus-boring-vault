// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { VaultArchitectureSharedSetup } from "test/shared-setup/VaultArchitectureSharedSetup.t.sol";
import { FreezeListBeforeTransferHook } from "src/helper/FreezeListBeforeTransferHook.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";

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
        freezeHook = new FreezeListBeforeTransferHook();
        boringVault.setBeforeTransferHook(address(freezeHook));

        // Give both users some vault shares
        deal(address(boringVault), frozenUser, 1000e18);
        deal(address(boringVault), normalUser, 1000e18);
    }

    function testFrozenAddressCannotTransfer() public {
        // Freeze the frozenUser address
        address[] memory addressesToFreeze = new address[](1);
        addressesToFreeze[0] = frozenUser;
        freezeHook.setFreezeList(addressesToFreeze, true);

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

        // Verify normal user can still transfer even to the frozen user
        vm.prank(normalUser);
        boringVault.transfer(frozenUser, 100e18);
    }

}
