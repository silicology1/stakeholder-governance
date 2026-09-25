# Security Analysis v3 — `StakeholderConviction` (Cairo / Starknet)

**Date:** 2026-09-23
**Scope:** `src/lib.cairo` (contract module + module header), `src/constants.cairo`, `src/types/{dispute,governance,admin}.cairo`, `src/events.cairo`, `src/utils/{math,fenwick,random}.cairo`, `tests/test_contract.cairo`, `Scarb.toml`, `Scarb.lock`.
**Method:** fresh manual/static pass over the entire code path (draw → commit → reveal → finalize → slash → reward; conviction → vote → execute; decay; timelock; upgrade), cross-checked against v1/v2 findings (`code_review_findings.md`, `StakeholderConviction_Security_Analysis_v2.md`) and the execution-backed regression suite.
**Verification:** `scarb check` ✅ · `scarb build` (sierra) ✅ · `snforge test` ✅ — **29/29 passing** (fuzz seed `1111`).
**Working-tree delta since v2:** doc-only. The v3 header comment changes in `src/lib.cairo` (L-7 semantics: `final_score >= 0` refunds bond and proposal deposit; score 0 neutral) were applied; **no code/test changed**. Class hash matches the v2 state.

---

## 1. Executive Summary

| Severity | Status | Count | Findings |
|---|---|---|---|
| High | Open (design, accepted residual) | 1 | A-1 governance capture via self-dealing evaluation |
| High | Open (new, code issue) | 1 | A-2 bonus-mint budget coupling bricks slashing & decay |
| Medium | Open (new) | 1 | B-1 atomic reward revert strands proposal deposits |
| Medium | Open (residual) | 1 | B-2 no escape hatch for never-executable proposals |
| Medium | Open (residual M-2) | 1 | B-3 permanently locked value (slash dust, slashed deposits) |
| Low | Open | 4 | C-1 `burn` misses reentrancy guard; C-2 `disable_upgrades_forever` untimelocked; C-3 `conviction_threshold(0)` allowed; C-4 dead constants |
| Info | Open | 2 | D-1 juror lock aggregation may exceed stake; D-2 negative votes don't reduce quorum |

A-2 and B-1 are the two findings new to this round and are the highest-priority *code* fixes (both cheap: decouple optional mints from mandatory state transitions). Everything the v2 round claimed as fixed for H-1…H-4, M-1, M-3, L-1…L-7 was re-verified in place (see §3). A-1 and the value-lock items remain accepted/known residual design risk.

This analysis is manual/static + execution-backed. It does **not** replace a paid audit before mainnet deployment.

---

## 2. Verified baseline (v2 fixes still present)

| # | Guard | Location (current) | Status |
|---|---|---|---|
| H-1 | `AccessControlMixinImpl` not `#[abi(embed_v0)]` — no external `grant_role`/`revoke_role`/`renounce_role` | `src/lib.cairo:365-366` | ✅ present |
| H-2 | `_apply_decay` asserts `user != get_contract_address()` | `src/lib.cairo:2252` | ✅ present |
| H-3 | zero-reveal disputes settle score-neutral, refund bond, clear flags | `src/lib.cairo:920-947` | ✅ present |
| H-4 | `MAX_NUM_DRAWS = 100` enforced | `src/constants.cairo:30`, `src/lib.cairo:1645` | ✅ present |
| M-1 | funding-token stub pair removed | interface/impl | ✅ absent |
| M-3 | all u256 `propose_set_*` cap at `MAX_SUPPLY` | `src/lib.cairo:1512-1633` | ✅ present |
| L-1 | month rollover clamps to `MAX_ROLLOVER_MONTHS` | `src/lib.cairo:1907-1911` | ✅ present |
| L-3 | SRC5 wired (`SRC5Impl` embedded; `supports_interface` exposed) | `src/lib.cairo:369-370` | ✅ present |
| L-4 | reentrancy guards on `commit_vote`/`reveal_vote` | `src/lib.cairo:801,819` | ✅ present |
| L-6 | `MAX_EVIDENCE_LEN = 1024` caps | `src/lib.cairo:679,1146` | ✅ present |
| L-7 | `final_score >= 0` refunds bond + deposit; score 0 neutral | `src/lib.cairo:1051-1052,1304-1305` | ✅ present |
| L-8 | fuzz/invariant config + 2 fuzz tests | `Scarb.toml`, tests | ✅ 29/29 |

Also re-verified in this pass: Fenwick `find`/`sub`/`add` invariants, the trimmed-mean/outlier math, i64/u64 intermediate overflow margins, commit-reveal hash binding, and the juror lock snapshot release accounting (each snapshot ≤ aggregate locked sum, so `_release_dispute_lock` cannot underflow).

---

## 3. New findings — code level

### A-2. Bonus-mint budget coupling bricks slashing and decay when the month budget is exhausted

- **Severity:** High (availability / mechanism stall)
- **Location:** `slash_non_revealer` `_mint_from_budget(caller, SLASH_KEEPER_REWARD)` at `src/lib.cairo:883`; `_apply_decay` caller-reward mint at `src/lib.cairo:2298`; mint gate at `src/lib.cairo:1956` (`assert(minted + amount <= budget, 'BudgetExceeded')`).
- **Description:** the pro-bono keeper reward and the decay-caller reward are minted **from the same monthly budget** that pays score rewards, inside the same transaction as the primary operation. When the month budget is exhausted — which is the *normal* terminal state once `total_supply() == MAX_SUPPLY` and prior-month burns are zero, but can also happen mid-month after any heavy reward month — these mints revert `'BudgetExceeded'`:
  - `slash_non_revealer` **reverts entirely**: the strike already applied (`_fenwick_sub`, `juror_stake`, `slash_pool`, `dispute_slashed`, `_release_dispute_lock`, `JurorSlashed` event) is rolled back. A non-revealer whose `reveal_deadline` has passed can therefore never be slashed, keeps their stake, and — critically — their dispute lock is never released: `juror_open_lock_count` stays elevated and `juror_locked_total` stays inflated, pushing them toward the `MAX_CONCURRENT_JUROR_LOCKS` skip state in future draws.
  - `apply_decay` **reverts the burn**: decayed balance is not burned, `_track_burn` does not record, and the user is not rewarded. During an exhausted month the token *stops decaying* for everyone, freezing an entire incentive mechanism.
  - `execute_proposal`'s reward mint revert makes the author deposit stay locked (see B-1).
- **Impact:** slashing/disincentive pipeline and the decay/caller-reward pipeline become non-functional exactly when supply is capped. Locks freeze; keepers cannot clear non-revealers; non-reveal evasion becomes free.
- **Recommendation:** make the optional (keeper / caller) reward mints **best-effort and non-blocking** — e.g. pre-check `get_remaining_month_budget() >= reward` and skip (no mint, no revert) when it does not hold, or route them out of the protocol budget entirely. The core state transition (slash, lock release, burn, `_track_burn`) must never depend on a bonus-mint succeeding.
- **Test gap:** no test covers `slash_non_revealer` or `apply_decay` under an exhausted month budget. Add: exhaust budget → try slash → assert slash succeeds (or reward skipped) and lock releases; try `apply_decay` → assert burn still applies.

### B-1. Atomic reward mint can strand an author's proposal deposit

- **Severity:** Medium (fund-lock + availability)
- **Location:** `execute_proposal` `src/lib.cairo:1304-1334` (deposit refund + `_mint_from_budget` in one tx); gate `src/lib.cairo:1956`.
- **Description:** when `final_score >= 0` a proposal's deposit refund and the score reward are paid in the same atomic transaction. If `_mint_from_budget` hits `'BudgetExceeded'`, the **entire call reverts** — including the deposit refund — and `p.executed` stays `false`. The author can try again later (a fresh month eventually arrives), but:
  - A large `reward_multiplier` relative to the budget, or a month with heavy competition for the budget, can make a legitimate positive-score proposal *repeatedly* revert, locking the deposit indefinitely; and
  - Once supply is capped and burns are low/zero, the budget is ~0 and **any positive-score proposal with a non-zero reward can never execute** — the deposit is irretrievably stuck (no cancel path, see B-2).
- **Recommendation:** decouple the two settlements. Pay the deposit refund unconditionally (it is owed regardless of score sign), then mint the reward as a separate best-effort step whose failure does not roll back execution. Consider honoring the refund even if the reward cannot be minted (record an unfulfilled-obligation view or queue for a future month).
- **Test gap:** `test_reward_exceeding_monthly_budget_reverts` asserts the revert but does not verify the deposit outcome; add a test that after the failed month the author can still recover the deposit (or that the refund path is never budget-dependent).

---

## 4. New findings — process / hygiene (Low)

### C-1. `burn` is the only state-mutating external without the reentrancy guard

- `src/lib.cairo:1374`. `burn` calls `erc20.burn` + `_track_burn` with no `reentrancyguard`. Harmless today (ERC20 hooks are empty, no external calls), but it is the sole inconsistency vs. every other entrypoint and invites a wrong-mode regression. Add `start()`/`end()`.

### C-2. `disable_upgrades_forever` is immediate, not timelocked

- `src/lib.cairo:1813`. An irreversible upgrade-path cut can be executed by a single admin key in the same block, while every other privileged action carries a 3–7 day timelock. Recommended: put `disable_upgrades_forever` behind the same `UPGRADE_TIMELOCK_DURATION` (or require a two-step confirm), so a compromised key cannot permanently brick the recovery path before the community can react. At minimum document it as intentionally instant.

### C-3. `propose_set_conviction_threshold(0)` is allowed

- `src/lib.cairo:1534`. A zero threshold makes the `total_power >= threshold` check vacuous: any proposal executes with the (possibly empty) histogram, scoring 0 → neutral, refunding the deposit. Not directly exploitable, but a footgun that turns the threshold gate off. Consider `assert(threshold > 0)`, mirroring the bond/stake guards.

### C-4. Dead constants

- `MAX_LOCK_DURATION` (`src/constants.cairo:59`) and the five `DEFAULT_*` economic constants (`DEFAULT_EVALUATION_BOND_AMOUNT`, `DEFAULT_REPUTATION_STAKE`, `DEFAULT_CONVICTION_THRESHOLD`, `DEFAULT_REWARD_MULTIPLIER`, `DEFAULT_MINI_REWARD_MULTIPLIER`, `src/constants.cairo:61-65`) are never read (the constructor ingests the values as parameters). Remove or wire them up (e.g. constructor defaults) to cut audit surface. `DEFAULT_CALLER_REWARD_AMOUNT` is used (lib.cairo:597).

---

## 5. Open residual risk (accepted / already tracked)

### A-1. Governance capture via self-dealing evaluation (design, High)

- **Description:** the candidate is **not excluded** from their own jury. `request_evaluation` (`src/lib.cairo:676-799`) draws stakeholders stake-weighted *with replacement* from the full Fenwick tree; a candidate who controls a large share of staked weight draws themselves at high frequency, votes their own dispute a high score, harvests a governance grant (`governance_tokens_for_score`, score 5 → 50,000 tokens, `src/utils/math.cairo:102`), converts it into conviction power, and repeats — compounding control over proposals and, via `execute_proposal`, up to the whole monthly inflation budget. Repeatable with no periodic cap on grants (slot rotation only enforces 64 outstanding grants).
- **Status:** this is v1 finding #3, unchanged by design (documented in AGENTS.md residual risk #4). Flagging again because it interacts with A-2/B-1 (the only budget back-pressure is the monthly mint cap, which a majority stakeholder can deliberately exhaust).
- **Recommendation (unchanged):** exclude the candidate from their own draw, cap any single stakeholder's share of total draws per dispute, require a minimum number of distinct jurors, and optionally gate governance-grant accumulation per holder per time window.

### B-2. No escape hatch for never-executable proposals

- Deposits are anti-Sybil, so spam-refund is intentionally unavailable, but there is **no cancel/expiry** either. A proposal that never reaches `conviction_threshold` (low turnout, or an admin threshold increase) locks the author's 10-token deposit forever with no recourse. Add a timelocked-only floor on threshold changes and/or a proposal expiry that forfeits the deposit to the `slash_pool` instead of silently wedging it.

### B-3. Permanently locked value (M-2 residual, still open)

- Slash-pool dust from floor division in `claim_juror_reward` (`src/lib.cairo:1099`) with no coherent claimant left, and slashed proposal deposits (`src/lib.cairo:1336-1343`, "relabeled" with no destination), accumulate in the contract balance with no withdrawal path. Recommend a governance sweep/`rescue` function or explicit burn-and-emit accounting, plus reconciliation tooling to confirm the contract's ERC20 balance always equals `Σ locked + Σ bonds + Σ deposits + Σ slash_pools − Σ released`.

### D-1. Juror lock aggregation can exceed stake

- Snapshots are taken per-dispute at draw time, so `juror_locked_total` is the sum of per-dispute snapshots and can exceed `juror_stake` (anti-evasion is honored, but "locked" is not collateralized 1:1). No underflow is reachable (`_release_dispute_lock` subtracts a snapshot that is always ≤ the aggregate), but `get_juror_unlocked_stake` reads 0 and `unstake` is fully blocked until every open dispute resolves. Document the accounting model explicitly; consider releasing over-locked margin on slash so stakeholders can self-serve partial unstake.

### D-2. Negative votes do not reduce quorum

- The execution threshold is on total voting *power* regardless of score sign (histogram `_compute_weighted_score` incl. negative buckets, `src/lib.cairo:2197`). A hostile flood of small-weight negative convictions can help pass the threshold while dragging the mean negative, slashing an author's deposit. Accepted design (see `security/negative_votes.md`), tracked for awareness.

---

## 6. Upgrade & timelock review (regression check)

- Generic engine `_propose_change`/`_execute_change` keys by felt252; reads cast via `try_into().unwrap()` — the values are guaranteed castable because every `execute_*` writes exactly what the matching `propose_*` stored under the same key, and all `propose_*` bound inputs (`<= MAX_SUPPLY`, `<= 10_000`, `<= MAX_NUM_DRAWS`). No cross-key alias since the M-1 removal.
- Admin roster: add/remove timelocked, `CannotRemoveLastAdmin`, re-propose overwrite semantics are sane; the pending entry is cleared on execute.
- `execute_upgrade` still has **no mechanical storage-layout-compat check** (residual M-2 #2): the 7-day timelock remains the only mitigant against a storage-colliding class. Recommend a documented layout manifest + pre-deploy diff check rather than on-chain enforcement (on-chain class-hash→layout checking is impractical today).

---

## 7. Test coverage gaps worth closing

1. Slash and decay continue to work (or reward is skipped) when the month budget is exhausted — **A-2**.
2. Deposit recovery when a reward doesn't fit the budget — **B-1**.
3. Self-dealing draw behaviour (candidate-drawn-into-own-dispute) — **A-1**.
4. Proposal that never reaches threshold: deposit status, and threshold-raised-above-reachable-power behaviour — **B-2**.
5. `slash_non_revealer` boundary: redraw-cap hit (`NoEligibleJurors`), 15-lock skip, slashing a juror across two concurrent disputes.
6. `disable_upgrades_forever` + `execute_upgrade` happy path and timelock.
7. `claim_juror_reward` dust left behind (reconciliation invariant).
8. Grant-slot overwrite at `MAX_GOV_GRANTS_PER_HOLDER` with mixed-decayed grants.

## 8. Fix priority

1. **A-2** — make keeper/decay rewards best-effort; never let a bonus mint revert the primary state transition. *(code, small)*
2. **B-1** — decouple deposit refund from reward mint; execute-without-reward fallback. *(code, small)*
3. **A-1 / B-2** — design decisions: candidate exclusion, threshold floor/expiry. *(design + code)*
4. **C-2** — timelock `disable_upgrades_forever`. *(code, small)*
5. **C-1, C-3, C-4** — hygiene. *(tiny)*
6. **B-3 / D-1** — rescue/accounting + documentation. *(code + docs)*

## 9. Verification record

```bash
scarb check   # Finished checking dev profile — clean
scarb build   # sierra target compiles
snforge test  # 29 passed, 0 failed (fuzzer seed 1111); test list below
```

`test_apply_decay_on_contract_address_reverts` · `test_batch_apply_decay…` · `test_zero_reveal_refunds_bond_and_clears_dispute` · `test_num_draws_above_max_reverts` · `test_param_amount_above_max_supply_reverts` · `test_far_future_rollover_clamps_instead_of_reverting` · `test_create_proposal_evidence_too_long_reverts` · `test_zero_score_refunds_deposit_and_mints_no_reward` · `test_fuzz_apply_decay_is_non_increasing` (100) · `test_fuzz_stake_unstake_conserves_value` (250) · plus the 19 prior selection/voting/timelock/budget tests.

## 10. Fix log (post-v3)

**Date:** 2026-09-23
**Scope:** A-2 · B-1 · C-1 · C-2 · C-3 · C-4 (the code fixes prioritized in §8). Contracts the worked-tree source of truth: `src/lib.cairo`, `src/events.cairo`, `src/constants.cairo`, `tests/test_contract.cairo`, plus docs (`AGENTS.md`, this file).

| ID | Fix applied | Notes |
|---|---|---|
| A-2 | `_mint_from_budget` is now **best-effort** (returns `bool`, never reverts): returns `false` on zero amount, remaining-month-budget exhaustion, or `MAX_SUPPLY` headroom exhaustion; always calls `_ensure_current_month` first. Both bonus-mint call sites (`slash_non_revealer` keeper reward, `_apply_decay` caller reward) skip the mint when it returns `false`; the slash/lock-release and the burn/cooldown write always happen. | `BudgetRewardMinted` + reward-specific events are emitted only on an actual mint, so skipping is observable. |
| B-1 | `execute_proposal` (positive-score branch) refunds the author's deposit **unconditionally**; the funding payout is minted only via the same best-effort path. | Verified in a zero-budget month: execute, refund, and governance flows all succeed with no payouts. |
| C-1 | `burn` wrapped in `reentrancyguard.start()` / `end()`. | |
| C-2 | `disable_upgrades_forever` (single-step) removed. Replaced with two-step `propose_disable_upgrades` / `execute_disable_upgrades` on the 7-day `UPGRADE_TIMELOCK_DURATION`, gated by a `pending_upgrade_disable: PendingChange` storage var + `UpgradeDisableProposed` event; `execute` also clears any pending upgrade. New view `get_pending_upgrade_disable`. | A single compromised admin key can no longer instantly brick the recovery path. |
| C-3 | `conviction_threshold > 0` asserted in `propose_set_conviction_threshold` and in the constructor. | |
| C-4 | Removed dead constants `MAX_LOCK_DURATION` and the five `DEFAULT_EVALUATION_BOND_AMOUNT` / `DEFAULT_REPUTATION_STAKE` / `DEFAULT_CONVICTION_THRESHOLD` / `DEFAULT_REWARD_MULTIPLIER` / `DEFAULT_MINI_REWARD_MULTIPLIER`. Kept `DEFAULT_CALLER_REWARD_AMOUNT` (still referenced). | |

**Tests:** reworked `test_reward_exceeding_monthly_budget_reverts` → `test_reward_exceeding_monthly_budget_skips_mint_but_executes`; added `test_zero_budget_month_slash_decay_and_execution_still_work`, `test_disable_upgrades_timelocked_flow`, `test_disable_upgrades_before_timelock_reverts`, `test_zero_conviction_threshold_reverts`.

```bash
scarb check   # Finished checking dev profile — clean
scarb build   # sierra target compiles (new class hash)
snforge test  # 33 passed, 0 failed (fuzzer seed 1111)
```

**ABI change (intentional):** `disable_upgrades_forever` removed; `propose_disable_upgrades`, `execute_disable_upgrades`, `get_pending_upgrade_disable` added.

## 11. Fix log (round 2 — conviction-voting redesign, dust-voting elimination)

**Date:** 2026-09-24
**Scope:** the 09-21 review findings #1 (vote histogram double-count / `remove_support` asymmetry) and #2 (unbounded supporter loop → execute DoS). This is a **design rewrite of the conviction subsystem**, not a point fix. Working-tree source of truth: `src/lib.cairo`, `src/types/governance.cairo`, `src/constants.cairo`, `tests/test_contract.cairo`, `AGENTS.md`. **Storage layout changed — fresh-deploy-only; this is not an upgrade path from any supporter-registry version.**

### 11.1 What changed

| Aspect | Before | After |
|---|---|---|
| Vote weight | `level * sqrt(amount * hours_locked)` — time-compounding, recomputed per read | `isqrt(level * amount)` (`_vote_weight`, `src/lib.cairo:2283`) — **static, frozen at vote time** |
| Supporters | `Supporter` registry, `proposal_supporters` map, `supporter_count`, `_proposal_total_power` (live loop over all supporters) | all **removed**. `FundingProposal.power_total` is a frozen accumulator bumped per vote (`src/lib.cairo:1286`, read at execute `src/lib.cairo:1330`) → `execute_proposal` is O(1), voting unbounded |
| Re-vote / retract | `remove_support` reset `is_supporting`, allowing infinite re-voting + weight double-count | **votes are permanent**; re-vote on the same proposal banned via `conviction_voted_on: Map<(ContractAddress, u32, u256), bool>` gate `'AlreadyVotedOnProposal'` (`src/lib.cairo:1270`) |
| Lock window | `created_at` + `level * 3 months` implied; `support_start` written, never read | `lock_duration = level * conviction_base_lock` stored at `create_conviction`; vote requires `now < created_at + lock_duration` (`'LockExpired'`), release requires `now >= created_at + lock_duration` (`'LockNotExpired'`, `src/lib.cairo:1305`) |
| Vote placeholders | one `active_proposal` per conviction | up to `max_votes_per_conviction` distinct proposals (`'MaxVotesReached'`), enforced by `conviction_voted_on` + `votes_cast` |
| Conviction power | nonzero once created | `0` until the first vote is cast (`get_conviction_power`, `src/lib.cairo:1399`) |

### 11.2 Why dust-voting capture is eliminated

The audit/review worst case was: park a dust conviction for years → it compounds to real voting power → occupy/cap-out the supporter list so real backers cannot reach threshold (also griefing `execute_proposal` gas). Three independent layers now rule this out:

1. **No time compounding.** Power is frozen at vote time and scales with `isqrt(amount)`: dust is dust forever, independent of how many years the conviction sits. `get_conviction_power` returns 0 until the first vote.
2. **No finite slots to exhaust.** The supporter registry and its caps are gone; votes are unbounded and `execute_proposal` reads a single frozen `power_total` accumulator (O(1)). A dust-storm cannot pad a list or become a gas bomb (regression-covered by `test_voting_scales_beyond_old_supporter_cap`, 400 backers).
3. **Convictions cost real resources.** Every vote occupies one of `max_votes_per_conviction` slots on a single conviction, each conviction is locked for `level * conviction_base_lock` before the stake frees again, votes are permanent, and released convictions can never vote again.

**Residual (accepted, inherent to the histogram, not a slot/gas attack):** a dust vote still tilts the weighted mean by its share `isqrt(amount)/Σpower` on an already-qualifying proposal (`_compute_weighted_score`, `src/lib.cairo:2290`). That share is **bounded by stake, not time**, scales linearly down with dust size, and there is no capped resource to hold hostage. Regression-covered by `test_dust_conviction_power_is_frozen_across_time` (1-wei conviction, 3-year timestamp jump, power and `power_total` unchanged).

### 11.3 Findings resolution

| Review finding | Verdict |
|---|---|
| #1 Vote histogram double-count + `remove_support` asymmetry | **RESOLVED.** `remove_support` is gone; votes permanent; re-vote forbidden (`'AlreadyVotedOnProposal'`). Weight can only ever be added once per conviction-proposal pair. |
| #2 Unbounded loops → permanent DoS (supporter pad / `execute_proposal` gas) | **RESOLVED.** `_proposal_total_power` loop and `Supporter` row-per-vote storage removed; `power_total` is an O(1) frozen accumulator. |
| #7 dead `proposal_total_votes` / `proposal_total_weight` | still present today — outside this round's scope (flagged for hygiene). |

### 11.4 New timelocked admin parameters

- `conviction_base_lock` — seconds of lock window per level. Default `9_460_800` (109.5 days/level ≈ 3 y at L10); cap `MAX_LOCK_DURATION = 157_680_000` (5 y). `propose_set_conviction_base_lock` asserts `> 0` (`'InvalidDuration'`) and `<= MAX_LOCK_DURATION` (`'TooHigh'`); key `PARAM_CONVICTION_BASE_LOCK` (`src/lib.cairo:1711-1725`).
- `max_votes_per_conviction` — max distinct proposals one conviction may vote on. Default 10, cap 100, `'TooHigh'` on propose; key `PARAM_MAX_VOTES_PER_CONVICTION` (`src/lib.cairo:1727-1740`).

Both use the existing `_propose_change`/`_execute_change` engine with getters; both are timelocked `TIMELOCK_DURATION` (3 days).

### 11.5 Verification record

```bash
scarb check   # Finished checking dev profile — clean
scarb build   # sierra target compiles (new class hash)
snforge test  # 43 passed, 0 failed (fuzzer seed 1111)
```

**Tests (round-2 delta, 29 → 43):** static-weight assertions `31_622_776_601` (L1×1000 tok) and `77_459_666_924` (L3×2000 tok); `test_conviction_cannot_vote_twice` now expects `'AlreadyVotedOnProposal'`; `test_max_votes_per_conviction_enforced` (`'MaxVotesReached'`), `test_single_conviction_votes_on_multiple_proposals`, `test_voting_scales_beyond_old_supporter_cap`, `test_conviction_power_and_release_accounting` (lock-window release), gate tests `'LockExpired'`/`'LockNotExpired'`, timelocked-change tests for both new params, cap/propose-revert tests (`'TooHigh'`, `'LockTooLong'`), `test_dust_conviction_power_is_frozen_across_time`, and fuzz `test_fuzz_power_total_matches_sum_of_vote_weights`.