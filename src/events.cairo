// SPDX-License-Identifier: MIT
//! Event payload structs for the StakeholderConviction contract. The
//! contract's `#[event]` enum lives in `lib.cairo` and lists these as
//! variants.

use starknet::ContractAddress;
use starknet::ClassHash;

/// Emitted when a juror adds transferable-token stake to the weighted pool.
#[derive(Drop, starknet::Event)]
pub struct Staked {
    /// Indexed juror whose stake changed.
    #[key]
    pub juror: ContractAddress,
    /// Amount added to the juror's total stake.
    pub amount: u256,
    /// Juror stake total after the addition.
    pub new_total: u256,
}

/// Emitted when a juror withdraws unlocked transferable-token stake.
#[derive(Drop, starknet::Event)]
pub struct Unstaked {
    /// Indexed juror whose stake changed.
    #[key]
    pub juror: ContractAddress,
    /// Amount removed from the juror's total stake.
    pub amount: u256,
    /// Juror stake total after the withdrawal.
    pub new_total: u256,
}

/// Emitted when a candidate creates a selection dispute.
#[derive(Drop, starknet::Event)]
pub struct DisputeCreated {
    /// Indexed identifier of the new dispute.
    #[key]
    pub dispute_id: u256,
    /// Indexed candidate being evaluated.
    #[key]
    pub candidate: ContractAddress,
    /// Number of requested weighted juror draws.
    pub num_draws: u32,
}

/// Emitted when an evaluation request and its bond are recorded.
#[derive(Drop, starknet::Event)]
pub struct EvaluationRequested {
    /// Indexed dispute identifier.
    #[key]
    pub dispute_id: u256,
    /// Indexed candidate being evaluated.
    #[key]
    pub candidate: ContractAddress,
    /// Evaluation bond escrowed for the request.
    pub bond_amount: u256,
}

/// Emitted for each accepted juror draw into a dispute.
#[derive(Drop, starknet::Event)]
pub struct JurorDrawn {
    /// Indexed dispute identifier.
    #[key]
    pub dispute_id: u256,
    /// Indexed selected juror.
    #[key]
    pub juror: ContractAddress,
    /// Number of times this juror has been drawn for the dispute so far.
    pub total_draws_for_juror: u32,
}

/// Emitted when a juror records a vote commitment.
#[derive(Drop, starknet::Event)]
pub struct VoteCommitted {
    /// Indexed dispute identifier.
    #[key]
    pub dispute_id: u256,
    /// Indexed committing juror.
    #[key]
    pub juror: ContractAddress,
}

/// Emitted when a juror reveals a committed score.
#[derive(Drop, starknet::Event)]
pub struct VoteRevealed {
    /// Indexed dispute identifier.
    #[key]
    pub dispute_id: u256,
    /// Indexed revealing juror.
    #[key]
    pub juror: ContractAddress,
    /// Revealed score in the inclusive range -5 through 5.
    pub score: i8,
}

/// Emitted when a non-revealing juror's stake is slashed.
#[derive(Drop, starknet::Event)]
pub struct JurorSlashed {
    /// Indexed dispute identifier.
    #[key]
    pub dispute_id: u256,
    /// Indexed slashed juror.
    #[key]
    pub juror: ContractAddress,
    /// Amount removed from the juror's stake.
    pub amount: u256,
}

/// Emitted when the caller reporting a non-revealer receives a reward.
#[derive(Drop, starknet::Event)]
pub struct SlashKeeperRewarded {
    /// Indexed caller that reported the non-revealer.
    #[key]
    pub caller: ContractAddress,
    /// Indexed reported juror.
    #[key]
    pub juror: ContractAddress,
    /// Indexed dispute identifier.
    #[key]
    pub dispute_id: u256,
    /// Reward minted or otherwise credited to the reporting caller.
    pub reward: u256,
}

/// Emitted when a dispute's final score is stored.
#[derive(Drop, starknet::Event)]
pub struct DisputeFinalized {
    /// Indexed finalized dispute identifier.
    #[key]
    pub dispute_id: u256,
    /// Indexed evaluated candidate.
    #[key]
    pub candidate: ContractAddress,
    /// Final score after outlier filtering, in the inclusive range -5 through 5.
    pub final_score: i64,
}

/// Emitted when a finalized juror claims the reward earned by participation.
#[derive(Drop, starknet::Event)]
pub struct JurorRewardClaimed {
    /// Indexed dispute identifier.
    #[key]
    pub dispute_id: u256,
    /// Indexed rewarded juror.
    #[key]
    pub juror: ContractAddress,
    /// Reward amount claimed.
    pub amount: u256,
}

/// Emitted when positive evaluation mints non-transferable governance tokens.
#[derive(Drop, starknet::Event)]
pub struct GovernanceTokensMinted {
    /// Indexed source dispute identifier.
    #[key]
    pub dispute_id: u256,
    /// Indexed recipient candidate.
    #[key]
    pub candidate: ContractAddress,
    /// Governance-token grant amount.
    pub amount: u256,
    /// Final score that determined the grant.
    pub final_score: i64,
}

/// Emitted when an evaluation bond is returned to its requester.
#[derive(Drop, starknet::Event)]
pub struct BondRefunded {
    /// Indexed settled dispute identifier.
    #[key]
    pub dispute_id: u256,
    /// Indexed requester receiving the refund.
    #[key]
    pub requester: ContractAddress,
    /// Refunded bond amount.
    pub amount: u256,
}

/// Emitted when an evaluation bond is added to a dispute's slash pool.
#[derive(Drop, starknet::Event)]
pub struct BondSlashed {
    /// Indexed settled dispute identifier.
    #[key]
    pub dispute_id: u256,
    /// Indexed requester whose bond was slashed.
    #[key]
    pub requester: ContractAddress,
    /// Slashed bond amount.
    pub amount: u256,
}

/// Emitted when a holder creates a conviction.
#[derive(Drop, starknet::Event)]
pub struct ConvictionCreated {
    /// Indexed conviction owner.
    #[key]
    pub owner: ContractAddress,
    /// Indexed per-owner conviction identifier.
    #[key]
    pub conviction_id: u32,
    /// Conviction level from 1 through 10.
    pub level: u8,
    /// Amount of governance tokens locked by the conviction.
    pub amount: u256,
}

/// Emitted when a conviction's locked governance stake is released.
#[derive(Drop, starknet::Event)]
pub struct ConvictionReleased {
    /// Indexed conviction owner.
    #[key]
    pub owner: ContractAddress,
    /// Indexed released conviction identifier.
    #[key]
    pub conviction_id: u32,
    /// Amount returned to the owner's available governance balance.
    pub amount: u256,
}

/// Emitted when a conviction permanently adds a vote to a proposal.
#[derive(Drop, starknet::Event)]
pub struct SupportAdded {
    /// Indexed proposal receiving the vote.
    #[key]
    pub proposal_id: u256,
    /// Indexed conviction owner.
    #[key]
    pub owner: ContractAddress,
    /// Conviction that supplied the vote.
    pub conviction_id: u32,
}

/// Emitted when a funding proposal and its reputation deposit are created.
#[derive(Drop, starknet::Event)]
pub struct ProposalCreated {
    /// Indexed new proposal identifier.
    #[key]
    pub proposal_id: u256,
    /// Indexed proposal author.
    #[key]
    pub author: ContractAddress,
    /// Reputation deposit escrowed at creation.
    pub deposit_amount: u256,
}

/// Emitted when a qualifying proposal is executed and its score is finalized.
#[derive(Drop, starknet::Event)]
pub struct ProposalExecuted {
    /// Indexed executed proposal identifier.
    #[key]
    pub proposal_id: u256,
    /// Frozen voting power used for the decision.
    pub total_power: u256,
    /// Final weighted proposal score.
    pub final_score: i64,
}

/// Emitted when a positive proposal score produces a budgeted reward.
#[derive(Drop, starknet::Event)]
pub struct ScoreRewardReleased {
    /// Indexed rewarded proposal identifier.
    #[key]
    pub proposal_id: u256,
    /// Indexed reward recipient.
    #[key]
    pub recipient: ContractAddress,
    /// Reward actually minted, if the budget and supply cap allowed it.
    pub amount: u256,
}

/// Emitted when a proposal deposit is returned to its author.
#[derive(Drop, starknet::Event)]
pub struct ProposalDepositRefunded {
    /// Indexed proposal identifier.
    #[key]
    pub proposal_id: u256,
    /// Indexed author receiving the refund.
    #[key]
    pub requester: ContractAddress,
    /// Refunded proposal deposit.
    pub amount: u256,
}

/// Emitted when a negative proposal score slashes its deposit.
#[derive(Drop, starknet::Event)]
pub struct ProposalDepositSlashed {
    /// Indexed proposal identifier.
    #[key]
    pub proposal_id: u256,
    /// Indexed author whose deposit was slashed.
    #[key]
    pub requester: ContractAddress,
    /// Slashed proposal deposit.
    pub amount: u256,
}

/// Emitted when ERC20 balance decay is applied to one address.
#[derive(Drop, starknet::Event)]
pub struct DecayApplied {
    /// Indexed address whose balance decayed.
    #[key]
    pub user: ContractAddress,
    /// Amount burned or removed by decay.
    pub amount: u256,
    /// Caller that submitted the decay operation.
    pub caller: ContractAddress,
}

/// Emitted when a decay caller earns its time-limited reward.
#[derive(Drop, starknet::Event)]
pub struct DecayCallerRewarded {
    /// Indexed rewarded caller.
    #[key]
    pub caller: ContractAddress,
    /// Indexed user whose decay generated the reward.
    #[key]
    pub user: ContractAddress,
    /// Reward amount.
    pub reward: u256,
}

/// Emitted when a fixed monthly reward budget is initialized or settled.
#[derive(Drop, starknet::Event)]
pub struct MonthlyBudgetSet {
    /// Indexed month identifier.
    #[key]
    pub month: u64,
    /// Total budget available for the month.
    pub budget: u256,
    /// Portion generated by the inflation schedule.
    pub inflation_part: u256,
    /// Portion recycled from the previous month's burns.
    pub recycle_part: u256,
}

/// Emitted when unused budget is written off during month rollover.
#[derive(Drop, starknet::Event)]
pub struct MonthlyBudgetBurned {
    /// Indexed month whose unused budget was written off.
    #[key]
    pub month: u64,
    /// Amount not carried forward.
    pub amount: u256,
}

/// Emitted when a reward successfully consumes monthly budget.
#[derive(Drop, starknet::Event)]
pub struct BudgetRewardMinted {
    /// Indexed month in which the reward consumed budget.
    #[key]
    pub month: u64,
    /// Indexed reward recipient.
    #[key]
    pub recipient: ContractAddress,
    /// Amount minted against the monthly budget.
    pub amount: u256,
}

/// Emitted when an administrative parameter change is proposed.
#[derive(Drop, starknet::Event)]
pub struct ChangeProposed {
    /// Indexed parameter key.
    #[key]
    pub param_key: felt252,
    /// Proposed encoded parameter value.
    pub new_value: u256,
    /// Timestamp at which execution becomes available.
    pub effective_at: u64,
}

/// Emitted when a pending administrative parameter change is executed.
#[derive(Drop, starknet::Event)]
pub struct ChangeExecuted {
    /// Indexed parameter key.
    #[key]
    pub param_key: felt252,
    /// Encoded value written to storage.
    pub new_value: u256,
}

/// Emitted when a protected-address flag change is proposed.
#[derive(Drop, starknet::Event)]
pub struct ProtectedAddressProposed {
    /// Indexed address whose protection status changes.
    #[key]
    pub target: ContractAddress,
    /// Proposed protection value.
    pub new_value: bool,
    /// Timestamp at which execution becomes available.
    pub effective_at: u64,
}

/// Emitted when a protected-address flag is executed.
#[derive(Drop, starknet::Event)]
pub struct ProtectedAddressSet {
    /// Indexed address whose protection status changed.
    #[key]
    pub target: ContractAddress,
    /// Current protection value.
    pub new_value: bool,
}

/// Emitted when adding an admin is proposed.
#[derive(Drop, starknet::Event)]
pub struct AdminAddProposed {
    /// Indexed address proposed for the admin roster.
    #[key]
    pub new_admin: ContractAddress,
    /// Timestamp at which execution becomes available.
    pub effective_at: u64,
}

/// Emitted when an address is added to the admin roster.
#[derive(Drop, starknet::Event)]
pub struct AdminAdded {
    /// Indexed address added to the admin roster.
    #[key]
    pub admin: ContractAddress,
}

/// Emitted when removing an admin is proposed.
#[derive(Drop, starknet::Event)]
pub struct AdminRemoveProposed {
    /// Indexed address proposed for removal.
    #[key]
    pub admin_to_remove: ContractAddress,
    /// Timestamp at which execution becomes available.
    pub effective_at: u64,
}

/// Emitted when an address is removed from the admin roster.
#[derive(Drop, starknet::Event)]
pub struct AdminRemoved {
    /// Indexed address removed from the admin roster.
    #[key]
    pub admin: ContractAddress,
}

/// Emitted when a class-hash upgrade is proposed.
#[derive(Drop, starknet::Event)]
pub struct UpgradeProposed {
    /// Indexed proposed class hash.
    #[key]
    pub new_class_hash: ClassHash,
    /// Timestamp at which execution becomes available.
    pub effective_at: u64,
}

/// Emitted when a class-hash upgrade is executed.
#[derive(Drop, starknet::Event)]
pub struct UpgradeExecuted {
    /// Indexed class hash written to the contract.
    #[key]
    pub new_class_hash: ClassHash,
}

/// Emitted when permanent upgrade disabling is proposed.
#[derive(Drop, starknet::Event)]
pub struct UpgradeDisableProposed {
    /// Timestamp at which the irreversible cut becomes executable.
    #[key]
    pub effective_at: u64,
}

/// Emitted when upgrades are permanently disabled.
#[derive(Drop, starknet::Event)]
pub struct UpgradesDisabledForever {
    /// Indexed admin that executed the permanent cut.
    #[key]
    pub by: ContractAddress,
}
