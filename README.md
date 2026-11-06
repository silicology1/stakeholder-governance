# StakeholderGovernanceModular

A modular Starknet (Cairo) governance and funding system: peer-evaluated stakeholders earn **non-transferable (soulbound) voting power**, and that power directs a **seigniorage-funded reward budget** through conviction voting on funding proposals.

The monolithic `stakeholder_governance` package is split into four `#[starknet::contract]` classes, each built from this single package and each with its own class-hash size envelope.

## Design principles

| Principle | Implementation |
|---|---|
| Voice is earned, not bought | Governance tokens are minted only by positive peer evaluation, and are non-transferable |
| Money is medium of exchange, not a savings asset | ERC20 balances decay hourly (~5%/year), recycled into the reward budget |
| Spending back is limited but real | Conviction voting locks grants in place for `level × base_lock` seconds |
| No single point of control | All admin parameters live behind a timelock; upgrades are time-delayed and can be permanently disabled |
| Contained module failure | Each contract is an independent class; module wiring is registered and re-pointable through the timelock |

## Architecture

```
                    ┌────────────────┐
                    │  AdminTimelock │  central parameter authority
                    │  (timelocked)  │  decay/inflation, coherence, durations,
                    └───────┬────────┘  admin roster, per-module upgrades
        timelocked params   │   upgrades / module wiring
        ┌───────────────────┼───────────────────────┐
        │                   │                       │
        ▼                   ▼                       ▼
┌───────────────┐   ┌───────────────┐   ┌────────────────┐
│ ConvictionToken│◄─►│   Selection   │◄─►│   Governance   │
│                │   │               │   │                │
│ transferable   │   │ juror stakes  │   │ soulbound grants│
│ ERC20 + decay  │   │ VRF sortition │   │ conviction vote│
│ monthly budget │   │ commit/reveal │   │ funding props  │
│ escrow hub     │   │ coherence slash│  │ execution+score│
└───────────────┘   └───────────────┘   └────────────────┘
```

- **`ConvictionToken`** — the transferable ERC20 plus the escrow custody hub.
  Owns the OZ ERC20, hourly balance decay (`apply_decay`, `batch_apply_decay`, keeper-rewarded), the monthly inflation + burn-recycling budget engine, and every escrowed ERC20 (juror stakes, evaluation bonds, proposal deposits). `Selection` and `Governance` move funds through module-gated `escrow` / `release` / `mint_from_budget` entrypoints only.
- **`Selection`** — Kleros-style juror layer.
  Jurors create stake IDs, apply them to evaluation IDs during an applying phase, and are drawn stake-weighted via a per-evaluation Fenwick tree with VRF randomness (Cartridge VRF, mixed with an on-chain block hash so entropy cannot be substituted by an off-chain party). Drawn jurors commit/reveal scores (-5..+5). Non-revealing and incoherent jurors are slashed. Finalization computes a stake-weighted, trimmed mean and, on a positive score, queues a soulbound grant for the evaluated candidate.
- **`Governance`** — voting and funding layer.
  Owns non-transferable, linearly-decaying (over one year) governance-token grants; conviction voting (`weight = isqrt(level × amount)`); funding proposals with frozen O(1) `power_total` accumulators; and execution with deposit refund/slash plus a score-scaled ERC20 reward paid from the inflation budget.
- **`AdminTimelock`** — the sole admin authority.
  All governance-side parameters (thresholds, multipliers, durations, decay/inflation rates, stake bounds) pass through a 3-day timelock; class-hash upgrades get a 7-day timelock, and every module exposes a one-way `disable_upgrades`.

## Token economics

| Mechanism | Rate (default) | Notes |
|---|---|---|
| ERC20 balance decay | `500` bps annualized, applied hourly (~4.9%/yr effective) | proportional, lazy (keeper-called), protectable addresses exempt |
| Monthly inflation | `500` bps annualized, applied per month (~5.1%/yr effective) | minted into the reward budget, capped by `MAX_SUPPLY` |
| Burn recycling | prior month's burns + inflation = next month's budget | decay is a wealth transfer into funding, not a loss |
| Soulbound grant | `1,000 × positive final_score` per evaluation (linear 1k–5k schedule) | minted via claim after finalization; decays linearly to zero over 365 days |
| Conviction weight | `isqrt(level × amount)`, `level` 1–10 | locks tokens for `level × 11 days`; max 10 distinct proposals per conviction |
| Supply | initial `10M` tokens, hard cap `50B` | inflation mints ~5%/yr from the cap headroom |

## Evaluation lifecycle (`Selection`)

```
APPLYING (3d) → DRAWING (12h) → COMMIT (3d) → REVEAL (3d) → SLASH (12h) → FINALIZED
```

- **Applying**: stake IDs opt into an evaluation; `DEFAULT_MIN_STAKE_IDS = 15`, `DEFAULT_MAX_EVALUATIONS_PER_STAKE = 10`.
- **Drawing**: Fenwick-tree stake-weighted draw via VRF snapshot; `DEFAULT_MIN_JURORS = 10`; up to `20` deterministic redraw attempts.
- **Commit/Reveal**: pulled commitments can never be stale-copied (cohort checked at reveal).
- **Coherence**: |juror score − final_score| ≤ `coherence band` (default 1) ⇒ coherent; incoherent jurors are slashed `3000` bps into the dispute slash pool.
- **Finalization**: sanitized mean is stored; coherent jurors split the reward pool (slashed funds) or the monthly budget (`DEFAULT_JUROR_REWARD_AMOUNT = 10` tokens each); the requester's bond is returned on a non-negative score and slashed into the pool otherwise; the soulbound grant claim is permissionless and retryable so misconfigured wiring can never brick finalization.

## Funding flow (`Governance`)

1. Any address creates a proposal with an evidence payload (≤ 1 KiB) and escrows a `reputation_stake` deposit. An author cannot vote on their own proposal.
2. Grant holders create convictions (lock level 1–10) and score proposals -5..+5. Each vote bucket `(proposal, score)` accumulates `isqrt(level × amount)` weight, and `power_total` is bumped O(1).
3. After the minimum voting period (default 7 days), anyone can execute:
   - `power_total ≥ conviction_threshold` required;
   - the weighted mean of score buckets becomes the final score (-5..+5);
   - **score ≥ 0**: deposit refunded, and a score-scaled ERC20 reward (`reward_multipliers`) is minted from the budget to the funding wallet;
   - **score < 0**: deposit slashed (event emitted).

## Project structure

```
src/
  lib.cairo              package map
  constants.cairo        all constants + timelocked parameter keys
  conviction_token.cairo ERC20 + decay + budget + escrow hub
  selection.cairo        juror staking, sortition, disputes
  governance.cairo       soulbound grants, conviction voting, funding
  admin_timelock.cairo   timelocked parameter authority
  types/                 storage structs (admin, dispute, governance)
  events/                event payload structs
  utils/                 pure helpers (math, fenwick, random)
  interfaces/            cross-contract dispatcher traits
tests/
  test_contract.cairo    snforge integration tests (33 passing)
```

## Building and testing

Requirements: [Scarb](https://docs.swmansion.com/scarb/) with Cairo edition `2024_07`, Starknet `2.20.0` toolchain, and [snforge](https://foundry.swmansion.com/) `0.64.1` for tests.

```bash
scarb build      # compiles the four contract classes
scarb test       # runs the snforge suite (incl. fuzzing: 100 runs, seed 1111)
```

Sierra and CASM artifacts land in `target/dev/` (`.starknet_artifacts.json`, compiled class JSONs).

## Security notes

- **Reentrancy** guards on every state-changing entrypoint; escrow custody is centralized in one contract and only reachable by registered modules.
- **Timelock-only admin**: parameter changes cannot bypass `AdminTimelock`; upgrades are delayed one week and permanently disablable per module.
- **Known design considerations**: stake-weighted sortition means a single entity controlling a majority of staked weight can dominate draws; the coherence rule treats majority dissent as incoherent (honest minorities can be slashed); `power_total` in `Governance` includes negative weight, so opposition votes can trigger execution of a proposal. These are intentional trade-offs of this iteration and documented in the code comments.

## License

MIT — see the `license` field in `Scarb.toml`.
