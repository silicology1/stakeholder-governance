// SPDX-License-Identifier: MIT
//! Governance-side types (Stages 2 and 3): non-transferable conviction
//! records and funding proposals. There is no per-proposal supporter registry:
//! a proposal's total power is a frozen accumulator (`power_total`) bumped at
//! vote time, so `execute_proposal` is O(1) and voting is unbounded.

use starknet::ContractAddress;

#[derive(Drop, Serde, Copy, starknet::Store)]
pub struct Conviction {
    pub owner: ContractAddress,
    pub id: u32,
    pub level: u8,
    pub amount: u256,
    pub created_at: u64,
    /// Total seconds this conviction's stake stays locked for. Computed as
    /// `level * conviction_base_lock` at `create_conviction` time.
    pub lock_duration: u64,
    /// Number of distinct proposals this conviction has voted on; capped by
    /// `max_votes_per_conviction`.
    pub votes_cast: u64,
    pub released: bool,
}

#[derive(Drop, Serde, starknet::Store)]
pub struct FundingProposal {
    pub author: ContractAddress,
    pub funding_wallet: ContractAddress,
    pub evidence: ByteArray,
    pub created_at: u64,
    pub executed: bool,
    /// Frozen sum of `isqrt(level * amount)` cast by all backers; bumped at
    /// vote time and read O(1) in `execute_proposal`.
    pub power_total: u256,
    pub deposit_amount: u256,
    pub final_score: i64,
    pub final_score_set: bool,
}