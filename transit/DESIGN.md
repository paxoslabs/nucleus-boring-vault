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

**Implemented (2026-06-04; revised 2026-06-05; reworked 2026-06-11):** `executePendingOrders(FillBatch[])`
takes fills **grouped by want asset** (`FillBatch { wantAsset, uuids, amounts }`), asserts each order's
`wantAsset` matches its batch (`WantAssetMismatch`), and asserts `allowance(wantAssetSource, station) == 0`
once per batch after its fills (`ResidualApproval`). This supersedes the 2026-06-05 choice of on-chain
token dedup over a backend-passed list — the grouped input is the backend-passed structure, accepted
because the per-order equality check is simpler and cheaper than the O(n²) dedup it replaced, and the
per-batch residual check forces all fills for an asset into a single batch. **Operational cost:**
the vault must approve exactly the per-asset batch total before each `execute`, or it reverts on the
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
UniswapX-style fee, → the per-quote `integratorFeeReceiver`). **`integratorFee` was uncapped on-chain**
(original decision: it's the frontend charging its own users; users were protected by seeing `amountDue`
in the quote before submitting). Consequence: the trust assumption above weakens — a compromised signer can
set `integratorFee` up to ~100% of the offer amount, so `MAX_PROTOCOL_FEE_BPS` no longer bounds total
extraction. Backstops remain as in KDD 21 (separate EXECUTOR key, off-chain rate limits, refunds). This
also revises the original "single fee → single recipient" intent: protocol and integrator fees are now
distinct on-chain fields/recipients. **Update (2026-06-10, KDD 27):** `amountDue` is no longer in the quote
for the user to "see", and with the rate derived on-chain an integrator-fee skim is bounded user-fund risk,
not a vault drain — and it is now **capped (`MAX_INTEGRATOR_FEE_BPS`, KDD 28).**

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

### KDD 27: `amountDue` Derived On-Chain From Normalized Amounts — Definitively 1:1, Varying Decimals Supported (2026-06-10)
**Problem.** Originally the backend signed `amountDue` (the want delivered) into the `Quote`. Because the
signer, the executor, and the vault's approval logic all live in one backend (one trust boundary — see §7),
a full compromise could sign `offerAmount = $1, amountDue = $1B` on an approved route and drain
`wantAssetSource` — the "EXECUTOR is an independent backstop" mitigation is illusory when all three are the
same backend. The only reason `amountDue` was signed at all was that the contract can't know the cross-token
decimal relationship: neither chain holds both tokens, so neither can read both `decimals()`.

**Decision.** Transit is **definitively a 1:1 stable swap** — equal value per whole unit across the pair —
**but supports pairs with differing token decimals.** `amountDue` is **removed from the signed quote and
derived on-chain**, and the decimals problem is solved by **normalizing all amounts to 18 decimals**
(`NORMALIZED_DECIMALS`) instead of bridging decimals:
- ALL `Quote` amounts are 18-decimal-normalized (`offerAmountNormalized18`, `protocolFeeNormalized18`,
  `integratorFeeNormalized18`); the field names carry the unit so the backend cannot misread them as raw.
- At collection (`_verifyAndCollect`), each amount is truncated down (`_toTokenUnits`) to the offer asset's
  native units, and the three transfers **partition the truncated offer amount exactly** — sub-token-unit
  fee dust folds into the net (the vault's side, the party already bearing peg risk) rather than vanishing.
  A net of zero token units reverts (`NetTruncatesToZero`).
- The order's `offerAmountNormalized18AfterFees` is **re-normalized FROM the collected token units**
  (`_toNormalized`), never taken from the signed figure, so sub-token-unit precision the user never paid
  cannot survive into the want owed.
- On the destination, `_pushOrder` derives `amountDue = _toTokenUnits(terms.offerAmountNormalized18AfterFees,
  wantAsset.decimals())`, truncating toward 0 (receiver never over-credited) and reverting `ZeroAmountDue`
  if it truncates to zero.
- Decimals are read only where each token is local (offer on the source, want on the destination) and
  **never bridge**. The LZ payload is `OrderTerms` — everything fixed at submit time (`uuid`, assets,
  `receiver`, `sourceEID`, the collected normalized net) — and `Order { OrderTerms terms; uint256 amountDue;
  uint64 queuedAt; }` **composes** the terms with the two destination-derived fields, so nothing ever
  bridges empty and a half-initialized `Order` never exists outside `_pushOrder`'s input.

*(An earlier same-day approach bridged raw `net` + `offerDecimals` in a dedicated `BridgeData` struct
modeled as "Order minus fields" — implemented, reverted, superseded by normalization + the `OrderTerms`
composition, which needs no decimals on the wire and no field-by-field copy between structs.)*

**Why this is the right trust model.** The rate is no longer a hot-key parameter — it's the collected
post-fee value rescaled by a pure decimal delta. The 1:1 attestation moves to the **owner/multisig** (it
only approves like-valued pegs via `approvedRoutes`). A compromised backend is reduced to fee griefing (the
originally-intended limited blast radius), not vault drain: the value math nets to `−protocolFee` for an
attacker who controls `receiver` + `integratorFeeReceiver`, so there is no profitable drain.

**Trade-offs accepted.** (1) Pairs must be genuine 1:1 pegs; a depeg is borne by the vault (business risk,
owner-managed). (2) Sub-dust orders revert — `NetTruncatesToZero` at the source if the net collects to zero
offer units, `ZeroAmountDue` in `_pushOrder` if the collected value truncates to zero want units; cross-chain
the latter strands a (retryable) message, so the backend must enforce a min order size. (3) Non-pegged or
oracle-priced swaps are explicitly out of scope for this version.

**Resolved follow-up:** the integrator-fee skim vector this left open is closed by KDD 28.

### KDD 28: Integrator Fee Cap (2026-06-10)
**Problem.** The integrator fee was deliberately uncapped: the explicit assumption was that the frontend can
charge whatever it wants, and if the frontend gets phished the user can get phished anyway — a phished
frontend means the user is already completely exposed, so an on-chain cap adds nothing against that threat.
But the fee and its receiver are signed by the **backend**, not the frontend: a backend (`quoteSigner`)
compromise *alone* — no frontend involvement — can set any integrator fee with any `integratorFeeReceiver`
and steal from every user. A user could in principle catch this by noticing the fee/receiver changed before
submitting, but that responsibility must not sit with the user.

**Decision.** **Introduce an integrator fee cap**: `MAX_INTEGRATOR_FEE_BPS = 1000` (10%), hardcoded immutable
like the protocol cap, enforced in `_verifyAndCollect` (`IntegratorFeeTooHigh(integratorFee, maxIntegratorFee)`;
the protocol-fee error was renamed `ProtocolFeeTooHigh` to keep the two distinguishable). With both fees
capped and the rate derived on-chain (KDD 27), a full backend compromise is now bounded to skimming
`MAX_PROTOCOL_FEE_BPS + MAX_INTEGRATOR_FEE_BPS` (10.5%) of each deposit it can get signed — the
`FeesExceedOffer` guard remains as defense-in-depth (and still blocks zero-offer quotes). *(The 10% value
leaves ample room for legitimate UniswapX-style frontend fees while still bounding theft; revisit as partner
pricing settles.)*

### KDD 29: Distributor Code — Backend-Attested Flow Attribution (2026-06-10)
**Problem.** Enterprises need to log funds as coming from them — a referral tag saying "this flow was mine."
Different from the integrator fee: no funds move, it's pure attribution.

**Decision.** Add `bytes32 distributorCode` to the signed `Quote` (the referral-code idea from
`DistributorCodeDepositor`, but fixed-width), emitted as an **indexed** field on `OrderSubmitted`.
- **Signed, not a loose submit param:** the backend authenticates the integrator (API key) and signs the
  quote, so attribution is backend-attested — nobody can tag volume with someone else's code, and a tampered
  code fails signature verification (it's in the EIP-712 digest, so it also feeds the order UUID).
- **Emitted on the source only, never bridged or stored:** attribution is about where the deposit came from,
  which is a source-chain fact; the destination has no use for it. Cross-chain analytics join by `uuid`
  (identical on both chains).
- **`bytes32`, not `bytes` (revised same day):** an indexed dynamic type stores only `keccak256(value)` in
  the topic, so consumers couldn't recover the code from the log — and EIP-712 reduces a `bytes` field to its
  32-byte hash for signing anyway. A `bytes32` is a value type: the indexed topic carries the code **itself**
  (filterable AND readable from the log), EIP-712 encodes it atomically (no hashing wrapper in `_hashQuote`),
  and it's cheaper (one calldata word). 32 bytes is ample for backend-assigned codes; an enterprise name
  longer than that can be keyed by its hash off-chain.
- `bytes32(0)` = unattributed flow; no validation (backend controls what it signs).

### KDD 30: Route Checked on Send Only — No Re-Check in `_lzReceive` (2026-06-11)
**Problem.** `approvedRoutes` was originally enforced on both the source (`submitOrder`) and the destination
(`_lzReceive`, reconstructing the route with `destEID = thisChainEID`). The dual check required every
cross-chain route to be approved on BOTH stations under the same key, and a destination config mismatch
stranded the LZ message (retryable, but an ops burden and a documented caveat).

**Decision.** **Check the route on send only; do not re-check on receive.**
- `_lzReceive` is only reachable past LZ peer authentication, so presenting an unapproved route there
  requires an LZ-level attack — and an attacker with that power would forge **amounts** on an approved
  route, not bother with the route. The re-check defended against nothing the attacker would actually do.
- Even a forged route is bounded by the inventory the station may pull from (`wantAssetSource`'s exact
  per-batch approvals), and the executor still has to choose to fill the order. Value-out was never gated by
  the receive check — `executePendingOrders` does not consult `approvedRoutes` — so the gates are unchanged:
  EXECUTOR role, exact approvals, `pause`.
- Checking only on send reduces confusion and complexity for the same security surface, and routes now need
  approval **only on the source station** — no stranded-message recovery flow, no dual-key config ceremony.

**Trade-off accepted:** de-approving a route on the destination no longer filters in-flight bridged orders
for it (it never affected already-queued orders either); the incident response for a bad route remains
`pause()` + the executor declining to fill.

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
- `OrderTerms { bytes32 uuid; address wantAsset; address receiver; uint32 sourceEID; address offerAsset;
  uint256 offerAmountNormalized18AfterFees; }` — everything fixed at submit time on the source; **the LZ
  wire format** (KDD 27). `offerAmountNormalized18AfterFees` is re-normalized from the token units actually
  collected.
- `Order { OrderTerms terms; uint256 amountDue; uint64 queuedAt; }` — the terms composed with the two
  destination-derived fields. `amountDue` is in **wantAsset token units** but is **DERIVED on-chain, not
  signed** (KDD 27). **`_pushOrder(OrderTerms)` is the only constructor of `Order` values**: it derives
  `amountDue = _toTokenUnits(terms.offerAmountNormalized18AfterFees, wantAsset.decimals())` and stamps
  `queuedAt` at construction — no half-initialized `Order` ever exists, and wire data can never smuggle an
  `amountDue` (the wire only carries terms).
- `Quote { Route route; uint256 offerAmountNormalized18; address receiver; uint256 protocolFeeNormalized18;
  uint256 integratorFeeNormalized18; address integratorFeeReceiver; bytes32 distributorCode; uint256 deadline;
  bytes32 salt; }` — `distributorCode` is a backend-attested referral tag, emitted on `OrderSubmitted` and
  never bridged/stored (KDD 29). Otherwise:
  backend-signed; **ALL amounts normalized to 18 decimals** (KDD 27) and truncated to the offer asset's
  native units at transfer time. **No `amountDue`** — the signer doesn't state the delivered amount. Two
  fees: `protocolFeeNormalized18`→`protocolFeeRecipient` (capped at `MAX_PROTOCOL_FEE_BPS`),
  `integratorFeeNormalized18`→`integratorFeeReceiver` (frontend's fee, capped at `MAX_INTEGRATOR_FEE_BPS`, KDD 28).
  Bearer (no payer binding): anyone may submit a signed quote — they pay the offer amount and the want
  asset goes to the fixed `receiver`, so reuse-by-others is only self-griefing.

*(No `RouteConfig` / policy system — superseded by KDD 21. No `PeerChain` struct — pruned; per-chain
gating comes from LZ `peers`, gas from the `messageGasLimit` mapping.)*

### State
- `uint32 immutable thisChainEID` — fetched from `endpoint.eid()`; tells us if a route is cross-chain.
- `address protocolFeeRecipient` — receives `protocolFee`; the integrator's cut goes to the per-quote `integratorFeeReceiver` instead.
- `address offerReceiver` — where the net offer deposit is sent on submit (owner-settable). In practice a BoringVault, but only ERC20-transferred to — role-named, not enforced as a vault.
- `address wantAssetSource` — the address `executePendingOrders` pulls the want asset FROM (via `transferFrom`) to the receiver; must approve the station (owner-settable). KDD 26: station custodies nothing.
- `address quoteSigner` — the single trusted backend signer (KDD 21).
- `uint256 constant MAX_PROTOCOL_FEE_BPS = 50` — hardcoded cap on `protocolFee` (KDD 21).
- `uint256 constant MAX_INTEGRATOR_FEE_BPS = 1000` — hardcoded cap on `integratorFee` (KDD 28).
- `mapping(uint32 => uint64) messageGasLimit` — per-destination-EID LZ executor gas.
- `mapping(uint32 => mapping(address => mapping(address => bool))) approvedRoutes` — global directional
  route allowlist (`destEID => offerAsset => wantAsset`); nested rather than hashed so the auto-getter
  reads `approvedRoutes(eid, offer, want)` legibly (KDD 22–24).
- `mapping(bytes32 => bool) usedDigests` — replay protection.
- `EnumerableSet.Bytes32Set pendingOrderIds` + `mapping(bytes32 => Order) pendingOrders` (KDD 2).
- `uint8 constant NORMALIZED_DECIMALS = 18` — the normalization target for all quote/bridged amounts (KDD 27).

### Non-View Functions
- `submitOrder(Quote quote, bytes signature) payable` — validates deadline, route ∈ `approvedRoutes`,
  the fee bounds in normalized space (`ProtocolFeeTooHigh` / `IntegratorFeeTooHigh` for the caps; `FeesExceedOffer` — the normalized
  net must be strictly positive), the EIP-712 signature recovers to `quoteSigner`, and replay (`usedDigests`);
  truncates each normalized amount to the offer asset's token units (`NetTruncatesToZero` if the net collects to
  zero) and pulls fees→recipients and net→`offerReceiver` as an exact partition of the truncated offer amount;
  builds the Order (carrying the collected net, re-normalized) and dispatches local or via LZ. Core logic is
  internal `_submitOrder` (KDD 27).
- `submitOrderWithPermit(Quote quote, bytes signature, uint256 permitDeadline, uint8 v, bytes32 r, bytes32 s) payable`
  — runs EIP-2612 `permit(msg.sender, address(this), <truncated token-unit offer amount>, ...)` (try/catch →
  allowance fallback, `PermitFailedAndAllowanceTooLow`), then `_submitOrder`. Approve + submit in one tx,
  matching the Teller/OneToOneQueue pattern.
- `executePendingOrders(FillBatch[] batches) requiresAuth` — fills grouped by want asset
  (`FillBatch { wantAsset, uuids, amounts }`). EXECUTOR fulfills by `safeTransferFrom`-ing the want asset
  from `wantAssetSource` straight to the receiver (KDD 26 — station custodies nothing); asserts each order's
  `wantAsset` matches its batch (`WantAssetMismatch`), subtracts from `amountDue`, removes when 0 (KDD 8),
  and asserts `allowance(wantAssetSource, this) == 0` once per batch (`ResidualApproval`). Reverts everything
  on any failure, with the offending `uuid` in the error (KDD 19).
- `forceRemovePendingOrder(bytes32 uuid) requiresAuth` — full removal only (KDD 16).
- `recoverETH(uint256)` / `recoverTokens(ERC20, uint256)` `requiresAuth` — to owner (KDD 6; LZ leaves ETH).
- `pause()` / `unpause()` `requiresAuth` — `Pausable` (`src/helper/Pausable.sol`, modified-OZ, idempotent `_pause`).
  `whenNotPaused` gates `submitOrder`, `submitOrderWithPermit`, AND `executePendingOrders` (revised 2026-06-08).
  Execute MUST halt when paused: EXECUTOR-gating alone is insufficient because the EXECUTOR key itself can be
  compromised — pausing is the kill-switch that freezes fulfillment (the value-out step) even against a hacked
  executor or a compromised backend whose malicious orders are already queued. `_lzReceive` is left ungated: no
  value moves on receive (only on execute, which is gated), and gating it would strand in-flight cross-chain
  messages.
- `setProtocolFeeRecipient(address)`, `setQuoteSigner(address)`, `setMessageGasLimit(uint32, uint64)`,
  `setRouteApprovals(Route[], bool[])` — all `requiresAuth`.
- `_lzReceive(...)` — decodes the bridged `OrderTerms` and pushes to the pending set (`_pushOrder` derives
  `amountDue` from the bridged normalized net + local `wantAsset.decimals()` and stamps `queuedAt`; the wire
  carries no `amountDue` to trust). Sender authenticity is enforced upstream by LZ `peers`; the route is NOT
  re-checked here (validated once on the source — KDD 30).

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
- **Trust boundary:** the `quoteSigner` is below the contract's trust level. As of KDD 27 the signer **no
  longer controls the rate** — `amountDue` is derived on-chain from the collected post-fee value, so a
  compromised signer is bounded to: griefing fees (`protocolFee` ≤ `MAX_PROTOCOL_FEE_BPS`; `integratorFee` ≤
  `MAX_INTEGRATOR_FEE_BPS` — KDD 28, total skim ≤ 10.5% per deposit) and mis-routing within
  `approvedRoutes`. It can NO LONGER over-price an order to drain `wantAssetSource`. Even so, **keep the
  `quoteSigner` and EXECUTOR keys separate** and use `pause()` (which also freezes execute) as the incident
  kill-switch.
- **1:1 / depeg risk (the surviving rate assumption):** the contract assumes every approved route is a
  like-valued peg (KDD 27). That trust sits with the **owner/multisig** (route approval), not the backend.
  If an approved pair depegs, the vault over- or under-pays at 1:1 — a business risk managed by only
  approving genuine pegs + monitoring, not a contract bug.
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
