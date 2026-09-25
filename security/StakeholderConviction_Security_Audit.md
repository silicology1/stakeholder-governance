# Security Audit — `StakeholderConviction` (Cairo / Starknet)

**Scope:** single-file contract, not compiled in this environment (per the module header). This review is manual/static; it does **not** replace `scarb build`, `snforge`/`Tayt` test runs, or a paid audit before mainnet deployment.

---

## 1. Executive Summary

| Severity | Count |
|---|---|
| Critical | 2 |
| High | 3 |
| Medium | 5 |
| Low / Informational | 8 |

The most serious issues are **not** in the capped ERC20 (that part is solid: single mint path, cap checked on every mint). They are in the **uncapped, non‑transferable governance-token system (Stage 2)** and in **admin key hygiene** — both of which can lead to unbounded governance capture or a fast hostile takeover.

---

## 2. Critical Findings

### C-1. Governance power can be minted without bound via self-dealt disputes
`create_selection_dispute` is permissionless, takes an attacker-chosen `candidate` **and an attacker-chosen `num_draws`**, with no cooldown, no per-candidate limit, and no requirement that the candidate consent. Combined with:
- Jurors are drawn **with replacement**, weighted by stake in this contract's own token (`_fenwick_find`).
- `num_draws` can be set to `1`. With a single draw, there is no outlier trimming (population stdev of a single sample is 0, so only that exact score survives the filter) — the whole "trimmed mean" defense is void.
- An address holding a large share of total staked weight has a correspondingly high probability of drawing **itself** as the sole juror.

An attacker can stake heavily, call `create_selection_dispute(self, 1)`, get drawn as the only juror, reveal a `+5`, and mint **500 non-transferable governance tokens to themselves** — repeatable indefinitely (no per-candidate or per-address cap on `Grant`s, explicitly "no supply cap" per the header). This directly buys conviction-voting power (Stage 3) and therefore control over the treasury payout, with no capped-supply ceiling to stop it.

**Fix:** require a minimum `num_draws` (e.g. ≥ 5–7, matching Kleros norms), rate-limit disputes per candidate (cooldown or max-concurrent), and/or require the caller ≠ candidate self-stake beyond some ratio, or require a bond/deposit from whoever opens a dispute that is forfeited if the dispute is later shown to be a self-deal. At minimum, treat "1 juror, no trimming" as a first-class attack surface, not just a math edge case.

### C-2. Admin roster changes bypass the 3-day timelock — single-key takeover path
Every other admin parameter goes through `propose_set_X` / `execute_set_X` with a 3-day delay. `add_admin` / `remove_admin` are **instant** (module header acknowledges this is deliberate). Concretely:

1. A single `DEFAULT_ADMIN_ROLE` key is compromised (or acts maliciously).
2. It calls `add_admin(attacker2)` — instant, no timelock.
3. It then calls `remove_admin(originalAdmin1)`, `remove_admin(originalAdmin2)`, … one at a time (each instant; only blocked when `admin_count == 1`).
4. Attacker ends up sole admin, with immediate control of `vrf_provider`, `funding_token`, thresholds, decay parameters, and `is_protected_address` — all future changes to which are timelocked, but the *takeover itself* was not.

This defeats the purpose of timelocking the other parameters: the attacker doesn't need to wait 3 days on anything if they can just remove every other admin first, and can then propose/wait-out timelocked changes at leisure with zero opposition.

**Fix:** either timelock admin add/remove as well, or require multi-admin quorum (e.g. N-of-M) for `remove_admin`, or at minimum emit-and-delay removal (a "removal cooldown" during which the target can still act) so a compromised key can't unilaterally strip the roster in one block.

---

## 3. High Findings

### H-1. Juror can dodge slashing by unstaking before `slash_non_revealer`
Already flagged in the header as a caveat, and it is a real, exploitable bug, not just a note: `slash_non_revealer` reads `self.juror_stake.entry(juror).read()` **at call time**, and `unstake()` has no lock tied to being an undrawn/pending-reveal juror. A juror drawn into a dispute who does not want to reveal (e.g., they know their vote would be an outlier, or they were bribed to abstain) can simply call `unstake(full_amount)` any time before someone calls `slash_non_revealer`, leaving `stake = 0` and `slash_amount = 0`. This breaks the economic security of the commit-reveal game (no cost to non-reveal), and by extension weakens `finalize_selection`'s trustworthiness.

**Fix:** track stake locked-per-dispute (or a single "locked until reveal deadline" flag) the moment a juror is drawn, and block `unstake` below that locked amount until the dispute is finalized or the juror has revealed/been slashed.

### H-2. Unbounded loops create both DoS and fund-lock vectors
Three places iterate over attacker-influenceable-length collections inside a single atomic call, with no cap:
- `create_selection_dispute`: loops `num_draws` times (caller-supplied, unbounded) doing a VRF-derived draw + Fenwick lookup each iteration.
- `finalize_selection`: loops 4 times over `d.unique_juror_count` (bounded by `num_draws`).
- `_proposal_total_power` / `_distribute_conviction_rewards` (called from `execute_proposal`): loop over **every** `(owner, conviction_id)` pair that has *ever* called `add_support` on a proposal, including long-inactive ones (already documented as a caveat, but there's no enforced cap in code).
- `_decayed_total`: loops over every `Grant` a holder has ever received, on every read of their governance balance (also documented, also uncapped in code).

The `execute_proposal` case is the most dangerous: it is the function that **releases treasury funds**. If a popular proposal accumulates thousands of distinct supporters (trivial to grief — anyone can call `add_support` with a tiny 1-wei conviction), `execute_proposal` can become too expensive to ever execute, effectively locking that proposal's requested funds forever, with no fallback path.

**Fix (two parts):**
1. Cap `num_draws` with a `MAX_DRAWS` constant.
2. Switch conviction-reward distribution to a **pull pattern** (see §6, Pull-over-Push) so `execute_proposal`'s gas cost doesn't scale with supporter count, and so `get_proposal_total_power`/execution aren't griefable by supporter-count spam. If total power must be computed on-chain, maintain it as an incrementally-updated running total (updated inside `add_support`/`remove_support`) instead of iterating the full history at execution time.

### H-3. `deposit_funds` violates Checks-Effects-Interactions
```
let ok = token.transfer_from(caller, get_contract_address(), amount);  // external call
assert(ok, 'TransferFailed');
let new_total = self.treasury_balance.read() + amount;                // state updated AFTER
self.treasury_balance.write(new_total);
```
The external call to `funding_token.transfer_from` happens **before** `treasury_balance` is updated. The `reentrancyguard` mitigates same-function/other-guarded-function re-entry, but it does **not** make the ordering itself safe by design — several state-changing functions (`commit_vote`, `reveal_vote`, `create_funding_proposal`, `create_conviction`, `add_support`, `remove_support`, `release_conviction`) are **not** reentrancy-guarded at all. None of them currently read `treasury_balance`, so today's blast radius is limited — but this is exactly the kind of latent bug that becomes exploitable the next time someone adds a feature that reads `treasury_balance` inside one of those unguarded functions. Follow CEI unconditionally, not "CEI when it happens to matter today."

**Fix:** update `treasury_balance` before the external `transfer_from` call (or accept the transferred amount as already-in-flight and reconcile), matching the pattern already used correctly in `execute_proposal`.

---

## 4. Medium Findings

### M-1. Decay clock is per-address, not per-acquisition (documented, but worth stress-testing)
`_apply_decay`'s checkpoint (`last_decay_at[user]`) is not reset or pro-rated on transfer (no ERC20 transfer hooks — `ERC20HooksEmptyImpl` is used). A holder can **evade years of decay indefinitely** by periodically moving their balance to a fresh, never-before-decayed address, or by cycling between two addresses they control (each swap effectively "resets the clock" for whichever address currently holds the balance, since a fresh address's `last_decay_at` is `0` and the *first* `apply_decay` call on any address only sets the checkpoint without burning anything). This fully defeats the decay mechanism for any economically rational holder, which likely undermines whatever tokenomics goal the decay is meant to serve (e.g. discouraging dormant whales).

**Fix:** decide explicitly whether this is acceptable (module header calls it "a product decision"), but if decay is meant to be evasion-resistant, wire real transfer hooks that carry forward (not reset) the earliest-acquisition timestamp, or decay is better modeled as a global emission/burn schedule rather than a per-holder clock.

### M-2. `funding_token` / weird-ERC20 compatibility
`deposit_funds`/`execute_proposal` call `funding_token.transfer_from`/`transfer` via a strictly-typed `IERC20Dispatcher` and `assert(ok, ...)` on the returned bool. Unlike Solidity, Cairo's dispatcher ABI is strict: if `funding_token` doesn't implement the exact expected interface (e.g. an older Cairo0-style token that doesn't return a felt/bool, or returns nothing), the call likely **fails outright** rather than silently succeeding — which is actually the *safer* failure mode versus EVM's classic "missing return value treated as success" bug class. Still:
- There is no on-chain check that `funding_token` actually behaves like a fee-less, non-rebasing ERC20. A fee-on-transfer or rebasing `funding_token` set via `propose_set_funding_token`/`execute_set_funding_token` would silently break the `treasury_balance` accounting invariant (`treasury_balance` assumes 1:1 with actual token balance held).
- Recommend adding an invariant check (e.g., compare `IERC20(funding_token).balance_of(this)` against `treasury_balance` periodically, or check delta-received in `deposit_funds` instead of trusting `amount`).

### M-3. `is_protected_address` self-service exemption is timelocked but still admin-unilateral
Being timelocked is good, but note that `execute_set_protected_address` lets an admin exempt **any** address (including the admin's own wallet, the treasury, or a designated "farm" address) from decay after only a 3-day wait, with no on-chain justification required. Combined with C-2 (admin takeover), an attacker admin could protect their own harvested balance from decay while letting everyone else's decay/burn. Low likelihood, but worth a comment/event-monitoring recommendation since it's silent unless someone is watching `ProtectedAddressProposed` events.

### M-4. `execute_proposal` mixes push-payout and push-reward-distribution in one unbounded call
See H-2. Independent of the DoS angle, this also means a **single malfunctioning supporter record** (there shouldn't be one given the code, but future upgrades could introduce one) could revert the whole proposal execution including the treasury payout — better to decouple "pay the proposal" from "distribute rewards to supporters" so a reward-side failure can never block the funding payout. Currently they're atomic together by design (comment says this is intentional), which is a defensible choice but worth calling out as a hard coupling risk.

### M-5. No upper bound on admin-settable durations
`propose_set_commit_duration`/`propose_set_reveal_duration` only assert `> 0`; there's no upper bound. A (post-takeover, see C-2) malicious admin could set `commit_duration`/`reveal_duration` to an enormous value, effectively freezing all future dispute resolution, or to a very small value that makes reveal windows practically un-usable across time zones/latency. Low severity on its own (admin-gated), but cheap to bound and worth doing as defense-in-depth given C-2.

---

## 5. Low / Informational

- **L-1 — Reward rounding dust:** `share = reward_total * power / total_power` truncates; leftover dust is simply never minted (stays under `MAX_SUPPLY`). Not a loss of funds, just note it's expected behavior, not a bug.
- **L-2 — No minimum for `create_conviction`/`add_support`:** anyone can lock `amount = 1` (in decayed-governance-token base units) and call `add_support`, which is the cheap griefing vector feeding H-2's supporter-list bloat. Consider a minimum lock size.
- **L-3 — `governance_available` / `create_conviction` re-reads `_decayed_total` and `governance_locked_total` separately** on every call — correct, but two O(n) passes over disputes/grants when one would do if refactored; a gas/read-cost nit, not a correctness bug.
- **L-4 — Missing per-function doc comments (NatSpec-equivalent) on the `IStakeholderConviction` trait itself.** The module header is excellent, but individual trait methods (e.g. `commit_vote`, `add_support`) have no `///` doc comments describing params/reverts/effects. Recommend adding them — see §6.7 for a template.
- **L-5 — `_score_to_i64`, `_round_scaled`, `_isqrt`, `_lowbit`, `_address_to_u256`, `_u256_to_address`** don't touch storage and are effectively "pure" functions, but are written as trait methods on `@ContractState`. Not a security issue, purely a style/gas nit — could be free functions instead.
- **L-6 — `stdev_scaled` cast chain** (`u256 -> u64 -> i64`) in `finalize_selection` will panic (not silently wrap) if variance ever produces a value that doesn't fit `u64`/`i64` after scaling. Given `SCALE=1000` and scores bounded to `[-5,5]`, this is safe today, but it's a brittle pattern if `SCALE` or the score range is ever widened without re-deriving the bound. Add a comment recording the bound assumption (`max diff² * SCALE² * max_weight` must fit `u64`) so a future change doesn't silently reintroduce a panic-DoS.
- **L-7 — `Dispute.final_score` is stored as `i64`, unscaled** — fine, but double-check every downstream consumer (`_governance_tokens_for_score`) treats it consistently as unscaled; it does, just flagging as something a future change could get wrong silently since `SCALE`-scaled and unscaled `i64`s look identical at the type level.
- **L-8 — Magic numbers:** overall good — `BPS_DENOM`, `DECAY_BPS_DENOM`, `MAX_BATCH_DECAY`, `TIMELOCK_DURATION`, `HOURS_PER_YEAR`, etc. are all named constants. The two literal `u256` constants (`MAX_SUPPLY`, `INITIAL_SUPPLY`) are explicitly justified in comments (corelib const-arithmetic limitations) — acceptable, not a real magic-number issue.

---

## 6. Checklist Responses

### 6.1 Function visibility (Cairo has no Solidity-style `pure/view/external/public/internal/private`, but here's the mapping)
- **External (state-changing):** every `fn` taking `ref self: TContractState` inside `#[abi(embed_v0)] impl StakeholderConvictionImpl` — these are callable by anyone off-chain/from other contracts, and appear in the ABI. Equivalent to Solidity `external`.
- **View:** every `fn` taking `self: @TContractState` inside that same embedded impl (e.g. `governance_balance`, `get_dispute`, `token_max_supply`) — read-only, in the ABI. Equivalent to Solidity `view`.
- **Internal:** everything inside `#[generate_trait] impl InternalImpl of InternalTrait` — **not** exposed in the contract ABI at all (no `#[abi(embed_v0)]`), reachable only from within this contract's own code. Equivalent to Solidity `internal`. This is used correctly and consistently.
- **"Pure"** doesn't exist as a distinct Cairo keyword, but functions like `_isqrt`, `_score_to_i64`, `_lowbit` that don't touch `Storage` are functionally pure — see L-5.
- No function is missing an access-control check where one is implied (admin-only functions correctly call `self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE)` — verified for every `propose_set_*`/`execute_set_*`/`add_admin`/`remove_admin`).

### 6.2 Test coverage
**None present in this file** — it's explicitly marked "not compiled... read it as a careful structural draft." Minimum recommended suite (Starknet Foundry / `snforge`):
- Happy-path: stake → dispute → commit/reveal → finalize → governance mint → conviction → support → execute_proposal → reward distribution.
- `_isqrt` against a Python/Rust reference over a wide input range (including 0, 1, perfect squares, `u256::MAX`-scale values).
- Trimmed-mean scoring against a reference Python model across juror counts 1, 2, 3, and large-N with deliberate outliers.
- Decay math (`_decayed_grant_amount`, `_apply_decay`) at boundary hours (0, 1, 8759, 8760, 8761).
- Every `assert(...)` revert path (wrong phase, insufficient stake, double-commit, double-reveal, hash mismatch, etc.).
- Timelock engine: execute-before-`effective_at` reverts; execute-with-no-pending-change reverts; re-proposing overwrites the prior pending value.
- `remove_admin` refusing to drop the last admin.
- Supply-cap boundary: mint that would exceed `MAX_SUPPLY` reverts atomically (including that it rolls back the paired treasury payout in `execute_proposal`).

### 6.3 Invariant tests (recommended, for fuzzing/formal tooling e.g. `Tayt`)
- `total_supply() <= MAX_SUPPLY` at all times.
- `sum(juror_stake) == _fenwick_total()` (Fenwick tree stays consistent with the flat stake map).
- `governance_locked_total[holder] <= _decayed_total(holder)` for every holder (never over-locked).
- `treasury_balance <= IERC20(funding_token).balance_of(this)` (see M-2).
- For any `Conviction`, `is_supporting == false ⇒ get_conviction_power(...) == 0`.
- `admin_count == count of addresses with DEFAULT_ADMIN_ROLE` (accounting never desyncs — but see C-2 about *how fast* it can change).
- No `Dispute` ever has `governance_tokens_minted > 0` while `final_score <= 0`.

### 6.4 Weird ERC20 compatibility
See M-2. Cairo's strict dispatcher typing means most Solidity "weird ERC20" failure modes (missing return value treated as success, `transfer` returning `void`) tend to fail loudly (call reverts) rather than silently succeed — which is safer by default, but still worth an explicit fee-on-transfer/rebasing guard around `funding_token` as noted.

### 6.5 Event indexing
`#[key]` usage was spot-checked across all events and looks consistent and sensible: entity IDs that you'd filter by (`dispute_id`, `proposal_id`, `owner`, `juror`, `caller`, `target`, `admin`) are marked `#[key]`; amounts/scores are left unindexed data fields. No missing-key or over-indexed issues found. One suggestion: `ConvictionRewardDistributed` indexes `proposal_id` and `recipient` but not `conviction_id` — fine as-is since `conviction_id` is scoped per-owner and rarely queried independently, but worth a second look if off-chain indexers need to join on it.

### 6.6 Slither / compiler static analysis
**Slither doesn't apply** — it's an EVM/Solidity-bytecode-and-AST tool and this is Cairo/Sierra. Cairo-native equivalents to run before deployment:
- `scarb build` — surface every compiler warning (unused imports, unused variables, etc.) — not run in this environment; do this first.
- **Caracal** (Trail of Bits / Crytic) — a static analyzer over Sierra for Starknet contracts, closest analogue to Slither.
- **Amarna** (Trail of Bits) — Cairo linter/static analyzer, exports SARIF.
- **Tayt** (Trail of Bits) — Cairo fuzzer, supports invariant testing (useful for §6.3 above).
- Trail of Bits also publishes a Cairo-specific vulnerability checklist ("not-so-smart-cairo") worth diffing this contract against (felt252 overflow patterns, L1↔L2 messaging if any is added later, address-conversion pitfalls — `_address_to_u256`/`_u256_to_address` here are already using the safe widening/narrowing pattern).

None of these were run in this environment (no network access to fetch/build the toolchain in this session); this audit is manual only — run the above before deploying.

### 6.7 NatSpec-equivalent docs
Cairo doesn't have NatSpec, but the community convention is `///` doc comments on trait methods. Example of what's currently missing, applied to one method as a template:

```cairo
/// Locks `amount` of the caller's currently-available (decayed, unlocked)
/// governance-token balance into a new `Conviction`.
///
/// # Arguments
/// * `amount` - amount to lock, in the same units as `governance_balance`.
///
/// # Reverts
/// * `'ZeroAmount'` if `amount == 0`.
/// * `'InsufficientGovBalance'` if `amount` exceeds the caller's available balance.
///
/// # Returns
/// The new conviction's `id` (unique per caller, not globally).
fn create_conviction(ref self: TContractState, amount: u256) -> u32;
```
Recommend applying this pattern to every method in `IStakeholderConviction`, particularly the ones with non-obvious revert conditions (`add_support`, `execute_proposal`, every `execute_set_*`).

### 6.8 Compiler warnings
Not run in this environment (file explicitly marked not compiled). Flag before deploy: `scarb build` with warnings-as-errors in CI.

### 6.9 Functions / variables never used
No dead code was found in the reviewed file — every storage field, event, and internal helper appears to be read/emitted/called from somewhere. (`ERC20InternalImpl`, `AccessControlInternalImpl`, `ReentrancyGuardInternalImpl`, `VrfConsumerInternalImpl` are all used via their respective `mint`/`burn`/`_grant_role`/`_revoke_role`/`start`/`end`/`set_vrf_provider` calls.) Re-verify with `scarb build`'s unused-import/unused-variable warnings once compiled, since static reading can miss macro-expanded usages.

### 6.10 Function/event parameter ordering
Spot-checked every event struct against its corresponding `self.emit(...)` call site — all field names are passed by name (Cairo struct literal syntax), so there's no positional-argument mis-ordering risk the way there can be in some languages; this is a structural advantage of the language here. No mismatches found.

### 6.11 Integer overflow / underflow
Cairo's `u256`/`i64`/etc. arithmetic is **checked by default** — overflow/underflow panics (reverts the transaction) rather than silently wrapping, unlike unchecked Solidity `uint`. So the classic silent-wrap exploit class is not present here. What remains is **panic-as-DoS**: e.g. `sum_weighted_scaled += score_i64 * SCALE * weight.into()` in `finalize_selection` could in principle overflow `i64` if `weight` (bounded by `num_draws`, currently unbounded — see H-2) is large enough, causing the whole `finalize_selection` call to revert permanently for that dispute. Bounding `num_draws` (H-2's fix) also closes this.

### 6.12 External call before updating a variable
Flagged as **H-3** (`deposit_funds`). `execute_proposal` gets this right (state updated, *then* external `token.transfer`).

### 6.13 Min/max deposit or revert
`deposit_funds` has no minimum (see L-2 for the related `create_conviction`/`add_support` dust-griefing angle) and no maximum. Not inherently unsafe for a treasury top-up, but a minimum would reduce dust-transaction spam; not a security-critical gap on its own.

### 6.14 Slippage protection
Not applicable — this contract has no AMM/swap-style function where price impact between quote and execution matters. All transfers are 1:1 fixed-amount token movements.

### 6.15 No magic numbers
See L-8 — overall good, essentially compliant.

### 6.16 Private constants
All module-level `const` declarations are effectively contract-private already (no `pub` on any of them, only the two `pub struct`/`pub trait` items and the handful of `pub` structs needed for the ABI are exposed). No leakage of internal constants into the public interface. No changes needed here.

### 6.17 Zero-address checks
Present for: `admin`, `initial_recipient`, `funding_token`, `vrf_provider` (constructor); `candidate` (`create_selection_dispute`); `funding_wallet` (`create_funding_proposal`); `new_admin` (`add_admin`); `token`/`new_vrf_provider`/`target` in the relevant `propose_set_*` calls. **Not explicitly checked:** `get_caller_address()` results are trusted implicitly to be non-zero (standard Starknet assumption — an unaccounted-for edge case if a zero-address caller is ever possible via some future account-abstraction quirk, but this is a very low-likelihood, low-severity gap, listed for completeness).

### 6.18 Failure to initialize
Not applicable in the usual "uninitialized proxy" sense — this contract has **no proxy/upgrade component** (`UpgradeableComponent` is not imported), and the constructor runs atomically at deployment, setting `admin`, initializing `erc20`, `accesscontrol`, and `vrf_consumer` all before any external call is possible. There is no "deploy-then-separately-initialize" window that a front-runner could hijack the way the linked openethereum/parity multisig-library issue describes (that bug was specifically about a shared, separately-initializable library contract). If this contract is ever placed behind a proxy in the future, re-run this check against that pattern specifically (constructor logic would need to move to an `initializer()` guarded by an `is_initialized` flag).

### 6.19 Storage collision
Not applicable for the same reason — no proxy pattern, no delegatecall-equivalent, so there's no separate implementation/storage-layout pairing that could collide. If this is ever wrapped in an upgradeable proxy later, storage-layout compatibility across upgrades would need to be audited at that time (Cairo's component-based storage model has its own layout rules distinct from Solidity's slot-based collision risk — worth a dedicated review if upgradability is added).

### 6.20 Centralization / silent upgrades
No upgrade mechanism exists in this contract at all (good — nothing to "silently upgrade"). Centralization risk instead concentrates in `DEFAULT_ADMIN_ROLE`: see **C-2** for the concrete takeover path via non-timelocked `add_admin`/`remove_admin`. Recommend a Safe/multisig (not an EOA) hold `DEFAULT_ADMIN_ROLE` regardless of the C-2 fix, as defense-in-depth.

### 6.21 Signature replay
Not applicable — no signature-based authorization scheme is used anywhere in this contract (no `is_valid_signature`, no meta-tx/permit pattern). The only "signed" data is Cartridge VRF's proof, which is verified inside `vrf_consumer.consume_random` (external component, out of scope for this file) and is inherently single-use per request by that component's design, not by anything in this file.

### 6.22 Weak randomness
VRF (Cartridge) is a sound choice over `block_timestamp`/`get_tx_info` hashing. The real weakness isn't the randomness source itself, it's **how few draws can be requested from it** — see **C-1**: `num_draws = 1` turns a Schelling-game into a coin flip an attacker can bias by controlling stake share.

### 6.23 Mishandling of ETH
Not applicable — this contract never handles native STRK/ETH; all value transfer is via ERC20 (`funding_token` externally, this contract's own embedded token internally). No `payable`-equivalent entrypoints exist, so there's no stuck-ETH or reentrant-ETH-transfer risk class here at all.

### 6.24 DoS attack analysis
Summarized: H-2 (unbounded loops in dispute creation, finalization, and — most importantly — proposal execution/reward distribution) is the core DoS surface. Secondary: L-2/M-4 (cheap-griefing of supporter/grant lists feeds directly into H-2's cost growth over time). `batch_apply_decay`'s `MAX_BATCH_DECAY = 50` cap is a correctly-applied mitigation pattern — the same style of cap should be applied to `num_draws` and, ideally, to supporters-per-proposal.

### 6.25 Pull-over-push pattern
This is the single highest-leverage structural fix available: **`execute_proposal` currently pushes** both the treasury payout (fine — single recipient, single external call, already CEI-safe) **and conviction rewards** (not fine — unbounded internal loop minting to every active supporter in one transaction, see H-2/M-4) in one atomic call. Contrast with `claim_juror_reward`, which **correctly uses a pull pattern** — jurors claim their own share individually, so no single caller's gas bill scales with the number of participants, and no participant can block another's payout. **Recommendation: rework conviction-reward distribution to mirror `claim_juror_reward`** — record each proposal's `total_power` and `reward_total` (or per-conviction snapshot) at execution time, then let each supporter call a new `claim_conviction_reward(proposal_id, conviction_id)` to pull their own share. This removes the unbounded loop from the critical fund-release path entirely and closes H-2's most dangerous instance.

### 6.26 Check-Effects-Interactions (CEI)
- `execute_proposal`: ✅ correct (state updated, then external call).
- `claim_juror_reward`: ✅ correct (claimed-flag set, then internal-component transfer).
- `stake`/`unstake`: technically call `self.erc20.transfer_from`/`transfer` before/after Fenwick updates respectively, but these are **same-contract embedded-component calls**, not cross-contract external calls — no real reentrancy surface there despite the raw ordering (Fenwick update happens after transfer_from in `stake` — worth reordering anyway for consistency/defense-in-depth, but not currently exploitable).
- `deposit_funds`: ❌ violates CEI — see **H-3**.

---

## 7. Priority Fix List (suggested order)

1. **C-2** — timelock or multisig-quorum `add_admin`/`remove_admin`.
2. **C-1** — bound `num_draws`, add per-candidate dispute rate limiting.
3. **H-1** — lock juror stake for the duration of a dispute they've been drawn into.
4. **H-2 / §6.25** — move conviction-reward distribution to a pull/claim pattern; cap `num_draws`.
5. **H-3** — fix CEI ordering in `deposit_funds`.
6. Everything in §4 (Medium) as time/budget allows before mainnet deployment.
7. Run `scarb build`, `snforge` (with the test list in §6.2), `Caracal`, and `Tayt` (invariants from §6.3) before audit sign-off — none of these were executed in this review.

---

*This is a manual code review, not a substitute for a funded third-party audit, formal verification of the arithmetic (especially `_isqrt` and the trimmed-mean pipeline), or fuzz/invariant testing against a compiled build.*
