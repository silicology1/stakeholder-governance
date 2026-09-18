// SPDX-License-Identifier: MIT
//! StakeholderConvictionGovernance
//! ================================
//! ONE Starknet/Cairo contract, ONE token: this contract embeds
//! OpenZeppelin's `ERC20Component` directly, so it *is* the transferable
//! token - there is no separate address to deploy, no `MINTER_ROLE` to
//! grant post-deploy, and no external mint entrypoint at all. The only
//! places that can ever increase total supply are:
//!   1. the constructor's one-time `INITIAL_SUPPLY` mint, and
//!   2. score-based reward minting in `execute_proposal`.
//!   3. the slash-keeper reward in `slash_non_revealer`.
//! Every mint goes through `_mint_capped`, which asserts
//! `total_supply() + amount <= MAX_SUPPLY` first.
//!
//!   STAGE 1 - SELECTION (Kleros-style Schelling game)
//!   ---------------------------------------------------
//!   A candidate puts themselves up for evaluation via `request_evaluation`
//!   (opt-in, bonded - see "OPT-IN EVALUATION WITH A BOND" below).
//!   Jurors stake this contract's own token (Fenwick-tree weighted
//!   sortition) and are drawn with replacement via Cartridge VRF. Each
//!   drawn juror commits, then reveals, a score in [-5, +5] for the
//!   candidate. On `finalize_selection` the contract computes a
//!   stake-weighted mean, drops outliers more than one (population) stdev
//!   away, and recomputes the mean over the remainder - the trimmed-mean
//!   routine. A positive final score mints non-transferable governance
//!   tokens to the candidate.
//!
//!   STAGE 2 - EMPOWERMENT (non-transferable, decaying governance tokens)
//!   ---------------------------------------------------------------------
//!   The instant a dispute finalizes with a positive final score, the
//!   candidate is minted non-transferable ("soulbound") governance tokens.
//!   A score of zero or negative mints nothing. These tokens are completely
//!   separate from the ERC20 embedded in this same contract - not minted
//!   through `_mint_capped`, not subject to MAX_SUPPLY, and cannot be
//!   transferred. A holder's balance is the sum of all their grants, each
//!   decaying linearly, in discrete hourly steps, from its minted amount
//!   down to zero over exactly 8_760 hours (365 days).
//!
//!   STAGE 3 - SCORE VOTING (proposal scoring via governance tokens)
//!   ----------------------------------------------------------------
//!   An empowered stakeholder creates a conviction: locks some of their
//!   *currently available* (decayed, unlocked) governance-token balance
//!   with a chosen level (1-10). They can then `vote_with_conviction` on
//!   a single proposal at a time, casting a score in [-5, +5]. Voting
//!   power for that vote is:
//!       weight = level * sqrt(locked_amount * hours_locked)
//!   where `locked_amount` is the governance-token stake frozen in the
//!   conviction and `hours_locked` counts whole hours since the conviction
//!   was created (`created_at`). Power therefore grows sub-linearly with
//!   both stake and lock time.
//!   Multiple supporters accumulate weighted scores in a histogram.
//!   Once the admin-set `conviction_threshold` of total voting power is
//!   cleared, anyone can call `execute_proposal` which:
//!     - Computes the weighted final score from the histogram
//!     - If final_score > 0: refunds the proposal deposit and mints a
//!       score-based reward to the funding_wallet
//!     - If final_score <= 0: slashes the proposal deposit
//!
//!   ANTI-SYBIL: PROPOSAL DEPOSIT
//!   --------------------------------
//!   Creating a proposal requires depositing `reputation_stake` of this
//!   contract's own ERC20 (must `approve` first). This filters out spam.
//!   The deposit is refunded on positive final score, slashed to the
//!   slash_pool on zero or negative.
//!
//!   MONTHLY INFLATION + BURN RECYCLING BUDGET
//!   ---------------------------------------------
//!   All ERC20 reward mints (proposal score rewards, slash-keeper reward,
//!   decay-caller reward) are capped by a per-month budget:
//!       budget_month[N] = inflation_part + recycle_part
//!     - inflation_part = total_supply() * inflation_rate_bps / (10000 * 12),
//!       i.e. at most 5%/12 of current supply per fixed 30-day month
//!       (MONTH_SECONDS). It is 0 once supply reaches MAX_SUPPLY.
//!     - recycle_part   = total ERC20 tokens actually burned during the
//!       previous month (decay burns + explicit `burn` calls).
//!   A month's unutilized budget is burned (written off) at rollover; it is
//!   NOT recycled. Rewards that exceed the remaining budget revert.
//!
//!   SUPPLY: fixed cap, one-time initial mint
//!   -------------------------------------------
//!     - `MAX_SUPPLY`     = 50,000,000 tokens (18 decimals).
//!     - `INITIAL_SUPPLY` = 10,000,000 tokens (18 decimals), minted in
//!       the constructor.
//!   Reward mints go through `_mint_from_budget` (monthly cap) then
//!   `_mint_capped` against MAX_SUPPLY.
//!
//!   ADMIN TIMELOCK
//!   ----------------
//!   Every admin parameter (bond amount, reputation stake, conviction
//!   threshold, reward multipliers, decay rates, etc.) uses a two-step
//!   `propose_*` / `execute_*` pair with a 3-day timelock
//!   (`TIMELOCK_DURATION = 259_200` seconds). Class-hash upgrades use a
//!   separate 7-day timelock (`UPGRADE_TIMELOCK_DURATION = 604_800`).
//!
//! JUROR STAKE LOCKING (anti-evasion)
//! ----------------------------------
//! * Every juror has `juror_locked_total`, the SUM of stake-at-draw-time
//!   snapshots across every dispute they are currently drawn into and have
//!   not yet resolved. `unstake` asserts
//!   `current_stake - withdraw_amount >= juror_locked_total`.
//! * `MAX_CONCURRENT_JUROR_LOCKS` (15) caps how many simultaneously-open
//!   dispute locks a juror can carry; past that, they are skipped in the
//!   draw via deterministic redraw.
//!
//! OPT-IN EVALUATION WITH A BOND
//! ------------------------------
//! * `request_evaluation` requires locking `evaluation_bond_amount`
//!   (admin-timelocked, default 50 tokens) of this contract's own token.
//!   Refunded on positive score, otherwise added to `slash_pool`.
//! * One open request at a time per candidate.
//!
//! SCORE VOTING POWER
//! -------------------
//! * weight = level (1-10) * sqrt(governance_tokens_locked * hours_locked)
//! * hours_locked = (now - created_at) / 3600, floored; 0 before the first
//!   whole hour elapses.
//! * Multiple convictions per holder are allowed (each with own level).
//! * A conviction can only support one proposal at a time.
//!
//! REWARD MINTING
//! ---------------
//! * `reward_multiplier` (for scores 4-5) and `mini_reward_multiplier`
//!   (for scores 1-3) are admin-timelocked.
//! * reward = final_score * multiplier, minted to funding_wallet on
//!   positive final score, subject to the monthly inflation budget
//!   (see "MONTHLY INFLATION + BURN RECYCLING BUDGET" above).
//!
//! CODE ORGANIZATION
//! -----------------
//! This file keeps everything that must touch the contract's generated
//! `ContractState` (storage, `#[event]` enum, constructor, and both impls).
//! Declarations that need no plugin context live in sibling modules:
//!   - `constants.cairo`  : all consts + timelocked-parameter keys
//!   - `types/`           : storage structs (dispute, governance, admin)
//!   - `events.cairo`     : event payload structs
//!   - `utils/`           : pure, storage-free helpers (math, fenwick, random)

mod constants;
mod events;
mod types;
mod utils;

#[starknet::interface]
pub trait IStakeholderConviction<TContractState> {
    // ---- juror staking (Kleros side) ----
    fn stake(ref self: TContractState, amount: u256);
    fn unstake(ref self: TContractState, amount: u256);

    // ---- stakeholder selection (Kleros dispute lifecycle) ----
    fn request_evaluation(ref self: TContractState, evidence: ByteArray) -> u256;
    fn commit_vote(ref self: TContractState, dispute_id: u256, commit_hash: felt252);
    fn reveal_vote(ref self: TContractState, dispute_id: u256, score: i8, salt: felt252);
    fn slash_non_revealer(
        ref self: TContractState, dispute_id: u256, juror: starknet::ContractAddress,
    );
    fn finalize_selection(ref self: TContractState, dispute_id: u256);
    fn claim_juror_reward(ref self: TContractState, dispute_id: u256);

    // ---- non-transferable governance tokens (Stage 2, decaying) ----
    fn governance_balance(self: @TContractState, holder: starknet::ContractAddress) -> u256;
    fn governance_available(self: @TContractState, holder: starknet::ContractAddress) -> u256;
    fn governance_locked(self: @TContractState, holder: starknet::ContractAddress) -> u256;

    // ---- score voting / proposal lifecycle ----
    fn create_proposal(
        ref self: TContractState,
        funding_wallet: starknet::ContractAddress,
        evidence: ByteArray,
    ) -> u256;
    fn create_conviction(ref self: TContractState, level: u8, amount: u256) -> u32;
    fn vote_with_conviction(
        ref self: TContractState, proposal_id: u256, conviction_id: u32, score: i8,
    );
    fn remove_support(ref self: TContractState, conviction_id: u32);
    fn release_conviction(ref self: TContractState, conviction_id: u32);
    fn execute_proposal(ref self: TContractState, proposal_id: u256);

    fn get_conviction_power(
        self: @TContractState, owner: starknet::ContractAddress, conviction_id: u32,
    ) -> u256;
    fn get_proposal_total_power(self: @TContractState, proposal_id: u256) -> u256;

    // ---- this contract's own ERC20 ----
    fn token_max_supply(self: @TContractState) -> u256;
    fn token_remaining_mintable(self: @TContractState) -> u256;
    fn burn(ref self: TContractState, amount: u256);

    // ---- monthly inflation / burn-recycling budget ----
    fn get_current_month(self: @TContractState) -> u64;
    fn get_month_start(self: @TContractState) -> u64;
    fn get_month_budget(self: @TContractState, month: u64) -> u256;
    fn get_month_budget_minted(self: @TContractState, month: u64) -> u256;
    fn get_month_burned(self: @TContractState, month: u64) -> u256;
    fn get_remaining_month_budget(self: @TContractState) -> u256;
    fn get_inflation_rate_bps(self: @TContractState) -> u16;

    // ---- ERC20 balance decay ----
    fn apply_decay(ref self: TContractState, user: starknet::ContractAddress);
    fn batch_apply_decay(ref self: TContractState, users: Array<starknet::ContractAddress>);
    fn get_decay_rate_bps(self: @TContractState) -> u16;
    fn get_min_decay_for_reward(self: @TContractState) -> u256;
    fn get_caller_reward_amount(self: @TContractState) -> u256;
    fn get_last_decay_at(self: @TContractState, user: starknet::ContractAddress) -> u64;
    fn is_protected_address(self: @TContractState, user: starknet::ContractAddress) -> bool;

    // ---- juror stake locking views ----
    fn get_juror_locked_stake(
        self: @TContractState, juror: starknet::ContractAddress,
    ) -> u256;
    fn get_juror_unlocked_stake(
        self: @TContractState, juror: starknet::ContractAddress,
    ) -> u256;
    fn get_juror_open_dispute_count(
        self: @TContractState, juror: starknet::ContractAddress,
    ) -> u32;

    // ---- opt-in evaluation bond views ----
    fn get_evaluation_bond_amount(self: @TContractState) -> u256;
    fn get_active_dispute_for_candidate(
        self: @TContractState, candidate: starknet::ContractAddress,
    ) -> u256;
    fn get_dispute_evidence(self: @TContractState, dispute_id: u256) -> ByteArray;

    // ---- admin: timelocked parameter changes ----
    fn propose_set_funding_token(ref self: TContractState, token: starknet::ContractAddress);
    fn execute_set_funding_token(ref self: TContractState);
    fn propose_set_evaluation_bond_amount(ref self: TContractState, amount: u256);
    fn execute_set_evaluation_bond_amount(ref self: TContractState);
    fn propose_set_reputation_stake(ref self: TContractState, amount: u256);
    fn execute_set_reputation_stake(ref self: TContractState);
    fn propose_set_conviction_threshold(ref self: TContractState, threshold: u256);
    fn execute_set_conviction_threshold(ref self: TContractState);
    fn propose_set_reward_multiplier(ref self: TContractState, amount: u256);
    fn execute_set_reward_multiplier(ref self: TContractState);
    fn propose_set_mini_reward_multiplier(ref self: TContractState, amount: u256);
    fn execute_set_mini_reward_multiplier(ref self: TContractState);
    fn propose_set_vrf_provider(
        ref self: TContractState, new_vrf_provider: starknet::ContractAddress,
    );
    fn execute_set_vrf_provider(ref self: TContractState);
    fn propose_set_commit_duration(ref self: TContractState, commit_duration: u64);
    fn execute_set_commit_duration(ref self: TContractState);
    fn propose_set_reveal_duration(ref self: TContractState, reveal_duration: u64);
    fn execute_set_reveal_duration(ref self: TContractState);
    fn propose_set_non_reveal_slash_bps(ref self: TContractState, bps: u16);
    fn execute_set_non_reveal_slash_bps(ref self: TContractState);
    fn propose_set_decay_rate_bps(ref self: TContractState, bps: u16);
    fn execute_set_decay_rate_bps(ref self: TContractState);
    fn propose_set_min_decay_for_reward(ref self: TContractState, amount: u256);
    fn execute_set_min_decay_for_reward(ref self: TContractState);
    fn propose_set_caller_reward_amount(ref self: TContractState, amount: u256);
    fn execute_set_caller_reward_amount(ref self: TContractState);
    fn propose_set_num_draws(ref self: TContractState, num_draws: u32);
    fn execute_set_num_draws(ref self: TContractState);
    fn get_num_draws(self: @TContractState) -> u32;
    fn propose_set_inflation_rate_bps(ref self: TContractState, bps: u16);
    fn execute_set_inflation_rate_bps(ref self: TContractState);
    fn propose_set_protected_address(
        ref self: TContractState,
        target: starknet::ContractAddress,
        protected: bool,
    );
    fn execute_set_protected_address(
        ref self: TContractState, target: starknet::ContractAddress,
    );
    fn get_pending_change(
        self: @TContractState, param_key: felt252,
    ) -> StakeholderConviction::PendingChange;
    fn get_pending_protected(
        self: @TContractState, target: starknet::ContractAddress,
    ) -> StakeholderConviction::PendingProtectedChange;

    // ---- admin roster (timelocked) ----
    fn propose_add_admin(ref self: TContractState, new_admin: starknet::ContractAddress);
    fn execute_add_admin(ref self: TContractState, new_admin: starknet::ContractAddress);
    fn propose_remove_admin(
        ref self: TContractState, admin_to_remove: starknet::ContractAddress,
    );
    fn execute_remove_admin(
        ref self: TContractState, admin_to_remove: starknet::ContractAddress,
    );
    fn get_pending_admin_change(
        self: @TContractState, target: starknet::ContractAddress,
    ) -> StakeholderConviction::PendingAdminChange;
    fn admin_count(self: @TContractState) -> u32;

    // ---- upgradeability ----
    fn propose_upgrade(ref self: TContractState, new_class_hash: starknet::ClassHash);
    fn execute_upgrade(ref self: TContractState);
    fn disable_upgrades_forever(ref self: TContractState);
    fn is_upgrades_disabled(self: @TContractState) -> bool;
    fn get_pending_upgrade(
        self: @TContractState,
    ) -> StakeholderConviction::PendingUpgrade;

    // ---- views ----
    fn get_dispute(self: @TContractState, dispute_id: u256) -> StakeholderConviction::Dispute;
    fn get_proposal(
        self: @TContractState, proposal_id: u256,
    ) -> StakeholderConviction::FundingProposal;
    fn get_conviction(
        self: @TContractState, owner: starknet::ContractAddress, id: u32,
    ) -> StakeholderConviction::Conviction;
    fn get_juror_stake(self: @TContractState, juror: starknet::ContractAddress) -> u256;
    fn total_stake_weight(self: @TContractState) -> u256;
}

#[starknet::contract]
pub mod StakeholderConviction {
    use core::array::ArrayTrait;
    use core::num::traits::Zero;
    use core::poseidon::poseidon_hash_span;
    use starknet::{
        ContractAddress, ClassHash, get_caller_address, get_block_timestamp, get_contract_address,
    };
    use starknet::storage::{
        Map, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess,
    };

    use openzeppelin_token::erc20::{ERC20Component, ERC20HooksEmptyImpl, DefaultConfig};
    use openzeppelin_access::accesscontrol::AccessControlComponent;
    use openzeppelin_access::accesscontrol::DEFAULT_ADMIN_ROLE;
    use openzeppelin_introspection::src5::SRC5Component;
    use openzeppelin_security::reentrancyguard::ReentrancyGuardComponent;
    use openzeppelin_upgrades::upgradeable::UpgradeableComponent;

    use cartridge_vrf::Source;
    use cartridge_vrf::vrf_consumer::vrf_consumer_component::VrfConsumerComponent;

    // ---- crate-local modules (constants, storage types, events, pure helpers) ----
    use crate::constants::*;
    use crate::utils::{
        derive_draw_random, governance_tokens_for_score, isqrt, lowbit, round_scaled, score_to_i64,
        score_to_u256,
    };
    // Types must be re-exported (not just imported) because the crate-root
    // interface trait references them as `StakeholderConviction::PendingChange`.
    pub use crate::types::*;
    use crate::events::*;

    component!(path: ERC20Component, storage: erc20, event: ERC20Event);
    component!(path: AccessControlComponent, storage: accesscontrol, event: AccessControlEvent);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);
    component!(
        path: ReentrancyGuardComponent, storage: reentrancyguard, event: ReentrancyGuardEvent
    );
    component!(path: VrfConsumerComponent, storage: vrf_consumer, event: VrfConsumerEvent);
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);

    #[abi(embed_v0)]
    impl ERC20Impl = ERC20Component::ERC20Impl<ContractState>;
    #[abi(embed_v0)]
    impl ERC20MetadataImpl = ERC20Component::ERC20MetadataImpl<ContractState>;
    impl ERC20InternalImpl = ERC20Component::InternalImpl<ContractState>;

    #[abi(embed_v0)]
    impl AccessControlMixinImpl =
        AccessControlComponent::AccessControlMixinImpl<ContractState>;
    impl AccessControlInternalImpl = AccessControlComponent::InternalImpl<ContractState>;
    impl ReentrancyGuardInternalImpl = ReentrancyGuardComponent::InternalImpl<ContractState>;

    #[abi(embed_v0)]
    impl VrfConsumerImpl = VrfConsumerComponent::VrfConsumerImpl<ContractState>;
    impl VrfConsumerInternalImpl = VrfConsumerComponent::InternalImpl<ContractState>;

    impl UpgradeableInternalImpl = UpgradeableComponent::InternalImpl<ContractState>;

    // //////////////////////////////////////////////////////////////
                              // STORAGE
    // //////////////////////////////////////////////////////////////

    #[storage]
    struct Storage {
        #[substorage(v0)]
        erc20: ERC20Component::Storage,
        #[substorage(v0)]
        accesscontrol: AccessControlComponent::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        #[substorage(v0)]
        reentrancyguard: ReentrancyGuardComponent::Storage,
        #[substorage(v0)]
        vrf_consumer: VrfConsumerComponent::Storage,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,

        pending_upgrade: PendingUpgrade,
        upgrades_disabled: bool,

        commit_duration: u64,
        reveal_duration: u64,
        non_reveal_slash_bps: u16,

        // ---- timelocked admin parameters ----
        evaluation_bond_amount: u256,
        reputation_stake: u256,
        conviction_threshold: u256,
        reward_multiplier: u256,
        mini_reward_multiplier: u256,
        num_draws: u32,

        // ---- staking / Fenwick tree ----
        tree_size: u32,
        next_index: u32,
        juror_index: Map<ContractAddress, u32>,
        index_juror: Map<u32, ContractAddress>,
        fenwick_tree: Map<u32, u256>,
        juror_stake: Map<ContractAddress, u256>,

        // ---- juror stake locking ----
        juror_locked_total: Map<ContractAddress, u256>,
        juror_open_lock_count: Map<ContractAddress, u32>,
        dispute_juror_locked_snapshot: Map<(u256, ContractAddress), u256>,
        dispute_juror_lock_released: Map<(u256, ContractAddress), bool>,

        // ---- selection disputes ----
        dispute_count: u256,
        disputes: Map<u256, Dispute>,
        dispute_juror_draws: Map<(u256, ContractAddress), u32>,
        dispute_juror_list: Map<(u256, u32), ContractAddress>,
        dispute_commit: Map<(u256, ContractAddress), felt252>,
        dispute_committed: Map<(u256, ContractAddress), bool>,
        dispute_revealed: Map<(u256, ContractAddress), bool>,
        dispute_score: Map<(u256, ContractAddress), i8>,
        dispute_coherent: Map<(u256, ContractAddress), bool>,
        dispute_slashed: Map<(u256, ContractAddress), bool>,
        dispute_reward_claimed: Map<(u256, ContractAddress), bool>,

        // ---- opt-in evaluation bond ----
        dispute_evidence: Map<u256, ByteArray>,
        has_active_dispute: Map<ContractAddress, bool>,
        active_dispute_for_candidate: Map<ContractAddress, u256>,

        // ---- non-transferable governance tokens ----
        governance_next_grant: Map<ContractAddress, u32>,
        governance_grant: Map<(ContractAddress, u32), Grant>,
        governance_locked_total: Map<ContractAddress, u256>,

        // ---- score voting / convictions ----
        next_conviction_id: Map<ContractAddress, u32>,
        convictions: Map<(ContractAddress, u32), Conviction>,

        // ---- proposals ----
        proposal_count: u256,
        proposals: Map<u256, FundingProposal>,
        proposal_supporters: Map<(u256, u32), Supporter>,
        proposal_score_counts: Map<(u256, u8), u256>,
        proposal_total_votes: Map<u256, u256>,
        proposal_total_weight: Map<u256, u256>,

        // ---- ERC20 balance decay ----
        decay_rate_bps: u16,
        min_decay_for_reward: u256,
        caller_reward_amount: u256,
        last_decay_at: Map<ContractAddress, u64>,
        last_caller_reward_at: Map<ContractAddress, u64>,
        is_protected: Map<ContractAddress, bool>,

        // ---- timelock engine ----
        pending_changes: Map<felt252, PendingChange>,
        pending_protected: Map<ContractAddress, PendingProtectedChange>,

        // ---- admin roster ----
        pending_admin_changes: Map<ContractAddress, PendingAdminChange>,
        admin_count: u32,

        // ---- monthly inflation / burn-recycling budget ----
        inflation_rate_bps: u16,
        month_start: u64,
        month_index: u64,
        month_budget: Map<u64, u256>,
        month_minted: Map<u64, u256>,
        month_burned: Map<u64, u256>,
    }

    // //////////////////////////////////////////////////////////////
                              // EVENTS
    // //////////////////////////////////////////////////////////////

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        ERC20Event: ERC20Component::Event,
        #[flat]
        AccessControlEvent: AccessControlComponent::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
        #[flat]
        ReentrancyGuardEvent: ReentrancyGuardComponent::Event,
        #[flat]
        VrfConsumerEvent: VrfConsumerComponent::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,

        Staked: Staked,
        Unstaked: Unstaked,
        DisputeCreated: DisputeCreated,
        EvaluationRequested: EvaluationRequested,
        JurorDrawn: JurorDrawn,
        VoteCommitted: VoteCommitted,
        VoteRevealed: VoteRevealed,
        JurorSlashed: JurorSlashed,
        SlashKeeperRewarded: SlashKeeperRewarded,
        DisputeFinalized: DisputeFinalized,
        JurorRewardClaimed: JurorRewardClaimed,
        GovernanceTokensMinted: GovernanceTokensMinted,
        BondRefunded: BondRefunded,
        BondSlashed: BondSlashed,
        ConvictionCreated: ConvictionCreated,
        ConvictionReleased: ConvictionReleased,
        SupportAdded: SupportAdded,
        SupportRemoved: SupportRemoved,
        ProposalCreated: ProposalCreated,
        ProposalExecuted: ProposalExecuted,
        ScoreRewardReleased: ScoreRewardReleased,
        ProposalDepositRefunded: ProposalDepositRefunded,
        ProposalDepositSlashed: ProposalDepositSlashed,
        DecayApplied: DecayApplied,
        DecayCallerRewarded: DecayCallerRewarded,
        MonthlyBudgetSet: MonthlyBudgetSet,
        MonthlyBudgetBurned: MonthlyBudgetBurned,
        BudgetRewardMinted: BudgetRewardMinted,
        ChangeProposed: ChangeProposed,
        ChangeExecuted: ChangeExecuted,
        ProtectedAddressProposed: ProtectedAddressProposed,
        ProtectedAddressSet: ProtectedAddressSet,
        AdminAddProposed: AdminAddProposed,
        AdminAdded: AdminAdded,
        AdminRemoveProposed: AdminRemoveProposed,
        AdminRemoved: AdminRemoved,
        UpgradeProposed: UpgradeProposed,
        UpgradeExecuted: UpgradeExecuted,
        UpgradesDisabledForever: UpgradesDisabledForever,
    }

    // //////////////////////////////////////////////////////////////
                            // CONSTRUCTOR
    // //////////////////////////////////////////////////////////////

    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin: ContractAddress,
        name: ByteArray,
        symbol: ByteArray,
        initial_recipient: ContractAddress,
        tree_capacity: u32,
        vrf_provider: ContractAddress,
        evaluation_bond_amount: u256,
        reputation_stake: u256,
        conviction_threshold: u256,
        reward_multiplier: u256,
        mini_reward_multiplier: u256,
    ) {
        assert(admin.is_non_zero(), 'ZeroAddress');
        assert(initial_recipient.is_non_zero(), 'ZeroAddress');
        assert(tree_capacity > 0, 'InvalidCapacity');
        assert(vrf_provider.is_non_zero(), 'ZeroAddress');
        assert(evaluation_bond_amount > 0, 'ZeroAmount');
        assert(reputation_stake > 0, 'ZeroAmount');
        assert(reward_multiplier > 0, 'ZeroAmount');
        assert(mini_reward_multiplier > 0, 'ZeroAmount');

        self.erc20.initializer(name, symbol);
        self.accesscontrol.initializer();
        self.accesscontrol._grant_role(DEFAULT_ADMIN_ROLE, admin);
        self.vrf_consumer.initializer(vrf_provider);

        self.tree_size.write(tree_capacity);
        self.next_index.write(0);
        self.commit_duration.write(DEFAULT_COMMIT_DURATION);
        self.reveal_duration.write(DEFAULT_REVEAL_DURATION);
        self.non_reveal_slash_bps.write(DEFAULT_SLASH_BPS);
        self.num_draws.write(DEFAULT_NUM_DRAWS);

        // Timelocked admin parameters
        self.evaluation_bond_amount.write(evaluation_bond_amount);
        self.reputation_stake.write(reputation_stake);
        self.conviction_threshold.write(conviction_threshold);
        self.reward_multiplier.write(reward_multiplier);
        self.mini_reward_multiplier.write(mini_reward_multiplier);

        self.upgrades_disabled.write(false);

        // Decay defaults
        self.decay_rate_bps.write(DEFAULT_DECAY_RATE_BPS);
        self.min_decay_for_reward.write(DEFAULT_MIN_DECAY_FOR_REWARD);
        self.caller_reward_amount.write(DEFAULT_CALLER_REWARD_AMOUNT);

        self.admin_count.write(1);

        // Monthly inflation / burn-recycling budget defaults
        self.inflation_rate_bps.write(DEFAULT_INFLATION_RATE_BPS);
        self.month_start.write(get_block_timestamp());
        self.month_index.write(0);

        // One-time initial mint
        self._mint_capped(initial_recipient, INITIAL_SUPPLY);

        // Month-0 budget = inflation share only (no prior-month burns yet).
        let month0_budget = self._compute_month_budget(0);
        self.month_budget.entry(0).write(month0_budget);
        self
            .emit(
                MonthlyBudgetSet {
                    month: 0, budget: month0_budget, inflation_part: month0_budget, recycle_part: 0,
                },
            );
    }

    // //////////////////////////////////////////////////////////////
                          // EXTERNAL IMPL
    // //////////////////////////////////////////////////////////////

    #[abi(embed_v0)]
    impl StakeholderConvictionImpl of super::IStakeholderConviction<ContractState> {
        // ----------------------------------------------------------
                                // STAKING
        // ----------------------------------------------------------

        fn stake(ref self: ContractState, amount: u256) {
            self.reentrancyguard.start();
            assert(amount > 0, 'ZeroAmount');
            let caller = get_caller_address();

            let ok = self.erc20.transfer_from(caller, get_contract_address(), amount);
            assert(ok, 'TransferFailed');

            let index = self._get_or_create_index(caller);
            self._fenwick_add(index, amount);

            let new_total = self.juror_stake.entry(caller).read() + amount;
            self.juror_stake.entry(caller).write(new_total);

            self.emit(Staked { juror: caller, amount, new_total });
            self.reentrancyguard.end();
        }

        fn unstake(ref self: ContractState, amount: u256) {
            self.reentrancyguard.start();
            assert(amount > 0, 'ZeroAmount');
            let caller = get_caller_address();

            let current = self.juror_stake.entry(caller).read();
            assert(current >= amount, 'InsufficientStake');

            let locked = self.juror_locked_total.entry(caller).read();
            assert(current - amount >= locked, 'InsufficientUnlockedStake');

            let index = self.juror_index.entry(caller).read();
            assert(index != 0, 'NotRegistered');
            self._fenwick_sub(index, amount);

            let new_total = current - amount;
            self.juror_stake.entry(caller).write(new_total);

            self.erc20._transfer(get_contract_address(), caller, amount);

            self.emit(Unstaked { juror: caller, amount, new_total });
            self.reentrancyguard.end();
        }

        // ----------------------------------------------------------
                    // STAKEHOLDER SELECTION (Kleros dispute)
        // ----------------------------------------------------------

        fn request_evaluation(ref self: ContractState, evidence: ByteArray) -> u256 {
            self.reentrancyguard.start();
            assert(evidence.len() > 0, 'EvidenceRequired');

            let candidate = get_caller_address();
            assert(!self.has_active_dispute.entry(candidate).read(), 'AlreadyUnderEvaluation');

            let bond_amount = self.evaluation_bond_amount.read();
            let ok = self.erc20.transfer_from(candidate, get_contract_address(), bond_amount);
            assert(ok, 'TransferFailed');

            let num_draws = self.num_draws.read();
            let total_weight = self._fenwick_total();
            assert(total_weight > 0, 'NoStake');

            let dispute_id = self.dispute_count.read();
            self.dispute_count.write(dispute_id + 1);

            let now = get_block_timestamp();
            let commit_deadline = now + self.commit_duration.read();
            let reveal_deadline = commit_deadline + self.reveal_duration.read();

            let dispute = Dispute {
                candidate,
                num_draws,
                unique_juror_count: 0,
                commit_deadline,
                reveal_deadline,
                phase: PHASE_COMMIT,
                final_score: 0,
                final_score_set: false,
                total_weight_revealed: 0,
                total_coherent_weight: 0,
                slash_pool: 0,
                governance_tokens_minted: 0,
                requester: candidate,
                bond_amount,
                bond_settled: false,
            };
            self.disputes.entry(dispute_id).write(dispute);
            self.dispute_evidence.entry(dispute_id).write(evidence);
            self.has_active_dispute.entry(candidate).write(true);
            self.active_dispute_for_candidate.entry(candidate).write(dispute_id);

            self.emit(DisputeCreated { dispute_id, candidate, num_draws });
            self.emit(EvaluationRequested { dispute_id, candidate, bond_amount });

            let base_seed: felt252 = self
                .vrf_consumer
                .consume_random(Source::Nonce(get_contract_address()));

            let mut unique_juror_count: u32 = 0;
            let mut i: u32 = 0;
            loop {
                if i >= num_draws {
                    break;
                }

                let mut rand_felt = derive_draw_random(base_seed, dispute_id, i);
                let mut attempt: u32 = 0;
                let juror = loop {
                    let rand_u256: u256 = rand_felt.into();
                    let target = rand_u256 % total_weight;
                    let index = self._fenwick_find(target);
                    let candidate_juror = self.index_juror.entry(index).read();
                    assert(candidate_juror.is_non_zero(), 'DrawFailed');

                    let already_drawn_here = self
                        .dispute_juror_draws
                        .entry((dispute_id, candidate_juror))
                        .read()
                        > 0;
                    let open_locks = self.juror_open_lock_count.entry(candidate_juror).read();

                    if already_drawn_here || open_locks < MAX_CONCURRENT_JUROR_LOCKS {
                        break candidate_juror;
                    }

                    attempt += 1;
                    assert(attempt < MAX_REDRAW_ATTEMPTS, 'NoEligibleJurors');
                    let mut redraw_input: Array<felt252> = ArrayTrait::new();
                    redraw_input.append(rand_felt);
                    redraw_input.append(attempt.into());
                    rand_felt = poseidon_hash_span(redraw_input.span());
                };

                let prior_draws = self.dispute_juror_draws.entry((dispute_id, juror)).read();
                self.dispute_juror_draws.entry((dispute_id, juror)).write(prior_draws + 1);

                if prior_draws == 0 {
                    self
                        .dispute_juror_list
                        .entry((dispute_id, unique_juror_count))
                        .write(juror);
                    unique_juror_count += 1;

                    let stake_at_draw = self.juror_stake.entry(juror).read();
                    self
                        .dispute_juror_locked_snapshot
                        .entry((dispute_id, juror))
                        .write(stake_at_draw);
                    let prior_locked = self.juror_locked_total.entry(juror).read();
                    self.juror_locked_total.entry(juror).write(prior_locked + stake_at_draw);
                    let prior_open = self.juror_open_lock_count.entry(juror).read();
                    self.juror_open_lock_count.entry(juror).write(prior_open + 1);
                }

                self
                    .emit(
                        JurorDrawn { dispute_id, juror, total_draws_for_juror: prior_draws + 1 },
                    );
                i += 1;
            };

            if unique_juror_count > 0 {
                let mut d = self.disputes.entry(dispute_id).read();
                d.unique_juror_count = unique_juror_count;
                self.disputes.entry(dispute_id).write(d);
            }

            self.reentrancyguard.end();
            dispute_id
        }

        fn commit_vote(ref self: ContractState, dispute_id: u256, commit_hash: felt252) {
            let caller = get_caller_address();
            let d = self.disputes.entry(dispute_id).read();
            assert(d.phase == PHASE_COMMIT, 'NotCommitPhase');
            assert(get_block_timestamp() < d.commit_deadline, 'CommitClosed');

            let draws = self.dispute_juror_draws.entry((dispute_id, caller)).read();
            assert(draws > 0, 'NotDrawn');
            assert(!self.dispute_committed.entry((dispute_id, caller)).read(), 'AlreadyCommitted');

            self.dispute_commit.entry((dispute_id, caller)).write(commit_hash);
            self.dispute_committed.entry((dispute_id, caller)).write(true);

            self.emit(VoteCommitted { dispute_id, juror: caller });
        }

        fn reveal_vote(ref self: ContractState, dispute_id: u256, score: i8, salt: felt252) {
            let caller = get_caller_address();
            let mut d = self.disputes.entry(dispute_id).read();
            assert(get_block_timestamp() >= d.commit_deadline, 'CommitStillOpen');
            assert(get_block_timestamp() < d.reveal_deadline, 'RevealClosed');
            assert(score >= -5 && score <= 5, 'InvalidScore');

            if d.phase == PHASE_COMMIT {
                d.phase = PHASE_REVEAL;
                self.disputes.entry(dispute_id).write(d);
            }

            assert(self.dispute_committed.entry((dispute_id, caller)).read(), 'NoCommit');
            assert(!self.dispute_revealed.entry((dispute_id, caller)).read(), 'AlreadyRevealed');

            let mut hash_input: Array<felt252> = ArrayTrait::new();
            hash_input.append(score.into());
            hash_input.append(salt);
            let computed = poseidon_hash_span(hash_input.span());
            let stored = self.dispute_commit.entry((dispute_id, caller)).read();
            assert(computed == stored, 'HashMismatch');

            self.dispute_score.entry((dispute_id, caller)).write(score);
            self.dispute_revealed.entry((dispute_id, caller)).write(true);
            self._release_dispute_lock(dispute_id, caller);

            self.emit(VoteRevealed { dispute_id, juror: caller, score });
        }

        fn slash_non_revealer(
            ref self: ContractState, dispute_id: u256, juror: ContractAddress,
        ) {
            self.reentrancyguard.start();
            let d = self.disputes.entry(dispute_id).read();
            assert(get_block_timestamp() >= d.reveal_deadline, 'RevealStillOpen');

            let draws = self.dispute_juror_draws.entry((dispute_id, juror)).read();
            assert(draws > 0, 'NotDrawn');
            assert(!self.dispute_revealed.entry((dispute_id, juror)).read(), 'DidReveal');
            assert(!self.dispute_slashed.entry((dispute_id, juror)).read(), 'AlreadySlashed');

            let stake = self.juror_stake.entry(juror).read();
            let bps: u256 = self.non_reveal_slash_bps.read().into();
            let slash_amount = stake * bps / BPS_DENOM;

            if slash_amount > 0 {
                let index = self.juror_index.entry(juror).read();
                self._fenwick_sub(index, slash_amount);
                self.juror_stake.entry(juror).write(stake - slash_amount);

                let mut dm = self.disputes.entry(dispute_id).read();
                dm.slash_pool += slash_amount;
                self.disputes.entry(dispute_id).write(dm);
            }

            self.dispute_slashed.entry((dispute_id, juror)).write(true);
            self._release_dispute_lock(dispute_id, juror);

            self.emit(JurorSlashed { dispute_id, juror, amount: slash_amount });

            let caller = get_caller_address();
            if caller != juror && SLASH_KEEPER_REWARD > 0 {
                self._mint_from_budget(caller, SLASH_KEEPER_REWARD);
                self
                    .emit(
                        SlashKeeperRewarded {
                            caller, juror, dispute_id, reward: SLASH_KEEPER_REWARD,
                        },
                    );
            }

            self.reentrancyguard.end();
        }

        fn finalize_selection(ref self: ContractState, dispute_id: u256) {
            self.reentrancyguard.start();
            let mut d = self.disputes.entry(dispute_id).read();
            assert(!d.final_score_set, 'AlreadyFinalized');
            assert(get_block_timestamp() >= d.reveal_deadline, 'RevealStillOpen');

            // pass 1: weighted mean
            let mut sum_weighted_scaled: i64 = 0;
            let mut total_weight: u32 = 0;
            let mut i: u32 = 0;
            loop {
                if i >= d.unique_juror_count {
                    break;
                }
                let juror = self.dispute_juror_list.entry((dispute_id, i)).read();
                if self.dispute_revealed.entry((dispute_id, juror)).read() {
                    let weight = self.dispute_juror_draws.entry((dispute_id, juror)).read();
                    let score = self.dispute_score.entry((dispute_id, juror)).read();
                    let score_i64 = score_to_i64(score);
                    sum_weighted_scaled += score_i64 * SCALE * weight.into();
                    total_weight += weight;
                }
                i += 1;
            };

            assert(total_weight > 0, 'NoReveals');
            let total_weight_i64: i64 = total_weight.into();
            let mean_scaled: i64 = sum_weighted_scaled / total_weight_i64;

            // pass 2: stdev
            let mut sum_weighted_sq: u64 = 0;
            i = 0;
            loop {
                if i >= d.unique_juror_count {
                    break;
                }
                let juror = self.dispute_juror_list.entry((dispute_id, i)).read();
                if self.dispute_revealed.entry((dispute_id, juror)).read() {
                    let weight = self.dispute_juror_draws.entry((dispute_id, juror)).read();
                    let score = self.dispute_score.entry((dispute_id, juror)).read();
                    let score_i64 = score_to_i64(score);
                    let diff = score_i64 * SCALE - mean_scaled;
                    let diff_sq: i64 = diff * diff;
                    let diff_sq_u64: u64 = diff_sq.try_into().unwrap();
                    sum_weighted_sq += diff_sq_u64 * weight.into();
                }
                i += 1;
            };
            let variance_scaled: u64 = sum_weighted_sq / total_weight.into();
            let stdev_scaled_u256: u256 = isqrt(variance_scaled.into());
            let stdev_scaled_u64: u64 = stdev_scaled_u256.try_into().unwrap();
            let stdev_scaled: i64 = stdev_scaled_u64.try_into().unwrap();

            // pass 3: drop outliers, recompute mean
            let mut sum_filtered_scaled: i64 = 0;
            let mut filtered_weight: u32 = 0;
            i = 0;
            loop {
                if i >= d.unique_juror_count {
                    break;
                }
                let juror = self.dispute_juror_list.entry((dispute_id, i)).read();
                if self.dispute_revealed.entry((dispute_id, juror)).read() {
                    let weight = self.dispute_juror_draws.entry((dispute_id, juror)).read();
                    let score = self.dispute_score.entry((dispute_id, juror)).read();
                    let score_i64 = score_to_i64(score);
                    let diff = score_i64 * SCALE - mean_scaled;
                    let abs_diff = if diff < 0 {
                        -diff
                    } else {
                        diff
                    };
                    if abs_diff <= stdev_scaled {
                        sum_filtered_scaled += score_i64 * SCALE * weight.into();
                        filtered_weight += weight;
                    }
                }
                i += 1;
            };

            let final_mean_scaled: i64 = if filtered_weight > 0 {
                sum_filtered_scaled / filtered_weight.into()
            } else {
                mean_scaled
            };
            let final_score: i64 = round_scaled(final_mean_scaled);

            d.final_score = final_score;
            d.final_score_set = true;
            d.total_weight_revealed = total_weight;
            d.phase = PHASE_FINALIZED;

            // coherence pass (for juror rewards)
            let mut total_coherent_weight: u32 = 0;
            i = 0;
            loop {
                if i >= d.unique_juror_count {
                    break;
                }
                let juror = self.dispute_juror_list.entry((dispute_id, i)).read();
                if self.dispute_revealed.entry((dispute_id, juror)).read() {
                    let weight = self.dispute_juror_draws.entry((dispute_id, juror)).read();
                    let score = self.dispute_score.entry((dispute_id, juror)).read();
                    let score_i64 = score_to_i64(score);
                    let diff = if score_i64 >= final_score {
                        score_i64 - final_score
                    } else {
                        final_score - score_i64
                    };
                    if diff <= COHERENCE_BAND {
                        self.dispute_coherent.entry((dispute_id, juror)).write(true);
                        total_coherent_weight += weight;
                    }
                }
                i += 1;
            };
            d.total_coherent_weight = total_coherent_weight;

            // governance token minting
            let mint_amount = governance_tokens_for_score(final_score);
            if mint_amount > 0 {
                self._mint_governance_tokens(d.candidate, mint_amount);
                d.governance_tokens_minted = mint_amount;
            }

            // bond settlement
            let bond_amount = d.bond_amount;
            let requester = d.requester;
            let refund_bond = bond_amount > 0 && final_score > 0;
            let slash_bond = bond_amount > 0 && final_score <= 0;
            if slash_bond {
                d.slash_pool += bond_amount;
            }
            d.bond_settled = true;
            if requester.is_non_zero() {
                self.has_active_dispute.entry(requester).write(false);
            }

            self.disputes.entry(dispute_id).write(d);
            self.emit(DisputeFinalized { dispute_id, candidate: d.candidate, final_score });
            if mint_amount > 0 {
                self
                    .emit(
                        GovernanceTokensMinted {
                            dispute_id,
                            candidate: d.candidate,
                            amount: mint_amount,
                            final_score,
                        },
                    );
            }

            if refund_bond {
                self.erc20._transfer(get_contract_address(), requester, bond_amount);
                self.emit(BondRefunded { dispute_id, requester, amount: bond_amount });
            } else if slash_bond {
                self.emit(BondSlashed { dispute_id, requester, amount: bond_amount });
            }

            self.reentrancyguard.end();
        }

        fn claim_juror_reward(ref self: ContractState, dispute_id: u256) {
            self.reentrancyguard.start();
            let caller = get_caller_address();
            let mut d = self.disputes.entry(dispute_id).read();
            assert(d.final_score_set, 'NotFinalized');
            assert(self.dispute_coherent.entry((dispute_id, caller)).read(), 'NotCoherent');
            assert(
                !self.dispute_reward_claimed.entry((dispute_id, caller)).read(),
                'AlreadyClaimed',
            );
            assert(d.total_coherent_weight > 0, 'NoCoherentWeight');

            let weight = self.dispute_juror_draws.entry((dispute_id, caller)).read();
            let amount = d.slash_pool * weight.into() / d.total_coherent_weight.into();

            self.dispute_reward_claimed.entry((dispute_id, caller)).write(true);

            if amount > 0 {
                self.erc20._transfer(get_contract_address(), caller, amount);
            }

            self.emit(JurorRewardClaimed { dispute_id, juror: caller, amount });
            self.reentrancyguard.end();
        }

        // ----------------------------------------------------------
                        // GOVERNANCE TOKEN VIEWS
        // ----------------------------------------------------------

        fn governance_balance(self: @ContractState, holder: ContractAddress) -> u256 {
            self._decayed_total(holder)
        }

        fn governance_available(self: @ContractState, holder: ContractAddress) -> u256 {
            let total = self._decayed_total(holder);
            let locked = self.governance_locked_total.entry(holder).read();
            if locked >= total {
                0
            } else {
                total - locked
            }
        }

        fn governance_locked(self: @ContractState, holder: ContractAddress) -> u256 {
            self.governance_locked_total.entry(holder).read()
        }

        // ----------------------------------------------------------
                    // SCORE VOTING / PROPOSAL LIFECYCLE
        // ----------------------------------------------------------

        fn create_proposal(
            ref self: ContractState,
            funding_wallet: ContractAddress,
            evidence: ByteArray,
        ) -> u256 {
            self.reentrancyguard.start();
            let caller = get_caller_address();
            assert(funding_wallet.is_non_zero(), 'ZeroAddress');
            assert(evidence.len() > 0, 'EvidenceRequired');

            // Anti-Sybil deposit: pull reputation_stake of own ERC20
            let deposit = self.reputation_stake.read();
            let ok = self.erc20.transfer_from(caller, get_contract_address(), deposit);
            assert(ok, 'TransferFailed');

            let proposal_id = self.proposal_count.read();
            self.proposal_count.write(proposal_id + 1);

            let p = FundingProposal {
                author: caller,
                funding_wallet,
                evidence,
                created_at: get_block_timestamp(),
                executed: false,
                supporter_count: 0,
                deposit_amount: deposit,
                deposit_settled: false,
                final_score: 0,
                final_score_set: false,
            };
            self.proposals.entry(proposal_id).write(p);

            self.emit(ProposalCreated { proposal_id, author: caller, deposit_amount: deposit });
            self.reentrancyguard.end();
            proposal_id
        }

        fn create_conviction(ref self: ContractState, level: u8, amount: u256) -> u32 {
            self.reentrancyguard.start();
            assert(level >= 1 && level <= 10, 'InvalidLevel');
            assert(amount > 0, 'ZeroAmount');
            let caller = get_caller_address();

            // Lock governance tokens from available balance
            let total = self._decayed_total(caller);
            let locked = self.governance_locked_total.entry(caller).read();
            let available = if locked >= total {
                0
            } else {
                total - locked
            };
            assert(amount <= available, 'InsufficientGovBalance');

            self.governance_locked_total.entry(caller).write(locked + amount);

            let id = self.next_conviction_id.entry(caller).read();
            self.next_conviction_id.entry(caller).write(id + 1);

            let c = Conviction {
                owner: caller,
                id,
                level,
                amount,
                created_at: get_block_timestamp(),
                is_supporting: false,
                active_proposal: 0,
                support_start: 0,
                released: false,
            };
            self.convictions.entry((caller, id)).write(c);

            self.emit(ConvictionCreated { owner: caller, conviction_id: id, level, amount });
            self.reentrancyguard.end();
            id
        }

        fn vote_with_conviction(
            ref self: ContractState, proposal_id: u256, conviction_id: u32, score: i8,
        ) {
            self.reentrancyguard.start();
            assert(score >= -5 && score <= 5, 'InvalidScore');

            let count = self.proposal_count.read();
            assert(proposal_id < count, 'InvalidProposalId');

            let p = self.proposals.entry(proposal_id).read();
            assert(!p.executed, 'AlreadyExecuted');
            assert(!p.final_score_set, 'AlreadyFinalized');

            let caller = get_caller_address();
            let mut c = self.convictions.entry((caller, conviction_id)).read();
            assert(c.owner == caller, 'Unauthorized');
            assert(!c.released, 'ConvictionReleased');
            assert(!c.is_supporting, 'AlreadySupporting');

            c.is_supporting = true;
            c.active_proposal = proposal_id;
            c.support_start = get_block_timestamp();
            self.convictions.entry((caller, conviction_id)).write(c);

            // Record supporter
            let idx = p.supporter_count;
            self
                .proposal_supporters
                .entry((proposal_id, idx))
                .write(Supporter { owner: caller, conviction_id });
            let mut pm = self.proposals.entry(proposal_id).read();
            pm.supporter_count = idx + 1;
            self.proposals.entry(proposal_id).write(pm);

            // Weighted vote: level * sqrt(locked amount * hours locked)
            let weight = self._vote_weight(@c);

            // Bucket the score (index = score + 5)
            let bucket: u8 = (score + 5).try_into().unwrap();
            let cur = self.proposal_score_counts.entry((proposal_id, bucket)).read();
            self.proposal_score_counts.entry((proposal_id, bucket)).write(cur + weight);

            let tv = self.proposal_total_votes.entry(proposal_id).read();
            self.proposal_total_votes.entry(proposal_id).write(tv + 1);
            let tw = self.proposal_total_weight.entry(proposal_id).read();
            self.proposal_total_weight.entry(proposal_id).write(tw + weight);

            self.emit(SupportAdded { proposal_id, owner: caller, conviction_id });
            self.reentrancyguard.end();
        }

        fn remove_support(ref self: ContractState, conviction_id: u32) {
            self.reentrancyguard.start();
            let caller = get_caller_address();
            let mut c = self.convictions.entry((caller, conviction_id)).read();
            assert(c.owner == caller, 'Unauthorized');
            assert(c.is_supporting, 'NotSupporting');

            let power = self._vote_weight(@c);
            let proposal_id = c.active_proposal;

            c.is_supporting = false;
            c.active_proposal = 0;
            c.support_start = 0;
            self.convictions.entry((caller, conviction_id)).write(c);

            self
                .emit(
                    SupportRemoved {
                        proposal_id, owner: caller, conviction_id, power_at_removal: power,
                    },
                );
            self.reentrancyguard.end();
        }

        fn release_conviction(ref self: ContractState, conviction_id: u32) {
            self.reentrancyguard.start();
            let caller = get_caller_address();
            let mut c = self.convictions.entry((caller, conviction_id)).read();
            assert(c.owner == caller, 'Unauthorized');
            assert(!c.is_supporting, 'StillSupporting');
            assert(!c.released, 'AlreadyReleased');

            let amount = c.amount;
            let locked = self.governance_locked_total.entry(caller).read();
            assert(locked >= amount, 'LockAccountingError');
            self.governance_locked_total.entry(caller).write(locked - amount);

            c.released = true;
            self.convictions.entry((caller, conviction_id)).write(c);

            self.emit(ConvictionReleased { owner: caller, conviction_id, amount });
            self.reentrancyguard.end();
        }

        fn execute_proposal(ref self: ContractState, proposal_id: u256) {
            self.reentrancyguard.start();
            assert(proposal_id < self.proposal_count.read(), 'InvalidProposalId');
            let mut p = self.proposals.entry(proposal_id).read();
            assert(!p.executed, 'AlreadyExecuted');

            let total_power = self._proposal_total_power(proposal_id, p.supporter_count);
            assert(total_power >= self.conviction_threshold.read(), 'ThresholdNotMet');

            // Compute weighted final score from histogram
            let final_score = self._compute_weighted_score(proposal_id);
            p.final_score = final_score;
            p.final_score_set = true;
            p.executed = true;

            let funding_wallet = p.funding_wallet;
            let deposit_amount = p.deposit_amount;
            let author = p.author;
            self.proposals.entry(proposal_id).write(p);

            self.emit(ProposalExecuted { proposal_id, total_power, final_score });

            // Deposit settlement + score-based reward
            if final_score > 0 {
                // Refund deposit
                if deposit_amount > 0 {
                    self.erc20._transfer(get_contract_address(), author, deposit_amount);
                    self
                        .emit(
                            ProposalDepositRefunded {
                                proposal_id, requester: author, amount: deposit_amount,
                            },
                        );
                }

                // Mint score-based reward to funding_wallet
                let score_u256 = score_to_u256(final_score);
                let rm = self.reward_multiplier.read();
                let mrm = self.mini_reward_multiplier.read();
                let reward: u256 = if score_u256 <= 3 {
                    score_u256 * mrm
                } else {
                    score_u256 * rm
                };
                if reward > 0 {
                    self._mint_from_budget(funding_wallet, reward);
                    self
                        .emit(
                            ScoreRewardReleased {
                                proposal_id, recipient: funding_wallet, amount: reward,
                            },
                        );
                }
            } else {
                // Slash deposit (tokens already in contract, just relabel)
                if deposit_amount > 0 {
                    self
                        .emit(
                            ProposalDepositSlashed {
                                proposal_id, requester: author, amount: deposit_amount,
                            },
                        );
                }
            }

            self.reentrancyguard.end();
        }

        fn get_conviction_power(
            self: @ContractState, owner: ContractAddress, conviction_id: u32,
        ) -> u256 {
            let c = self.convictions.entry((owner, conviction_id)).read();
            self._vote_weight(@c)
        }

        fn get_proposal_total_power(self: @ContractState, proposal_id: u256) -> u256 {
            let p = self.proposals.entry(proposal_id).read();
            self._proposal_total_power(proposal_id, p.supporter_count)
        }

        // ----------------------------------------------------------
                        // THIS CONTRACT'S OWN ERC20
        // ----------------------------------------------------------

        fn token_max_supply(self: @ContractState) -> u256 {
            MAX_SUPPLY
        }

        fn token_remaining_mintable(self: @ContractState) -> u256 {
            MAX_SUPPLY - self.erc20.total_supply()
        }

        fn burn(ref self: ContractState, amount: u256) {
            assert(amount > 0, 'ZeroAmount');
            self.erc20.burn(get_caller_address(), amount);
            self._track_burn(amount);
        }

        // ----------------------------------------------------------
                // MONTHLY INFLATION / BURN-RECYCLING BUDGET
        // ----------------------------------------------------------

        fn get_current_month(self: @ContractState) -> u64 {
            self.month_index.read()
        }

        fn get_month_start(self: @ContractState) -> u64 {
            self.month_start.read()
        }

        fn get_month_budget(self: @ContractState, month: u64) -> u256 {
            self.month_budget.entry(month).read()
        }

        fn get_month_budget_minted(self: @ContractState, month: u64) -> u256 {
            self.month_minted.entry(month).read()
        }

        fn get_month_burned(self: @ContractState, month: u64) -> u256 {
            self.month_burned.entry(month).read()
        }

        fn get_remaining_month_budget(self: @ContractState) -> u256 {
            let month = self.month_index.read();
            let budget = self.month_budget.entry(month).read();
            let minted = self.month_minted.entry(month).read();
            if minted >= budget {
                0
            } else {
                budget - minted
            }
        }

        fn get_inflation_rate_bps(self: @ContractState) -> u16 {
            self.inflation_rate_bps.read()
        }

        // ----------------------------------------------------------
                        // DECAY (ERC20 balances)
        // ----------------------------------------------------------

        fn apply_decay(ref self: ContractState, user: ContractAddress) {
            self.reentrancyguard.start();
            assert(!self.is_protected.entry(user).read(), 'ProtectedAddress');
            self._apply_decay(user);
            self.reentrancyguard.end();
        }

        fn batch_apply_decay(ref self: ContractState, users: Array<ContractAddress>) {
            self.reentrancyguard.start();
            assert(users.len() <= MAX_BATCH_DECAY, 'TooManyUsers');
            let mut i: u32 = 0;
            loop {
                if i >= users.len() {
                    break;
                }
                let user = *users.at(i);
                if !self.is_protected.entry(user).read() {
                    self._apply_decay(user);
                }
                i += 1;
            };
            self.reentrancyguard.end();
        }

        fn get_decay_rate_bps(self: @ContractState) -> u16 {
            self.decay_rate_bps.read()
        }

        fn get_min_decay_for_reward(self: @ContractState) -> u256 {
            self.min_decay_for_reward.read()
        }

        fn get_caller_reward_amount(self: @ContractState) -> u256 {
            self.caller_reward_amount.read()
        }

        fn get_last_decay_at(self: @ContractState, user: ContractAddress) -> u64 {
            self.last_decay_at.entry(user).read()
        }

        fn is_protected_address(self: @ContractState, user: ContractAddress) -> bool {
            self.is_protected.entry(user).read()
        }

        // ----------------------------------------------------------
              // JUROR STAKE LOCKING VIEWS
        // ----------------------------------------------------------

        fn get_juror_locked_stake(self: @ContractState, juror: ContractAddress) -> u256 {
            self.juror_locked_total.entry(juror).read()
        }

        fn get_juror_unlocked_stake(self: @ContractState, juror: ContractAddress) -> u256 {
            let total = self.juror_stake.entry(juror).read();
            let locked = self.juror_locked_total.entry(juror).read();
            if locked >= total {
                0
            } else {
                total - locked
            }
        }

        fn get_juror_open_dispute_count(self: @ContractState, juror: ContractAddress) -> u32 {
            self.juror_open_lock_count.entry(juror).read()
        }

        // ----------------------------------------------------------
              // OPT-IN EVALUATION BOND VIEWS
        // ----------------------------------------------------------

        fn get_evaluation_bond_amount(self: @ContractState) -> u256 {
            self.evaluation_bond_amount.read()
        }

        fn get_active_dispute_for_candidate(
            self: @ContractState, candidate: ContractAddress,
        ) -> u256 {
            self.active_dispute_for_candidate.entry(candidate).read()
        }

        fn get_dispute_evidence(self: @ContractState, dispute_id: u256) -> ByteArray {
            self.dispute_evidence.entry(dispute_id).read()
        }

        // ----------------------------------------------------------
              // ADMIN - timelocked parameter changes
        // ----------------------------------------------------------

        fn propose_set_funding_token(ref self: ContractState, token: ContractAddress) {
            // Kept for ABI compatibility; funding_token was removed.
            assert(token.is_non_zero(), 'ZeroAddress');
            self._propose_change(PARAM_VRF_PROVIDER, 0);
        }

        fn execute_set_funding_token(ref self: ContractState) {
            self._execute_change(PARAM_VRF_PROVIDER);
        }

        fn propose_set_evaluation_bond_amount(ref self: ContractState, amount: u256) {
            assert(amount > 0, 'ZeroAmount');
            self._propose_change(PARAM_EVALUATION_BOND_AMOUNT, amount);
        }

        fn execute_set_evaluation_bond_amount(ref self: ContractState) {
            let value = self._execute_change(PARAM_EVALUATION_BOND_AMOUNT);
            self.evaluation_bond_amount.write(value);
        }

        fn propose_set_reputation_stake(ref self: ContractState, amount: u256) {
            assert(amount > 0, 'ZeroAmount');
            self._propose_change(PARAM_REPUTATION_STAKE, amount);
        }

        fn execute_set_reputation_stake(ref self: ContractState) {
            let value = self._execute_change(PARAM_REPUTATION_STAKE);
            self.reputation_stake.write(value);
        }

        fn propose_set_conviction_threshold(ref self: ContractState, threshold: u256) {
            self._propose_change(PARAM_CONVICTION_THRESHOLD, threshold);
        }

        fn execute_set_conviction_threshold(ref self: ContractState) {
            let value = self._execute_change(PARAM_CONVICTION_THRESHOLD);
            self.conviction_threshold.write(value);
        }

        fn propose_set_reward_multiplier(ref self: ContractState, amount: u256) {
            self._propose_change(PARAM_REWARD_MULTIPLIER, amount);
        }

        fn execute_set_reward_multiplier(ref self: ContractState) {
            let value = self._execute_change(PARAM_REWARD_MULTIPLIER);
            self.reward_multiplier.write(value);
        }

        fn propose_set_mini_reward_multiplier(ref self: ContractState, amount: u256) {
            self._propose_change(PARAM_MINI_REWARD_MULTIPLIER, amount);
        }

        fn execute_set_mini_reward_multiplier(ref self: ContractState) {
            let value = self._execute_change(PARAM_MINI_REWARD_MULTIPLIER);
            self.mini_reward_multiplier.write(value);
        }

        fn propose_set_vrf_provider(
            ref self: ContractState, new_vrf_provider: ContractAddress,
        ) {
            assert(new_vrf_provider.is_non_zero(), 'ZeroAddress');
            self._propose_change(PARAM_VRF_PROVIDER, self._address_to_u256(new_vrf_provider));
        }

        fn execute_set_vrf_provider(ref self: ContractState) {
            let value = self._execute_change(PARAM_VRF_PROVIDER);
            self.vrf_consumer.set_vrf_provider(self._u256_to_address(value));
        }

        fn propose_set_commit_duration(ref self: ContractState, commit_duration: u64) {
            assert(commit_duration > 0, 'InvalidDuration');
            self._propose_change(PARAM_COMMIT_DURATION, commit_duration.into());
        }

        fn execute_set_commit_duration(ref self: ContractState) {
            let value = self._execute_change(PARAM_COMMIT_DURATION);
            let value_u64: u64 = value.try_into().unwrap();
            self.commit_duration.write(value_u64);
        }

        fn propose_set_reveal_duration(ref self: ContractState, reveal_duration: u64) {
            assert(reveal_duration > 0, 'InvalidDuration');
            self._propose_change(PARAM_REVEAL_DURATION, reveal_duration.into());
        }

        fn execute_set_reveal_duration(ref self: ContractState) {
            let value = self._execute_change(PARAM_REVEAL_DURATION);
            let value_u64: u64 = value.try_into().unwrap();
            self.reveal_duration.write(value_u64);
        }

        fn propose_set_non_reveal_slash_bps(ref self: ContractState, bps: u16) {
            assert(bps <= 10_000, 'TooHigh');
            self._propose_change(PARAM_NON_REVEAL_SLASH_BPS, bps.into());
        }

        fn execute_set_non_reveal_slash_bps(ref self: ContractState) {
            let value = self._execute_change(PARAM_NON_REVEAL_SLASH_BPS);
            let value_u64: u64 = value.try_into().unwrap();
            let value_u16: u16 = value_u64.try_into().unwrap();
            self.non_reveal_slash_bps.write(value_u16);
        }

        fn propose_set_decay_rate_bps(ref self: ContractState, bps: u16) {
            assert(bps <= 10_000, 'TooHigh');
            self._propose_change(PARAM_DECAY_RATE_BPS, bps.into());
        }

        fn execute_set_decay_rate_bps(ref self: ContractState) {
            let value = self._execute_change(PARAM_DECAY_RATE_BPS);
            let value_u64: u64 = value.try_into().unwrap();
            let value_u16: u16 = value_u64.try_into().unwrap();
            self.decay_rate_bps.write(value_u16);
        }

        fn propose_set_min_decay_for_reward(ref self: ContractState, amount: u256) {
            self._propose_change(PARAM_MIN_DECAY_FOR_REWARD, amount);
        }

        fn execute_set_min_decay_for_reward(ref self: ContractState) {
            let value = self._execute_change(PARAM_MIN_DECAY_FOR_REWARD);
            self.min_decay_for_reward.write(value);
        }

        fn propose_set_caller_reward_amount(ref self: ContractState, amount: u256) {
            self._propose_change(PARAM_CALLER_REWARD_AMOUNT, amount);
        }

        fn execute_set_caller_reward_amount(ref self: ContractState) {
            let value = self._execute_change(PARAM_CALLER_REWARD_AMOUNT);
            self.caller_reward_amount.write(value);
        }

        fn propose_set_num_draws(ref self: ContractState, num_draws: u32) {
            assert(num_draws >= MIN_NUM_DRAWS, 'BelowMinNumDraws');
            self._propose_change(PARAM_NUM_DRAWS, num_draws.into());
        }

        fn execute_set_num_draws(ref self: ContractState) {
            let value = self._execute_change(PARAM_NUM_DRAWS);
            let value_u32: u32 = value.try_into().unwrap();
            self.num_draws.write(value_u32);
        }

        fn get_num_draws(self: @ContractState) -> u32 {
            self.num_draws.read()
        }

        fn propose_set_inflation_rate_bps(ref self: ContractState, bps: u16) {
            assert(bps <= MAX_INFLATION_BPS, 'TooHigh');
            self._propose_change(PARAM_INFLATION_RATE_BPS, bps.into());
        }

        fn execute_set_inflation_rate_bps(ref self: ContractState) {
            let value = self._execute_change(PARAM_INFLATION_RATE_BPS);
            let value_u64: u64 = value.try_into().unwrap();
            let value_u16: u16 = value_u64.try_into().unwrap();
            self.inflation_rate_bps.write(value_u16);
        }

        fn propose_set_protected_address(
            ref self: ContractState, target: ContractAddress, protected: bool,
        ) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(target.is_non_zero(), 'ZeroAddress');
            let effective_at = get_block_timestamp() + TIMELOCK_DURATION;
            self
                .pending_protected
                .entry(target)
                .write(PendingProtectedChange { new_value: protected, effective_at, exists: true });
            self.emit(ProtectedAddressProposed { target, new_value: protected, effective_at });
        }

        fn execute_set_protected_address(ref self: ContractState, target: ContractAddress) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let pc = self.pending_protected.entry(target).read();
            assert(pc.exists, 'NoPendingChange');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            self
                .pending_protected
                .entry(target)
                .write(PendingProtectedChange { new_value: false, effective_at: 0, exists: false });
            self.is_protected.entry(target).write(pc.new_value);
            self.emit(ProtectedAddressSet { target, new_value: pc.new_value });
        }

        fn get_pending_change(self: @ContractState, param_key: felt252) -> PendingChange {
            self.pending_changes.entry(param_key).read()
        }

        fn get_pending_protected(
            self: @ContractState, target: ContractAddress,
        ) -> PendingProtectedChange {
            self.pending_protected.entry(target).read()
        }

        // ---- admin roster ----

        fn propose_add_admin(ref self: ContractState, new_admin: ContractAddress) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(new_admin.is_non_zero(), 'ZeroAddress');
            assert(!self.accesscontrol.has_role(DEFAULT_ADMIN_ROLE, new_admin), 'AlreadyAdmin');
            let effective_at = get_block_timestamp() + TIMELOCK_DURATION;
            self
                .pending_admin_changes
                .entry(new_admin)
                .write(PendingAdminChange { is_add: true, effective_at, exists: true });
            self.emit(AdminAddProposed { new_admin, effective_at });
        }

        fn execute_add_admin(ref self: ContractState, new_admin: ContractAddress) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let pc = self.pending_admin_changes.entry(new_admin).read();
            assert(pc.exists, 'NoPendingChange');
            assert(pc.is_add, 'NotAnAddProposal');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            assert(!self.accesscontrol.has_role(DEFAULT_ADMIN_ROLE, new_admin), 'AlreadyAdmin');
            self
                .pending_admin_changes
                .entry(new_admin)
                .write(PendingAdminChange { is_add: false, effective_at: 0, exists: false });
            self.accesscontrol._grant_role(DEFAULT_ADMIN_ROLE, new_admin);
            self.admin_count.write(self.admin_count.read() + 1);
            self.emit(AdminAdded { admin: new_admin });
        }

        fn propose_remove_admin(ref self: ContractState, admin_to_remove: ContractAddress) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(
                self.accesscontrol.has_role(DEFAULT_ADMIN_ROLE, admin_to_remove), 'NotAnAdmin',
            );
            let effective_at = get_block_timestamp() + TIMELOCK_DURATION;
            self
                .pending_admin_changes
                .entry(admin_to_remove)
                .write(PendingAdminChange { is_add: false, effective_at, exists: true });
            self.emit(AdminRemoveProposed { admin_to_remove, effective_at });
        }

        fn execute_remove_admin(ref self: ContractState, admin_to_remove: ContractAddress) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let pc = self.pending_admin_changes.entry(admin_to_remove).read();
            assert(pc.exists, 'NoPendingChange');
            assert(!pc.is_add, 'NotARemoveProposal');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            assert(
                self.accesscontrol.has_role(DEFAULT_ADMIN_ROLE, admin_to_remove), 'NotAnAdmin',
            );
            let count = self.admin_count.read();
            assert(count > 1, 'CannotRemoveLastAdmin');
            self
                .pending_admin_changes
                .entry(admin_to_remove)
                .write(PendingAdminChange { is_add: false, effective_at: 0, exists: false });
            self.accesscontrol._revoke_role(DEFAULT_ADMIN_ROLE, admin_to_remove);
            self.admin_count.write(count - 1);
            self.emit(AdminRemoved { admin: admin_to_remove });
        }

        fn get_pending_admin_change(
            self: @ContractState, target: ContractAddress,
        ) -> PendingAdminChange {
            self.pending_admin_changes.entry(target).read()
        }

        fn admin_count(self: @ContractState) -> u32 {
            self.admin_count.read()
        }

        // ----------------------------------------------------------
                          // UPGRADEABILITY
        // ----------------------------------------------------------

        fn propose_upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(!self.upgrades_disabled.read(), 'UpgradesDisabledForever');
            let hash_felt: felt252 = new_class_hash.into();
            assert(hash_felt.is_non_zero(), 'ZeroClassHash');
            let effective_at = get_block_timestamp() + UPGRADE_TIMELOCK_DURATION;
            self
                .pending_upgrade
                .write(PendingUpgrade { new_class_hash, effective_at, exists: true });
            self.emit(UpgradeProposed { new_class_hash, effective_at });
        }

        fn execute_upgrade(ref self: ContractState) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(!self.upgrades_disabled.read(), 'UpgradesDisabledForever');
            let pu = self.pending_upgrade.read();
            assert(pu.exists, 'NoPendingUpgrade');
            assert(get_block_timestamp() >= pu.effective_at, 'TimelockNotElapsed');
            self
                .pending_upgrade
                .write(
                    PendingUpgrade {
                        new_class_hash: 0.try_into().unwrap(), effective_at: 0, exists: false,
                    },
                );
            self.upgradeable.upgrade(pu.new_class_hash);
            self.emit(UpgradeExecuted { new_class_hash: pu.new_class_hash });
        }

        fn disable_upgrades_forever(ref self: ContractState) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(!self.upgrades_disabled.read(), 'AlreadyDisabled');
            self
                .pending_upgrade
                .write(
                    PendingUpgrade {
                        new_class_hash: 0.try_into().unwrap(), effective_at: 0, exists: false,
                    },
                );
            self.upgrades_disabled.write(true);
            self.emit(UpgradesDisabledForever { by: get_caller_address() });
        }

        fn is_upgrades_disabled(self: @ContractState) -> bool {
            self.upgrades_disabled.read()
        }

        fn get_pending_upgrade(self: @ContractState) -> PendingUpgrade {
            self.pending_upgrade.read()
        }

        // ----------------------------------------------------------
                                // VIEWS
        // ----------------------------------------------------------

        fn get_dispute(self: @ContractState, dispute_id: u256) -> Dispute {
            self.disputes.entry(dispute_id).read()
        }

        fn get_proposal(self: @ContractState, proposal_id: u256) -> FundingProposal {
            self.proposals.entry(proposal_id).read()
        }

        fn get_conviction(
            self: @ContractState, owner: ContractAddress, id: u32,
        ) -> Conviction {
            self.convictions.entry((owner, id)).read()
        }

        fn get_juror_stake(self: @ContractState, juror: ContractAddress) -> u256 {
            self.juror_stake.entry(juror).read()
        }

        fn total_stake_weight(self: @ContractState) -> u256 {
            self._fenwick_total()
        }
    }

    // //////////////////////////////////////////////////////////////
                          // INTERNAL HELPERS
    // //////////////////////////////////////////////////////////////

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn _mint_capped(ref self: ContractState, to: ContractAddress, amount: u256) {
            assert(amount > 0, 'ZeroAmount');
            let current_supply = self.erc20.total_supply();
            assert(current_supply + amount <= MAX_SUPPLY, 'SupplyCapExceeded');
            self.erc20.mint(to, amount);
        }

        // ---- monthly inflation / burn-recycling budget ----

        fn _compute_month_budget(self: @ContractState, month: u64) -> u256 {
            let recycle = if month == 0 {
                0
            } else {
                self.month_burned.entry(month - 1).read()
            };

            let supply = self.erc20.total_supply();
            if supply >= MAX_SUPPLY {
                return recycle;
            }

            let rate_bps: u256 = self.inflation_rate_bps.read().into();
            let inflation = supply * rate_bps / (DECAY_BPS_DENOM * MONTHS_PER_YEAR.into());
            let headroom = MAX_SUPPLY - supply;
            let inflation_part = if inflation > headroom { headroom } else { inflation };
            inflation_part + recycle
        }

        fn _ensure_current_month(ref self: ContractState) {
            let now = get_block_timestamp();
            let mut start = self.month_start.read();
            if now < start + MONTH_SECONDS {
                return;
            }

            let elapsed = (now - start) / MONTH_SECONDS;
            assert(elapsed <= MAX_ROLLOVER_MONTHS, 'TooManyMonthsBehind');

            let mut idx = self.month_index.read();
            let mut i: u64 = 0;
            loop {
                if i >= elapsed {
                    break;
                }

                // Settle the just-closed month: burn any unutilized budget.
                let budget = self.month_budget.entry(idx).read();
                let minted = self.month_minted.entry(idx).read();
                if minted < budget {
                    let leftover = budget - minted;
                    self.emit(MonthlyBudgetBurned { month: idx, amount: leftover });
                }

                // Open the next month with a fresh budget.
                idx += 1;
                start += MONTH_SECONDS;
                let new_budget = self._compute_month_budget(idx);
                let recycle = self.month_burned.entry(idx - 1).read();
                let inflation_part = new_budget - recycle;
                self.month_budget.entry(idx).write(new_budget);
                self
                    .emit(
                        MonthlyBudgetSet {
                            month: idx, budget: new_budget, inflation_part, recycle_part: recycle,
                        },
                    );

                i += 1;
            };

            self.month_index.write(idx);
            self.month_start.write(start);
        }

        fn _mint_from_budget(ref self: ContractState, to: ContractAddress, amount: u256) {
            assert(amount > 0, 'ZeroAmount');
            self._ensure_current_month();

            let month = self.month_index.read();
            let budget = self.month_budget.entry(month).read();
            let minted = self.month_minted.entry(month).read();
            assert(minted + amount <= budget, 'BudgetExceeded');

            self._mint_capped(to, amount);
            self.month_minted.entry(month).write(minted + amount);
            self.emit(BudgetRewardMinted { month, recipient: to, amount });
        }

        fn _track_burn(ref self: ContractState, amount: u256) {
            assert(amount > 0, 'ZeroAmount');
            self._ensure_current_month();

            let month = self.month_index.read();
            let burned = self.month_burned.entry(month).read();
            self.month_burned.entry(month).write(burned + amount);
        }

        // ---- juror slot registry ----

        fn _get_or_create_index(ref self: ContractState, juror: ContractAddress) -> u32 {
            let existing = self.juror_index.entry(juror).read();
            if existing != 0 {
                return existing;
            }
            let next = self.next_index.read() + 1;
            assert(next <= self.tree_size.read(), 'CapacityExceeded');
            self.next_index.write(next);
            self.juror_index.entry(juror).write(next);
            self.index_juror.entry(next).write(juror);
            next
        }

        // ---- Fenwick tree ----

        fn _fenwick_add(ref self: ContractState, index: u32, amount: u256) {
            let size = self.tree_size.read();
            let mut i = index;
            loop {
                if i > size {
                    break;
                }
                let cur = self.fenwick_tree.entry(i).read();
                self.fenwick_tree.entry(i).write(cur + amount);
                i += lowbit(i);
            };
        }

        fn _fenwick_sub(ref self: ContractState, index: u32, amount: u256) {
            let size = self.tree_size.read();
            let mut i = index;
            loop {
                if i > size {
                    break;
                }
                let cur = self.fenwick_tree.entry(i).read();
                assert(cur >= amount, 'FenwickUnderflow');
                self.fenwick_tree.entry(i).write(cur - amount);
                i += lowbit(i);
            };
        }

        fn _fenwick_prefix_sum(self: @ContractState, index: u32) -> u256 {
            let mut sum: u256 = 0;
            let mut i = index;
            loop {
                if i == 0 {
                    break;
                }
                sum += self.fenwick_tree.entry(i).read();
                i -= lowbit(i);
            };
            sum
        }

        fn _fenwick_total(self: @ContractState) -> u256 {
            self._fenwick_prefix_sum(self.tree_size.read())
        }

        fn _fenwick_find(self: @ContractState, target: u256) -> u32 {
            let size = self.tree_size.read();
            let mut log_size: u32 = 1;
            loop {
                if log_size * 2 > size {
                    break;
                }
                log_size = log_size * 2;
            };

            let mut pos: u32 = 0;
            let mut remaining = target;
            let mut step = log_size;
            loop {
                if step == 0 {
                    break;
                }
                let next = pos + step;
                if next <= size {
                    let val = self.fenwick_tree.entry(next).read();
                    if val <= remaining {
                        pos = next;
                        remaining -= val;
                    }
                }
                step = step / 2;
            };
            pos + 1
        }

        // ---- non-transferable governance token accounting ----

        fn _mint_governance_tokens(
            ref self: ContractState, holder: ContractAddress, amount: u256,
        ) {
            let id = self.governance_next_grant.entry(holder).read();
            self.governance_next_grant.entry(holder).write(id + 1);
            self
                .governance_grant
                .entry((holder, id))
                .write(Grant { amount, minted_at: get_block_timestamp() });
        }

        fn _decayed_grant_amount(self: @ContractState, grant: @Grant) -> u256 {
            let now = get_block_timestamp();
            if now <= *grant.minted_at {
                return *grant.amount;
            }
            let elapsed_seconds = now - *grant.minted_at;
            let hours_elapsed: u64 = elapsed_seconds / SECONDS_PER_HOUR;
            if hours_elapsed >= HOURS_PER_YEAR {
                return 0;
            }
            let amount = *grant.amount;
            amount - (amount * hours_elapsed.into() / HOURS_PER_YEAR.into())
        }

        fn _decayed_total(self: @ContractState, holder: ContractAddress) -> u256 {
            let count = self.governance_next_grant.entry(holder).read();
            let mut total: u256 = 0;
            let mut i: u32 = 0;
            loop {
                if i >= count {
                    break;
                }
                let g = self.governance_grant.entry((holder, i)).read();
                total += self._decayed_grant_amount(@g);
                i += 1;
            };
            total
        }

        // ---- score voting power ----

        /// weight = level * isqrt(locked_amount * hours_locked)
        /// hours_locked counts from `created_at` (when the stash was locked),
        /// floored to whole hours. At 0 elapsed hours the weight is 0.
        fn _vote_weight(self: @ContractState, c: @Conviction) -> u256 {
            if !*c.is_supporting {
                return 0;
            }
            let now: u64 = get_block_timestamp();
            let elapsed: u64 = if now >= *c.created_at { now - *c.created_at } else { 0 };
            let hours_locked: u64 = elapsed / SECONDS_PER_HOUR;
            let locked_u256: u256 = (*c.amount).into();
            let level_u256: u256 = (*c.level).into();
            level_u256 * isqrt(locked_u256 * hours_locked.into())
        }

        fn _proposal_total_power(
            self: @ContractState, proposal_id: u256, supporter_count: u32,
        ) -> u256 {
            let mut total: u256 = 0;
            let mut i: u32 = 0;
            loop {
                if i >= supporter_count {
                    break;
                }
                let s = self.proposal_supporters.entry((proposal_id, i)).read();
                let c = self.convictions.entry((s.owner, s.conviction_id)).read();
                if c.is_supporting && c.active_proposal == proposal_id {
                    total += self._vote_weight(@c);
                }
                i += 1;
            };
            total
        }

        /// Compute weighted score from the 11-bucket histogram.
        fn _compute_weighted_score(self: @ContractState, proposal_id: u256) -> i64 {
            let mut weighted_pos: u256 = 0;
            let mut weighted_neg: u256 = 0;
            let mut total: u256 = 0;
            let mut i: u8 = 0;
            loop {
                if i > 10 {
                    break;
                }
                let cnt = self.proposal_score_counts.entry((proposal_id, i)).read();
                if i >= 5 {
                    weighted_pos += cnt * (i - 5).into();
                } else {
                    weighted_neg += cnt * (5 - i).into();
                }
                total += cnt;
                i += 1;
            };

            let (is_neg, magnitude): (bool, u256) = if total == 0 {
                (false, 0)
            } else if weighted_pos >= weighted_neg {
                (false, (weighted_pos - weighted_neg) / total)
            } else {
                (true, (weighted_neg - weighted_pos) / total)
            };
            assert(magnitude <= 5, 'InvalidAvgScore');

            let unsigned_score: i64 = if magnitude == 0 {
                0
            } else if magnitude == 1 {
                1
            } else if magnitude == 2 {
                2
            } else if magnitude == 3 {
                3
            } else if magnitude == 4 {
                4
            } else {
                5
            };

            if is_neg {
                -unsigned_score
            } else {
                unsigned_score
            }
        }

        // ---- ERC20 balance decay ----

        fn _apply_decay(ref self: ContractState, user: ContractAddress) {
            let caller = get_caller_address();
            let now = get_block_timestamp();
            let last = self.last_decay_at.entry(user).read();

            if last == 0 {
                self.last_decay_at.entry(user).write(now);
                return;
            }
            if now <= last {
                return;
            }

            let elapsed_seconds = now - last;
            let hours_elapsed: u64 = elapsed_seconds / SECONDS_PER_HOUR;
            if hours_elapsed == 0 {
                return;
            }

            self.last_decay_at.entry(user).write(last + hours_elapsed * SECONDS_PER_HOUR);

            let balance = self.erc20.balance_of(user);
            if balance == 0 {
                return;
            }

            let rate_bps: u256 = self.decay_rate_bps.read().into();
            let numerator: u256 = balance * rate_bps * hours_elapsed.into();
            let denominator: u256 = DECAY_BPS_DENOM * HOURS_PER_YEAR.into();
            let mut burn_amount: u256 = numerator / denominator;
            if burn_amount > balance {
                burn_amount = balance;
            }

            if burn_amount > 0 {
                self.erc20.burn(user, burn_amount);
                self._track_burn(burn_amount);
                self.emit(DecayApplied { user, amount: burn_amount, caller });
            }

            if caller != user && burn_amount >= self.min_decay_for_reward.read() {
                let last_reward = self.last_caller_reward_at.entry(caller).read();
                if now >= last_reward + CALLER_REWARD_COOLDOWN {
                    self.last_caller_reward_at.entry(caller).write(now);
                    let reward = self.caller_reward_amount.read();
                    if reward > 0 {
                        self._mint_from_budget(caller, reward);
                        self.emit(DecayCallerRewarded { caller, user, reward });
                    }
                }
            }
        }

        // ---- juror stake locking ----

        fn _release_dispute_lock(
            ref self: ContractState, dispute_id: u256, juror: ContractAddress,
        ) {
            if self.dispute_juror_lock_released.entry((dispute_id, juror)).read() {
                return;
            }
            let snapshot = self.dispute_juror_locked_snapshot.entry((dispute_id, juror)).read();
            let total = self.juror_locked_total.entry(juror).read();
            self.juror_locked_total.entry(juror).write(total - snapshot);

            let open = self.juror_open_lock_count.entry(juror).read();
            if open > 0 {
                self.juror_open_lock_count.entry(juror).write(open - 1);
            }

            self.dispute_juror_lock_released.entry((dispute_id, juror)).write(true);
        }

        // ---- generic timelock engine ----

        fn _propose_change(ref self: ContractState, param_key: felt252, new_value: u256) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let effective_at = get_block_timestamp() + TIMELOCK_DURATION;
            self
                .pending_changes
                .entry(param_key)
                .write(PendingChange { new_value, effective_at, exists: true });
            self.emit(ChangeProposed { param_key, new_value, effective_at });
        }

        fn _execute_change(ref self: ContractState, param_key: felt252) -> u256 {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let pc = self.pending_changes.entry(param_key).read();
            assert(pc.exists, 'NoPendingChange');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            self
                .pending_changes
                .entry(param_key)
                .write(PendingChange { new_value: 0, effective_at: 0, exists: false });
            self.emit(ChangeExecuted { param_key, new_value: pc.new_value });
            pc.new_value
        }

        fn _address_to_u256(self: @ContractState, addr: ContractAddress) -> u256 {
            let addr_felt: felt252 = addr.into();
            addr_felt.into()
        }

        fn _u256_to_address(self: @ContractState, value: u256) -> ContractAddress {
            let value_felt: felt252 = value.try_into().unwrap();
            value_felt.try_into().unwrap()
        }
    }
}
