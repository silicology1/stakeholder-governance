// SPDX-License-Identifier: MIT
//! Kleros-side dispute types: the selection dispute and the per-grant
//! record of non-transferable governance tokens.

use starknet::ContractAddress;

#[derive(Drop, Serde, Copy, starknet::Store)]
pub struct Dispute {
    pub candidate: ContractAddress,
    pub num_draws: u32,
    pub unique_juror_count: u32,
    pub commit_deadline: u64,
    pub reveal_deadline: u64,
    pub phase: u8,
    pub final_score: i64,
    pub final_score_set: bool,
    pub total_weight_revealed: u32,
    pub total_coherent_weight: u32,
    pub slash_pool: u256,
    pub governance_tokens_minted: u256,
    pub requester: ContractAddress,
    pub bond_amount: u256,
    pub bond_settled: bool,
}

#[derive(Drop, Serde, Copy, starknet::Store)]
pub struct Grant {
    pub amount: u256,
    pub minted_at: u64,
}