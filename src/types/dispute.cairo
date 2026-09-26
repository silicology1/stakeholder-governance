// SPDX-License-Identifier: MIT
//! Kleros-side dispute types: the selection dispute and the per-grant
//! record of non-transferable governance tokens.

use starknet::ContractAddress;

/// All durable state associated with one candidate evaluation dispute.
#[derive(Drop, Serde, Copy, starknet::Store)]
pub struct Dispute {
    /// Candidate whose reputation is being evaluated.
    pub candidate: ContractAddress,
    /// Number of weighted juror draws requested when the dispute opened.
    pub num_draws: u32,
    /// Number of distinct jurors retained after deduplicating draws.
    pub unique_juror_count: u32,
    /// Timestamp at which vote commitments must be submitted.
    pub commit_deadline: u64,
    /// Timestamp at which vote reveals must be submitted.
    pub reveal_deadline: u64,
    /// One of `PHASE_COMMIT`, `PHASE_REVEAL`, or `PHASE_FINALIZED`.
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
