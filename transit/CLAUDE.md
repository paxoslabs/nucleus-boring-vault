# Transit Project

## Status
`TransitStation.sol` written and rearchitected to the **server-approved quote** model
(2026-06-02). Compiles. No tests, no NatSpec yet (per user: "optimize for the meat,
polish later"). Source-of-truth design is `transit/DESIGN.md` (updated 2026-06-03 to KDDs 1–24,
reflecting the server-signed-quote + onchain-route-allowlist model — now in sync with the code).

## Architecture: server-approved quotes (current)
The contract holds **no fee or route configuration**. Instead the PXL backend authenticates
integrators by API key, computes fees + the offer→want rate dynamically, and signs a `Quote`.
`submitOrder` verifies that the quote was signed by the trusted `quoteSigner` (a single,
owner-settable address), enforces an immutable `MAX_FEE_BPS` cap, **checks the route against an
on-chain global allowlist**, collects funds, and dispatches. This deletes the old *fee* config
and the per-enterprise policy system (RouteConfig, signerPolicies, routeConfigForPolicy,
_calcFees, setPolicyRoutes, setSignerPolicies, DEFAULT_POLICY) — but **keeps a global on-chain
route allowlist** (`approvedRoutes`).

**Route allowlist (re-added 2026-06-02).** `mapping(uint32 destEID => mapping(address offerAsset => mapping(address wantAsset => bool))) approvedRoutes` —
global per station, NOT per enterprise. Set via `setRouteApprovals(Route[], bool[])`. Enforced in
**both** `submitOrder` (source) and `_lzReceive` (destination, reconstructing the route with
destEID = thisChainEID) so a compromised backend can only ever land orders for globally-approved
asset pairs. **No merkle root** — a mapping gives O(1) white/blacklist + on-chain getters.
Caveat: a disallowed route in `_lzReceive` reverts and strands that LZ message (deposit stays
safe + admin-refundable on source); only fires on config mismatch / attack.

**Residual risk to remember:** the route allowlist constrains *which assets*, not *how much* —
a compromised `quoteSigner` can still manipulate `amountDue` (rate) within an approved route. Real
backstops there: EXECUTOR refusing to fulfill (**keep quoteSigner and EXECUTOR keys separate**),
off-chain rate limits (KDD 9), and `MAX_FEE_BPS` (fees only). Trade-off accepted: fees opaque
on-chain; integrators depend on PXL infra; compromised `quoteSigner` rotatable via `setQuoteSigner`.

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

Constructor: `(address _owner, Authority _authority, address _endpoint, address _protocolFeeRecipient, address _quoteSigner)`. Zero-address checks on `_owner`/`_protocolFeeRecipient`/`_quoteSigner`; code-existence check on `_authority` (interface dep). `thisChainEID` is fetched from `endpoint.eid()` rather than passed in.

Structs:
- `Route { uint32 destEID; address offerAsset; address wantAsset; }`
- `Order { bytes32 uuid; address wantAsset; uint256 amountDue; address receiver; uint32 sourceEID; address offerAsset; uint256 offerAmount; uint64 receiveTime; }` — `amountDue` is in **wantAsset units** (the quote's rate), resolving the old units ambiguity.
- (No `PeerChain` struct — pruned 2026-06-03. Per-EID LZ gas is a single `mapping(uint32 => uint64) messageGasLimit`.)
- `Quote { Route route; uint256 offerAmount; uint256 amountDue; address receiver; uint256 fee; address payer; uint256 deadline; bytes32 salt; }` — backend-signed. `fee` is a single total in offerAsset units; `amountDue` is wantAsset units; `payer` must == msg.sender.

Storage:
- `mapping(uint32 => uint64) messageGasLimit` — per-destination-EID LZ executor gas for the peer's lzReceive. (Per-chain allowlisting + peer authenticity now come entirely from LZ's own `peers` mapping + `setPeer`; route/asset gating from `approvedRoutes`. The old `PeerChain` allowFrom/allowTo/peerStation were all redundant — pruned.)
- `address quoteSigner` — the single trusted backend signer (owner-settable via `setQuoteSigner`).
- `address protocolFeeRecipient` — single fee recipient (point at a splitter to divide PXL/integrator on-chain).
- `mapping(uint32 => mapping(address => mapping(address => bool))) approvedRoutes` — global per-station directional route allowlist (`destEID => offerAsset => wantAsset`). Nested (not a routeHash) so callers can read `approvedRoutes(eid, offer, want)` directly.
- `mapping(bytes32 => bool) usedDigests` — replay protection.
- `EnumerableSet.Bytes32Set pendingOrderIds` + `mapping(bytes32 => Order) pendingOrders` (per KDD 2)

Constants:
- `ONE_HUNDRED_PERCENT = 10_000` (basis-points denominator)
- `MAX_FEE_BPS = 50` (0.5%) — hardcoded immutable fee cap; bounds blast radius of a compromised `quoteSigner`. Not owner-settable by design.

Functions (meat only):
- `submitOrder(Quote quote, bytes signature) payable` — user-facing. `_verifyAndCollect` checks deadline, `msg.sender == quote.payer`, **route is in `approvedRoutes`** (else `RouteNotApproved`), `fee <= offerAmount * MAX_FEE_BPS / 10_000`, recovers signer from `keccak256(chainId, addr(this), quote)` and requires `== quoteSigner` (else `InvalidSigner(recovered)`), marks `usedDigests[digest]` (else `SignatureAlreadyUsed`), pulls `offerAmount`, pays `fee` to `protocolFeeRecipient`. Then builds the Order from the quote and dispatches local-or-LZ. **Every order now requires a valid quote — no unsigned/DEFAULT path.**
- `setRouteApprovals(Route[] routes, bool[] approved) requiresAuth` — batched, length-checked global route white/blacklist.
- `executePendingOrders(bytes32[] uuids, uint256[] amounts) requiresAuth` — EXECUTOR fulfills by `safeTransfer`-ing wantAsset from the station's own balance to the receiver (KDD 20 custody), decrements `amountDue`, removes when zero (KDD 8 partial fills). Units consistent (amountDue is wantAsset). Reverts the batch on any failure with the offending `uuid` (`OrderNotFound(uuid)` / `AmountExceedsDue(uuid)`, KDD 19).
- `forceRemovePendingOrder(bytes32 uuid) requiresAuth` — force-remove, full only (KDD D).
- `recoverETH(uint256) requiresAuth` / `recoverTokens(ERC20, uint256) requiresAuth` — to owner.
- `setProtocolFeeRecipient(addr) requiresAuth` (zero-checked), `setQuoteSigner(addr) requiresAuth` (zero-checked; no code check — it's an EOA key), `setMessageGasLimit(eid, uint64) requiresAuth`.
- `_lzReceive` — decodes `Order`, **re-validates the route against `approvedRoutes`** (destEID = thisChainEID), stamps `receiveTime`, pushes to set. Sender authenticity is enforced upstream by `OAppAuthReceiver.lzReceive` (`peers[srcEid]`); no separate `allowFrom` gate.
- `quoteSend(destEID, Order) view` — LZ fee preview.
- Views: `getPendingOrderIds`, `pendingOrderCount`, plus the public `pendingOrders`/`usedDigests` mappings and the nested `approvedRoutes(eid, offer, want)` auto-getter (replaced the old `isRouteApproved(Route)` helper).

Fee model: a single `fee` (offerAsset units) is computed off-chain and signed into the quote; the contract only enforces `fee <= offerAmount * MAX_FEE_BPS / ONE_HUNDRED_PERCENT` and pays it to `protocolFeeRecipient`. The receiver is owed `quote.amountDue` (wantAsset units). The offer residual (`offerAmount - fee`) stays in the contract under vault custody on the source chain.

UUID generation: `keccak256(thisChainEID, address(this), user, ++orderNonce)`.

## Open questions / things I flagged to the user
1. **Signature scheme (server-approved quotes).** Digest is `keccak256(block.chainid, address(this), quote)`, ecrecovered and required to equal the single `quoteSigner`. Replay protection via `usedDigests` + `quote.salt`; `quote.deadline` bounds validity window; `quote.payer` must == msg.sender. **Still open for polish:** move to EIP-712 typed/domain-separated digest (CLAUDE.md C11) instead of raw keccak. Rearchitected 2026-06-02.
2. **`amountDue` units — RESOLVED.** Now unambiguously **wantAsset units**, carried in the signed quote (the backend provides the rate). `executePendingOrders` transfers wantAsset and decrements `amountDue` in matching units.
3. **Station custody — RESOLVED (KDD 20, 2026-06-03).** `executePendingOrders` now pays the want asset via `safeTransfer` from the **station's own pre-positioned balance** (not pulled from the executor). The station custodies both the deposited offer assets and the want-asset fulfillment liquidity; the EXECUTOR only authorizes release. Implies the station must be pre-funded with want-asset liquidity (offchain/backend responsibility), and accumulated offer assets are swept via `recoverTokens`/rebalancing.
4. **`PeerChain` — RESOLVED (pruned 2026-06-03).** `peerStation` was redundant with LZ's `peers` mapping; `allowTo` was redundant with `approvedRoutes` (destEID is in the route); `allowFrom` was redundant with LZ `setPeer` (per-chain on/off) since `srcEid` adds no asset dimension. `minimumMessageGas` was dead (gas isn't caller-provided here). The whole struct collapsed to `mapping(uint32 => uint64) messageGasLimit`. Trade-off accepted: lost the reversible directional pause (use `setPeer(eid, 0)` for a per-chain kill-switch instead).
5. **Fee cap — RESOLVED.** `MAX_FEE_BPS = 50` (0.5%), hardcoded immutable, enforced on the quote's single `fee` vs `offerAmount`. A compromised `quoteSigner` is bounded by the cap (fees) and rotatable via `setQuoteSigner`.
6. **Routing — on-chain global allowlist (re-added).** `approvedRoutes` mapping enforced on source + destination (no merkle). Constrains *which* asset pairs but NOT `amountDue`/rate — see residual-risk note in the architecture section (keep quoteSigner ≠ EXECUTOR keys).
7. **Reentrancy handled via CEI, not guards (decided 2026-06-03).** No `nonReentrant` modifier — Carson explicitly chose checks-effects-interactions over a guard. `executePendingOrders` now settles order state (decrement / remove+delete) BEFORE the want-asset `safeTransfer`, caching `wantAsset`/`receiver`/`remaining` first. `submitOrder` marks `usedDigests[digest]` before any token transfer (the replay-critical effect); the order is recorded after the offer pull, which is benign (orders aren't executable until a separate EXECUTOR tx, and `executePendingOrders`/`_lzReceive` aren't reenterable by an arbitrary caller).
8. **`recoverETH`** uses low-level call to owner — non-reentrant by trust assumption (owner is trusted).
9. **No event for `setPeer` / `transferOwnership`** at the Transit layer — inherited from `OAppAuthCore` / `Auth`.
10. **Did NOT add NatSpec** per user instruction. Will add in polish pass.
11. **Did NOT factor out a base contract** like the teller's `MultiChain*` split. Single file for first draft; can refactor when patterns repeat.
12. **Min order size (KDD 10/15) is NOT enforced on-chain.** The quote redesign deleted `RouteConfig.minAmount`; min is currently only enforceable off-chain (backend won't sign below it). KDDs 10/15 say per-route min on the source chain — needs a decision: keep off-chain, or re-add a per-route `minAmount` mapping. OPEN.

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
**Transit Stations** are per-chain smart contracts that let a user deposit one asset (e.g., USDC) and request a different asset on the same or a different chain (e.g., USDG on Ethereum). The actual swap is orchestrated off-chain by a privileged executor. On submission, the user presents a `Quote` signed by the PXL backend (which authenticated their integrator API key, picked the route, and priced fees + rate). The station verifies the signature against `quoteSigner`, enforces `MAX_FEE_BPS`, deducts the quote's `fee` to `protocolFeeRecipient`, and either:
- records a pending order locally (single-chain), or
- sends a LayerZero message containing the **full order data** to the destination station (cross-chain).

The destination station's `_lzReceive` validates the route and places the order in an `EnumerableSet` of order UUIDs mapped to `Order` structs. Backend iterates and batch-fulfills, with partial fills supported (decrement `amountDue` until zero, then remove). Fulfillment is permissioned via RolesAuthority `EXECUTOR` — users never pull funds. Contracts are immutable (no upgradeability). No user-initiated refunds, no order expiry, no on-chain max-size (off-chain rate limit guards LZ reorg risk). Owner can force-remove orders and recover stray ETH/ERC20s; vault retains custody/refund authority.

## Cross-Chain Handling — Important Nuance
Cross-chain is **message-passing only, never value-passing**:
1. Source station takes user's deposit + fees locally.
2. Source station emits a LayerZero message to destination station containing the **full order data** (asset, amount, receiver, source chain, etc. — per KDD 3, not just a hash).
3. Destination station's `_lzReceive` validates the route and records the order in its own pending-orders set — as if a single-chain order had been submitted there directly.
4. Executor fulfills out of **pre-positioned liquidity held in the destination station itself** (KDD 20 custody) — the off-chain orchestrator is responsible for funding the station; fulfillment is a `safeTransfer` from its balance.

Funds never bridge — the deposit sits in the source station and the wanted asset is paid from the destination station's own pre-positioned liquidity (KDD 20).

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

## Policy System — REMOVED (superseded 2026-06-02)
The on-chain policy system (`signerPolicies`, `routeConfigForPolicy`, `DEFAULT_POLICY`,
per-signer integrator keys, UniswapX-style `feFeePercent`) is **gone**. Fees, routing, and
integrator authentication now live entirely off-chain in the PXL backend, which signs a `Quote`.
See "Architecture: server-approved quotes" at the top. Frontend-fee cap is resolved as
`MAX_FEE_BPS`.

## Open Questions
- Concrete LZ block-confirmation number per source chain (KDD F is N/A — formula given, value TBD per deployment).
- Exact `Order` payload encoding for LZ (size affects `messageGas` defaults).
- EIP-712 migration for the quote digest (deferred polish).

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
- *2026-06-02*: **Rearchitected to server-approved quotes.** Backend authenticates integrators by API key, computes fees + rate, and signs a `Quote`; the contract holds no fee config and only verifies the signature against a single owner-settable `quoteSigner`. Deleted the whole policy system (RouteConfig/signerPolicies/routeConfigForPolicy/_calcFees/setPolicyRoutes/setSignerPolicies/DEFAULT_POLICY). Decisions: (1) single fee → single `protocolFeeRecipient` (splitter if division needed); (2) `MAX_FEE_BPS = 50` hardcoded immutable cap; (3) one `quoteSigner`, no signer set; (4) no unsigned/DEFAULT path — every order needs a quote; (5) `payer` bound to msg.sender, kept `usedDigests`+`salt`, added `deadline`. `amountDue` now in wantAsset units (resolves prior ambiguity). EIP-712 still deferred.
- *2026-06-02*: **Re-added on-chain route allowlist** (`approvedRoutes`, global per station, NOT per enterprise) after realizing off-chain-only routing leaves a compromised backend able to deposit/request unapproved assets. Mapping (no merkle), enforced on BOTH source (`submitOrder`) and destination (`_lzReceive`). Critique noted + accepted: this bounds *which assets*, not `amountDue`/rate — mitigated by keeping `quoteSigner` and EXECUTOR on separate keys + off-chain rate limits. `setRouteApprovals(Route[], bool[])` batch setter.
- *2026-06-03*: **Pruned `PeerChain` struct entirely** once `approvedRoutes` + LZ `peers` were in place — `peerStation`/`allowTo`/`allowFrom`/`minimumMessageGas` were all redundant or dead. `selectorToChains` → `mapping(uint32 => uint64) messageGasLimit`; `setPeerChain` → `setMessageGasLimit`; removed `ChainNotAllowedFrom/To`, `PeerStationNotSet`, `GasOutOfBounds` (added `GasLimitNotSet`). `_lzReceive` no longer checks `allowFrom` (LZ peer auth suffices); `_sendOrder` relies on `_getPeerOrRevert` for peer existence.
