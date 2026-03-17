// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Test, stdStorage, StdStorage, stdError, console } from "@forge-std/Test.sol";
import { DeployAll } from "script/deploy/deployAll.s.sol";
import { ConfigReader } from "script/ConfigReader.s.sol";
import { SOLVER_ROLE } from "script/deploy/single/06_DeployRolesAuthority.s.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";

import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";
import { RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { DeployRateProviders } from "script/deploy/01_DeployRateProviders.s.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { stdJson as StdJson } from "@forge-std/StdJson.sol";

import { CrossChainTellerBase, BridgeData, ERC20 } from "src/base/Roles/CrossChain/CrossChainTellerBase.sol";
import {
    MultiChainLayerZeroTellerWithMultiAssetSupport
} from "src/base/Roles/CrossChain/MultiChainLayerZeroTellerWithMultiAssetSupport.sol";

import { console2 } from "forge-std/console2.sol";

string constant DEFAULT_RPC_URL = "L1_RPC_URL";
uint256 constant DELTA = 1000;

// We use this so that we can use the inheritance linearization to start the fork before other constructors
abstract contract ForkTest is Test {

    constructor() {
        // the start fork must be done before the constructor in the Base.s.sol, as it attempts to access an onchain
        // asset, CREATEX
        _startFork(DEFAULT_RPC_URL);
    }

    function _startFork(string memory rpcKey) internal virtual returns (uint256 forkId) {
        if (block.chainid == 31_337) {
            forkId = vm.createFork(vm.envString(rpcKey));
            vm.selectFork(forkId);
        }
    }

}

contract LiveDeploy is ForkTest, DeployAll {

    using Strings for address;
    using StdJson for string;
    using FixedPointMathLib for uint256;

    ERC20 constant NATIVE_ERC20 = ERC20(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
    uint256 ONE_SHARE;

    function setUp() public virtual {
        string memory FILE_NAME;

        // 31_337 is default if this script is ran with no --fork-url= CLI flag
        // when using the Makefile we use this flag to simplify use of the makefile
        // however, the script should still have a default configuration for fork and FILE_NAME
        if (block.chainid == 31_337) {
            // default file is exampleL1
            FILE_NAME = "exampleL1.json";

            // we have to start the fork again... I don't exactly know why. But it's a known issue with foundry re:
            // https://github.com/foundry-rs/foundry/issues/5471
            _startFork(DEFAULT_RPC_URL);
        } else {
            // Otherwise we use the makefile provided deployment file ENV name
            FILE_NAME = vm.envString("LIVE_DEPLOY_READ_FILE_NAME");
        }

        // Run the deployment scripts

        runLiveTest(FILE_NAME);

        // check for if all rate providers are deployed, if not error
        for (uint256 i; i < mainConfig.withdrawAssets.length; ++i) {
            // set the corresponding rate provider
            string memory key = string(
                abi.encodePacked(
                    ".assetToRateProviderAndPriceFeed.", mainConfig.withdrawAssets[i].toHexString(), ".rateProvider"
                )
            );
            string memory chainConfig = getChainConfigFile();
            bool isPegged = chainConfig.readBool(
                string(
                    abi.encodePacked(
                        ".assetToRateProviderAndPriceFeed.", mainConfig.withdrawAssets[i].toHexString(), ".isPegged"
                    )
                )
            );
            if (!isPegged) {
                address rateProvider = chainConfig.readAddress(key);
                assertNotEq(rateProvider, address(0), "Rate provider address is 0");
                assertNotEq(rateProvider.code.length, 0, "No code at rate provider address");
            }
        }
        // perform the same checks for the deposit assets
        for (uint256 i; i < mainConfig.depositAssets.length; ++i) {
            // set the corresponding rate provider
            string memory key = string(
                abi.encodePacked(
                    ".assetToRateProviderAndPriceFeed.", mainConfig.depositAssets[i].toHexString(), ".rateProvider"
                )
            );
            string memory chainConfig = getChainConfigFile();
            bool isPegged = chainConfig.readBool(
                string(
                    abi.encodePacked(
                        ".assetToRateProviderAndPriceFeed.", mainConfig.depositAssets[i].toHexString(), ".isPegged"
                    )
                )
            );
            if (!isPegged) {
                address rateProvider = chainConfig.readAddress(key);
                assertNotEq(rateProvider, address(0), "Rate provider address is 0");
                assertNotEq(rateProvider.code.length, 0, "No code at rate provider address");
            }
        }

        // define one share based off of vault decimals
        ONE_SHARE = 10 ** BoringVault(payable(mainConfig.boringVault)).decimals();

        // give this the SOLVER_ROLE to call bulkWithdraw
        RolesAuthority rolesAuthority = RolesAuthority(mainConfig.rolesAuthority);
        vm.startPrank(mainConfig.protocolAdmin);
        rolesAuthority.setUserRole(address(this), SOLVER_ROLE, true);
        rolesAuthority.setRoleCapability(
            SOLVER_ROLE, mainConfig.teller, TellerWithMultiAssetSupport.bulkWithdraw.selector, true
        );

        if (mainConfig.distributorCodeDepositorDeploy) {
            require(
                !rolesAuthority.isCapabilityPublic(mainConfig.teller, TellerWithMultiAssetSupport.deposit.selector),
                "Teller must not have deposit public capability set if using DCD"
            );
            // we set it public for the sake of testing here where we use the Teller as an entrypoint for deposits
            rolesAuthority.setPublicCapability(mainConfig.teller, TellerWithMultiAssetSupport.deposit.selector, true);
            require(mainConfig.distributorCodeDepositor != address(0), "Distributor Code Depositor is not deployed");
            require(mainConfig.distributorCodeDepositor.code.length != 0, "Distributor Code Depositor has no code");
        }
        vm.stopPrank();
    }

    function testDepositAndBridge(uint256 amount) public {
        string memory tellerName = mainConfig.tellerContractName;
        if (compareStrings(tellerName, "MultiChainLayerZeroTellerWithMultiAssetSupport")) {
            _testLZDepositAndBridge(ERC20(mainConfig.base), amount);
        } else { }
    }

    function testDepositBaseAssetAndUpdateRate(uint256 depositAmount, uint256 rateChange256) public {
        AccountantWithRateProviders accountant = AccountantWithRateProviders(mainConfig.accountant);
        // bound and cast since bound does not support uint96
        uint96 rateChange = uint96(
            bound(rateChange256, mainConfig.allowedExchangeRateChangeLower, mainConfig.allowedExchangeRateChangeUpper)
        );

        depositAmount = bound(depositAmount, 1, 10_000e18);

        // mint a bunch of extra tokens to the vault for if rate increased
        deal(mainConfig.base, mainConfig.boringVault, depositAmount);

        _depositAssetWithApprove(ERC20(mainConfig.base), depositAmount);
        BoringVault boringVault = BoringVault(payable(mainConfig.boringVault));
        uint256 expected_shares = depositAmount;

        assertEq(
            boringVault.balanceOf(address(this)),
            expected_shares,
            "Should have received expected shares 1:1 for base asset"
        );

        // update the rate
        // We need to warp forward in time to avoid pausing on exchange rate update.
        vm.warp(block.timestamp + mainConfig.minimumUpdateDelayInSeconds);
        _updateRate(rateChange, accountant);

        uint256 expectedAssetsBack = depositAmount * rateChange / 10_000;

        // attempt a withdrawal after
        TellerWithMultiAssetSupport(mainConfig.teller)
            .bulkWithdraw(ERC20(mainConfig.base), expected_shares, expectedAssetsBack, address(this));
        assertEq(
            ERC20(mainConfig.base).balanceOf(address(this)),
            expectedAssetsBack,
            "Should have been able to withdraw back the depositAmount with rate factored"
        );
    }

    function testDepositBaseAssetOnStartingRate(uint256 depositAmount, uint256 rateChange256) public {
        AccountantWithRateProviders accountant = AccountantWithRateProviders(mainConfig.accountant);

        // bound and cast since bound does not support uint96
        uint96 rateChange = uint96(
            bound(rateChange256, mainConfig.allowedExchangeRateChangeLower, mainConfig.allowedExchangeRateChangeUpper)
        );
        depositAmount = bound(depositAmount, 2, 10_000e18);

        // update the rate
        // We need to warp forward in time to avoid pausing on exchange rate update.
        vm.warp(block.timestamp + mainConfig.minimumUpdateDelayInSeconds);
        _updateRate(rateChange, accountant);
        _depositAssetWithApprove(ERC20(mainConfig.base), depositAmount);

        BoringVault boringVault = BoringVault(payable(mainConfig.boringVault));
        uint256 sharesOut = boringVault.balanceOf(address(this));

        // attempt a withdrawal after
        TellerWithMultiAssetSupport(mainConfig.teller)
            .bulkWithdraw(ERC20(mainConfig.base), sharesOut, depositAmount - 2, address(this));

        assertApproxEqAbs(
            ERC20(mainConfig.base).balanceOf(address(this)),
            depositAmount,
            2,
            "Should have been able to withdraw back the depositAmount"
        );
    }

    function testDepositBaseAsset(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1, 10_000e18);
        _depositAssetWithApprove(ERC20(mainConfig.base), depositAmount);

        BoringVault boringVault = BoringVault(payable(mainConfig.boringVault));
        uint256 expected_shares = depositAmount;
        assertEq(
            boringVault.balanceOf(address(this)),
            expected_shares,
            "Should have received expected shares 1:1 for base asset"
        );

        // attempt a withdrawal after
        TellerWithMultiAssetSupport(mainConfig.teller)
            .bulkWithdraw(ERC20(mainConfig.base), expected_shares, depositAmount, address(this));
        assertEq(
            ERC20(mainConfig.base).balanceOf(address(this)),
            depositAmount,
            "Should have been able to withdraw back the depositAmount"
        );
    }

    function testDepositASupportedAssetAndUpdateRate(uint256 depositAmount, uint96 rateChange) public {
        AccountantWithRateProviders accountant = AccountantWithRateProviders(mainConfig.accountant);
        // manual bounding done because bound() doesn't exist for uint96
        rateChange = rateChange % uint96(mainConfig.allowedExchangeRateChangeUpper - 1);
        rateChange = (rateChange < mainConfig.allowedExchangeRateChangeLower + 1)
            ? mainConfig.allowedExchangeRateChangeLower + 1
            : rateChange;

        depositAmount = bound(depositAmount, 0.5e18, 10_000e18);

        uint256 depositAssetsLength = mainConfig.depositAssets.length;
        uint256 withdrawAssetsLength = mainConfig.withdrawAssets.length;

        if (depositAssetsLength == 0 || withdrawAssetsLength == 0) return; // skip test if there's no assets to deposit
        // or withdraw

        uint256 largestAssetArray =
            withdrawAssetsLength > depositAssetsLength ? withdrawAssetsLength : depositAssetsLength;

        // Loop through the arrays together in O(n) with modular indexing of the arrays. Purpose is just to: deposit
        // every deposit asset and withdraw every withdraw asset, not test every combination
        for (uint256 i; i < largestAssetArray; ++i) {
            ERC20 depositAsset = ERC20(mainConfig.depositAssets[i % depositAssetsLength]);
            ERC20 withdrawAsset = ERC20(mainConfig.withdrawAssets[i % withdrawAssetsLength]);

            // We need to warp forward in time to avoid pausing on exchange rate update.
            // We also need to do this before getting the rateInQuoteBefore so that any rates that are time based (like
            // apxETH) are accounted for
            vm.warp(block.timestamp + mainConfig.minimumUpdateDelayInSeconds);
            uint256 rateInQuoteBefore = accountant.getRateInQuoteSafe(ERC20(depositAsset));
            uint256 expectedShares =
                depositAmount.mulDivDown(ONE_SHARE, accountant.getRateInQuoteSafe(ERC20(depositAsset)));

            _depositAssetWithApprove(depositAsset, depositAmount);

            BoringVault boringVault = BoringVault(payable(mainConfig.boringVault));
            assertEq(boringVault.balanceOf(address(this)), expectedShares, "Should have received expected shares");

            // update the rate
            _updateRate(rateChange, accountant);

            assertApproxEqAbs(
                accountant.getRateInQuote(ERC20(depositAsset)),
                rateInQuoteBefore * rateChange / 10_000,
                1,
                "Rate change did not apply to asset"
            );

            // mint extra assets for vault to give out
            uint256 expectedBaseValueBack = ((depositAmount) * rateChange / 10_000);
            uint256 expectedAssetsBack = expectedBaseValueBack.mulDivDown(
                accountant.getRateInQuoteSafe(depositAsset), accountant.getRateInQuoteSafe(withdrawAsset)
            );
            // We deal extra in order for any failures in accounting to show up in our more verbose testing rather than
            // the ERC20 error
            deal(address(withdrawAsset), mainConfig.boringVault, expectedAssetsBack * (1e18 + DELTA) / 1e18);

            uint256 assetsOut = expectedShares.mulDivDown(accountant.getRateInQuoteSafe(ERC20(depositAsset)), ONE_SHARE);

            // Delta must be set very high to pass
            assertApproxEqRel(assetsOut, expectedAssetsBack, DELTA, "assets out not equal to expected assets back");

            TellerWithMultiAssetSupport(mainConfig.teller)
                .bulkWithdraw(ERC20(withdrawAsset), expectedShares, expectedAssetsBack * 99 / 100, address(this));

            assertApproxEqRel(
                ERC20(withdrawAsset).balanceOf(address(this)),
                expectedAssetsBack,
                DELTA,
                "Should have been able to withdraw back the depositAmounts"
            );
        }
    }

    function testDepositASupportedAsset(uint256 depositAmount, uint256 indexOfSupported) public {
        uint256 depositAssetsCount = mainConfig.depositAssets.length;

        indexOfSupported = bound(indexOfSupported, 0, depositAssetsCount);
        depositAmount = bound(depositAmount, 1, 10_000e18);

        uint256 expecteShares;
        AccountantWithRateProviders accountant = AccountantWithRateProviders(mainConfig.accountant);
        uint256[] memory expectedSharesByAsset = new uint256[](depositAssetsCount);
        for (uint256 i; i < depositAssetsCount; ++i) {
            expectedSharesByAsset[i] =
                depositAmount.mulDivDown(ONE_SHARE, accountant.getRateInQuoteSafe(ERC20(mainConfig.depositAssets[i])));
            expecteShares += expectedSharesByAsset[i];

            _depositAssetWithApprove(ERC20(mainConfig.depositAssets[i]), depositAmount);
        }

        BoringVault boringVault = BoringVault(payable(mainConfig.boringVault));
        assertEq(boringVault.balanceOf(address(this)), expecteShares, "Should have received expected shares");

        // withdrawal the assets for the same amount back
        for (uint256 i; i < depositAssetsCount; ++i) {
            // Only continue if we may also withdraw this asset
            if (!TellerWithMultiAssetSupport(mainConfig.teller).isWithdrawSupported(ERC20(mainConfig.depositAssets[i])))
            {
                continue;
            }
            TellerWithMultiAssetSupport(mainConfig.teller)
                .bulkWithdraw(
                    ERC20(mainConfig.depositAssets[i]), expectedSharesByAsset[i], depositAmount - 1, address(this)
                );
            assertApproxEqAbs(
                ERC20(mainConfig.depositAssets[i]).balanceOf(address(this)),
                depositAmount,
                1,
                "Should have been able to withdraw back the depositAmounts"
            );
        }
    }

    function testAssetsAreAllNormalERC20(uint256 mintAmount, uint256 transferAmount) public {
        // Add a large but reasonable bound to the amount. If allowed to hit max, some proxy implementations of assets
        // cause storage errors when attempting to use deal. USDC on Base in particular sparked this change.
        mintAmount = bound(mintAmount, 1, 10 ** 25);
        transferAmount = bound(transferAmount, 1, mintAmount);
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        for (uint256 i; i < mainConfig.withdrawAssets.length; ++i) {
            ERC20 asset = ERC20(mainConfig.withdrawAssets[i]);
            deal(address(asset), user1, mintAmount);
            assertEq(asset.balanceOf(user1), mintAmount, "asset did not deal to user1 correctly");
            uint256 totalSupplyStart = asset.totalSupply();
            vm.prank(user1);
            asset.transfer(user2, transferAmount);
            assertEq(asset.balanceOf(user1), mintAmount - transferAmount, "user1 balance not removed after transfer");
            assertEq(asset.balanceOf(user2), transferAmount, "user2 balance not incremented after transfer");
            assertEq(asset.totalSupply(), totalSupplyStart, "asset total supply not the same after transfer");
        }
        address user3 = makeAddr("user3");
        address user4 = makeAddr("user4");
        for (uint256 i; i < mainConfig.depositAssets.length; ++i) {
            ERC20 asset = ERC20(mainConfig.depositAssets[i]);
            deal(address(asset), user3, mintAmount);
            assertEq(asset.balanceOf(user3), mintAmount, "asset did not deal to user3 correctly");
            uint256 totalSupplyStart = asset.totalSupply();
            vm.prank(user3);
            asset.transfer(user4, transferAmount);
            assertEq(asset.balanceOf(user3), mintAmount - transferAmount, "user3 balance not removed after transfer");
            assertEq(asset.balanceOf(user4), transferAmount, "user4 balance not incremented after transfer");
            assertEq(asset.totalSupply(), totalSupplyStart, "asset total supply not the same after transfer");
        }
    }

    function _depositAssetWithApprove(ERC20 asset, uint256 depositAmount) internal {
        deal(address(asset), address(this), depositAmount);
        asset.approve(mainConfig.boringVault, depositAmount);
        TellerWithMultiAssetSupport(mainConfig.teller).deposit(asset, depositAmount, 0);
    }

    function _testLZDepositAndBridge(ERC20 asset, uint256 amount) internal {
        MultiChainLayerZeroTellerWithMultiAssetSupport sourceTeller =
            MultiChainLayerZeroTellerWithMultiAssetSupport(mainConfig.teller);
        BoringVault boringVault = BoringVault(payable(mainConfig.boringVault));
        AccountantWithRateProviders accountant = AccountantWithRateProviders(mainConfig.accountant);

        amount = bound(amount, 0.0001e18, 10_000e18);
        // make a user and give them BASE
        address user = makeAddr("A user");
        address userChain2 = makeAddr("A user on chain 2");
        deal(address(asset), user, amount);

        // approve teller to spend BASE
        vm.startPrank(user);
        vm.deal(user, 10e18);
        asset.approve(address(boringVault), amount);

        // perform depositAndBridge
        BridgeData memory data = BridgeData({
            chainSelector: mainConfig.peerEid,
            destinationChainReceiver: userChain2,
            bridgeFeeToken: NATIVE_ERC20,
            messageGas: 100_000,
            data: ""
        });

        uint256 ONE_SHARE = 10 ** boringVault.decimals();

        // so you don't really need to know exact shares in reality
        // just need to pass in a number roughly the same size to get quote
        // I still get the real number here for testing
        uint256 shares = amount.mulDivDown(ONE_SHARE, accountant.getRateInQuoteSafe(asset));
        uint256 quote = sourceTeller.previewFee(shares, data);
        uint256 assetBefore = asset.balanceOf(address(boringVault));

        sourceTeller.depositAndBridge{ value: quote }(asset, amount, shares, data);
        // verifyPackets(uint32(mainConfig.peerEid), addressToBytes32(address(mainConfig.teller)));

        assertEq(boringVault.balanceOf(user), 0, "Should have burned shares.");

        // assertEq(boringVault.balanceOf(userChain2), shares), ;

        assertEq(asset.balanceOf(address(boringVault)), assetBefore + shares, "boring vault should have shares");
        vm.stopPrank();
    }

    function addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }

    function _updateRate(uint96 rateChange, AccountantWithRateProviders accountant) internal {
        // update the rate
        vm.startPrank(mainConfig.exchangeRateBot);
        uint96 newRate = uint96(accountant.getRate()) * rateChange / 10_000;
        accountant.updateExchangeRate(newRate);
        vm.stopPrank();
    }

}
