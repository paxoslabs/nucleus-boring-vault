# EquivalentExchange

## Purpose

`EquivalentExchange` (EE) is a stateless helper that sanitizes **1:1 swaps**: a caller hands it
a set of tokens and an arbitrary list of calls (a swap route), EE performs the calls, returns its
**entire** balance of those tokens to the caller, and reverts unless the total value returned is
**greater than or equal to** the total value pulled in — where every token is treated as worth one
unit of every other token (1:1), normalized for decimals.

It exists so that swap routes executed by a `BoringVault` can be gated to *guarantee no net loss of
principal*, regardless of what the underlying swap calls do.

## Where it sits

```
strategist
  └─ ManagerWithMerkleVerification.manageVaultWithMerkleVerification(...)   (merkle-gated)
       └─ BoringVault.manage(EquivalentExchange, execute(...), 0)
            └─ EquivalentExchange.execute(tokens, amountsIn, targets, targetData)
                 ├─ pulls `amountsIn` from the vault (msg.sender) via transferFrom
                 ├─ runs the arbitrary (targets, targetData) calls  (the actual swap)
                 ├─ sweeps its ENTIRE balance of every listed token back to the vault
                 └─ requires totalOut >= totalIn  (else revert)
```

`EquivalentExchange` is a **target**, not a manager. The `BoringVault` calls it through a normal
`manage` call. Because the `ManagerWithMerkleVerification` leaf commits to the target plus the
address arguments extracted by a decoder/sanitizer, the merkle tree controls **which tokens and
which call-targets** a strategist may route through EE. The `out >= in` invariant then bounds the
economic outcome of whatever those calls do.

### Typical manage sequence

A strategist rebalancing the vault via EE issues these merkle-gated `manage` calls in one batch:

1. `USDC.approve(EquivalentExchange, amountIn)` — vault approves EE for **exactly** what EE will pull.
2. (optional) `USDT.transfer(EquivalentExchange, subsidy)` — vault pre-funds a subsidy directly to EE.
3. `EquivalentExchange.execute([USDC, USDT], [amountIn, 0], targets, targetData)` — EE pulls USDC, runs the
   swap calls, sweeps all USDC+USDT back, and asserts the vault received `>=` what it put in.

## The invariant

Let `tokens` be the listed tokens and `amountsIn` the amount of each pulled from the caller.

- `totalIn  = Σ normalize(amountsIn[i], decimals[i])`
- `totalOut = Σ normalize(balanceOf(EE)[i], decimals[i])`  (measured after the calls, then swept out)
- Reverts unless `totalOut >= totalIn`.

`normalize(amount, decimals)` rescales `amount` to 18 decimals so that one whole unit of any token
counts the same as one whole unit of any other. Tokens with `<= 18` decimals are scaled up
(lossless); tokens with `> 18` decimals are scaled down. This matches the decimal-normalization
approach used by the `one-to-one-queue` helper.

### What is and isn't protected

- **Principal is protected.** `totalIn` counts only what EE pulls via `transferFrom`. The caller is
  guaranteed to receive at least that much value back (1:1, normalized).
- **The subsidy is deliberately *not* protected.** A subsidy is value sent to EE *outside* of
  `amountsIn` (a direct transfer before the call, or any pre-existing EE balance). It is included in
  `totalOut` but not `totalIn`, so it can be fully consumed to cover swap losses — that is its entire
  purpose. The amount of subsidy is therefore the maximum loss a single `execute` can incur, and is
  bounded by the strategist per call. Targets routed through EE must be trusted (merkle-gated)
  because, within the subsidy budget, the calls have latitude over EE's transient balance.

## No dangling approvals (caller → EE)

After pulling, EE requires `allowance(msg.sender, EquivalentExchange) == 0` for **every** listed
token, and does this **before** running the arbitrary calls.

This is a security control, not just hygiene. While EE runs the `(targets, targetData)` calls, *EE is the
`msg.sender`* of those calls. If the caller had left a non-zero allowance to EE, a call could direct
EE to `transferFrom` additional tokens out of the caller, beyond `amountsIn`. Forcing the allowance
to zero first means EE holds no power to pull more from the caller during the call phase. It also
enforces that the caller approves *exactly* what is pulled — no lingering allowance survives the call.

Approvals that EE grants outward to swap venues (inside `targetData`) are intentionally **not** reset.
They cannot cause loss: EE holds no tokens between calls (it sweeps everything every time), the
reentrancy guard blocks re-entry mid-call, and the `out >= in` invariant bounds every outcome. So a
leftover EE→venue allowance is inert.

## Reentrancy guard (required)

`execute` is `nonReentrant`. This is one of the cases where a lock is genuinely necessary rather than
replaceable by checks-effects-interactions ordering: EE sweeps its **entire** balance to the caller,
not a per-call delta, and the swap calls are inherently mid-flow.

Without the guard, a malicious or compromised swap target could re-enter `execute` while an outer
call is in progress and sweep the outer call's transient balance — including a pre-funded subsidy —
to itself. The outer invariant would not catch this, because the subsidy is not part of `totalIn`.
Concretely: vault pulls 100 USDC (`totalIn = 100`) and pre-funds 100 USDT of subsidy; a re-entrant
call sweeps the 100 USDT to an attacker; the outer call still returns the 100 USDC, so
`totalOut (100) >= totalIn (100)` passes while the subsidy is stolen. The lock prevents the
re-entry, so each `execute` observes only its own funds.

## Access control

`execute` is **permissionless** by design. Safety comes from the invariant, not from an allowlist:

- EE pulls via `transferFrom(msg.sender, ...)`, so a third party can never spend the vault's approval
  — it only ever pulls from whoever is calling.
- Any caller is guaranteed `out >= in` for itself.
- Use by the vault is separately gated upstream by `ManagerWithMerkleVerification`.

EE holds no funds at rest and has no owner, admin functions, or upgradability.

## Merkle integration (companion decoder required)

To route the vault through EE, the `ManagerWithMerkleVerification` tree needs a decoder/sanitizer
whose `execute(...)` selector matches EE's and which returns the packed address arguments the leaf
commits to: every entry of `tokens` followed by every entry of `targets`. (See
`src/base/DecodersAndSanitizers` for the canonical pattern — array arguments are packed by appending
each element.) This decoder is a separate contract from EE and is **not** included here yet.

Note the trust boundary this creates: the merkle leaf pins the token set and the call-targets, but
the per-target calldata (`targetData`) is free. Security of the vault's principal does not rest on
restricting that calldata — it rests on the `out >= in` invariant. The merkle gating bounds *which*
venues and tokens are reachable and (with the subsidy budget) thereby bounds discretionary loss.

## Token assumptions

- Standard ERC20 behavior. Each token must implement `decimals()`, `balanceOf`, `transfer`,
  `transferFrom`, and `allowance`.
- Fee-on-transfer / rebasing tokens are **not** supported: EE accounts using observed balances and a
  1:1 value model, so transfer fees or rebases would misstate `totalIn`/`totalOut`. Do not list them.
- Tokens treated 1:1 should be genuinely interchangeable in value (e.g. a basket of stablecoins).
  Listing tokens whose real values diverge would let the invariant pass while extracting value, up to
  the divergence; the merkle tree is responsible for only pairing equivalent assets.

## Function reference

`execute(ERC20[] tokens, uint256[] amountsIn, address[] targets, bytes[] targetData)`
- `tokens` / `amountsIn` — parallel arrays. `amountsIn[i]` is pulled from the caller for `tokens[i]`
  (use `0` for an output-only token that EE should still sweep back and count toward `totalOut`).
- `targets` / `targetData` — parallel arrays of arbitrary calls EE makes in order (the swap route,
  including any approvals the venues need).
- Reverts: `LengthMismatch`, `DanglingApproval(token)`, `InsufficientReturn(totalIn, totalOut)`, or
  bubbles a failing call's revert.
- Emits `Executed(caller, totalIn, totalOut)` (amounts normalized to 18 dp).

## Status / TODO

- [ ] Comments / NatSpec (intentionally omitted for now).
- [ ] Companion decoder/sanitizer for `ManagerWithMerkleVerification`.
- [ ] Tests under `test/` (fork-based, mirroring existing helper tests).
- [ ] Gas-refinement pass (e.g. `unchecked` loop increments, caching) deferred until logic is final.
