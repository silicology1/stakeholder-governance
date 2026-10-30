// SPDX-License-Identifier: MIT
//! Cross-contract interface for `AdminTimelock`, the central timelock that
//! owns parameter proposals, protected-address changes, the admin roster,
//! and class-hash upgrade / disable orchestration for the other modules.

use starknet::{ClassHash, ContractAddress};
use crate::types::{PendingAdminChange, PendingChange, PendingProtectedChange, PendingUpgrade};

#[starknet::interface]
pub trait IAdminTimelock<TContractState> {
    // ---- parameter changes (Selection module) ----

    fn propose_set_evaluation_bond_amount(ref self: TContractState, amount: u256);
    fn execute_set_evaluation_bond_amount(ref self: TContractState);

    fn propose_set_commit_duration(ref self: TContractState, duration: u64);
    fn execute_set_commit_duration(ref self: TContractState);

    fn propose_set_reveal_duration(ref self: TContractState, duration: u64);
    fn execute_set_reveal_duration(ref self: TContractState);
    fn propose_set_slashing_duration(ref self: TContractState, duration: u64);
    fn execute_set_slashing_duration(ref self: TContractState);

    fn propose_set_non_reveal_slash_bps(ref self: TContractState, bps: u16);
    fn execute_set_non_reveal_slash_bps(ref self: TContractState);

    fn propose_set_incoherence_slash_bps(ref self: TContractState, bps: u16);
    fn execute_set_incoherence_slash_bps(ref self: TContractState);

    fn propose_set_coherence_band(ref self: TContractState, band: u8);
    fn execute_set_coherence_band(ref self: TContractState);

    fn propose_set_evaluation_cooldown(ref self: TContractState, cooldown: u64);
    fn execute_set_evaluation_cooldown(ref self: TContractState);

    fn propose_set_applying_duration(ref self: TContractState, duration: u64);
    fn execute_set_applying_duration(ref self: TContractState);

    fn propose_set_min_stake_ids(ref self: TContractState, count: u32);
    fn execute_set_min_stake_ids(ref self: TContractState);

    fn propose_set_min_jurors(ref self: TContractState, count: u32);
    fn execute_set_min_jurors(ref self: TContractState);

    fn propose_set_max_evaluations_per_stake(ref self: TContractState, count: u32);
    fn execute_set_max_evaluations_per_stake(ref self: TContractState);

    fn propose_set_juror_reward_amount(ref self: TContractState, amount: u256);
    fn execute_set_juror_reward_amount(ref self: TContractState);

    fn propose_set_drawing_duration(ref self: TContractState, duration: u64);
    fn execute_set_drawing_duration(ref self: TContractState);

    fn propose_set_vrf_provider(ref self: TContractState, provider: ContractAddress);
    fn execute_set_vrf_provider(ref self: TContractState);

    fn propose_set_selection_admin(ref self: TContractState, new_admin: ContractAddress);
    fn execute_set_selection_admin(ref self: TContractState);

    fn propose_set_governance_admin(ref self: TContractState, new_admin: ContractAddress);
    fn execute_set_governance_admin(ref self: TContractState);

    fn propose_set_conviction_token_admin(
        ref self: TContractState, new_admin: ContractAddress,
    );
    fn execute_set_conviction_token_admin(ref self: TContractState);

    fn propose_set_governance_selection(
        ref self: TContractState, selection: ContractAddress,
    );
    fn execute_set_governance_selection(ref self: TContractState);

    fn propose_set_conviction_token_modules(
        ref self: TContractState, selection: ContractAddress, governance: ContractAddress,
    );
    fn execute_set_conviction_token_modules(ref self: TContractState);

    // ---- parameter changes (ConvictionToken module) ----

    fn propose_set_decay_rate_bps(ref self: TContractState, bps: u16);
    fn execute_set_decay_rate_bps(ref self: TContractState);

    fn propose_set_min_decay_for_reward(ref self: TContractState, amount: u256);
    fn execute_set_min_decay_for_reward(ref self: TContractState);

    fn propose_set_caller_reward_amount(ref self: TContractState, amount: u256);
    fn execute_set_caller_reward_amount(ref self: TContractState);

    fn propose_set_inflation_rate_bps(ref self: TContractState, bps: u16);
    fn execute_set_inflation_rate_bps(ref self: TContractState);

    // ---- parameter changes (Governance module) ----

    fn propose_set_reputation_stake(ref self: TContractState, amount: u256);
    fn execute_set_reputation_stake(ref self: TContractState);

    fn propose_set_conviction_threshold(ref self: TContractState, amount: u256);
    fn execute_set_conviction_threshold(ref self: TContractState);

    fn propose_set_reward_multiplier(ref self: TContractState, amount: u256);
    fn execute_set_reward_multiplier(ref self: TContractState);

    fn propose_set_mini_reward_multiplier(ref self: TContractState, amount: u256);
    fn execute_set_mini_reward_multiplier(ref self: TContractState);

    fn propose_set_conviction_base_lock(ref self: TContractState, duration: u64);
    fn execute_set_conviction_base_lock(ref self: TContractState);

    fn propose_set_max_votes_per_conviction(ref self: TContractState, count: u64);
    fn execute_set_max_votes_per_conviction(ref self: TContractState);

    fn propose_set_proposal_voting_period(ref self: TContractState, period: u64);
    fn execute_set_proposal_voting_period(ref self: TContractState);

    fn get_pending_change(
        self: @TContractState, target: ContractAddress, param_key: felt252,
    ) -> PendingChange;

    // ---- protected address (decay) ----

    fn propose_set_protected_address(
        ref self: TContractState, target: ContractAddress, protected: bool,
    );
    fn execute_set_protected_address(ref self: TContractState, target_address: ContractAddress);
    fn get_pending_protected(
        self: @TContractState, target_address: ContractAddress,
    ) -> PendingProtectedChange;

    // ---- admin roster ----

    fn propose_add_admin(ref self: TContractState, new_admin: ContractAddress);
    fn execute_add_admin(ref self: TContractState, new_admin: ContractAddress);
    fn propose_remove_admin(ref self: TContractState, admin_to_remove: ContractAddress);
    fn execute_remove_admin(ref self: TContractState, admin_to_remove: ContractAddress);
    fn get_pending_admin_change(
        self: @TContractState, target: ContractAddress,
    ) -> PendingAdminChange;
    fn admin_count(self: @TContractState) -> u32;

    // ---- upgrade orchestration ----

    fn propose_upgrade(
        ref self: TContractState, target: ContractAddress, new_class_hash: ClassHash,
    );
    fn execute_upgrade(ref self: TContractState, target: ContractAddress);
    fn propose_disable_upgrades(ref self: TContractState, target: ContractAddress);
    fn execute_disable_upgrades(ref self: TContractState, target: ContractAddress);
    fn is_upgrades_disabled(self: @TContractState, target: ContractAddress) -> bool;
    fn propose_set_stake_amount(ref self: TContractState, amount: u256);
    fn execute_set_stake_amount(ref self: TContractState);
    fn get_pending_upgrade(self: @TContractState, target: ContractAddress) -> PendingUpgrade;
    fn get_pending_upgrade_disable(self: @TContractState, target: ContractAddress) -> PendingChange;
}
