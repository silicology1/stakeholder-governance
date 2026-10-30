// SPDX-License-Identifier: MIT
//! Kleros-side dispute types: the selection dispute and the per-grant
//! record of non-transferable governance tokens.

use starknet::ContractAddress;

/// All durable state associated with one candidate evaluation dispute.
#[derive(Drop, Serde, Copy, starknet::Store)]
pub struct Dispute {
    /// Candidate whose reputation is being evaluated.
    pub candidate: ContractAddress,
    /// Number of distinct jurors retained after deduplicating draws.
    pub unique_juror_count: u32,
    /// Timestamp at which vote commitments must be submitted.
    pub commit_deadline: u64,
    /// Timestamp at which vote reveals must be submitted.
    pub reveal_deadline: u64,
    /// One of `PHASE_COMMIT`, `PHASE_REVEAL`, `PHASE_SLASH`, or `PHASE_FINALIZED`; see `Evaluation`.
    pub phase: u8,
    /// Final trimmed-mean score in the inclusive range -5 through 5; meaningful after finalization.
    pub final_score: i64,
    /// Whether `final_score` has been committed by finalization.
    pub final_score_set: bool,
    /// Sum of juror weights whose votes were revealed.
    pub total_weight_revealed: u32,
    /// Sum of weights retained after coherence filtering.
    pub total_coherent_weight: u32,
    /// Tokens currently held in this dispute's slash pool.
    pub slash_pool: u256,
    /// Non-transferable governance tokens granted to the candidate.
    pub governance_tokens_minted: u256,
    /// Address that requested evaluation and supplied the bond.
    pub requester: ContractAddress,
    /// Evaluation bond escrowed for the dispute.
    pub bond_amount: u256,
    /// Whether the bond has been refunded or slashed.
    pub bond_settled: bool,
}

/// One non-transferable governance-token grant issued to a holder.
#[derive(Drop, Serde, Copy, starknet::Store)]
pub struct Grant {
    /// Original grant amount before hourly decay.
    pub amount: u256,
    /// Timestamp at which the grant was minted; decay is measured from here.
    pub minted_at: u64,
}

/// One juror stake deposit. Stakes are identified by a `stake_id` and can be
/// applied to multiple evaluation IDs (up to `max_evaluations_per_stake`).
/// The ERC20 amount is escrowed in the ConvictionToken custody hub.
#[derive(Drop, Serde, Copy, starknet::Store)]
pub struct Stake {
    /// Address that created and owns this stake.
    pub owner: ContractAddress,
    /// ERC20 amount escrowed for this stake.
    pub amount: u256,
    /// Block timestamp at stake creation.
    pub created_at: u64,
    /// Whether the stake has been fully withdrawn and retired.
    pub retired: bool,
}

/// Durable state for one candidate evaluation. Each evaluation has its own
/// Fenwick tree (stored separately in `evaluation_fenwick`) and its own
/// lifecycle phases: APPLYING, DRAWING, COMMIT, REVEAL, FINALIZED, DISMISSED.
#[derive(Drop, Serde, Copy, starknet::Store)]
pub struct Evaluation {
    /// Candidate whose reputation is being evaluated.
    pub candidate: ContractAddress,
    /// Address that requested evaluation and supplied the bond.
    pub requester: ContractAddress,
    /// Evaluation bond escrowed for the request.
    pub bond_amount: u256,
    /// One of `PHASE_APPLYING`, `PHASE_DRAWING`, `PHASE_COMMIT`,
    /// `PHASE_REVEAL`, `PHASE_SLASH`, `PHASE_FINALIZED`, `PHASE_DISMISSED`.
    pub phase: u8,
    /// Timestamp at which the applying phase ends.
    pub apply_deadline: u64,
    /// Timestamp at which the drawing phase ends.
    pub draw_deadline: u64,
    /// Timestamp at which the commit phase ends.
    pub commit_deadline: u64,
    /// Timestamp at which the reveal phase ends.
    pub reveal_deadline: u64,
    /// Timestamp at which the slash phase ends (finalization gate).
    pub slash_deadline: u64,
    /// Number of stake IDs currently applied to this evaluation.
    pub applied_count: u32,
    /// Number of stake IDs drawn for this evaluation.
    pub drawn_count: u32,
    /// Minimum jurors required to proceed to commit phase.
    pub min_jurors: u32,
    /// Final trimmed-mean score in the inclusive range -5 through 5.
    pub final_score: i64,
    /// Whether `final_score` has been committed by finalization.
    pub final_score_set: bool,
    /// Tokens currently held in this evaluation's slash pool.
    pub slash_pool: u256,
    /// Non-transferable governance tokens granted to the candidate.
    pub governance_tokens_minted: u256,
    /// Whether the bond has been refunded or slashed.
    pub bond_settled: bool,
}
