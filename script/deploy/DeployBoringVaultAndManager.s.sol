// SPDX-License-Identifier: Apache-2.0
pragma solidity =0.8.21;

import { console } from "forge-std/console.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { ManagerWithMerkleVerification } from "src/base/Roles/ManagerWithMerkleVerification.sol";
import { EquivalentExchangeUManager } from "src/micro-managers/EquivalentExchangeUManager.sol";
import { EthPerTokenRateProvider } from "src/oracles/EthPerTokenRateProvider.sol";
import { IPriceFeed } from "src/interfaces/IPriceFeed.sol";
import { IRateProvider } from "src/interfaces/IRateProvider.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { RolesAuthority, Authority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { stdJson } from "@forge-std/Script.sol";
import { BaseScript } from "script/Base.s.sol";
import "src/helper/Constants.sol";

contract DeployBoringVaultAndManager is BaseScript {

    string constant NAME = "PAXGy Funds Automation Vault";
    string constant SYMBOL = "PFAV";
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    uint8 constant DECIMALS = 18;

    // ---- Basket tokens (Ethereum mainnet). USDC is inherited from Constants.sol. ----
    address constant USDG = 0xe343167631d89B6Ffc58B88d6b7fB0228795491D; // Global Dollar (USDG), 6 decimals
    address constant PAXG = 0x45804880De22913dAFE09f4980848ECE6EcbAf78; // Pax Gold (PAXG), 18 decimals

    // ---- Chainlink PAXG/USD price feed (proxy) on Ethereum mainnet. Verified on-chain: description() is
    //      "PAXG / USD" and decimals() is 8. The reference asset for the whole basket is USD. ----
    IPriceFeed constant PAXG_USD_FEED = IPriceFeed(0x9944D86CEB9160aF5C5feB251FD671923323f8C3);
    string constant PAXG_USD_DESCRIPTION = "PAXG / USD"; // must byte-match PAXG_USD_FEED.description()
    uint8 constant PAXG_USD_RATE_DECIMALS = 8; // feed decimals; also the basket rateDecimals for PAXG
    // The Chainlink PAXG/USD feed's heartbeat is 86400s (24h); we add 100s to account for block delay.
    uint256 constant PAXG_USD_MAX_STALENESS = 86_500;

    function run() public broadcast {
        // Every hardcoded address below (USDC, USDG, PAXG, the PAXG/USD feed, BALANCER_VAULT) is
        // Ethereum-mainnet-specific and is NOT shared cross-chain: e.g. USDG's mainnet address is an
        // unrelated token ("FLX") on Arbitrum, and PAXG/USDC/the feed all differ per chain. Fail loudly on
        // any other chain rather than deploying a basket around the wrong tokens.
        require(block.chainid == 1, "DeployBoringVaultAndManager: Ethereum mainnet only");

        // Salts are computed here (not as state-variable initializers) so `broadcaster` is already set;
        // otherwise they would encode address(0), CreateX's squattable permissionless form.
        bytes32 SALT_ROLES_AUTHORITY = makeSalt(broadcaster, false, "PaxgyFundsAutomationVault: RolesAuthority");
        bytes32 SALT_BORING_VAULT = makeSalt(broadcaster, false, "PaxgyFundsAutomationVault: BoringVault");
        bytes32 SALT_MANAGER_WITH_MERKLE_VERIFICATION =
            makeSalt(broadcaster, false, "PaxgyFundsAutomationVault: ManagerWithMerkleVerification");
        bytes32 SALT_EQUIVALENT_EXCHANGE_UMANAGER =
            makeSalt(broadcaster, false, "PaxgyFundsAutomationVault: EquivalentExchangeUManager");
        bytes32 SALT_PAXG_USD_RATE_PROVIDER =
            makeSalt(broadcaster, false, "PaxgyFundsAutomationVault: PaxgUsdRateProvider");

        // deploy a roles authority
        RolesAuthority rolesAuthority = RolesAuthority(
            CREATEX.deployCreate3(
                SALT_ROLES_AUTHORITY,
                abi.encodePacked(type(RolesAuthority).creationCode, abi.encode(broadcaster, Authority(address(0))))
            )
        );

        // deploy a boring vault
        address boringVaultAddress = CREATEX.deployCreate3(
            SALT_BORING_VAULT,
            abi.encodePacked(type(BoringVault).creationCode, abi.encode(broadcaster, NAME, SYMBOL, DECIMALS))
        );
        BoringVault boringVault = BoringVault(payable(boringVaultAddress));

        // deploy a managerWithMerkleVerification
        ManagerWithMerkleVerification managerWithMerkleVerification = ManagerWithMerkleVerification(
            CREATEX.deployCreate3(
                SALT_MANAGER_WITH_MERKLE_VERIFICATION,
                abi.encodePacked(
                    type(ManagerWithMerkleVerification).creationCode,
                    abi.encode(broadcaster, address(boringVault), BALANCER_VAULT)
                )
            )
        );

        // Set Authority
        boringVault.setAuthority(rolesAuthority);
        managerWithMerkleVerification.setAuthority(rolesAuthority);

        // configure the roles
        rolesAuthority.setRoleCapability(
            MANAGER_ROLE,
            address(boringVault),
            bytes4(keccak256(abi.encodePacked("manage(address,bytes,uint256)"))),
            true
        );

        rolesAuthority.setRoleCapability(
            MANAGER_ROLE,
            address(boringVault),
            bytes4(keccak256(abi.encodePacked("manage(address[],bytes[],uint256[])"))),
            true
        );
        rolesAuthority.setRoleCapability(
            STRATEGIST_ROLE,
            address(managerWithMerkleVerification),
            ManagerWithMerkleVerification.manageVaultWithMerkleVerification.selector,
            true
        );

        rolesAuthority.setUserRole(address(managerWithMerkleVerification), MANAGER_ROLE, true);
        // TODO: uncomment STRATEGIST_ADDRESS and the setUserRole call below to grant STRATEGIST_ROLE before
        // mainnet.
        // address STRATEGIST_ADDRESS = address(0);
        // rolesAuthority.setUserRole(STRATEGIST_ADDRESS, STRATEGIST_ROLE, true);

        // Deploy the EquivalentExchangeUManager that drives this vault through the merkle-verification
        // manager. Deployed owned by the broadcaster so its authority can be wired here before it is handed
        // to the multisig alongside the other contracts below. Every RolesAuthority mutation must precede
        // the rolesAuthority ownership transfer further down.
        EquivalentExchangeUManager equivalentExchangeUManager = EquivalentExchangeUManager(
            CREATEX.deployCreate3(
                SALT_EQUIVALENT_EXCHANGE_UMANAGER,
                abi.encodePacked(
                    type(EquivalentExchangeUManager).creationCode,
                    abi.encode(broadcaster, address(managerWithMerkleVerification))
                )
            )
        );

        // Point the UManager at the shared RolesAuthority (its constructor hardcodes Authority(0), i.e.
        // owner-only) and grant the roles it needs:
        //   - execute() is callable by STRATEGIST_ROLE holders (the strategist granted above); setBasketTokens
        //     is given no role capability, so it stays owner-only (the multisig, after the transfer below).
        //   - the UManager itself holds STRATEGIST_ROLE so it may call manageVaultWithMerkleVerification.
        equivalentExchangeUManager.setAuthority(rolesAuthority);
        rolesAuthority.setRoleCapability(
            STRATEGIST_ROLE, address(equivalentExchangeUManager), EquivalentExchangeUManager.execute.selector, true
        );
        rolesAuthority.setUserRole(address(equivalentExchangeUManager), STRATEGIST_ROLE, true);

        // Deploy the PAXG/USD oracle: a Chainlink adapter that decodes latestRoundData, staleness-guards,
        // SafeCasts (rejecting negative prices), and scales to RATE_DECIMALS. GenericRateProvider is unsuitable
        // (no staleness, and it would misdecode Chainlink's tuple), so EthPerTokenRateProvider is used -- its
        // "Eth" naming is cosmetic; the pair here is USD, validated against the feed's description() below.
        EthPerTokenRateProvider paxgUsdOracle = EthPerTokenRateProvider(
            CREATEX.deployCreate3(
                SALT_PAXG_USD_RATE_PROVIDER,
                abi.encodePacked(
                    type(EthPerTokenRateProvider).creationCode,
                    abi.encode(
                        PAXG_USD_DESCRIPTION,
                        PAXG_USD_FEED,
                        PAXG_USD_MAX_STALENESS,
                        PAXG_USD_RATE_DECIMALS,
                        EthPerTokenRateProvider.PriceFeedType.CHAINLINK
                    )
                )
            )
        );
        // Liveness/sanity: the feed must return a positive rate now, or the deploy fails here rather than at
        // the strategist's first execute().
        require(paxgUsdOracle.getRate() > 0, "PAXG/USD oracle not live");

        // Configure the accounting basket while the broadcaster still owns the UManager (setBasketTokens is
        // owner-gated and ownership moves to the multisig below). Reference asset is USD: USDC and USDG peg to
        // ~$1 and need no oracle; PAXG is priced through the Chainlink adapter above.
        EquivalentExchangeUManager.BasketToken[] memory basket = new EquivalentExchangeUManager.BasketToken[](3);
        basket[0] = EquivalentExchangeUManager.BasketToken({
            token: ERC20(USDC),
            config: EquivalentExchangeUManager.RateProviderConfig({
                isPeggedToken: true, rateProvider: IRateProvider(address(0)), rateDecimals: 0
            })
        });
        basket[1] = EquivalentExchangeUManager.BasketToken({
            token: ERC20(USDG),
            config: EquivalentExchangeUManager.RateProviderConfig({
                isPeggedToken: true, rateProvider: IRateProvider(address(0)), rateDecimals: 0
            })
        });
        basket[2] = EquivalentExchangeUManager.BasketToken({
            token: ERC20(PAXG),
            config: EquivalentExchangeUManager.RateProviderConfig({
                isPeggedToken: false,
                rateProvider: IRateProvider(address(paxgUsdOracle)),
                rateDecimals: PAXG_USD_RATE_DECIMALS
            })
        });
        equivalentExchangeUManager.setBasketTokens(basket);

        // Transfer ownership to the multisig
        rolesAuthority.transferOwnership(getMultisig());
        boringVault.transferOwnership(getMultisig());
        managerWithMerkleVerification.transferOwnership(getMultisig());
        equivalentExchangeUManager.transferOwnership(getMultisig());

        // Post-deploy checks for the UManager wiring.
        require(
            address(equivalentExchangeUManager.authority()) == address(rolesAuthority),
            "uManager authority should be rolesAuthority"
        );
        require(equivalentExchangeUManager.owner() == getMultisig(), "uManager owner should be multisig");
        require(
            rolesAuthority.doesUserHaveRole(address(equivalentExchangeUManager), STRATEGIST_ROLE),
            "uManager should have STRATEGIST_ROLE"
        );
        require(equivalentExchangeUManager.getBasketTokens().length == 3, "basket should have 3 tokens");
        require(equivalentExchangeUManager.isBasketToken(ERC20(USDC)), "USDC should be in basket");
        require(equivalentExchangeUManager.isBasketToken(ERC20(USDG)), "USDG should be in basket");
        require(equivalentExchangeUManager.isBasketToken(ERC20(PAXG)), "PAXG should be in basket");

        console.log("vault deployed at: ", address(boringVault));
        console.log("Roles Authority deployed at: ", address(rolesAuthority));
        console.log("Manager With Merkle Verification deployed at: ", address(managerWithMerkleVerification));
        console.log("Equivalent Exchange UManager deployed at: ", address(equivalentExchangeUManager));
        console.log("PAXG/USD RateProvider deployed at: ", address(paxgUsdOracle));
    }

}
