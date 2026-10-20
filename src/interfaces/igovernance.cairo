// SPDX-License-Identifier: MIT
//! Cross-contract interface for `Governance`, the non-transferable
//! governance-token grant, conviction, and funding-proposal module.
//! `Selection` calls `mint_governance_tokens` on positive finalization;
//! `AdminTimelock` calls the admin half.

use starknet::ContractAddress;
use crate::types::{Conviction, FundingProposal};

#[starknet::interface]
pub trait IGovernance<TContractState> {
    // ---- proposals / convictions ----

    fn create_proposal(
        ref self: TContractState, funding_wallet: ContractAddress, evidence: ByteArray,
    ) -> u256;
    fn create_conviction(ref self: TContractState, level: u8, amount: u256) -> u32;
    fn vote_with_conviction(
        ref self: TContractState, proposal_id: u256, conviction_id: u32, score: i8,
    );
    fn release_conviction(ref self: TContractState, conviction_id: u32);
    fn execute_proposal(ref self: TContractState, proposal_id: u256);

    // ---- governance-token views ----

    fn governance_balance(self: @TContractState, holder: ContractAddress) -> u256;
    fn governance_available(self: @TContractState, holder: ContractAddress) -> u256;
    fn governance_locked(self: @TContractState, holder: ContractAddress) -> u256;
    fn get_conviction_power(
        self: @TContractState, owner: ContractAddress, conviction_id: u32,
    ) -> u256;
    fn get_proposal_total_power(self: @TContractState, proposal_id: u256) -> u256;
    fn get_conviction(self: @TContractState, owner: ContractAddress, id: u32) -> Conviction;
    fn get_proposal(self: @TContractState, proposal_id: u256) -> FundingProposal;

    // ---- selection-gated ----

    /// Mints a decaying non-transferable governance-token grant. Only the
    /// registered `Selection` module may call this.
    fn mint_governance_tokens(ref self: TContractState, holder: ContractAddress, amount: u256);

    // ---- admin ----

    fn set_admin(ref self: TContractState, new_admin: ContractAddress);
    fn set_selection(ref self: TContractState, selection: ContractAddress);
    fn get_admin(self: @TContractState) -> ContractAddress;
    fn get_selection(self: @TContractState) -> ContractAddress;

    // ---- ADMIN - timelocked parameter changes (executed by AdminTimelock) ----

    fn execute_set_reputation_stake(ref self: TContractState, amount: u256);
    fn execute_set_conviction_threshold(ref self: TContractState, amount: u256);
    fn execute_set_reward_multiplier(ref self: TContractState, amount: u256);
    fn execute_set_mini_reward_multiplier(ref self: TContractState, amount: u256);
    fn execute_set_conviction_base_lock(ref self: TContractState, duration: u64);
    fn execute_set_max_votes_per_conviction(ref self: TContractState, count: u64);
    fn execute_set_proposal_voting_period(ref self: TContractState, period: u64);

    // ---- parameter views ----

    fn get_conviction_threshold(self: @TContractState) -> u256;
    fn get_reputation_stake(self: @TContractState) -> u256;
    fn get_reward_multiplier(self: @TContractState) -> u256;
    fn get_mini_reward_multiplier(self: @TContractState) -> u256;
    fn get_conviction_base_lock(self: @TContractState) -> u64;
    fn get_max_votes_per_conviction(self: @TContractState) -> u64;
    fn get_proposal_voting_period(self: @TContractState) -> u64;
}
