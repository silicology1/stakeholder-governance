// SPDX-License-Identifier: MIT
//! Constants and timelocked-parameter keys for the StakeholderConviction
//! contract. Everything here is compile-time constant; nothing is stored.
//!
//! Token amounts use the embedded ERC20's smallest unit. A token has 18
//! decimals, so a value ending in 18 zeroes represents one whole token.
//! Basis-point values use a denominator of 10,000. Durations are seconds
//! unless a name explicitly says otherwise.

/// Fixed-point multiplier used while calculating weighted means and standard
/// deviations. Scores are integers in the range -5 through 5.
pub const SCALE: i64 = 1000;
/// Default maximum absolute score difference used to classify a juror as
/// coherent. Admin-tunable through the timelocked `PARAM_COHERENCE_BAND`.
pub const DEFAULT_COHERENCE_BAND: u8 = 1;
/// Maximum configurable coherence band. `propose_set_coherence_band` rejects
/// values above this.
pub const MAX_COHERENCE_BAND: u8 = 3;
/// Default fraction of a non-revealing juror's stake that is slashed.
pub const DEFAULT_SLASH_BPS: u16 = 3000;
/// Default fraction of an incoherent (revealed-but-against-the-majority)
/// juror's stake that is slashed into the dispute slash pool.
pub const DEFAULT_INCOHERENCE_SLASH_BPS: u16 = 3000;
/// Denominator for values expressed in basis points.
pub const BPS_DENOM: u256 = 10_000;

/// Default duration of the commitment phase in seconds (three days).
pub const DEFAULT_COMMIT_DURATION: u64 = 259_200;
/// Default duration of the reveal phase in seconds (three days).
pub const DEFAULT_REVEAL_DURATION: u64 = 259_200;

/// Number of seconds in one hour, used by hourly governance-grant decay.
pub const SECONDS_PER_HOUR: u64 = 3_600;
/// Number of decay hours in the 365-day governance-token lifetime.
pub const HOURS_PER_YEAR: u64 = 8_760;

/// Hard upper bound on total ERC20 supply, expressed in wei-sized token units.
pub const MAX_SUPPLY: u256 = 50_000_000_000_000_000_000_000_000;
/// Initial ERC20 supply minted once by the constructor, in token base units.
pub const INITIAL_SUPPLY: u256 = 10_000_000_000_000_000_000_000_000;
/// Delay applied to ordinary administrative parameter changes, in seconds.
pub const TIMELOCK_DURATION: u64 = 259_200;
/// Delay applied to class-hash upgrade changes, in seconds.
pub const UPGRADE_TIMELOCK_DURATION: u64 = 604_800;

/// Default hourly ERC20 balance-decay rate, in basis points.
pub const DEFAULT_DECAY_RATE_BPS: u16 = 500;
/// Denominator used by the ERC20 balance-decay calculation.
pub const DECAY_BPS_DENOM: u256 = 10_000;
/// Default minimum ERC20 amount burned before a decay caller earns a reward.
pub const DEFAULT_MIN_DECAY_FOR_REWARD: u256 = 1_000_000_000_000_000_000;
/// Default reward minted to a caller who applies qualifying decay.
pub const DEFAULT_CALLER_REWARD_AMOUNT: u256 = 1_000_000_000_000_000;
/// Minimum seconds between decay-caller reward payments.
pub const CALLER_REWARD_COOLDOWN: u64 = 86_400;
/// Maximum number of addresses accepted by `batch_apply_decay`.
pub const MAX_BATCH_DECAY: u32 = 50;
/// Maximum number of simultaneously open disputes for which one juror can
/// retain stake lock.
pub const MAX_CONCURRENT_JUROR_LOCKS: u32 = 15;
/// Maximum number of deterministic redraws attempted for one selection draw.
pub const MAX_REDRAW_ATTEMPTS: u32 = 20;
/// Default reward for the caller that reports a non-revealing juror.
pub const SLASH_KEEPER_REWARD: u256 = 500_000_000_000_000;
/// Maximum accepted length of proposal or evaluation evidence in bytes.
pub const MAX_EVIDENCE_LEN: usize = 1024;
/// Bounds the per-holder governance-grant array so `_decayed_total` (and
/// every governance balance read) is O(MAX_GOV_GRANTS_PER_HOLDER).
pub const MAX_GOV_GRANTS_PER_HOLDER: u32 = 64;

/// Base lock period per conviction level, in seconds. Level `N` locks stake
/// for `N * conviction_base_lock` seconds. The value is admin-tunable through
/// the timelocked `PARAM_CONVICTION_BASE_LOCK` parameter.
pub const DEFAULT_CONVICTION_BASE_LOCK: u64 = 9_460_800;
/// Maximum duration of one conviction, in seconds (five years). The value is
/// enforced when creating a conviction and when changing the base lock.
pub const MAX_LOCK_DURATION: u64 = 157_680_000;
/// Default number of distinct proposals one conviction may vote on.
pub const DEFAULT_MAX_VOTES_PER_CONVICTION: u64 = 10;
/// Maximum configurable value for votes per conviction.
pub const MAX_MAX_VOTES_PER_CONVICTION: u64 = 1000;
/// Default minimum seconds a funding proposal must be open for voting before
/// `execute_proposal` is allowed to run.
pub const DEFAULT_PROPOSAL_VOTING_PERIOD: u64 = 604_800;
/// Maximum configurable funding-proposal voting period in seconds (one year).
pub const MAX_PROPOSAL_VOTING_PERIOD: u64 = 31_536_000;
/// Default cooldown a candidate must wait after a finalized evaluation before
/// they may reapply (request another evaluation), in seconds (two 30-day
/// months).
pub const DEFAULT_EVALUATION_COOLDOWN: u64 = 5_184_000;
/// Maximum configurable evaluation cooldown in seconds (one year).
pub const MAX_EVALUATION_COOLDOWN: u64 = 31_536_000;

/// Number of calendar months used when annualizing inflation.
pub const MONTHS_PER_YEAR: u64 = 12;
/// Length of one fixed reward-budget month, in seconds (30 days).
pub const MONTH_SECONDS: u64 = 2_592_000;
/// Maximum configurable monthly inflation rate, in basis points.
pub const MAX_INFLATION_BPS: u16 = 500;
/// Default monthly inflation rate, in basis points.
pub const DEFAULT_INFLATION_RATE_BPS: u16 = 500;
/// Maximum number of months processed by one lazy month-rollover call.
pub const MAX_ROLLOVER_MONTHS: u64 = 120;

/// Number of blocks to look back for a syscall-available block hash, used
/// as an on-chain, contract-read entropy component mixed into the VRF seed.
/// Starknet only exposes hashes for blocks at least this many blocks behind
/// the current one; the value is public by the time it's read, so it does
/// not add unpredictability on its own, but it cannot be substituted or
/// withheld by any off-chain party, unlike the VRF proof.
pub const BLOCK_HASH_LOOKBACK: u64 = 10;

// ---- timelocked-parameter keys ----

/// Storage key for the evaluation-bond parameter.
pub const PARAM_EVALUATION_BOND_AMOUNT: felt252 = 'EVAL_BOND_AMT';
/// Storage key for the proposal reputation-deposit parameter.
pub const PARAM_REPUTATION_STAKE: felt252 = 'REPUTATION_STAKE';
/// Storage key for the proposal conviction-threshold parameter.
pub const PARAM_CONVICTION_THRESHOLD: felt252 = 'CONVICTION_THRESHOLD';
/// Storage key for the score 4-5 reward multiplier.
pub const PARAM_REWARD_MULTIPLIER: felt252 = 'REWARD_MULTIPLIER';
/// Storage key for the score 1-3 reward multiplier.
pub const PARAM_MINI_REWARD_MULTIPLIER: felt252 = 'MINI_REWARD_MULT';
/// Storage key for the Cartridge VRF provider address.
pub const PARAM_VRF_PROVIDER: felt252 = 'VRF_PROVIDER';
/// Storage key for the commitment-phase duration.
pub const PARAM_COMMIT_DURATION: felt252 = 'COMMIT_DURATION';
/// Storage key for the reveal-phase duration.
pub const PARAM_REVEAL_DURATION: felt252 = 'REVEAL_DURATION';
/// Storage key for the non-reveal slash rate.
pub const PARAM_NON_REVEAL_SLASH_BPS: felt252 = 'NON_REVEAL_SLASH_BPS';
/// Storage key for the incoherence slash rate.
pub const PARAM_INCOHERENCE_SLASH_BPS: felt252 = 'INCOHERENCE_SLASH_BPS';
/// Storage key for the coherence band (max score distance for coherence).
pub const PARAM_COHERENCE_BAND: felt252 = 'COHERENCE_BAND';
/// Storage key for the ERC20 balance-decay rate.
pub const PARAM_DECAY_RATE_BPS: felt252 = 'DECAY_RATE_BPS';
/// Storage key for the minimum decay amount required for a caller reward.
pub const PARAM_MIN_DECAY_FOR_REWARD: felt252 = 'MIN_DECAY_FOR_REWARD';
/// Storage key for the decay caller reward amount.
pub const PARAM_CALLER_REWARD_AMOUNT: felt252 = 'CALLER_REWARD_AMOUNT';
/// Storage key for the monthly inflation rate.
pub const PARAM_INFLATION_RATE_BPS: felt252 = 'INFLATION_RATE';
/// Storage key for the per-level conviction lock duration.
pub const PARAM_CONVICTION_BASE_LOCK: felt252 = 'CONVICTION_BASE_LOCK';
/// Storage key for the per-conviction distinct-proposal vote limit.
pub const PARAM_MAX_VOTES_PER_CONVICTION: felt252 = 'MAX_VOTES_CONVICTION';
/// Storage key for the minimum funding-proposal voting period.
pub const PARAM_PROPOSAL_VOTING_PERIOD: felt252 = 'PROPOSAL_VOTE_WINDOW';
/// Storage key for the evaluation cooldown before a candidate may reapply.
pub const PARAM_EVALUATION_COOLDOWN: felt252 = 'EVAL_COOLDOWN';

/// ---- Evaluation lifecycle phases ----

/// Jurors may apply stake IDs to this evaluation.
pub const PHASE_APPLYING: u8 = 1;
/// Jurors are being drawn for this evaluation.
pub const PHASE_DRAWING: u8 = 2;
/// Drawn jurors may commit votes.
pub const PHASE_COMMIT: u8 = 3;
/// Drawn jurors may reveal votes.
pub const PHASE_REVEAL: u8 = 4;
/// Evaluation is finalized.
pub const PHASE_FINALIZED: u8 = 5;
/// Evaluation was dismissed (minimum jurors not reached).
pub const PHASE_DISMISSED: u8 = 6;

// ---- Applying phase ----

/// Default duration of the applying phase in seconds (three days).
pub const DEFAULT_APPLYING_DURATION: u64 = 259_200;
/// Maximum configurable applying duration in seconds (100 days).
pub const MAX_APPLYING_DURATION: u64 = 8_640_000;
/// Default minimum number of stake IDs required per evaluation.
pub const DEFAULT_MIN_STAKE_IDS: u32 = 15;

// ---- Drawing phase ----

/// Default minimum number of jurors to draw per evaluation.
pub const DEFAULT_MIN_JURORS: u32 = 10;
/// Maximum configurable minimum jurors (admin-timelocked).
pub const MAX_MIN_JURORS: u32 = 200;
/// Default duration of the drawing phase in seconds (12 hours).
pub const DEFAULT_DRAWING_DURATION: u64 = 43_200;
/// Maximum configurable drawing duration in seconds (100 days).
pub const MAX_DRAWING_DURATION: u64 = 8_640_000;

// ---- Stake ID limits ----

/// Default maximum number of evaluation IDs a single stake ID can be applied to.
pub const DEFAULT_MAX_EVALUATIONS_PER_STAKE: u32 = 10;
/// Maximum configurable value (admin-timelocked).
pub const MAX_MAX_EVALUATIONS_PER_STAKE: u32 = 100;

// ---- Juror reward ----

/// Default reward (in ERC token base units) for all coherent jurors when no
/// incoherent slash occurs. Funded via `_mint_from_budget`.
pub const DEFAULT_JUROR_REWARD_AMOUNT: u256 = 10 * 1_000_000_000_000_000_000;
/// Maximum configurable juror reward (admin-timelocked).
pub const MAX_JUROR_REWARD_AMOUNT: u256 = 10_000 * 1_000_000_000_000_000_000;

// ---- Per-evaluation Fenwick tree ----

/// Maximum index size for the Fenwick tree of a single evaluation.
pub const EVAL_FENWICK_SIZE: u32 = 10_000;

// ---- timelocked-parameter keys (new) ----

pub const PARAM_APPLYING_DURATION: felt252 = 'APPLY_DURATION';
pub const PARAM_MIN_STAKE_IDS: felt252 = 'MIN_STAKE_IDS';
pub const PARAM_MIN_JURORS: felt252 = 'MIN_JURORS';
pub const PARAM_MAX_EVALUATIONS_PER_STAKE: felt252 = 'MAX_EVAL_PER_STAKE';
pub const PARAM_JUROR_REWARD_AMOUNT: felt252 = 'JUROR_REWARD';
pub const PARAM_DRAWING_DURATION: felt252 = 'DRAW_DURATION';
