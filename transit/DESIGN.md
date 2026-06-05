# Transit Stations – Smart Contract Design Doc

> Process/template preamble (lifecycle, "how to use a design doc," AI-usage guidance) is
> omitted here as boilerplate. This file captures the project-specific design only. The
> authoritative source is the Transit Stations Design Doc; this is the engineering mirror.

## 1. Overview

| | |
|---|---|
| **Date** | 05/21/26 |
| **Author** | Carson Case |
| **Owner** | Dashan McCain |
| **Members** | carsonpcase@gmail.com, Jun Kim |

**Spikes:** meaningful takeaways must be translated into this document — other engineers should
not have to read the spike to understand its insights.

## 2. Discussion

The original code we are working off of comes from the **OneToOneQueue**:
- Code: https://github.com/paxoslabs/nucleus-boring-vault/blob/master/src/helper/one-to-one-queue/OneToOneQueue.sol
- Audit docs: USDC → USDG Minimal Fee Path SC Design Doc

## 3. User Flows

**Single chain**
1. User deposits 10 USDC, says "I want USDG."
2. We determine fees (e.g. 0.01 USDC) at a rate of 1:1.
3. We record a "receipt" for that user of 9.99 USDG.
4. Once the USDG is ready, the bot calls fulfill on that receipt to grant the USDG and burn the receipt.

**Multi chain**
1. User deposits 10 USDC on BASE, says "I want USDG" on ETHEREUM.
2. We determine fees (e.g. 0.01 USDC) at a rate of 1:1.
3. We send a cross-chain message to ETHEREUM of a "receipt" for that user of 9.99 USDG.
4. The ETHEREUM station notes that receipt.
5. Once the USDG is ready, the bot calls fulfill on that receipt to grant the USDG and burn the receipt.

## 4. Key Design Decisions (KDDs)

### KDD 1: Complex Configuration – Should We Use A Merkle Root
`(NUM_CHAINS * NUM_ASSETS)^2` route combinations are many and annoying to track, so we considered
merkle roots + proofs to let users "prove" their route is valid on submission.

**Decision:** Configure per chain with mappings — nothing fancy. The UX cost (requiring users to
prove a route, and losing onchain getters for route data) was too high. *(Note: the UX rationale is
later voided by KDD 23 once quotes come from the backend regardless; KDD 23 re-decides the
mapping-vs-merkle question on its actual merits and still lands on a mapping.)*

### KDD 2: Pending Order Storage
We must store pending orders so the backend can iterate them and remove any element in a batch in O(1).

**Decision:** **Do not swap-and-pop** — swaps reorder mid-batch and break batch processing. Use an
`EnumerableSet` of order UUIDs mapped to the `Order` structs.

### KDD 3: Order Hashes vs. Full Order Data Bridged
Bridge only a hash, or the whole order? A hash is cheaper but the real data must live somewhere.

**Decision:** Bridge **full order data**. The gas savings of hashes isn't worth storing all the data
offchain. Revisit if gas savings becomes paramount.

### KDD 4: LZ vs. CCIP
CCIP is seen as more secure but is slow, non-configurable in speed, and more expensive.

**Decision:** **LayerZero** — it allows configuration via block confirmations; CCIP is too rigid for
the speed Transit needs.

### KDD 5: Upgradeability
**Decision:** Contracts are **not upgradeable**. Iterate by releasing new immutable versions; Transit
can support old versions while migrating to new ones.

### KDD 6: Protocol-Initiated Refunds
**Decision:** Fund management stays under the vault's control; the station only does station stuff —
an owner-only function to remove an order from the array. Admins already have god-mode control over
funds, so this is not a new trust assumption.

### KDD 7: Customer-Initiated Refunds
**Decision:** **No** customer-initiated refunds. Users must not command when/where funds are released —
that's antithetical to Transit.

### KDD 8: Partial Fills
**Decision:** **Allow** partial fills (subtract from `amountDue` until 0, then remove), but not below
the minimum order size. We don't have to use them, but the optionality is strictly better.

### KDD 9: Max Order Size / Rate Limits
LZ re-org risk means we want to rate-limit risk.

**Decision:** **No** max order size onchain. Implement sliding-window rate limits **offchain** based on
max capital at re-org risk. Meaningful onchain limits are too hard (rolling windows can be gamed), and
the backend releases funds anyway, so rate limits + emergency stops live there.

### KDD 10: Min Order Size
Griefers can spam small orders we must pay gas to orchestrate/execute.

**Decision:** Set a min order size on the source chain, **per order**.

### KDD 11: Order Expiry
**Decision:** **No expiry.** Expiry reintroduces all the liquidity-tracking and refund problems. If it
becomes a real issue we refund manually, or users wait.

### KDD 12: Cross-Chain & Single Chain
**Decision:** Support **both** — a core product requirement (orchestrate between coins and/or chains).

### KDD 13: Privileged Execution
Will users execute claims on receipts, or will we?

**Decision:** **Only us.** Users must never determine when liquidity leaves the system. One intelligent
entity with a global view finds the optimal solve and executes; permissionless claims would break that.

### KDD 14: Flat Fees
**Decision:** **Yes** — configured the same way as percent fees (per KDD 15). We must cover gas for
orchestration/execution.

### KDD 15: Min Amount Per Route
**Decision:** **Per route.** We configure per route anyway, so it's more optionality for minimal effort.

### KDD 16: Force-Remove in Partial Amounts
**Decision:** **No.** Not useful and only invites mistakes. Partial-fill + removal already covers the
partial case.

### KDD 17: Additive Fees
**Decision:** **Yes** — fee = flat fee + percent of principal (not percent of post-flat amount). This is
the industry and PXL standard.

### KDD 18: LayerZero Config for Low Latency Without Sacrificing Security
Estimated delivery: `(srcBlockTime × confirmations) + (destBlockTime × (2 + numDVNs))`. Assuming 3 DVNs:
`(srcBlockTime × confirmations) + (destBlockTime × 5)`. Example (Eth src 12s, dest 2s, 15 confs):
`(12 × 15) + (2 × 5) = 190s ≈ 3.17 min`.

**Decision:** N/A (formula given; concrete confirmation count is per-deployment).

### KDD 19: Error Handling on Batch Process
If one order in a batch fails, revert the whole batch or skip-and-emit?
- **Revert:** simpler, but the backend must debug/prune the failing order. Mitigate by reverting with a
  custom error including the failing order's index.
- **Skip-and-emit:** never reverts, but risks silent-failure loops (backend retries the same failing
  orders forever) and the nightmare edge case where a "silent failure" still mutates order state.

**Decision:** **Throw on errors.** Less can go wrong; rules out the state-mutating-silent-failure case.

### KDD 20: Station Custody — SUPERSEDED by KDD 26
Original decision was "custody in the station." **Reversed by KDD 26 (below): the station never
custodies.** Kept here for history.

### KDD 26: Offer Destinations and Station Custody
Where do offer assets go on submit, and where do want assets come from on execute? Should the station
ever custody assets (even multi-block)?

**Decision: the station never custodies funds, and a dangling approval counts as custody.**
- Offer assets go to a configurable `offerReceiver` (in practice a BoringVault) on submit — pulled
  user→`offerReceiver` via `transferFrom`, never resting in the station.
- Want assets are pulled from a configurable `wantAssetSource` (the vault) straight to the receiver on
  execute via `transferFrom` (`wantAssetSource` approves the station). The station holds nothing between blocks.
- Rationale for the backend simplification (Dashan): order placement doesn't know at submit time whether
  an order will be inventory vs orchestrated, so a per-order "station vs vault" toggle is unusable — keep
  it simple, never custody.
- **Approvals (pull) over transfers-to-station:** chosen because the contract can enforce the remaining
  approval is 0 after execution, guaranteeing no custody. A balance==0 check is defeatable — a user can
  donate by setting `receiver` = the station — whereas users cannot influence an approval.

**Implemented (2026-06-04; revised 2026-06-05):** `executePendingOrders(uuids, amounts)` derives the
distinct want-assets touched **on-chain** (O(n²) dedup) and asserts `allowance(wantAssetSource, station)
== 0` for each after the fills (`ResidualApproval`). Chose self-derivation over a backend-passed token
list for a cleaner backend interface, accepting ~slightly higher gas. **Operational cost:**
the vault must approve exactly the per-token batch total before each `execute`, or it reverts on the
residual check.

### KDD 21: Fee Model — Server-Signed Quotes Bounded by an Onchain `MAX_FEE`
We want per-integrator, per-route, dynamic fees. Two ways to identify the integrator:
- **Private key per integrator** — onchain the signer maps to a fixed fee config. Transparent and
  compromise-resistant, but can't express dynamic fees and is operationally heavy to configure per
  enterprise onchain.
- **API key + one PXL signer** — integrators hold familiar API keys; the PXL server holds a single key
  and signs a quote `(route, fee, nonce, msg.sender)` the user submits. Full fee flexibility, but the
  exact fee is opaque onchain and integrators depend on our offchain infra.

**Decision:** **Server-signed quotes with an onchain `MAX_FEE` (~50 bps) as the only onchain fee guard.**
- Dynamic fees enabled. The contract validates the signature and enforces only `fee <= MAX_FEE`.
- **No default fee, no unsigned submission** — every order requires a valid signature mapping to a
  policy. Not permissionless in V1.
- Onchain fee transparency is low-value because integrators interact via the API regardless.

**Trust assumption:** a compromised signer can set any fee up to `MAX_FEE`. Acceptable — volume is
bounded and we can refund — and it is the *entire* extent of trust placed in the signer. We deliberately
do **not** extend that trust to which routes/assets are allowed (see KDD 22).

**Revision (2026-06-04) — two fees:** the quote now carries TWO fees: `protocolFee` (PXL's cut, →
`protocolFeeRecipient`, capped at `MAX_PROTOCOL_FEE_BPS = 50`) and `integratorFee` (the frontend's own
UniswapX-style fee, → the per-quote `integratorFeeReceiver`). **`integratorFee` is uncapped on-chain**
(decision: it's the frontend charging its own users; users are protected by seeing `amountDue` in the
quote before submitting). Consequence: the trust assumption above weakens — a compromised signer can set
`integratorFee` up to ~100% of `offerAmount`, so `MAX_PROTOCOL_FEE_BPS` no longer bounds total
extraction. Backstops remain as in KDD 21 (separate EXECUTOR key, off-chain rate limits, refunds). This
also revises the original "single fee → single recipient" intent: protocol and integrator fees are now
distinct on-chain fields/recipients.

**Note — permissionless access (V1 scope):** a separate permissionless, fixed-fee, all-onchain path was
considered and rejected for V1 (two entry points isn't worth it; dynamic/enterprise fees need a
signature anyway). A permissionless V2 can be a new deployment behind the same endpoints — Luis
confirmed the interface needn't change.

### KDD 22: Route Enforcement — Onchain Route Config, Not Backend-Gating or Asset Whitelists
If the backend signs orders and sets fees, can it also decide which routes are approved? No — the
backend is a *lower trust level* than the contract; a compromised signer must not cause losses beyond
bounded fees. Two cheaper alternatives, both rejected:
- **Backend-only route gating (no onchain limits):** a compromised signer could authorize any pair, e.g.
  "deposit 1 CARSON token, receive 100 WBTC." Unacceptable.
- **Asset whitelist on the station:** closes the junk-asset hole but allows every permutation of approved
  assets implicitly — it throws away **direction**. USDC → USDG ≠ USDG → USDC.

**Concrete attack the asset whitelist does not stop:** we support USDC → USDG but not the reverse. USDG
depegs ~50%. A compromised signer force-creates USDG → USDC orders; the bot keeps filling them; we pay
out good USDC and bag-hold depegged USDG. Both assets are individually whitelisted, so an asset-level
allowlist permits this. Only a **directional route allowlist** blocks it.

**Decision:** Enforce routes onchain as **directional entries** `(offerAsset, wantAsset, destChainEID)`.
Reject asset-only whitelisting. The route allowlist sits at the contract trust level; the signer's
authority stops at fees. Chain reachability is already gated by LZ peers, so route config governs the
asset-direction dimension on top of that.

**Note — when an asset whitelist would suffice:** only if we intend to approve *all* permutations of
approved assets. We won't out of the gate (likely years away, if ever) because directional
pricing/availability is fluid (e.g. a USDT → USDG route at ~5 bps via a bank integration may vanish if
the deal changes). Revisit only if "approve everything" becomes true.

### KDD 23: Route Config Representation — Onchain Mapping vs Merkle Root
**Supersedes the rationale in KDD 1.** KDD 1's "use a mapping" rested on merkle's UX cost (forcing users
to fetch a proof). That's now void: integrators query our backend for the signed quote on every order
(KDD 21), so attaching a proof adds no friction. Re-deciding on actual merits:
- **Merkle root:** one identical root across all chains, trivial to confirm stations match. But the
  backend must build trees and generate proofs (overhead grows with size); reduced transparency
  (verifying what's allowed means reconstructing the tree from a secured pipeline — a new vuln surface);
  needs a separate transparency dashboard.
- **Onchain mapping:** parameters are visible directly in the setting transaction (reviewing an obvious
  multisig beats "read the root, find the PR, check the file"); easy to read/query onchain; no proof
  infra. But more individual writes and harder to confirm-at-a-glance that all chains match.

Routes change infrequently, so per-route multisig updates are acceptable and the review surface is smaller.

**Decision:** **Onchain mapping, not merkle root, for now.** Simplest, most transparent, most flexible
while commercials and deal structures change rapidly. Merkle is a pure cost/DevX optimization, swappable
later via a new deployment without changing the integrator interface.

### KDD 24: Per-Enterprise Routes — Universal Onchain, Offchain Subsetting
Can per-enterprise *route* gating be enforced onchain? **No** — same reason fees can't be per-enterprise
onchain. The contract only knows which enterprise submitted via the backend signature, so a compromised
backend can impersonate any enterprise; an onchain enterprise → route mapping adds no security (the
attacker signs as whichever enterprise has the route they want). The recipient address can't anchor
identity either — enterprises serve their own clients, so valid recipients are unbounded. This is exactly
why fees use a universal `MAX_FEE` rather than per-enterprise onchain caps.

**Decision (pending business confirmation):** Routes are **universal onchain** (all supported routes set
via multisig); offchain signing selects the subset each enterprise may use.
- **Failure mode under backend compromise:** an attacker can make one enterprise use another's route —
  bounded and acceptable. They cannot submit a route we don't support at all (the property KDD 22
  guarantees).
- **Segmentation:** public = all onchain routes + default signed fees; enterprise = a signed subset of
  onchain routes + custom signed fees. No hidden enterprise-only routes outside the onchain set.

**OPEN — confirm with business:** is per-enterprise route differentiation actually required? If no, fees
are the only enterprise-specific value. If yes, the model above still holds. The earlier motivation for
blocking an org from a supported route (preventing wholesaling/reselling orchestration — the
Sprint→Comcast analogy) was judged weak: contractual terms, fee controls, and key revocation address it,
and route gating can't be enforced onchain anyway.

## 5. Software-Level Requirements

> **Reconciled to the implemented contract (`src/transit/TransitStation.sol`).** The originally-drafted
> Section 5 predated KDDs 21–24 and described the old onchain policy/fee system (`signerPolicies`,
> `RouteConfig` fee fields, `setPolicy`/`setUserPolicy`); that has been removed. This section reflects the
> server-signed-quote design.

### Libraries
- **Solmate** — `Auth`, `ERC20`, `SafeTransferLib`. *(Note: solmate is AGPL-3.0 — see the licensing
  question being run down before any BUSL relicensing.)*
- **RolesAuthority** (Solmate) — for the EXECUTOR role.
- **LayerZero** via **`OAppAuth`** — our OApp fork built on Roles Authority, already used by the teller.

### Auth
- **OWNER** — admin (`requiresAuth` / Solmate `Auth`).
- **EXECUTOR** — RolesAuthority role permitted to call `executePendingOrders`. Requires a RolesAuthority,
  not plain ownable.

### Data Structures
- `Route { uint32 destEID; address offerAsset; address wantAsset; }` — directional (KDD 22).
- `Order { bytes32 uuid; address wantAsset; uint256 amountDue; address receiver; uint32 sourceEID;
  address offerAsset; uint256 offerAmount; uint64 queuedAt; }` — `amountDue` is in **wantAsset units**
  (the quote's rate). `queuedAt` = block.timestamp the order was queued, stamped in `_pushOrder`.
  Invariant: `queuedAt != 0` ⟺ queued in this contract; a bridged order carries `0` on the source
  (creation time = the event's block) and gets the real time stamped on the destination.
- `Quote { Route route; uint256 offerAmount; uint256 amountDue; address receiver; uint256 protocolFee;
  uint256 integratorFee; address integratorFeeReceiver; uint256 deadline; bytes32 salt; }` — backend-signed.
  Two fees (offerAsset units): `protocolFee`→`protocolFeeRecipient` (capped at `MAX_PROTOCOL_FEE_BPS`),
  `integratorFee`→`integratorFeeReceiver` (frontend's fee, uncapped on-chain).
  Bearer (no payer binding): anyone may submit a signed quote — they pay `offerAmount` and the want
  asset goes to the fixed `receiver`, so reuse-by-others is only self-griefing.

*(No `RouteConfig` / policy system — superseded by KDD 21. No `PeerChain` struct — pruned; per-chain
gating comes from LZ `peers`, gas from the `messageGasLimit` mapping.)*

### State
- `uint32 immutable thisChainEID` — fetched from `endpoint.eid()`; tells us if a route is cross-chain.
- `address protocolFeeRecipient` — receives `protocolFee`; the integrator's cut goes to the per-quote `integratorFeeReceiver` instead.
- `address offerReceiver` — where the net offer deposit is sent on submit (owner-settable). In practice a BoringVault, but only ERC20-transferred to — role-named, not enforced as a vault.
- `address wantAssetSource` — the address `executePendingOrders` pulls the want asset FROM (via `transferFrom`) to the receiver; must approve the station (owner-settable). KDD 26: station custodies nothing.
- `address quoteSigner` — the single trusted backend signer (KDD 21).
- `uint256 constant MAX_PROTOCOL_FEE_BPS = 50` — hardcoded cap on `protocolFee` only (KDD 21); `integratorFee` uncapped.
- `mapping(uint32 => uint64) messageGasLimit` — per-destination-EID LZ executor gas.
- `mapping(uint32 => mapping(address => mapping(address => bool))) approvedRoutes` — global directional
  route allowlist (`destEID => offerAsset => wantAsset`); nested rather than hashed so the auto-getter
  reads `approvedRoutes(eid, offer, want)` legibly (KDD 22–24).
- `mapping(bytes32 => bool) usedDigests` — replay protection.
- `EnumerableSet.Bytes32Set pendingOrderIds` + `mapping(bytes32 => Order) pendingOrders` (KDD 2).
- `uint256 orderNonce` — feeds UUID generation.

### Non-View Functions
- `submitOrder(Quote quote, bytes signature) payable` — validates deadline, route ∈ `approvedRoutes`,
  `protocolFee <= offerAmount * MAX_PROTOCOL_FEE_BPS / 10_000` (`FeeTooHigh`) and `protocolFee + integratorFee < offerAmount` (`FeesExceedOffer` — net must be strictly positive), the EIP-712 signature recovers to `quoteSigner`, and replay
  (`usedDigests`); pulls `protocolFee`→`protocolFeeRecipient`, `integratorFee`→`integratorFeeReceiver`, net→`offerReceiver`, builds the Order, dispatches local or via LZ. Core logic is internal `_submitOrder`.
- `submitOrderWithPermit(Quote quote, bytes signature, uint256 permitDeadline, uint8 v, bytes32 r, bytes32 s) payable`
  — runs EIP-2612 `permit(msg.sender, address(this), offerAmount, ...)` (try/catch → allowance fallback, `PermitFailedAndAllowanceTooLow`), then `_submitOrder`. Approve + submit in one tx, matching the Teller/OneToOneQueue pattern.
- `executePendingOrders(bytes32[] uuids, uint256[] amounts) requiresAuth` — EXECUTOR fulfills by
  `safeTransferFrom`-ing the want asset from `wantAssetSource` straight to the receiver (KDD 26 — station custodies nothing); subtract from `amountDue`,
  then derives the distinct want-assets on-chain and asserts `allowance(wantAssetSource, this) == 0` for each (`ResidualApproval`);
  remove when 0 (KDD 8). Reverts the whole batch on any failure, with the offending `uuid` in the error
  (KDD 19).
- `forceRemovePendingOrder(bytes32 uuid) requiresAuth` — full removal only (KDD 16).
- `recoverETH(uint256)` / `recoverTokens(ERC20, uint256)` `requiresAuth` — to owner (KDD 6; LZ leaves ETH).
- `pause()` / `unpause()` `requiresAuth` — `Pausable` (`src/helper/Pausable.sol`, modified-OZ, idempotent `_pause`).
  `whenNotPaused` gates only the permissionless entrypoints (`submitOrder`, `submitOrderWithPermit`); execute is
  EXECUTOR-gated and `_lzReceive` is left ungated so in-flight cross-chain orders don't strand.
- `setProtocolFeeRecipient(address)`, `setQuoteSigner(address)`, `setMessageGasLimit(uint32, uint64)`,
  `setRouteApprovals(Route[], bool[])` — all `requiresAuth`.
- `_lzReceive(...)` — re-validates the route against `approvedRoutes` (destEID = thisChainEID), stamps
  pushes to the pending set (`_pushOrder` stamps `queuedAt`). Sender authenticity is enforced upstream by LZ `peers`.

**Signatures / replay:** the quote is signed by the backend (`quoteSigner`) as **EIP-712** typed data
— domain `{name:"TransitStation", version:"1", chainId, verifyingContract}` over `hashStruct(Quote)`
(nested `Route` sub-struct), recovered with OZ `ECDSA.recover`. The OZ `EIP712` base is NOT inherited
(its `ShortStrings`→`StorageSlot` dep needs solc `^0.8.24`; repo pins `0.8.21`), so the domain separator
is computed inline — equally fork-safe (chainId read live) and identical for backend `signTypedData`.
Replay uses **unordered nonces** (a `usedDigests` map + caller `salt`, i.e. checking digest collisions),
since Transit requests are independent and order needn't be enforced; `deadline` bounds validity. Quotes
are bearer (no `payer`/`msg.sender` binding) — see the Data Structures note above.

### View Functions
- `getPendingOrderIds()` / `pendingOrderCount()` — iterate the pending set.
- Public mappings (auto-getters): `pendingOrders`, `approvedRoutes(eid, offer, want)`, `usedDigests`, `messageGasLimit`.

### Events
Emit for every state change; with special care for receipts:
- Order details + route on **submission**.
- Order details + route on **receive**.
- Order details on **execution**.
- A distinct event for **force removals**.

## 6. Testing Requirements
- Base test (shared helpers/fixtures).
- Unit tests.
- Integration tests.
- Invariant tests.

## 7. Security Notes
- **Trust boundary:** the `quoteSigner` is below the contract's trust level. A compromised signer is
  bounded on `protocolFee` ≤ `MAX_PROTOCOL_FEE_BPS` and to routes in `approvedRoutes` (KDD 21–22) — but note `integratorFee` is uncapped, so a signer compromise can still extract up to ~100% via it. **Keep the
  `quoteSigner` and EXECUTOR keys separate** so one compromise can't both sign a bad quote and fulfill it.
- **Residual risk:** the route allowlist constrains *which* assets, not `amountDue`/the rate; a
  compromised signer can still set a favorable rate within an approved route. Backstops: EXECUTOR
  fulfillment control + offchain rate limits (KDD 9).
- **Reentrancy:** handled via **checks-effects-interactions, not a guard modifier**. `executePendingOrders`
  settles order state before the want-asset `safeTransfer`; `submitOrder` marks the replay digest before
  any transfer. Want/offer assets are vetted approved-route tokens, further limiting hook surface.
- **LZ re-org risk:** mitigated offchain via rate limits, not onchain (KDD 9).
- **Licensing:** solmate is AGPL-3.0 — resolve before any BUSL relicensing.

## 8. Reviewers

| Reviewer | Done |
|---|---|
| Person A | ✅ / ❌ |
| Person B | ✅ / ❌ |

## 9. Appendix
- Transit Stations – Smart Contract Project Doc
- OneToOneQueue code + audit docs (see §2)
