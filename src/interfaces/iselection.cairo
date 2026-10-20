// SPDX-License-Identifier: MIT
//! Cross-contract interface for `Selection`, the reworked juror selection
//! and dispute module. Juror stakes are represented by stake IDs. Each
//! evaluation ID has its own Fenwick tree and lifecycle phases
//! (APPLYING, DRAWING, COMMIT, REVEAL, FINALIZED, DISMISSED).

use starknet::ContractAddress;
use crate::types::{Dispute, Evaluation, Stake};

#[starknet::interface]
pub trait ISelection<TContractState> {
    // ---- stake management ----

    /// Deposit ERC20 and create a new stake; returns the stake ID.
    fn create_stake(ref self: TContractState, amount: u256) -> u256;

    /// Withdraw ERC20 from a stake (only when no active evaluations lock it).
    fn unstake_stake(ref self: TContractState, stake_id: u256, amount: u256);

    // ---- evaluation lifecycle ----

    /// Request candidate evaluation, escrow a bond, and receive an evaluation ID.
    fn request_evaluation(ref self: TContractState, evidence: ByteArray) -> u256;

    /// Apply a stake ID to an evaluation during the applying phase.
    fn apply_to_evaluation(ref self: TContractState, evaluation_id: u256, stake_id: u256);

    /// Remove a stake ID from an evaluation (applying phase only, or after
    /// commit if the juror was not drawn).
    fn remove_from_evaluation(ref self: TContractState, evaluation_id: u256, stake_id: u256);

    /// Advance an evaluation's phase when conditions are met (called by anyone).
    fn advance_evaluation(ref self: TContractState, evaluation_id: u256);

    /// Draw jurors stake-weighted for an evaluation (drawing phase).
    fn draw_jurors(ref self: TContractState, evaluation_id: u256);

    /// Commit a vote hash for a drawn stake ID.
    fn commit_vote(
        ref self: TContractState, evaluation_id: u256, stake_id: u256, commit_hash: felt252,
    );

    /// Reveal a committed score for a drawn stake ID.
    fn reveal_vote(
        ref self: TContractState, evaluation_id: u256, stake_id: u256, score: i8, salt: felt252,
    );

    /// Slash a non-revealing drawn stake ID.
    fn slash_non_revealer(ref self: TContractState, evaluation_id: u256, stake_id: u256);

    /// Finalize an evaluation: compute score, slash incoherent jurors,
    /// distribute rewards, settle bond.
    fn finalize_evaluation(ref self: TContractState, evaluation_id: u256);

    /// Claim a juror reward for a finalized evaluation.
    fn claim_juror_reward(ref self: TContractState, evaluation_id: u256, stake_id: u256);

    /// Stakeholder: withdraw bond after evaluation finalized (only if score >= 0).
    fn unstake_bond(ref self: TContractState, evaluation_id: u256);

    // ---- admin ----

    fn set_admin(ref self: TContractState, new_admin: ContractAddress);
    fn get_admin(self: @TContractState) -> ContractAddress;

    // ---- ADMIN - timelocked parameter changes (executed by AdminTimelock) ----

    fn execute_set_evaluation_bond_amount(ref self: TContractState, amount: u256);
    fn execute_set_commit_duration(ref self: TContractState, duration: u64);
    fn execute_set_reveal_duration(ref self: TContractState, duration: u64);
    fn execute_set_non_reveal_slash_bps(ref self: TContractState, bps: u16);
    fn execute_set_incoherence_slash_bps(ref self: TContractState, bps: u16);
    fn execute_set_coherence_band(ref self: TContractState, band: u8);
    fn execute_set_evaluation_cooldown(ref self: TContractState, cooldown: u64);
    fn execute_set_applying_duration(ref self: TContractState, duration: u64);
    fn execute_set_min_stake_ids(ref self: TContractState, count: u32);
    fn execute_set_min_jurors(ref self: TContractState, count: u32);
    fn execute_set_max_evaluations_per_stake(ref self: TContractState, count: u32);
    fn execute_set_juror_reward_amount(ref self: TContractState, amount: u256);
    fn execute_set_drawing_duration(ref self: TContractState, duration: u64);
    fn execute_set_vrf_provider(ref self: TContractState, provider: ContractAddress);

    // ---- dispute / stake / evaluation views ----

    fn get_dispute(self: @TContractState, dispute_id: u256) -> Dispute;
    fn get_dispute_evidence(self: @TContractState, dispute_id: u256) -> ByteArray;
    fn get_evaluation(self: @TContractState, evaluation_id: u256) -> Evaluation;
    fn get_evaluation_evidence(self: @TContractState, evaluation_id: u256) -> ByteArray;
    fn get_stake(self: @TContractState, stake_id: u256) -> Stake;
    fn get_juror_stake(self: @TContractState, juror: ContractAddress) -> u256;
    fn get_juror_stake_ids(self: @TContractState, juror: ContractAddress) -> Array<u256>;
    fn total_stake_weight(self: @TContractState) -> u256;
    fn get_stake_evaluation_count(self: @TContractState, stake_id: u256) -> u32;
    fn get_juror_locked_stake(self: @TContractState, juror: ContractAddress) -> u256;
    fn get_juror_unlocked_stake(self: @TContractState, juror: ContractAddress) -> u256;
    fn get_juror_open_evaluation_count(self: @TContractState, juror: ContractAddress) -> u32;
    fn get_evaluation_bond_amount(self: @TContractState) -> u256;
    fn get_active_evaluation_for_candidate(
        self: @TContractState, candidate: ContractAddress,
    ) -> u256;
    fn get_evaluation_cooldown(self: @TContractState) -> u64;
    fn get_last_evaluation_finalized(self: @TContractState, candidate: ContractAddress) -> u64;
    fn get_stake_slashed_total(self: @TContractState, stake_id: u256, evaluation_id: u256) -> u256;

    // ---- parameter views ----

    fn get_incoherence_slash_bps(self: @TContractState) -> u16;
    fn get_coherence_band(self: @TContractState) -> u8;
    fn get_commit_duration(self: @TContractState) -> u64;
    fn get_reveal_duration(self: @TContractState) -> u64;
    fn get_non_reveal_slash_bps(self: @TContractState) -> u16;
    fn get_applying_duration(self: @TContractState) -> u64;
    fn get_min_stake_ids(self: @TContractState) -> u32;
    fn get_min_jurors(self: @TContractState) -> u32;
    fn get_max_evaluations_per_stake(self: @TContractState) -> u32;
    fn get_juror_reward_amount(self: @TContractState) -> u256;
    fn get_drawing_duration(self: @TContractState) -> u64;
}
