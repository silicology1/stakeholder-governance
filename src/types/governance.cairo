// SPDX-License-Identifier: MIT
//! Governance-side types (Stages 2 and 3): non-transferable conviction
//! records and funding proposals. There is no per-proposal supporter registry:
//! a proposal's total power is a frozen accumulator (`power_total`) bumped at
//! vote time, so `execute_proposal` is O(1) and voting is unbounded.

use starknet::ContractAddress;

/// Durable state for one conviction created by a governance-token holder.
#[derive(Drop, Serde, Copy, starknet::Store)]
pub struct Conviction {
    /// Address that owns the conviction and can cast or release it.
    pub owner: ContractAddress,
    /// Per-owner conviction identifier.
    pub id: u32,
    /// Chosen conviction level from 1 through 10.
    pub level: u8,
    /// Amount of non-transferable governance tokens locked by the conviction.
    pub amount: u256,
    /// Block timestamp at conviction creation.
    pub created_at: u64,
    /// Total seconds this conviction's stake stays locked for. Computed as
    /// `level * conviction_base_lock` at `create_conviction` time.
    pub lock_duration: u64,
    /// Number of distinct proposals this conviction has voted on; capped by
    /// `max_votes_per_conviction`.
    pub votes_cast: u64,
    /// Whether the locked stake has been released after lock expiry.
    pub released: bool,
}

/// Durable state for one conviction-scored funding proposal.
#[derive(Drop, Serde, starknet::Store)]
pub struct FundingProposal {
    /// Address that created the proposal and supplied its deposit.
    pub author: ContractAddress,
    /// Address eligible to receive a positive-score reward.
    pub funding_wallet: ContractAddress,
    /// Evidence supplied by the proposal author.
    pub evidence: ByteArray,
    /// Block timestamp at proposal creation.
    pub created_at: u64,
    /// Whether the proposal has reached the execution path.
    pub executed: bool,
    /// Frozen sum of `isqrt(level * amount)` cast by all backers; bumped at
    /// vote time and read O(1) in `execute_proposal`.
    pub power_total: u256,
    /// ERC20 proposal deposit currently escrowed for the proposal.
    pub deposit_amount: u256,
    /// Final weighted score in the inclusive range -5 through 5 after execution.
    pub final_score: i64,
    /// Whether `final_score` has been stored.
    pub final_score_set: bool,
}
