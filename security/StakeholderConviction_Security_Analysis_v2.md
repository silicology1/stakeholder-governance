# Security Analysis v2 — `StakeholderConviction` (Cairo / Starknet)

**Date:** 2026-09-22
**Scope:** `src/lib.cairo`, `src/constants.cairo`, `src/types/{dispute,governance,admin}.cairo`, `src/events.cairo`, `src/utils/*`, `tests/test_contract.cairo`, `Scarb.toml`, `Scarb.lock`.
**Code state:** fixes for the v2 checklist are **implemented and verified** in the working tree (not yet committed).
**Verification:** `scarb check` ✅ · `scarb build` (sierra) ✅ · `snforge test` ✅ — **29/29 passing** (19 prior + 10 new), fuzz at 100/250 runs (seed `1111`).

---

## 1. Executive Summary

| Severity | Count | Origin |
|---|---|---|
| High | 4 | v2 checklist (H-1 … H-4) |
| Medium | 3 | v2 checklist (M-1 … M-3) |
| Low / informational | 8 | v2 checklist (L-1 … L-8) |

All four High findings are fixed and covered by regression tests. The Medium items are fixed (M-1, M-3); M-2 (residual value-lock / upgrade-storage items, see §5) remains **open** and is documented as residual risk. The Low items are all fixed except the process/tooling subset of L-8 that was intentionally scoped out (see §6).

This analysis is manual/static + execution-backed by the snforge suite. It does **not** replace a paid audit before mainnet deployment.

---

## 2. Change-set recap since v1

Prior review rounds (v1, `code_review_findings.md`) drove these already-landed changes, which the v2 analysis assumed as baseline:

- `remove_support` **deleted** — votes are permanent; the frozen histogram always matches the live supporter set.
- `release_conviction` frees locked stake **without retracting** the cast vote (vote ledger unchanged).
- `MAX_PROPOSAL_SUPPORTERS = 200`, `MAX_GOV_GRANTS_PER_HOLDER = 64` bound `execute_proposal` / `_decayed_total` iteration.
- Admin roster add/remove is timelocked; last-admin guard enforced.

Today's session additionally implemented every fix in §3–§5. See §7 for the verification record.

---

## 3. High Findings (all fixed)

### H-1. Public AccessControl bypass of the timelocked admin roster

- **Location:** impl bindings block (`src/lib.cairo:361-364`).
- **Description:** `AccessControlMixinImpl` was previously declared `#[abi(embed_v0)]`, exporting OZ's external `grant_role`, `revoke_role`, and `renounce_role` entrypoints. Any caller could grant themselves `DEFAULT_ADMIN_ROLE` instantly — completely bypassing the timelocked `propose_add_admin` / `propose_remove_admin` roster and the last-admin guard, and instantly controlling every timelocked parameter and the upgrade path.
- **Impact:** catastrophic — full privileged takeover in a single transaction.
- **Resolution:** the `#[abi(embed_v0)]` attribute is removed. The unembedded impl remains so internal code still resolves `self.accesscontrol.has_role(...)`. There is now **no external** `grant_role`/`revoke_role`/`renounce_role` in the ABI. Note: because of this, the last admin can no longer renounce — an intentional "cannot remove last admin" hardening.
- **Verification:** compiles with internal roster code intact; no test exercises `grant_role` (none exposed). Not directly assertable via snforge, but the ABI no longer contains the selector.

### H-2. Public ERC20 decay can burn the contract's own escrow → insolvency

- **Location:** `_apply_decay` (`src/lib.cairo:2251`).
- **Description:** `apply_decay` / `batch_apply_decay` let anyone decay any address, including the **contract itself**. Because `_apply_decay` calls `erc20.burn(user, …)`, burning the contract's own balance destroys the escrowed pool backing locked juror stakes, evaluation bonds, and proposal deposits — making `unstake`, `claim_juror_reward`, bond refunds, and deposit refunds insolvent-revert after enough decay.
- **Impact:** silent insolvency / frozen obligations.
- **Resolution:** `_apply_decay` now asserts `user != get_contract_address()` → `'ProtectedAddress'`, covering both single and batch entrypoints.
- **Verification:** `test_apply_decay_on_contract_address_reverts`, `test_batch_apply_decay_with_contract_address_reverts` (both `#[should_panic(expected: 'ProtectedAddress')]`, PASS).

### H-3. Zero-reveal disputes permanently stuck as active (bond + candidate lock)

- **Location:** `finalize_selection` (`src/lib.cairo:894`, zero-reveal branch at `:919`).
- **Description:** finalization asserted `total_weight > 0` (`'NoReveals'`). A dispute where no drawn juror reveals could therefore never finalize: the `final_score >= 0` refund path was unreachable, the evaluation bond stayed locked in the contract forever, and `has_active_dispute`/`active_dispute_for_candidate` stayed set so the candidate could never be evaluated again. Since a voter can also abstain on purpose, this was a cheap grief to (a) burn a candidate's bond and (b) permanently DoS that candidate.
- **Impact:** permanent loss of the evaluation bond + permanent denial of evaluation for a candidate.
- **Resolution:** zero-reveal disputes now settle score-neutral: `final_score = 0`, `final_score_set = true`, `total_weight_revealed = total_coherent_weight = 0`, `phase = PHASE_FINALIZED`, `bond_settled = true`; the bond is refunded to the requester (`BondRefunded`), both active-dispute flags are cleared, `DisputeFinalized` is emitted, and the candidate may re-apply.
- **Verification:** `test_zero_reveal_refunds_bond_and_clears_dispute` (PASS) asserts refund, neutral score, cleared flags, and successful re-request.

### H-4. Unbounded juror draw loop in `request_evaluation` (gas bomb)

- **Location:** `propose_set_num_draws` (`src/lib.cairo:1643-1644`); draw loop in `request_evaluation`.
- **Description:** `num_draws` (a timelocked admin parameter) had a lower bound (`MIN_NUM_DRAWS`) but **no upper bound**; the draw loop in `request_evaluation` runs `num_draws` Fenwick lookups + storage writes per call. A mis-set or compromised value turned every candidate's evaluation into a guaranteed out-of-gas revert.
- **Impact:** evaluation permanently unusable.
- **Resolution:** new `MAX_NUM_DRAWS = 100` (`src/constants.cairo:30`); `propose_set_num_draws` rejects anything above it with `'AboveMaxNumDraws'`.
- **Verification:** `test_num_draws_above_max_reverts` (PASS); existing timelock test still passes.

---

## 4. Medium Findings

### M-1. `funding_token` ABI stub wrote garbage under `PARAM_VRF_PROVIDER`

- **Location:** removed — interface + `propose_set_funding_token`/`execute_set_funding_token` (`src/lib.cairo`).
- **Description:** the unused funding-token pair were routed through the timelock engine under the **`PARAM_VRF_PROVIDER` key**, so proposing/executing a funding-token "change" silently consumed or wiped any pending (or future) VRF-provider change.
- **Impact:** admin footgun that corrupts the VRF provider configuration.
- **Resolution:** **both entrypoints removed** from the interface and impl (deliberate ABI change; breaking, but no deployed consumers). `PARAM_VRF_PROVIDER` is now used only by the real `propose_set_vrf_provider`/`execute_set_vrf_provider` pair.
- **Verification:** compiles; `grep` confirms no remaining references.

### M-2. Residual — permanently locked value + upgrade storage-collision guard (open)

- **Location:** `claim_juror_reward` truncation (`src/lib.cairo:~1061`), slashed-proposal-deposit handling, `execute_upgrade`.
- **Description:** slash-pool dust left over from integer truncation, and slashed proposal deposits, have no withdrawal path once no coherent claimant exists; `execute_upgrade` documents but does not mechanically enforce a storage-layout-compatible class.
- **Impact:** value stuck in the contract; silent state corruption on a mis-designed class (mitigated by the 7-day upgrade timelock).
- **Resolution:** **open** — out of scope for this fix round; tracked in §8. Not regressed by any change here.

### M-3. Uncapped u256 admin parameters

- **Location:** the seven `propose_set_*` u256 setters (`src/lib.cairo:1512-1633`).
- **Description:** `evaluation_bond_amount`, `reputation_stake`, `conviction_threshold`, `reward_multiplier`, `mini_reward_multiplier`, `min_decay_for_reward`, `caller_reward_amount` accepted arbitrary `u256` values. A reckless/compromised admin could set values that break accounting or overflow timestamp math (e.g., a `conviction_threshold` above any reachable power silently locks all proposals).
- **Impact:** trusted-admin, but cheap to guard.
- **Resolution:** every one now asserts `value <= MAX_SUPPLY` → `'TooHigh'` (bond/stake/reward multipliers also keep their `> 0` checks).
- **Verification:** `test_param_amount_above_max_supply_reverts` (PASS); existing timelock/budget tests unaffected.

---

## 5. Low Findings (all fixed)

### L-1. Month rollover hard-revert after 120 months → operational freeze

- **Location:** `_ensure_current_month` (`src/lib.cairo:1909`).
- **Description:** a long-idle contract (deployed >120 months before the next interaction) reverted on every mint/burn with `'TooManyMonthsBehind'`, freezing governance minting and recycling.
- **Resolution:** elapsed months are now **clamped** to `MAX_ROLLOVER_MONTHS` per call; successive calls nudge the calendar forward instead of reverting. Loop remains bounded (≤120 iterations).
- **Verification:** `test_far_future_rollover_clamps_instead_of_reverting` (PASS) — 130-month gap settles exactly 120 months, no revert.

### L-2. Dead storage and struct fields removed

- **Location:** `proposal_total_votes`/`proposal_total_weight` (removed from storage and their writes in `vote_with_conviction`); `FundingProposal.deposit_settled`; `Conviction.support_start`.
- **Description:** written-but-never-read storage and struct fields (dead code, audit noise, storage footprint for free).
- **Resolution:** removed. Struct-field removal is storage-layout-safe (the slots were never read; per-field addressing).
- **Verification:** clean `scarb check`; test suite (which asserts on `Deposit`/`Proposal`/`Conviction` struct views) still passes.

### L-3. SRC5 component declared but never wired

- **Location:** `src/lib.cairo:367-369`.
- **Description:** the `src5` component existed (storage + event) and `accesscontrol.initializer()` registered `IACCESSCONTROL_ID` into it, but no impl exposed `supports_interface`, so introspection was inert and unreadable.
- **Resolution:** `SRC5InternalImpl` binding added and `SRC5Impl` embedded → `supports_interface` is now a live entrypoint returning `true` for `ISRC5` and `IACCESSCONTROL_ID`. (ERC20 3.0 defines no interface ID, so none is registered for it.)
- **Verification:** compiles and is ABI-exposed.

### L-4. `commit_vote` / `reveal_vote` lacked the reentrancy guard

- **Location:** `commit_vote`, `reveal_vote`.
- **Description:** all other state-mutating externals run under `reentrancyguard`; these two did not. Safe today (no external calls), but inconsistent and fragile.
- **Resolution:** `reentrancyguard.start()` / `end()` added to both.
- **Verification:** the existing disclose flow (commit-reveal helper in every evaluation test) exercises the guarded path; all PASS.

### L-5. `cartridge_vrf` git dependency unpinned

- **Location:** `Scarb.toml`.
- **Description:** the git dependency had no `rev`, so the effective commit floated with upstream resolution (the committed lockfile had resolved it, but a fresh resolve could differ).
- **Resolution:** pinned to `rev = "cc00aa61fa5157100cde134fac3148f318448e18"` — exactly the commit the committed lockfile resolved to; `Scarb.lock` now records the pin explicitly with no commit change.
- **Verification:** `scarb build` resolves against the pinned commit.

### L-6. Unbounded `evidence: ByteArray` inputs

- **Location:** `request_evaluation` (`src/lib.cairo:678`) and `create_proposal` (`src/lib.cairo:1145`).
- **Description:** evidence payloads were only checked non-empty; a multi-KB `ByteArray` bloats calldata and storage per call (storage cost paid by the contract).
- **Resolution:** new `MAX_EVIDENCE_LEN = 1024` (`src/constants.cairo`); both entrypoints assert `len <= MAX_EVIDENCE_LEN` → `'EvidenceTooLong'`.
- **Verification:** `test_create_proposal_evidence_too_long_reverts` (PASS).

### L-7. Score-zero deposit slashing inconsistency (`final_score == 0`)

- **Location:** `execute_proposal` deposit settlement (`src/lib.cairo:1263+`); `finalize_selection` bond refund condition.
- **Description:** a final score of `0` slashed the anti-Sybil deposit (and the evaluation bond under the old `> 0` rule) despite being a fully legitimate, signal-valid neutral outcome — inconsistent with "refund on positive, slash on negative".
- **Resolution:** **score 0 is neutral**: the proposal deposit is refunded when `final_score >= 0` and slashed only when `< 0` (no reward minted either way — `score_u256 = 0` produces zero reward automatically); the evaluation-bond refund condition was aligned to `>= 0` for consistency.
- **Verification:** `test_zero_score_refunds_deposit_and_mints_no_reward` (PASS).

### L-8. Process/tooling — partially addressed

- **Location:** `Scarb.toml` `[tool.snforge]`; `tests/test_contract.cairo`.
- **Description:** no active fuzz/invariant configuration and only unit-style integration tests.
- **Resolution (in scope):** `[tool.snforge]` is now active (`fuzzer_runs = 100`, `fuzzer_seed = 1111`, `tracked_resource = "sierra-gas"`), and two fuzz/invariant tests were added:
  - `test_fuzz_stake_unstake_conserves_value` (250 runs) — stake + partial-unstake conserves `balance + stake` exactly.
  - `test_fuzz_apply_decay_is_non_increasing` (100 runs) — decay at arbitrary/out-of-order timestamps never increases a balance.
- **Resolution (out of scope, tracked):** NatSpec doc pass, and static-analysis tooling (caracal / cairo-lint) plus CI config — no CI exists and the tools are not installed in this environment.

---

## 6. Residual Risks / Open Items

1. **Value-lock (M-2):** slash-pool rounding dust and slashed proposal deposits are unrecoverable with no coherent claimant. Recommend a governance sweep/`rescue` path or burn-and-emit accounting.
2. **Upgrade storage collision (M-2):** still trusted to the 7-day timelock + admin diligence; recommend a documented storage-layout-compat check or an enforced check in `execute_upgrade`.
3. **Single-admin / key hygiene:** the roster is now timelocked and last-admin-protected, but a single compromised admin key still controls the roster and (after timelock) all parameters. Consider N-of-M or a second admin role.
4. **Majority-stake capture:** stake-weighted draws with replacement still allow a majority staker to dominate evaluations and vote outcomes (v1 finding #3, unchanged by design). Excluding the candidate from their own draw and/or requiring N distinct jurors remains a design recommendation.
5. **L-8 residuals:** NatSpec and CI static analysis not yet added.
6. **Build reproducibility:** the un-embedded `AccessControlMixinImpl` plus all this round's changes alter the compiled class hash (expected); ABI shrinkage from M-1/L-3 is intentional. No storage layout changes were made to live slots; the only storage change was removing never-read slots (L-2), which is deployment-safe.

---

## 7. Verification Record

```bash
scarb check                # Finished checking dev profile — clean
scarb build                # Finished — sierra contract compiles
snforge test               # 29 passed, 0 failed (fuzzer seed 1111)
```

| Test | Guards |
|---|---|
| `test_apply_decay_on_contract_address_reverts` | H-2 |
| `test_batch_apply_decay_with_contract_address_reverts` | H-2 |
| `test_zero_reveal_refunds_bond_and_clears_dispute` | H-3 |
| `test_num_draws_above_max_reverts` | H-4 |
| `test_param_amount_above_max_supply_reverts` | M-3 |
| `test_far_future_rollover_clamps_instead_of_reverting` | L-1 |
| `test_create_proposal_evidence_too_long_reverts` | L-6 |
| `test_zero_score_refunds_deposit_and_mints_no_reward` | L-7 |
| `test_fuzz_stake_unstake_conserves_value` (250 runs) | L-8 |
| `test_fuzz_apply_decay_is_non_increasing` (100 runs) | L-8 |

All 10 new tests PASS alongside the pre-existing 19 (histogram/threshold, bond slash/refund, deposits, rewards, permanent votes, supporter cap, timelock, monthly budget).

## 8. Fix Log (v2 round)

| # | Severity | Fix commit-landing |
|---|---|---|
| H-1 | High | `src/lib.cairo` — de-embed `AccessControlMixinImpl` |
| H-2 | High | `src/lib.cairo` — `_apply_decay` guard `user != get_contract_address()` |
| H-3 | High | `src/lib.cairo` — zero-reveal neutral settlement + bond refund |
| H-4 | High | `src/constants.cairo` + `propose_set_num_draws` — `MAX_NUM_DRAWS = 100` |
| M-1 | Medium | `src/lib.cairo` — delete funding-token ABI stub pair |
| M-3 | Medium | 7 × `propose_set_*` — `<= MAX_SUPPLY` (`'TooHigh'`) |
| L-1 | Low | `_ensure_current_month` — clamp to 120 months |
| L-2 | Low | remove dead storage/fields |
| L-3 | Low | wire SRC5 (`SRC5InternalImpl` + embedded `SRC5Impl`) |
| L-4 | Low | reentrancy guards on `commit_vote`/`reveal_vote` |
| L-5 | Low | pin `cartridge_vrf` `rev` |
| L-6 | Low | `MAX_EVIDENCE_LEN = 1024` caps |
| L-7 | Low | score-neutral refund semantics (`final_score >= 0`) |
| L-8 | Low (partial) | `[tool.snforge]` fuzzer + 2 fuzz/invariant tests |