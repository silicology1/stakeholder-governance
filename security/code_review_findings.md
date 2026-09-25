# StakeholderConviction — Security Review Findings

Date: 2026-09-21
Scope: `src/lib.cairo`, `src/constants.cairo`, `src/events.cairo`, `src/types/*`, `src/utils/*`, `tests/test_contract.cairo`
Status: findings only; no code changes made.

---

## High

### 1. Vote histogram double-count + `remove_support` asymmetry (governance manipulation)

- `vote_with_conviction` (src/lib.cairo:1195) adds a frozen weight to `proposal_score_counts`, but `remove_support` (src/lib.cairo:1222) never decrements it.
- No check prevents a conviction from re-voting on the same proposal after removal: `vote_with_conviction` only asserts `!c.is_supporting`, which is reset to `false` by `remove_support`.
- A single conviction can therefore be toggled infinitely, each toggle appending a new `Supporter` entry to `proposal_supporters` and adding another full weight to the histogram (`supporter_count` and weighted buckets grow unbounded).

Consequences:
- Unbounded weighted-score inflation toward any single voter's chosen score (each re-vote freezes a *larger* weight as `hours_locked` grows).
- `execute_proposal` checks the threshold with **live** recomputed power (`_proposal_total_power`, src/lib.cairo:1272) but computes the final score from the **stale frozen** histogram (`_compute_weighted_score`, src/lib.cairo:2119). An attacker whose threshold is met by others can add huge −5 weight, then `remove_support`, forcing a negative final score that slashes an innocent author's deposit and suppresses an otherwise-legitimate proposal.

Recommended fix direction: decrement the histogram (and `supporter_count`) on `remove_support`, forbid re-voting a proposal a conviction already supported, cap `supporter_count`, or track per-proposal power with an aggregate (Fenwick) structure.

### 2. Unbounded loops → permanent DoS (funds stuck)

- `_proposal_total_power` (src/lib.cairo:2099) iterates every supporter ever recorded; `supporter_count` only grows (removal does not shrink it). A grief attacker can pad a proposal with thousands of one-wei convictions, making `execute_proposal` exceed the step limit forever — the deposit then becomes irrecoverable. (This is acknowledged in AGENTS.md as a known limitation, but it is a live exploit.)
- `_decayed_total` (src/lib.cairo:2067) sums every grant per holder. `create_conviction` (src/lib.cairo:1139) and `governance_*` reads on a repeatedly-evaluated holder also grow unbounded (self-DoS), and enable mass governance-token accumulation.

### 3. Majority-stake captures the whole system (economic / design)

- Juror draws are stake-weighted with replacement (`request_evaluation`, src/lib.cairo:719-780), and the candidate is **not** excluded from their own dispute.
- Whoever holds/stakes the token majority controls every evaluation score (score 5 → 50k governance tokens per evaluation, src/utils/math.cairo:101), every conviction outcome, and therefore up to the full monthly inflation budget.
- This turns selection into confirmable self-dealing. Consider excluding the candidate from their own draw and capping single-juror dominance (e.g., require N distinct jurors).

---

## Medium

### 4. `propose_set_funding_token` / `execute_set_funding_token` stub corrupts `PARAM_VRF_PROVIDER`

- src/lib.cairo:1495-1503. The ABI-compat stub writes value `0` under the `PARAM_VRF_PROVIDER` key, and on execute consumes/clears any pending VRF-provider change while setting nothing.
- Any admin calling the funding-token path silently wipes or corrupts pending VRF-provider updates, and can leave the provider effectively unset. Remove the pair from the ABI.

### 5. Missing parameter bounds (trusted-admin, but trivial to guard)

- `propose_set_conviction_threshold(0)` is allowed (src/lib.cairo:1525) → any proposal, even with zero voting power, executes instantly and slashes the deposit.
- `propose_set_reward_multiplier` / `propose_set_mini_reward_multiplier` accept 0 (src/lib.cairo:1534, 1543).
- `num_draws` has no upper cap (src/lib.cairo:1628) → a large setting makes the draw loop in `request_evaluation` a gas bomb at candidate expense.

### 6. Permanently locked value

- Slash-pool leftovers from truncated division in `claim_juror_reward` (src/lib.cairo:1057) and slashed proposal deposits (src/lib.cairo:1319-1328) have no withdrawal path once no coherent claimant exists.

### 7. Dead storage / constants

- `proposal_total_votes` and `proposal_total_weight` (src/lib.cairo:448-449) are written but never read.
- `MAX_LOCK_DURATION` (src/constants.cairo:46) and several `DEFAULT_*` constants (src/constants.cairo:48-52) are unused.

### 8. Upgrade storage-collision risk

- `execute_upgrade` (src/lib.cairo:1793) has no guard against a new class whose storage layout collides with the existing one → silent state corruption. The 7-day timelock mitigates, but the constraint should be documented or mechanically enforced.

---

## Low

- `commit_vote` / `reveal_vote` skip the reentrancy guard (src/lib.cairo:792, 808). Safe today because they make no external calls, but fragile.
- `_ensure_current_month` (src/lib.cairo:1880) reverts if the block timestamp jumps more than `MAX_ROLLOVER_MONTHS` (120) behind → mints and burns become blocked (operational freeze).
- `support_start` is written but never read (src/lib.cairo:1192); vote weight counts lock time from conviction `created_at`, not from vote placement.
- No NatSpec doc comments on external functions.
- Test suite (currently 17 snforge tests) lacks invariant/fuzz coverage of scoring, slashing, admin roster, decay, and upgrade paths.

---

## Priority

1. Fix #1 (histogram decrement on `remove_support` / forbid re-vote / cap supporters).
2. Fix #2 (bound or aggregate supporter and grant iteration).
3. Fix #4 (remove the funding-token stub that aliases the VRF key).
4. Add bounds to #5.

---

## Resolution status (2026-09-24)

Round-2 conviction redesign in `src/lib.cairo` / `src/types/governance.cairo` / `src/constants.cairo` (see `StakeholderConviction_Security_Analysis_v3.md` §11, "round 2 — conviction-voting redesign, dust-voting elimination"). Original finding text above retained as historical record. **Storage layout changed — fresh-deploy-only.**

### RESOLVED — #1 Vote histogram double-count + `remove_support` asymmetry (High)

- `remove_support` is deleted; `vote_with_conviction` no longer toggles `is_supporting`.
- Votes are permanent; a conviction can never vote the same proposal twice (`conviction_voted_on: Map<(ContractAddress, u32, u256), bool>`, gate `'AlreadyVotedOnProposal'` at `src/lib.cairo:1270`), so the weight double-count / infinite re-vote inflation path is gone.
- Live-vs-frozen mismatch is moot: `execute_proposal` reads the same frozen `FundingProposal.power_total` accumulator the histogram was built from at vote time (both O(1)).

### RESOLVED — #2 Unbounded loops → permanent DoS, supporter-pad grief (High)

- `Supporter` struct, `proposal_supporters`, `supporter_count`, `MAX_PROPOSAL_SUPPORTERS`, and `_proposal_total_power` are all removed. No per-proposal supporter iteration remains; `execute_proposal` is O(1) (`power_total` bump at `src/lib.cairo:1286`, threshold check at `src/lib.cairo:1330`).
- Voting is unbounded by design (regression: `test_voting_scales_beyond_old_supporter_cap`, 400 backers) with no cap/slot resource left to pad.
- Note: #2's second clause (grant-array self-DoS via `_decayed_total`) is unchanged but already bounded by `MAX_GOV_GRANTS_PER_HOLDER` (64); remains an operational cap, not a live exploit.

### Unchanged — #3 (High, design), #6 (Medium), #8 (Medium)

- #3 majority-stake capture: not addressed by this round (accepted design risk, see v3 §5 A-1).
- #6 permanently locked value (slash dust / slashed deposits): still open (v3 §5 B-3).
- #8 upgrade storage-collision: still mitigated only by the timelock (v3 §6).

### Tracking note

- #7 (`proposal_total_votes` / `proposal_total_weight` dead storage) is flagged but not yet removed.