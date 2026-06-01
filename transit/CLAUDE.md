# Transit Project

## Status
First draft of `TransitStation.sol` written. Compiles. No tests, no NatSpec yet
(per user: "optimize for the meat, polish later"). Source-of-truth design is in
`transit/DESIGN.md`.

## Where the code lives
- `src/transit/TransitStation.sol` — single concrete contract (no abstract layering yet;
  may break into base + concrete later, mirroring `MultiChainLayerZeroTellerWithMultiAssetSupport`).
- Imports `OAppAuth` directly from `src/base/Roles/CrossChain/OAppAuth/`. User noted this is clunky;
  these helpers will likely move to a shared `helpers/` location later.

## First-draft contract shape (TransitStation.sol)
Inheritance: `OAppAuth` only. `Auth` is initialized directly in the constructor
(`Auth(_owner, Authority(address(0)))`) because `OAppAuthCore` inherits `Auth` but
does **not** call its constructor — the teller relies on its other branch
(`TellerWithMultiAssetSupport`) to do it; we have no such branch.

Constructor: `(address _owner, address _endpoint, address _protocolFeeRecipient)`. The `thisChainEID` is fetched from `endpoint.eid()` (via `IMessagingChannel`) rather than passed in.

Structs:
- `Route { uint32 destEID; address offerAsset; address wantAsset; }`
- `RouteConfig { bool isSupported; uint256 flatFeeProtocol; uint256 percentFeeProtocolBps; uint256 flatFeeSigner; uint256 percentFeeSignerBps; uint256 minAmount; }`
- `Order { bytes32 uuid; address wantAsset; uint256 amountDue; address receiver; uint32 sourceEID; address offerAsset; uint256 offerAmount; uint64 receiveTime; }`
- `PeerChain { bool allowFrom; bool allowTo; address peerStation; uint64 messageGasLimit; uint64 minimumMessageGas; }`

Storage:
- `mapping(uint32 => PeerChain) selectorToChains` — per-EID allowlist + gas. (Note: LZ peer authenticity is enforced by the `OAppReceiver` `peers` mapping; `peerStation` here is currently informational/redundant — see open question.)
- `mapping(address => string) signerPolicies`
- `mapping(string => mapping(bytes32 routeHash => RouteConfig)) routeConfigForPolicy` (Route hashed to bytes32 because struct-keyed mappings aren't allowed)
- `EnumerableSet.Bytes32Set pendingOrderIds` + `mapping(bytes32 => Order) pendingOrders` (per KDD 2)

Constants:
- `ONE_HUNDRED_PERCENT = 10_000` (basis-points denominator)
- `DEFAULT_POLICY = "DEFAULT"`
- (No frontend-fee cap on-chain — design's open question is now deferred entirely.)

Functions (meat only):
- `submitOrder(route, amount, receiver, feFeePercentBps, salt, signature) payable` — user-facing. Resolves policy (empty sig → DEFAULT; otherwise `ecrecover` over `keccak256(chainId, addr(this), route, amount, receiver, feFeePercentBps, msg.sender, salt)`), validates route, pulls offerAsset, pays fees, builds Order, dispatches local-or-LZ. Split into helper `_validateAndCollect` to dodge stack-too-deep. Replay protection: the signed digest is recorded in `usedDigests` and rejected on reuse (`SignatureAlreadyUsed`); `salt` lets a legitimate repeat order be re-signed with a fresh value. `msg.sender` is still bound in the digest (signature is tied to the submitter).
- `executePendingOrders(bytes32[] uuids, uint256[] amounts) requiresAuth` — EXECUTOR pulls wantAsset from msg.sender to receiver, decrements `amountDue`, removes when zero (KDD 8 partial fills).
- `forceRemovePendingOrder(bytes32 uuid) requiresAuth` — owner only force-remove, full only (KDD D).
- `recoverETH(uint256) requiresAuth` / `recoverTokens(ERC20, uint256) requiresAuth` — to owner.
- `setPolicyRoutes(policy, Route[], RouteConfig[]) requiresAuth` — batch route config.
- `setSignerPolicies(address[] signers, string[] policies) requiresAuth` — batched, length-checked. `setProtocolFeeRecipient(addr) requiresAuth`, `setPeerChain(eid, PeerChain) requiresAuth`.
- `_lzReceive` — checks `allowFrom`, decodes `Order`, stamps `receiveTime`, pushes to set. LZ peer-sender authenticity is enforced upstream by `OAppAuthReceiver.lzReceive`.
- `quoteSend(destEID, Order) view` — fee preview.
- Views: `getRouteConfig`, `getPendingOrderIds`, `pendingOrderCount`, plus the public `pendingOrders` mapping.

Fee math (additive, per KDD B/C/E):
```
protocolFee = flatFeeProtocol + amount * percentFeeProtocolBps / ONE_HUNDRED_PERCENT
signerFee   = flatFeeSigner   + amount * (percentFeeSignerBps + feFeePercentBps) / ONE_HUNDRED_PERCENT
net         = amount - protocolFee - signerFee
```
`net` is the value stored as both `amountDue` and `offerAmount`.

UUID generation: `keccak256(thisChainEID, address(this), user, ++orderNonce)`.

## Open questions / things I flagged to the user
1. **Signature scheme (partly resolved).** Digest is `keccak256(block.chainid, address(this), route, amount, receiver, feFeePercentBps, msg.sender, salt)`, ecrecovered. **Replay protection now exists** via the `usedDigests` mapping + caller-supplied `salt` (single-use signed quotes; chose the used-digest+salt approach over a Permit2-style nonce bitmap for simplicity — same security, simpler ops, slightly more gas per sig). `msg.sender` is intentionally kept in the digest (signature bound to submitter — decided NOT to make it a relayer/meta-tx model). **Still open for polish:** (a) move to EIP-712 typed/domain-separated digest (CLAUDE.md C11) instead of raw keccak; (b) add a `deadline`/expiry so a signed quote can't be redeemed indefinitely. Decided 2026-05-29.
2. **`amountDue` units ambiguity.** `amountDue` is stored in offer-asset units (the post-fee `net`). But `executePendingOrders` transfers `wantAsset` to the receiver and decrements `amountDue` by the same units. This implies the executor does rate conversion off-chain and provides matching amounts in offer-asset units. **The design doc doesn't specify which units `amountDue` is in.** Worth clarifying — current draft assumes off-chain rate handling, but if it's want-asset units, the storage and the fee/net math need to change.
3. **`executePendingOrders` pulls `wantAsset` from `msg.sender` (the executor).** Design says "vault retains custody". Probably fine — executor pulls from a vault address by setting an approval — but if we want the contract to hold liquidity itself, this changes.
4. **`PeerChain.peerStation` is redundant with LZ's `peers` mapping.** `OAppAuthReceiver.lzReceive` already enforces `_origin.sender == peers[srcEid]`. We can either: (a) keep `peerStation` as a sanity-check mirror that admin sets in sync with `setPeer`, or (b) drop it. Keeping for now to keep `selectorToChains` self-describing.
5. **Frontend fee is currently uncapped on-chain.** The design doc flagged a cap as an open question; we explicitly chose to leave it off the contract for now (caller-side / off-chain caller is responsible). Revisit if we want to harden against misconfigured frontends.
6. **No reentrancy guards anywhere.** ERC20 transfers can reenter via ERC-777 / hooks (CLAUDE.md D7). For first draft I left them off — should add `nonReentrant` on `submitOrder` and `executePendingOrders` once the shape is settled.
7. **`recoverETH`** uses low-level call to owner — non-reentrant by trust assumption (owner is trusted).
8. **No event for `setPeer` / `transferOwnership`** at the Transit layer — inherited from `OAppAuthCore` / `Auth`.
9. **Did NOT add NatSpec** per user instruction. Will add in polish pass.
10. **Did NOT factor out a base contract** like the teller's `MultiChain*` split. Single file for first draft; can refactor when patterns repeat.

## Existing LayerZero Infrastructure to Reuse
The repo already has a production LZ pattern in `src/base/Roles/CrossChain/`. We will reuse this directly:

- **`OAppAuth/`** (`OAppAuth.sol`, `OAppAuthCore.sol`, `OAppAuthSender.sol`, `OAppAuthReceiver.sol`)
  - Local fork of LZ's OApp that uses Solmate `Auth` instead of OZ `Ownable`.
  - Constructor: `(address _endpoint, address _delegate)`.
  - `OAppAuthCore` inherits `Auth` but does NOT call its constructor; child must.
  - Receiver enforces `peers[srcEid] == _origin.sender` before calling `_lzReceive`.

- **`CrossChainTellerBase.sol`** — abstract bridge contract pattern (reference only, not directly used).
- **`MultiChainTellerBase.sol`** — per-chain config & admin (reference; we replicated the `selectorToChains` idea with our own `PeerChain` struct).
- **`MultiChainLayerZeroTellerWithMultiAssetSupport.sol`** — the canonical concrete LZ impl we patterned after.
- **Shared types in `src/interfaces/ICrossChainTypes.sol`** — `BridgeData`, `Chain`. Not directly used by Transit (we have our own richer types) but kept as a future option.

## What We're Building (One-Paragraph Summary)
**Transit Stations** are per-chain smart contracts that let a user deposit one asset (e.g., USDC) and request a different asset on the same or a different chain (e.g., USDG on Ethereum). The actual swap is orchestrated off-chain by a privileged executor. On submission, the station validates the route against a per-policy config (`route = destEID + offerAsset + wantAsset`), deducts protocol + signer/frontend fees (additive: flat + percent, with the frontend optionally signing in a custom fee à la UniswapX), and either:
- records a pending order locally (single-chain), or
- sends a LayerZero message containing the **full order data** to the destination station (cross-chain).

The destination station's `_lzReceive` validates the route and places the order in an `EnumerableSet` of order UUIDs mapped to `Order` structs. Backend iterates and batch-fulfills, with partial fills supported (decrement `amountDue` until zero, then remove). Fulfillment is permissioned via RolesAuthority `EXECUTOR` — users never pull funds. Contracts are immutable (no upgradeability). No user-initiated refunds, no order expiry, no on-chain max-size (off-chain rate limit guards LZ reorg risk). Owner can force-remove orders and recover stray ETH/ERC20s; vault retains custody/refund authority.

## Cross-Chain Handling — Important Nuance
Cross-chain is **message-passing only, never value-passing**:
1. Source station takes user's deposit + fees locally.
2. Source station emits a LayerZero message to destination station containing the **full order data** (asset, amount, receiver, source chain, etc. — per KDD 3, not just a hash).
3. Destination station's `_lzReceive` validates the route and records the order in its own pending-orders set — as if a single-chain order had been submitted there directly.
4. Executor fulfills out of **pre-positioned liquidity** that the off-chain orchestrator/vault is responsible for having at the destination.

Funds never bridge — they sit on the source chain (under vault control) and the wanted asset is paid from destination-side liquidity.

### LZ choice (KDD 4)
LayerZero over CCIP for configurable block confirmations / latency. 3 DVNs assumed for security. Formula for delivery time: `(srcBlockTime × confirmations) + (destBlockTime × (2 + numDVNs))`.

## Existing LayerZero Infrastructure to Reuse
The repo already has a production LZ pattern in `src/base/Roles/CrossChain/`. We will reuse this directly:

- **`OAppAuth/`** (`OAppAuth.sol`, `OAppAuthCore.sol`, `OAppAuthSender.sol`, `OAppAuthReceiver.sol`)
  - Local fork of LZ's OApp that uses Solmate `Auth` instead of OZ `Ownable`.
  - Constructor: `(address _endpoint, address _delegate)`.
  - Already required by the design doc (Libraries section).

- **`CrossChainTellerBase.sol`** — abstract bridge contract pattern:
  - Virtual `_bridge`, `_quote`, `_beforeBridge`, `_afterBridge`, `_beforeReceive`, `_afterReceive`.
  - Emits `MessageSent` / `MessageReceived`.
  - *Not directly inheritable for Transit (teller-specific), but the hook layering pattern is the template.*

- **`MultiChainTellerBase.sol`** — per-chain config & admin:
  - `mapping(uint32 => Chain) selectorToChains` keyed by LZ EID.
  - Admin: `addChain`, `removeChain`, `allowMessagesFromChain`, `allowMessagesToChain`, `stopMessagesFrom/ToChain`, `setChainGasLimit`. All `requiresAuth`.
  - `_beforeBridge` enforces: chain allowed-to, non-zero target/receiver, gas within `[minimumMessageGas, messageGasLimit]`.

- **`MultiChainLayerZeroTellerWithMultiAssetSupport.sol`** — concrete LZ impl, our reference:
  - Inherits `MultiChainTellerBase` + `OAppAuth`.
  - `_bridge`: `abi.encode(payload)` → `OptionsBuilder.newOptions().addExecutorLzReceiveOption(messageGas, 0)` → `_lzSend(chainSelector, payload, options, MessagingFee(msg.value, 0), refund=msg.sender)`. Native gas only.
  - `_lzReceive`: validates `selectorToChains[_origin.srcEid].allowMessagesFrom`, decodes payload, runs receive hooks, performs destination-side action (for teller: `vault.enter(...)`; for Transit: push order into pending set).

- **Shared types in `src/interfaces/ICrossChainTypes.sol`**:
  ```solidity
  struct BridgeData { uint32 chainSelector; address destinationChainReceiver; ERC20 bridgeFeeToken; uint64 messageGas; bytes data; }
  struct Chain { bool allowMessagesFrom; bool allowMessagesTo; address targetTeller; uint64 messageGasLimit; uint64 minimumMessageGas; }
  ```
  Transit will likely need its own richer payload type (full order data) but can reuse `Chain` for per-EID allowlisting verbatim.

### Translation: Teller → Transit Station
| Teller concept | Transit equivalent |
|---|---|
| `shareAmount` payload | Full `Order` struct (asset, amount, receiver, srcChain, offerAsset, offerAmount, receiveTime, UUID) |
| `vault.enter(..., receiver, shareAmount)` in `_lzReceive` | Push order into `EnumerableSet` + `mapping(bytes32 => Order)` |
| `selectorToChains[].targetTeller` allowlist | Same pattern — only accept messages from the known peer Transit station per EID |
| `BridgeData.messageGas` / `OptionsBuilder` | Same — required because destination payload size is larger, so gas limits matter more |
| `requiresAuth` on `bridge()` | On Transit, `submitOrder` is **user-facing** (not authed) but `executePendingOrders` is `requiresAuth` (EXECUTOR role) |

## Key Design Decisions (Quick Reference — see DESIGN.md for full context)
- KDD 1: Per-chain mapping config, **no merkle root**.
- KDD 2: `EnumerableSet<bytes32>` of UUIDs + `mapping(bytes32 => Order)`. **No swap-and-pop** (breaks batch processing).
- KDD 3: Bridge **full** order data, not hashes.
- KDD 4: **LZ** over CCIP.
- KDD 5: **Not upgradeable** — new versions are new deployments.
- KDD 6/7: **No on-chain refunds** (user or protocol-initiated); admin force-remove only.
- KDD 8: **Partial fills allowed** at smart-contract level; min applies per order, not per fill.
- KDD 9: **No on-chain max size**; rate limits live off-chain.
- KDD 10: **Per-route minimum** order size.
- KDD 11: **No expiry**.
- KDD 12: Single-chain **and** cross-chain in the same contract.
- KDD A: **Privileged execution only** (EXECUTOR role).
- KDD B/C/E: **Additive flat + percent fees**, per route.
- KDD D: No partial force-remove.

## Policy System
- `mapping(address signer => string policy) signerPolicies`
- `mapping(string policy => mapping(Route => RouteConfig)) routeConfigForPolicy`
- `string constant DEFAULT_POLICY = "DEFAULT"`
- Signer = frontend integrator. Empty signature → DEFAULT policy. Valid signature → look up signer's policy. Frontends can also pass a `feFeePercent` in the call à la UniswapX.
- **Open question (DESIGN.md):** cap on frontend fee — should we have one, and at what number?

## Open Questions
- Frontend-fee cap value (above).
- Concrete LZ block-confirmation number per source chain (KDD F is N/A — formula given, value TBD per deployment).
- Exact `Order` payload encoding for LZ (size affects `messageGas` defaults).

## Where We Left Off
- First draft of `src/transit/TransitStation.sol` compiles. Pending user review.
- No tests written. No NatSpec. No abstract-base layering.
- **Next:** user review of draft → resolve open questions (esp. signature scheme + `amountDue` units) → tests → polish (NatSpec, possibly base/concrete split, reentrancy guards).

## Decisions Log
- *2026-05-28*: Transit Stations will reuse `OAppAuth` directly and follow the layered abstract-contract pattern from `MultiChainLayerZeroTellerWithMultiAssetSupport` (own `MultiChain*` base + concrete LZ contract), but with Transit-specific payload (full Order) and a per-EID peer-station allowlist mirroring `selectorToChains`.
- *2026-05-28*: First draft is a **single concrete contract** (no base/concrete split yet). Will refactor if/when a second variant or shared base emerges. Skipped NatSpec for review readability per user instruction.
- *2026-05-28*: Constructor calls `Auth`'s constructor directly (passing in the authority) because the only base contract is `OAppAuth`, and `OAppAuthCore` extends `Auth` without invoking its constructor (the teller's other branch normally provides it).
- *2026-05-28*: `Route` struct is hashed (`keccak256(abi.encode(destEID, offerAsset, wantAsset))`) for use as a mapping key, since Solidity doesn't allow struct-keyed mappings.
- *2026-05-29*: Constructor now takes `Authority` as a param (not defaulted to `address(0)`) since an EXECUTOR role is required from day one; added zero-address checks (`_owner`, `_protocolFeeRecipient`) and a code-existence check on `_authority`.
- *2026-05-29*: Signature replay protection = **used-digest map + caller `salt`** (not a nonce bitmap). Chose simplicity over the marginal gas savings of Permit2's bitmap. Kept `msg.sender` bound in the digest (not a relayer/meta-tx model). EIP-712 + `deadline` deferred to polish.
