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
owner-settable address), enforces an immutable `MAX_PROTOCOL_FEE_BPS` cap on the protocol fee, **checks the route against an
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
off-chain rate limits (KDD 9), and `MAX_PROTOCOL_FEE_BPS` (protocol fee only — `integratorFee` is uncapped). Trade-off accepted: fees opaque
on-chain; integrators depend on PXL infra; compromised `quoteSigner` rotatable via `setQuoteSigner`.

## Where the code lives
- `src/transit/TransitStation.sol` — single concrete contract (no abstract layering yet;
  may break into base + concrete later, mirroring `MultiChainLayerZeroTellerWithMultiAssetSupport`).
- Imports `OAppAuth` directly from `src/base/Roles/CrossChain/OAppAuth/`. User noted this is clunky;
  these helpers will likely move to a shared `helpers/` location later.

## First-draft contract shape (TransitStation.sol)
Inheritance: `OAppAuth, Pausable`. `Auth` is initialized directly in the constructor
(`Auth(_owner, _authority)`) because `OAppAuthCore` inherits `Auth` but does **not** call
its constructor — the teller relies on its other branch (`TellerWithMultiAssetSupport`) to do
it; we have no such branch. `Pausable` (`src/helper/Pausable.sol`) is the modified-OZ variant
(idempotent `_pause`) relocated out of `one-to-one-queue/access/` (cursed path).

Constructor: `(address _owner, Authority _authority, address _endpoint, address _protocolFeeRecipient, address _quoteSigner, address _offerReceiver, address _wantAssetSource)`. Zero-address checks on all of `_owner`/`_protocolFeeRecipient`/`_quoteSigner`/`_offerReceiver`/`_wantAssetSource`; code-existence check on `_authority` (interface dep). `thisChainEID` is fetched from `endpoint.eid()` rather than passed in.

Structs:
- `Route { uint32 destEID; address offerAsset; address wantAsset; }`
- `Order { bytes32 uuid; address wantAsset; uint256 amountDue; address receiver; uint32 sourceEID; address offerAsset; uint256 offerAmount; uint64 queuedAt; }` — `amountDue` is in **wantAsset units** (the quote's rate), resolving the old units ambiguity. `queuedAt` = block.timestamp the order was queued, stamped in `_pushOrder` (the only place an order enters a pending set). Invariant: `queuedAt != 0` ⟺ queued in this contract. So a cross-chain order's `OrderSubmitted` on the source shows `0` (not queued there; creation time = the event's block); the destination stamps the real time on receive. (Renamed `receiveTime`→`pendingSince`→`queuedAt`.)
- (No `PeerChain` struct — pruned 2026-06-03. Per-EID LZ gas is a single `mapping(uint32 => uint64) messageGasLimit`.)
- `Quote { Route route; uint256 offerAmount; uint256 amountDue; address receiver; uint256 protocolFee; uint256 integratorFee; address integratorFeeReceiver; uint256 deadline; bytes32 salt; }` — backend-signed. Two fees, both offerAsset units: `protocolFee` → `protocolFeeRecipient` (capped at `MAX_PROTOCOL_FEE_BPS`), `integratorFee` → `integratorFeeReceiver` (the frontend's own fee, **uncapped on-chain** — UniswapX-style). `amountDue` is wantAsset units. **Bearer** — no `payer` binding; anyone can submit (they pay `offerAmount`, want asset goes to the fixed `receiver`, so a griefer only burns their own funds).

Storage:
- `mapping(uint32 => uint64) messageGasLimit` — per-destination-EID LZ executor gas for the peer's lzReceive. (Per-chain allowlisting + peer authenticity now come entirely from LZ's own `peers` mapping + `setPeer`; route/asset gating from `approvedRoutes`. The old `PeerChain` allowFrom/allowTo/peerStation were all redundant — pruned.)
- `address quoteSigner` — the single trusted backend signer (owner-settable via `setQuoteSigner`).
- `address protocolFeeRecipient` — receives `protocolFee` (PXL's cut). The integrator's cut goes to the per-quote `integratorFeeReceiver` instead, so they're now separate on-chain (revises KDD 21's single-recipient decision).
- `address offerReceiver` — where the net deposit (`offerAmount - protocolFee - integratorFee`) is sent on submit; not held by the station (owner-settable via `setOfferReceiver`). In practice a BoringVault, but the contract only ERC20-transfers to it — role-named, not enforced as a vault.
- `address wantAssetSource` — the address `executePendingOrders` pulls the want asset FROM (via `transferFrom`) to the receiver; must approve the station (owner-settable via `setWantAssetSource`). KDD 26: the station custodies nothing — assets flow through, never rest.
- `mapping(uint32 => mapping(address => mapping(address => bool))) approvedRoutes` — global per-station directional route allowlist (`destEID => offerAsset => wantAsset`). Nested (not a routeHash) so callers can read `approvedRoutes(eid, offer, want)` directly.
- `mapping(bytes32 => bool) usedDigests` — replay protection.
- `EnumerableSet.Bytes32Set pendingOrderIds` + `mapping(bytes32 => Order) pendingOrders` (per KDD 2)

Constants:
- `ONE_HUNDRED_PERCENT = 10_000` (basis-points denominator)
- `MAX_PROTOCOL_FEE_BPS = 50` (0.5%) — hardcoded immutable cap on `protocolFee` only; bounds the protocol fee a compromised `quoteSigner` can charge. `integratorFee` is NOT capped. Not owner-settable by design.

Functions (meat only):
- `submitOrder(Quote quote, bytes signature) payable` — user-facing. `_verifyAndCollect` checks deadline, **route is in `approvedRoutes`** (else `RouteNotApproved`), `protocolFee <= offerAmount * MAX_PROTOCOL_FEE_BPS / 10_000` (else `FeeTooHigh`), `protocolFee + integratorFee < offerAmount` (else `FeesExceedOffer` — net to `offerReceiver` must be strictly positive), recovers the signer from the **EIP-712** digest (`ECDSA.recover`) and requires `== quoteSigner` (else `InvalidSigner(recovered)`), marks `usedDigests[digest]` (else `SignatureAlreadyUsed`), then pulls from msg.sender: `protocolFee` → `protocolFeeRecipient`, `integratorFee` → `integratorFeeReceiver`, and net (`offerAmount - protocolFee - integratorFee`) → `offerReceiver` (the station never custodies the offer asset). Then builds the Order and dispatches local-or-LZ. **Every order now requires a valid quote — no unsigned/DEFAULT path.**
- `submitOrderWithPermit(Quote quote, bytes signature, uint256 permitDeadline, uint8 v, bytes32 r, bytes32 s) payable` — same as `submitOrder` but first runs EIP-2612 `permit(msg.sender, address(this), offerAmount, ...)` so the user approves + submits in one tx. `try/catch` falls back to an allowance check (`PermitFailedAndAllowanceTooLow`) — handles permit front-running / already-approved. Shared core extracted into internal `_submitOrder` (so the permit path reuses it without an external self-call that would clobber `msg.sender`). Matches the Teller/OneToOneQueue pattern; permit spender is the station (it pulls the offer asset).
- `setRouteApprovals(Route[] routes, bool[] approved) requiresAuth` — batched, length-checked global route white/blacklist.
- `executePendingOrders(bytes32[] uuids, uint256[] amounts, address[] usedTokens) requiresAuth` — EXECUTOR fulfills by `safeTransferFrom`-ing wantAsset from `wantAssetSource` directly to the receiver (KDD 26 — station custodies nothing), decrements `amountDue`, removes when zero (KDD 8 partial fills). After the fills, asserts `allowance(wantAssetSource, this) == 0` for each token in `usedTokens` (else `ResidualApproval(token, remaining)`) — enforces no dangling approval (KDD 26). `usedTokens` = the distinct want assets the batch touched, passed by the backend (cheaper than on-chain dedup; same effective security since the vault sets approvals anyway). **Operational consequence: the vault must approve EXACTLY the per-token batch total before each execute, or it reverts.** Reverts the batch on any failure with the offending `uuid` (`OrderNotFound(uuid)` / `AmountExceedsDue(uuid)`, KDD 19).
- `forceRemovePendingOrder(bytes32 uuid) requiresAuth` — force-remove, full only (KDD D).
- `recoverETH(uint256) requiresAuth` / `recoverTokens(ERC20, uint256) requiresAuth` — to owner.
- `pause() requiresAuth` / `unpause() requiresAuth` — emergency stop via `Pausable` (`src/helper/Pausable.sol`, the modified-OZ one where `_pause` is idempotent). `whenNotPaused` gates `submitOrder` + `submitOrderWithPermit` only (the permissionless entrypoints). `executePendingOrders`/`_lzReceive` are intentionally NOT gated — execute is already EXECUTOR-gated, and gating `_lzReceive` would strand in-flight cross-chain orders. `paused()` is the public view.
- `setProtocolFeeRecipient(addr) requiresAuth` (zero-checked), `setQuoteSigner(addr) requiresAuth` (zero-checked; no code check — it's an EOA key), `setOfferReceiver(addr) requiresAuth` (zero-checked), `setWantAssetSource(addr) requiresAuth` (zero-checked), `setMessageGasLimit(eid, uint64) requiresAuth`.
- `_lzReceive` — decodes `Order`, **re-validates the route against `approvedRoutes`** (destEID = thisChainEID), pushes to set (`_pushOrder` stamps `queuedAt`). Sender authenticity is enforced upstream by `OAppAuthReceiver.lzReceive` (`peers[srcEid]`); no separate `allowFrom` gate.
- `quoteSend(destEID, Order) view` — LZ fee preview.
- Views: `getPendingOrderIds`, `pendingOrderCount`, plus the public `pendingOrders`/`usedDigests` mappings and the nested `approvedRoutes(eid, offer, want)` auto-getter (replaced the old `isRouteApproved(Route)` helper).

Fee model: two fees (offerAsset units), both computed off-chain and signed into the quote. `protocolFee` (PXL's cut) → `protocolFeeRecipient`, capped at `MAX_PROTOCOL_FEE_BPS`. `integratorFee` (the frontend's own UniswapX-style fee) → the per-quote `integratorFeeReceiver`, **uncapped on-chain** (the frontend charges its own users; users are protected by seeing `amountDue` in the quote before submitting). The receiver is owed `quote.amountDue` (wantAsset units). The net (`offerAmount - protocolFee - integratorFee`) is pulled to `offerReceiver` (in practice a BoringVault).

UUID generation: `keccak256(thisChainEID, address(this), user, ++orderNonce)`.

## Open questions / things I flagged to the user
1. **Signature scheme (server-approved quotes) — EIP-712 (done 2026-06-03).** Digest is the EIP-712 typed-data hash: domain `{name:"TransitStation", version:"1", chainId, verifyingContract}` (hand-rolled `_domainSeparator()` + `DOMAIN_TYPEHASH`) over `hashStruct(Quote)` (with nested `Route` sub-struct, `QUOTE_TYPEHASH`/`ROUTE_TYPEHASH`). Recovered via OZ `ECDSA.recover` and required to equal the single `quoteSigner` (else `InvalidSigner(recovered)`); malformed sigs revert with OZ's `ECDSAInvalidSignature*` errors. Did NOT inherit OZ's `EIP712` base — its `ShortStrings`→`StorageSlot` dep requires `^0.8.24` and the repo pins `0.8.21`, so the domain separator is computed inline (also fork-safe, chainId read live). Replay via `usedDigests` + `quote.salt`; `quote.deadline` bounds validity. Bearer (no `payer` — removed 2026-06-03; a third-party submitter pays `offerAmount` and the want asset goes to the fixed `receiver`, so reuse is only self-griefing), keeping relayer/gas-sponsor flows open. Backend signs with standard `signTypedData`. Rearchitected 2026-06-02.
2. **`amountDue` units — RESOLVED.** Now unambiguously **wantAsset units**, carried in the signed quote (the backend provides the rate). `executePendingOrders` transfers wantAsset and decrements `amountDue` in matching units.
3. **Custody — RESOLVED (KDD 26, 2026-06-04): station never custodies.** Supersedes KDD 20. Offer goes user→`offerReceiver` on submit; want is pulled `wantAssetSource`→receiver on execute. The station holds nothing between blocks. KDD 26 also treats a *dangling approval* as custody, and prefers approvals (pull) over transfers because the contract can enforce the remaining approval is 0 after execution (a balance check is defeatable — users can donate by setting receiver = station). **IMPLEMENTED (2026-06-04):** `executePendingOrders` takes `address[] usedTokens` and asserts `allowance(wantAssetSource, this) == 0` for each after the fills (`ResidualApproval`). Chose the backend-passed token list over on-chain dedup (O(n²), and buys no real security since the vault controls approvals — the check is an honest-operator guardrail against over-approval, not a defense against a compromised backend). **Operational cost: vault must approve exactly the per-token batch total before each execute.** (Temporary: `executePendingOrders2(uuids, amounts)` is a second variant that derives `usedTokens` on-chain via an O(n²) dedup instead of taking it as a param — kept side-by-side so Carson can gas-compare the two; one will be deleted.)
4. **`PeerChain` — RESOLVED (pruned 2026-06-03).** `peerStation` was redundant with LZ's `peers` mapping; `allowTo` was redundant with `approvedRoutes` (destEID is in the route); `allowFrom` was redundant with LZ `setPeer` (per-chain on/off) since `srcEid` adds no asset dimension. `minimumMessageGas` was dead (gas isn't caller-provided here). The whole struct collapsed to `mapping(uint32 => uint64) messageGasLimit`. Trade-off accepted: lost the reversible directional pause (use `setPeer(eid, 0)` for a per-chain kill-switch instead).
5. **Fee cap — RESOLVED (revised 2026-06-04).** Two fees: `protocolFee` capped at `MAX_PROTOCOL_FEE_BPS = 50` (0.5%, hardcoded immutable); `integratorFee` **uncapped on-chain** (Carson's call — it's the frontend's own fee, and users see `amountDue` before submitting). Residual-risk note: since `integratorFee` is signed by the same `quoteSigner`, a signer compromise can extract up to ~100% of a deposit via `integratorFee`/`integratorFeeReceiver` — `MAX_PROTOCOL_FEE_BPS` no longer bounds total extraction. Mitigations are the same as KDD 21's: separate EXECUTOR key + off-chain rate limits + refunds, plus users seeing `amountDue` upfront. Compromised `quoteSigner` rotatable via `setQuoteSigner`.
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
**Transit Stations** are per-chain smart contracts that let a user deposit one asset (e.g., USDC) and request a different asset on the same or a different chain (e.g., USDG on Ethereum). The actual swap is orchestrated off-chain by a privileged executor. On submission, the user presents a `Quote` signed by the PXL backend (which authenticated their integrator API key, picked the route, and priced fees + rate). The station verifies the signature against `quoteSigner`, enforces `MAX_PROTOCOL_FEE_BPS` on the protocol fee, deducts `protocolFee` → `protocolFeeRecipient` and `integratorFee` → `integratorFeeReceiver`, and either:
- records a pending order locally (single-chain), or
- sends a LayerZero message containing the **full order data** to the destination station (cross-chain).

The destination station's `_lzReceive` validates the route and places the order in an `EnumerableSet` of order UUIDs mapped to `Order` structs. Backend iterates and batch-fulfills, with partial fills supported (decrement `amountDue` until zero, then remove). Fulfillment is permissioned via RolesAuthority `EXECUTOR` — users never pull funds. Contracts are immutable (no upgradeability). No user-initiated refunds, no order expiry, no on-chain max-size (off-chain rate limit guards LZ reorg risk). Owner can force-remove orders and recover stray ETH/ERC20s; vault retains custody/refund authority.

## Cross-Chain Handling — Important Nuance
Cross-chain is **message-passing only, never value-passing**:
1. Source station takes user's deposit + fees locally.
2. Source station emits a LayerZero message to destination station containing the **full order data** (asset, amount, receiver, source chain, etc. — per KDD 3, not just a hash).
3. Destination station's `_lzReceive` validates the route and records the order in its own pending-orders set — as if a single-chain order had been submitted there directly.
4. Executor fulfills by pulling the want asset from the destination station's configured `wantAssetSource` (KDD 26) straight to the receiver via `transferFrom`; the station custodies nothing.

Funds never bridge — the deposit goes to the source `offerReceiver`, and the wanted asset is pulled from the destination station's `wantAssetSource` to the receiver (KDD 26; station holds nothing).

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
| `shareAmount` payload | Full `Order` struct (asset, amount, receiver, srcChain, offerAsset, offerAmount, queuedAt, UUID) |
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
See "Architecture: server-approved quotes" at the top. The integrator/frontend fee now exists on-chain as the quote's `integratorFee`/`integratorFeeReceiver` (uncapped); only `protocolFee` is capped (`MAX_PROTOCOL_FEE_BPS`).

## Open Questions
- Concrete LZ block-confirmation number per source chain (KDD F is N/A — formula given, value TBD per deployment).
- Exact `Order` payload encoding for LZ (size affects `messageGas` defaults).
- (EIP-712 quote digest — DONE 2026-06-03.)

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
- *2026-06-02*: **Rearchitected to server-approved quotes.** Backend authenticates integrators by API key, computes fees + rate, and signs a `Quote`; the contract holds no fee config and only verifies the signature against a single owner-settable `quoteSigner`. Deleted the whole policy system (RouteConfig/signerPolicies/routeConfigForPolicy/_calcFees/setPolicyRoutes/setSignerPolicies/DEFAULT_POLICY). Decisions: (1) single fee → single `protocolFeeRecipient` (splitter if division needed); (2) `MAX_FEE_BPS = 50` hardcoded immutable cap; (3) one `quoteSigner`, no signer set; (4) no unsigned/DEFAULT path — every order needs a quote; (5) kept `usedDigests`+`salt`, added `deadline`. `amountDue` now in wantAsset units (resolves prior ambiguity). *(Updates 2026-06-03: `payer` binding removed — quotes are bearer; digest moved to EIP-712 via hand-rolled domain separator + OZ `ECDSA`, since OZ's `EIP712` base needs solc `^0.8.24` and the repo pins `0.8.21`.)*
- *2026-06-04*: **KDD 26 — station never custodies; supersedes KDD 20.** Offer→`offerReceiver` on submit (already), want pulled `wantAssetSource`→receiver on execute (`safeTransfer`→`safeTransferFrom`). Added `wantAssetSource` (constructor param + `setWantAssetSource` + zero-check). A dangling approval counts as custody → prefer pull/approvals over transfers, and (TBD) enforce `allowance(wantAssetSource, this) == 0` after execute. `offerReceiver` + `wantAssetSource` kept as two configs (usually the same vault).
- *2026-06-04*: **Two fees, not one** — revises decision (1) above. Added `integratorFee` + `integratorFeeReceiver` to the `Quote` (frontend's UniswapX-style fee); renamed `fee`→`protocolFee` and `MAX_FEE_BPS`→`MAX_PROTOCOL_FEE_BPS`. `protocolFee` capped at 50 bps; **`integratorFee` uncapped** (Carson's call — frontend's own fee, users see `amountDue` before submitting). Residual: a compromised `quoteSigner` can now extract ~100% via `integratorFee`, so `MAX_PROTOCOL_FEE_BPS` no longer bounds total loss; relies on EXECUTOR-key separation + rate limits + refunds. Added `FeesExceedOffer` guard.
- *2026-06-02*: **Re-added on-chain route allowlist** (`approvedRoutes`, global per station, NOT per enterprise) after realizing off-chain-only routing leaves a compromised backend able to deposit/request unapproved assets. Mapping (no merkle), enforced on BOTH source (`submitOrder`) and destination (`_lzReceive`). Critique noted + accepted: this bounds *which assets*, not `amountDue`/rate — mitigated by keeping `quoteSigner` and EXECUTOR on separate keys + off-chain rate limits. `setRouteApprovals(Route[], bool[])` batch setter.
- *2026-06-03*: **Pruned `PeerChain` struct entirely** once `approvedRoutes` + LZ `peers` were in place — `peerStation`/`allowTo`/`allowFrom`/`minimumMessageGas` were all redundant or dead. `selectorToChains` → `mapping(uint32 => uint64) messageGasLimit`; `setPeerChain` → `setMessageGasLimit`; removed `ChainNotAllowedFrom/To`, `PeerStationNotSet`, `GasOutOfBounds` (added `GasLimitNotSet`). `_lzReceive` no longer checks `allowFrom` (LZ peer auth suffices); `_sendOrder` relies on `_getPeerOrRevert` for peer existence.
