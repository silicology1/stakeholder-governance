// SPDX-License-Identifier: MIT
//! Governance-side types (Stages 2 and 3): non-transferable conviction
//! records, funding proposals, and their supporter registry.

use starknet::ContractAddress;

#[derive(Drop, Serde, Copy, starknet::Store)]
pub struct Conviction {
    pub owner: ContractAddress,
    pub id: u32,
    pub level: u8,
    pub amount: u256,
    pub created_at: u64,
    pub is_supporting: bool,
    pub active_proposal: u256,
    pub support_start: u64,
    pub released: bool,
}

#[derive(Drop, Serde, starknet::Store)]
pub struct FundingProposal {
    pub author: ContractAddress,
    pub funding_wallet: ContractAddress,
    pub evidence: ByteArray,
    pub created_at: u64,
    pub executed: bool,
    pub supporter_count: u32,
    pub deposit_amount: u256,
    pub deposit_settled: bool,
    pub final_score: i64,
    pub final_score_set: bool,
}

#[derive(Drop, Serde, Copy, starknet::Store)]
pub struct Supporter {
    pub owner: ContractAddress,
    pub conviction_id: u32,
}