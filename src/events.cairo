// SPDX-License-Identifier: MIT
//! Event payload structs for the StakeholderConviction contract. The
//! contract's `#[event]` enum lives in `lib.cairo` and lists these as
//! variants.

use starknet::ContractAddress;
use starknet::ClassHash;

#[derive(Drop, starknet::Event)]
pub struct Staked {
    #[key]
    pub juror: ContractAddress,
    pub amount: u256,
    pub new_total: u256,
}

#[derive(Drop, starknet::Event)]
pub struct Unstaked {
    #[key]
    pub juror: ContractAddress,
    pub amount: u256,
    pub new_total: u256,
}

#[derive(Drop, starknet::Event)]
pub struct DisputeCreated {
    #[key]
    pub dispute_id: u256,
    #[key]
    pub candidate: ContractAddress,
    pub num_draws: u32,
}

#[derive(Drop, starknet::Event)]
pub struct EvaluationRequested {
    #[key]
    pub dispute_id: u256,
    #[key]
    pub candidate: ContractAddress,
    pub bond_amount: u256,
}

#[derive(Drop, starknet::Event)]
pub struct JurorDrawn {
    #[key]
    pub dispute_id: u256,
    #[key]
    pub juror: ContractAddress,
    pub total_draws_for_juror: u32,
}

#[derive(Drop, starknet::Event)]
pub struct VoteCommitted {
    #[key]
    pub dispute_id: u256,
    #[key]
    pub juror: ContractAddress,
}

#[derive(Drop, starknet::Event)]
pub struct VoteRevealed {
    #[key]
    pub dispute_id: u256,
    #[key]
    pub juror: ContractAddress,
    pub score: i8,
}

#[derive(Drop, starknet::Event)]
pub struct JurorSlashed {
    #[key]
    pub dispute_id: u256,
    #[key]
    pub juror: ContractAddress,
    pub amount: u256,
}

#[derive(Drop, starknet::Event)]
pub struct SlashKeeperRewarded {
    #[key]
    pub caller: ContractAddress,
    #[key]
    pub juror: ContractAddress,
    #[key]
    pub dispute_id: u256,
    pub reward: u256,
}

#[derive(Drop, starknet::Event)]
pub struct DisputeFinalized {
    #[key]
    pub dispute_id: u256,
    #[key]
    pub candidate: ContractAddress,
    pub final_score: i64,
}

#[derive(Drop, starknet::Event)]
pub struct JurorRewardClaimed {
    #[key]
    pub dispute_id: u256,
    #[key]
    pub juror: ContractAddress,
    pub amount: u256,
}

#[derive(Drop, starknet::Event)]
pub struct GovernanceTokensMinted {
    #[key]
    pub dispute_id: u256,
    #[key]
    pub candidate: ContractAddress,
    pub amount: u256,
    pub final_score: i64,
}

#[derive(Drop, starknet::Event)]
pub struct BondRefunded {
    #[key]
    pub dispute_id: u256,
    #[key]
    pub requester: ContractAddress,
    pub amount: u256,
}

#[derive(Drop, starknet::Event)]
pub struct BondSlashed {
    #[key]
    pub dispute_id: u256,
    #[key]
    pub requester: ContractAddress,
    pub amount: u256,
}

#[derive(Drop, starknet::Event)]
pub struct ConvictionCreated {
    #[key]
    pub owner: ContractAddress,
    #[key]
    pub conviction_id: u32,
    pub level: u8,
    pub amount: u256,
}

#[derive(Drop, starknet::Event)]
pub struct ConvictionReleased {
    #[key]
    pub owner: ContractAddress,
    #[key]
    pub conviction_id: u32,
    pub amount: u256,
}

#[derive(Drop, starknet::Event)]
pub struct SupportAdded {
    #[key]
    pub proposal_id: u256,
    #[key]
    pub owner: ContractAddress,
    pub conviction_id: u32,
}

#[derive(Drop, starknet::Event)]
pub struct ProposalCreated {
    #[key]
    pub proposal_id: u256,
    #[key]
    pub author: ContractAddress,
    pub deposit_amount: u256,
}

#[derive(Drop, starknet::Event)]
pub struct ProposalExecuted {
    #[key]
    pub proposal_id: u256,
    pub total_power: u256,
    pub final_score: i64,
}

#[derive(Drop, starknet::Event)]
pub struct ScoreRewardReleased {
    #[key]
    pub proposal_id: u256,
    #[key]
    pub recipient: ContractAddress,
    pub amount: u256,
}

#[derive(Drop, starknet::Event)]
pub struct ProposalDepositRefunded {
    #[key]
    pub proposal_id: u256,
    #[key]
    pub requester: ContractAddress,
    pub amount: u256,
}

#[derive(Drop, starknet::Event)]
pub struct ProposalDepositSlashed {
    #[key]
    pub proposal_id: u256,
    #[key]
    pub requester: ContractAddress,
    pub amount: u256,
}

#[derive(Drop, starknet::Event)]
pub struct DecayApplied {
    #[key]
    pub user: ContractAddress,
    pub amount: u256,
    pub caller: ContractAddress,
}

#[derive(Drop, starknet::Event)]
pub struct DecayCallerRewarded {
    #[key]
    pub caller: ContractAddress,
    #[key]
    pub user: ContractAddress,
    pub reward: u256,
}

#[derive(Drop, starknet::Event)]
pub struct MonthlyBudgetSet {
    #[key]
    pub month: u64,
    pub budget: u256,
    pub inflation_part: u256,
    pub recycle_part: u256,
}

#[derive(Drop, starknet::Event)]
pub struct MonthlyBudgetBurned {
    #[key]
    pub month: u64,
    pub amount: u256,
}

#[derive(Drop, starknet::Event)]
pub struct BudgetRewardMinted {
    #[key]
    pub month: u64,
    #[key]
    pub recipient: ContractAddress,
    pub amount: u256,
}

#[derive(Drop, starknet::Event)]
pub struct ChangeProposed {
    #[key]
    pub param_key: felt252,
    pub new_value: u256,
    pub effective_at: u64,
}

#[derive(Drop, starknet::Event)]
pub struct ChangeExecuted {
    #[key]
    pub param_key: felt252,
    pub new_value: u256,
}

#[derive(Drop, starknet::Event)]
pub struct ProtectedAddressProposed {
    #[key]
    pub target: ContractAddress,
    pub new_value: bool,
    pub effective_at: u64,
}

#[derive(Drop, starknet::Event)]
pub struct ProtectedAddressSet {
    #[key]
    pub target: ContractAddress,
    pub new_value: bool,
}

#[derive(Drop, starknet::Event)]
pub struct AdminAddProposed {
    #[key]
    pub new_admin: ContractAddress,
    pub effective_at: u64,
}

#[derive(Drop, starknet::Event)]
pub struct AdminAdded {
    #[key]
    pub admin: ContractAddress,
}

#[derive(Drop, starknet::Event)]
pub struct AdminRemoveProposed {
    #[key]
    pub admin_to_remove: ContractAddress,
    pub effective_at: u64,
}

#[derive(Drop, starknet::Event)]
pub struct AdminRemoved {
    #[key]
    pub admin: ContractAddress,
}

#[derive(Drop, starknet::Event)]
pub struct UpgradeProposed {
    #[key]
    pub new_class_hash: ClassHash,
    pub effective_at: u64,
}

#[derive(Drop, starknet::Event)]
pub struct UpgradeExecuted {
    #[key]
    pub new_class_hash: ClassHash,
}

#[derive(Drop, starknet::Event)]
pub struct UpgradeDisableProposed {
    #[key]
    pub effective_at: u64,
}

#[derive(Drop, starknet::Event)]
pub struct UpgradesDisabledForever {
    #[key]
    pub by: ContractAddress,
}