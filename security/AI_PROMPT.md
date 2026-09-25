Date: 21-09-2026 08:25:48 PM IST

Will it be better to use beta bayes reputation instead of this in terms of effective fund allocation and game theory:
avgScore = Σ(score_i  weight_i) / Σ(weight_i)

Reputation = α_total × α_weight / (α_total× α_weight + β_total× β_weight)

Reputation comes 0-1

0 reputation  means score -5
0 - 0.09 reputation means score -4
0.1 - 0.19 reputation means score -3
0.2 - 0.29 means score -2
0.3 - 0.39 means score -1
0.4 - 0.49 means score  0
0.5 - 0.59 means score 1
0.6 - 0.69 means score 2
0.7 - 0.79 means score 3
0.8 - 0.89 means score 4
0.9 - 1 means score 5






Date: 18-09-2026 09:19:37 PM IST

For rewards in erc20

Maximum 5% inflation per year.
Burning percentage is decided by admin, default 5 percent (seems its already done isn't it)

Decide monthly budget 5%/12 inflation money + total amount burned last month.

If inflation reached max supply no more inflation, total monthly budget is only last month burned erc tokens

If monthly budget remain un-utilized, burn it. 

Write functions to track total budget per month. 


Date: 16-09-2026

EVALUATION_BOND_AMOUNT can be changed by admin. Provide time lock

Remove funding_token, use  contract has its own embedded ERC20 token

  fn create_funding_proposal(
            ref self: ContractState,
            funding_wallet: ContractAddress,
            requested_amount: u256,
            evidence: ByteArray,
        )

Funding proposal has requested_amount, remove it.
make conviction voting as score voting like this, except conviction is done with nontradable governance tokens rather the contract erc20. And nontradable token are decayble, in a year if user has 50_000_000_000_000_000_000_000 governance token after a year it becomes zero, constant decay every hour,

Give reward and mini reward miniting erc20 of contract, also keep most admin controlled timelocked variable

  let score_as_u256: u256 = if p.final_score == 1 {
                1
            } else if p.final_score == 2 {
                2
            } else if p.final_score == 3 {
                3
            } else if p.final_score == 4 {
                4
            } else {
                5
            };
            let rm = self.reward_multiplier.read();
            let mrm = self.mini_reward_multiplier.read();


```cairo
// SPDX-License-Identifier: MIT
//! Single-contract Cairo port of the Solidity Pushti / Conviction protocol
//! (PushtiToken + ConvictionStorage + ProposalController + VotingController +
//!  DecayController + ConfigController collapsed into one Starknet contract).
//!
//! NOTES ON THE PORT
//! ------------------
//! * All the separate Solidity contracts talked to each other through
//!   `WRITER_ROLE` / `OPERATOR_ROLE` grants because state and logic lived in
//!   different deployments. In a single Cairo contract that indirection is
//!   unnecessary: all storage is local and all "cross-contract" calls become
//!   plain internal function calls, so `WRITER_ROLE` / `OPERATOR_ROLE` and the
//!   escrow-transfer plumbing have been removed. `MINTER_ROLE` / `BURNER_ROLE`
//!   are likewise dropped in favor of internal-only mint/burn helpers that are
//!   only reachable from the gated public entry points below.
//! * `uint256` amounts -> Cairo `u256`. Solidity `int256`/`int64`/`int8`
//!   scores -> Cairo `i64` / `i8`. Timestamps -> Cairo `u64`
//!   (`get_block_timestamp`).
//! * Solidity `string` (evidence CID) -> Cairo `ByteArray`.
//! * The 11-slot `uint256[11]` score histogram is stored as a `Map<(u256,
//!   u8), u256>` keyed by `(proposal_id, bucket)`.
//! * `Math.mulDiv` / `Math.tryAdd` / `Math.trySub` are replaced with plain
//!   `u256` arithmetic; Cairo's `u256` add/sub/mul panic on overflow /
//!   underflow by default, which mirrors Solidity 0.8's checked-arithmetic
//!   behaviour, so the explicit `Overflow`/`Underflow` custom errors are
//!   only re-added where the original code needed a *specific* revert
//!   reason ahead of time.
//! * This file has not been run through `scarb build` in this environment
//!   (no Cairo toolchain available here) — read it as a careful structural
//!   port that should compile with only minor massaging, not as an audited,
//!   deployed artifact. Please compile, test, and (given this manages real
//!   value) get it audited before deploying.

#[starknet::interface]
pub trait IPushtiConviction<TContractState> {
    // ---- Proposals ----
    fn create_proposal(
        ref self: TContractState, evidence: ByteArray, funding_wallet: starknet::ContractAddress
    );
    fn calculate_reputation(ref self: TContractState, proposal_id: u256);
    fn release_reward(ref self: TContractState, proposal_id: u256);
    fn release_author_stake(ref self: TContractState, proposal_id: u256);

    // ---- Conviction / voting ----
    fn create_conviction(ref self: TContractState, level: u8, stake: u256);
    fn vote_with_conviction(
        ref self: TContractState, proposal_id: u256, conviction_id: u32, score: i8
    );
    fn release_conviction(ref self: TContractState, conviction_id: u32);

    // ---- Decay ----
    fn apply_decay(ref self: TContractState, user: starknet::ContractAddress);
    fn batch_apply_decay(ref self: TContractState, users: Array<starknet::ContractAddress>);
    fn set_protected_address(
        ref self: TContractState, user: starknet::ContractAddress, protected: bool
    );

    // ---- Config (admin, timelocked) ----
    fn initialize_config(
        ref self: TContractState,
        initial_supply: u256,
        reputation_score_expiration: u64,
        reputation_stake: u256,
        conviction_lock_duration: u64,
        conviction_vote_duration: u64,
        max_votes_per_conviction: u64,
        inactivity_decay_bps: u16,
        min_votes_per_quarter: u64,
        conviction_protection_bps: u16,
        reward_multiplier_value: u256,
    );

    fn schedule_config_update(
        ref self: TContractState,
        reputation_score_expiration: u64,
        reputation_stake: u256,
        conviction_lock_duration: u64,
        conviction_vote_duration: u64,
    );
    fn execute_config_update(ref self: TContractState);
    fn cancel_config_update(ref self: TContractState);

    fn schedule_thresholds_update(
        ref self: TContractState, min_votes: u256, min_conviction: u256
    );
    fn execute_thresholds_update(ref self: TContractState);
    fn cancel_thresholds_update(ref self: TContractState);

    fn schedule_max_votes_update(ref self: TContractState, new_max: u64);
    fn execute_max_votes_update(ref self: TContractState);
    fn cancel_max_votes_update(ref self: TContractState);

    fn schedule_inactivity_update(
        ref self: TContractState, decay_bps: u16, min_votes: u64, protection_bps: u16
    );
    fn execute_inactivity_update(ref self: TContractState);
    fn cancel_inactivity_update(ref self: TContractState);

    fn schedule_reward_multiplier_update(
        ref self: TContractState, new_reward: u256, new_mini_reward: u256
    );
    fn execute_reward_multiplier_update(ref self: TContractState);
    fn cancel_reward_multiplier_update(ref self: TContractState);

    fn freeze_config(ref self: TContractState);
    fn freeze_max_votes_per_conviction(ref self: TContractState);

    // ---- Views ----
    fn get_config(self: @TContractState) -> PushtiConviction::Config;
    fn get_proposal(self: @TContractState, id: u256) -> PushtiConviction::Proposal;
    fn get_conviction(
        self: @TContractState, owner: starknet::ContractAddress, id: u32
    ) -> PushtiConviction::Conviction;
    fn get_activity(
        self: @TContractState, user: starknet::ContractAddress
    ) -> PushtiConviction::Activity;
    fn get_all_scores(self: @TContractState, proposal_id: u256) -> Array<u256>;
    fn get_proposal_stats(self: @TContractState, id: u256) -> (u256, u256);
    fn remaining_mintable(self: @TContractState) -> u256;
}

#[starknet::contract]
pub mod PushtiConviction {
    use core::num::traits::Zero;
    use core::array::ArrayTrait;
    use starknet::{ContractAddress, get_caller_address, get_block_timestamp, get_contract_address};
    use starknet::storage::{
        Map, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess,
    };

    use openzeppelin_token::erc20::{ERC20Component, ERC20HooksEmptyImpl, DefaultConfig};
    use openzeppelin_access::accesscontrol::AccessControlComponent;
    use openzeppelin_access::accesscontrol::DEFAULT_ADMIN_ROLE;
    use openzeppelin_introspection::src5::SRC5Component;
    use openzeppelin_security::reentrancyguard::ReentrancyGuardComponent;

    component!(path: ERC20Component, storage: erc20, event: ERC20Event);
    component!(path: AccessControlComponent, storage: accesscontrol, event: AccessControlEvent);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);
    component!(
        path: ReentrancyGuardComponent, storage: reentrancyguard, event: ReentrancyGuardEvent
    );

    // NOTE: we deliberately embed the plain (non-mixin) ERC20/AccessControl
    // impls. The *Mixin* impls implement their ABI trait directly on
    // `ContractState` (so its methods would be `self.transfer(...)`, not
    // `self.erc20.transfer(...)`); the component-level impls below implement
    // it on the component's own state, which is what lets internal code call
    // `self.erc20.transfer_from(...)`, `self.erc20.mint(...)`, etc. from the
    // business-logic functions further down in this file.
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

    // //////////////////////////////////////////////////////////////
                              // CONSTANTS
    // //////////////////////////////////////////////////////////////

    const TOTAL_SUPPLY_CAP: u256 = 50_000_000_000_000_000_000_000_000; // 50_000_000 * 1e18
    const MAX_REWARD_PER_PROPOSAL: u256 = 1_000_000_000_000_000_000_000; // 1000 * 1e18
    const MIN_SCORE_FOR_REWARD: i64 = 1;
    const SCORE_BUFFER: u64 = 900; // 15 minutes

    const MAX_LOCK_DURATION: u64 = 157_680_000; // 5 * 365 days

    const YEAR: u64 = 31_536_000; // 365 days
    const MIN_DECAY_INTERVAL: u64 = 86_400; // 1 day
    const QUARTER: u64 = 7_862_400; // 91 days
    const MIN_DECAY_FOR_REWARD: u256 = 100_000_000_000_000_000; // 0.1 ether
    const CALLER_REWARD: u256 = 1_000_000_000_000_000; // 0.001 ether

    const CONFIG_TIMELOCK_DELAY: u64 = 432_000; // 5 days

    // //////////////////////////////////////////////////////////////
                              // STRUCTS
    // //////////////////////////////////////////////////////////////

    #[derive(Drop, Serde, Copy, starknet::Store)]
    pub struct Config {
        pub reputation_score_expiration: u64,
        pub reputation_stake: u256,
        pub conviction_lock_duration: u64,
        pub conviction_vote_duration: u64,
        pub max_votes_per_conviction: u64,
        pub inactivity_decay_bps: u16, // basis points, e.g. 500 = 5 %
        pub min_votes_per_quarter: u64,
        pub conviction_protection_bps: u16, // e.g. 10000 = 1x multiplier
        pub initialized: bool,
        pub config_frozen: bool,
        pub max_votes_per_conviction_frozen: bool,
    }

    #[derive(Drop, Serde, Copy, starknet::Store)]
    pub struct Activity {
        pub current_votes: u32,
        pub previous_votes: u32,
        pub window_start: u64,
        pub last_decay_timestamp: u64,
    }

    #[derive(Drop, Serde, Copy, starknet::Store)]
    pub struct Conviction {
        pub owner: ContractAddress,
        pub id: u32,
        pub level: u8,
        pub stake: u256,
        pub lock_duration: u64,
        pub created_at: u64,
        pub votes_cast: u64,
        pub released: bool,
        pub exists: bool,
    }

    #[derive(Drop, Serde, starknet::Store)]
    pub struct Proposal {
        pub author: ContractAddress,
        pub funding_wallet: ContractAddress,
        pub evidence: ByteArray,
        pub submit_time: u64,
        pub stake: u256,
        pub stake_released: bool,
        pub reward_released: bool,
        pub final_score: i64,
        pub score_updated_at: u64,
    }

    #[derive(Drop, Serde, Copy, starknet::Store)]
    struct PendingConfigUpdate {
        reputation_score_expiration: u64,
        reputation_stake: u256,
        conviction_lock_duration: u64,
        conviction_vote_duration: u64,
        scheduled_at: u64,
        pending: bool,
    }

    #[derive(Drop, Serde, Copy, starknet::Store)]
    struct PendingThresholdsUpdate {
        min_votes: u256,
        min_conviction: u256,
        scheduled_at: u64,
        pending: bool,
    }

    #[derive(Drop, Serde, Copy, starknet::Store)]
    struct PendingMaxVotesUpdate {
        new_max: u64,
        scheduled_at: u64,
        pending: bool,
    }

    #[derive(Drop, Serde, Copy, starknet::Store)]
    struct PendingInactivityUpdate {
        decay_bps: u16,
        min_votes: u64,
        protection_bps: u16,
        scheduled_at: u64,
        pending: bool,
    }

    #[derive(Drop, Serde, Copy, starknet::Store)]
    struct PendingRewardMultiplierUpdate {
        new_reward: u256,
        new_mini_reward: u256,
        scheduled_at: u64,
        pending: bool,
    }

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

        // ---- config ----
        config: Config,
        reward_multiplier: u256,
        mini_reward_multiplier: u256,
        min_total_votes: u256,
        min_total_conviction: u256,

        // ---- activity ----
        activity: Map<ContractAddress, Activity>,

        // ---- conviction ----
        total_conviction_stake: Map<ContractAddress, u256>,
        next_conviction_id: Map<ContractAddress, u32>,
        convictions: Map<(ContractAddress, u32), Conviction>,
        conviction_voted_on_proposal: Map<(ContractAddress, u32, u256), bool>,

        // ---- proposals ----
        global_proposal_count: u256,
        proposals: Map<u256, Proposal>,
        author_last_proposal_id: Map<ContractAddress, u256>,
        has_created_proposal: Map<ContractAddress, bool>,

        // ---- scoring: 11 buckets, index = score + 5 ----
        proposal_score_counts: Map<(u256, u8), u256>,
        proposal_total_votes: Map<u256, u256>,
        proposal_total_conviction: Map<u256, u256>,

        // ---- decay ----
        is_protected_address: Map<ContractAddress, bool>,
        last_caller_reward_at: Map<ContractAddress, u64>,

        // ---- timelocked pending updates ----
        pending_config: PendingConfigUpdate,
        pending_thresholds: PendingThresholdsUpdate,
        pending_max_votes: PendingMaxVotesUpdate,
        pending_inactivity: PendingInactivityUpdate,
        pending_reward_multiplier: PendingRewardMultiplierUpdate,
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

        ProposalCreated: ProposalCreated,
        RewardReleased: RewardReleased,
        ConvictionCreated: ConvictionCreated,
        ConvictionReleased: ConvictionReleased,
        VoteCast: VoteCast,
        DecayApplied: DecayApplied,
        ProtectedStatusUpdated: ProtectedStatusUpdated,
        ConfigInitialized: ConfigInitialized,
        ConfigUpdated: ConfigUpdated,
        MaxVotesPerConvictionUpdated: MaxVotesPerConvictionUpdated,
        ConfigFrozenDone: ConfigFrozenDone,
        MaxVotesPerConvictionFrozen: MaxVotesPerConvictionFrozen,
        ConfigUpdateScheduled: ConfigUpdateScheduled,
        ConfigUpdateExecuted: ConfigUpdateExecuted,
        ConfigUpdateCancelled: ConfigUpdateCancelled,
        ThresholdsUpdateScheduled: ThresholdsUpdateScheduled,
        ThresholdsUpdateExecuted: ThresholdsUpdateExecuted,
        ThresholdsUpdateCancelled: ThresholdsUpdateCancelled,
        MaxVotesUpdateScheduled: MaxVotesUpdateScheduled,
        MaxVotesUpdateExecuted: MaxVotesUpdateExecuted,
        MaxVotesUpdateCancelled: MaxVotesUpdateCancelled,
        InactivityUpdateScheduled: InactivityUpdateScheduled,
        InactivityUpdateExecuted: InactivityUpdateExecuted,
        InactivityUpdateCancelled: InactivityUpdateCancelled,
        RewardMultiplierUpdateScheduled: RewardMultiplierUpdateScheduled,
        RewardMultiplierUpdateExecuted: RewardMultiplierUpdateExecuted,
        RewardMultiplierUpdateCancelled: RewardMultiplierUpdateCancelled,
    }

    #[derive(Drop, starknet::Event)]
    struct ProposalCreated {
        #[key]
        proposal_id: u256,
        #[key]
        author: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct RewardReleased {
        #[key]
        proposal_id: u256,
        #[key]
        recipient: ContractAddress,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct ConvictionCreated {
        #[key]
        owner: ContractAddress,
        #[key]
        id: u32,
        stake: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct ConvictionReleased {
        #[key]
        owner: ContractAddress,
        #[key]
        id: u32,
        stake: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct VoteCast {
        #[key]
        proposal_id: u256,
        #[key]
        voter: ContractAddress,
        #[key]
        conviction_id: u32,
        score: i8,
        weight: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct DecayApplied {
        #[key]
        user: ContractAddress,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct ProtectedStatusUpdated {
        #[key]
        user: ContractAddress,
        is_protected: bool,
    }

    #[derive(Drop, starknet::Event)]
    struct ConfigInitialized {
        initial_supply: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct ConfigUpdated {}

    #[derive(Drop, starknet::Event)]
    struct MaxVotesPerConvictionUpdated {
        old_value: u64,
        new_value: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct ConfigFrozenDone {}

    #[derive(Drop, starknet::Event)]
    struct MaxVotesPerConvictionFrozen {}

    #[derive(Drop, starknet::Event)]
    struct ConfigUpdateScheduled {
        execute_after: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct ConfigUpdateExecuted {}

    #[derive(Drop, starknet::Event)]
    struct ConfigUpdateCancelled {}

    #[derive(Drop, starknet::Event)]
    struct ThresholdsUpdateScheduled {
        execute_after: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct ThresholdsUpdateExecuted {}

    #[derive(Drop, starknet::Event)]
    struct ThresholdsUpdateCancelled {}

    #[derive(Drop, starknet::Event)]
    struct MaxVotesUpdateScheduled {
        execute_after: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct MaxVotesUpdateExecuted {}

    #[derive(Drop, starknet::Event)]
    struct MaxVotesUpdateCancelled {}

    #[derive(Drop, starknet::Event)]
    struct InactivityUpdateScheduled {
        execute_after: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct InactivityUpdateExecuted {}

    #[derive(Drop, starknet::Event)]
    struct InactivityUpdateCancelled {}

    #[derive(Drop, starknet::Event)]
    struct RewardMultiplierUpdateScheduled {
        execute_after: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct RewardMultiplierUpdateExecuted {}

    #[derive(Drop, starknet::Event)]
    struct RewardMultiplierUpdateCancelled {}

    // //////////////////////////////////////////////////////////////
                            // CONSTRUCTOR
    // //////////////////////////////////////////////////////////////

    #[constructor]
    fn constructor(ref self: ContractState, admin: ContractAddress) {
        assert(admin.is_non_zero(), 'ZeroAddress');
        self.erc20.initializer("AROGYA", "AROGYA");
        self.accesscontrol.initializer();
        self.accesscontrol._grant_role(DEFAULT_ADMIN_ROLE, admin);

        let this = get_contract_address();
        self.is_protected_address.entry(this).write(true);
        // NOTE: the zero address is never a valid `user` argument on Starknet
        // (calls always originate from a real contract address), so unlike
        // the Solidity original we don't need to special-case address(0).
    }

    // //////////////////////////////////////////////////////////////
                          // EXTERNAL IMPL
    // //////////////////////////////////////////////////////////////

    #[abi(embed_v0)]
    impl PushtiConvictionImpl of super::IPushtiConviction<ContractState> {
        // ----------------------------------------------------------
                              // PROPOSALS
        // ----------------------------------------------------------

        fn create_proposal(
            ref self: ContractState, evidence: ByteArray, funding_wallet: ContractAddress
        ) {
            self.reentrancyguard.start();
            let caller = get_caller_address();
            let cfg = self.config.read();
            assert(cfg.initialized, 'NotInitialized');
            assert(funding_wallet.is_non_zero(), 'InvalidWallet');

            if self.has_created_proposal.entry(caller).read() {
                let last_id = self.author_last_proposal_id.entry(caller).read();
                let prev = self.proposals.entry(last_id).read();
                assert(prev.author == caller, 'InvalidLastProposal');
                assert(
                    get_block_timestamp() >= prev.submit_time + cfg.reputation_score_expiration,
                    'CooldownActive',
                );
            }

            self._apply_inactivity_decay(caller);

            // Pull stake into contract-held escrow.
            self.erc20._transfer(caller, get_contract_address(), cfg.reputation_stake);

            let proposal_id = self.global_proposal_count.read();
            self.global_proposal_count.write(proposal_id + 1);

            let p = Proposal {
                author: caller,
                funding_wallet,
                evidence,
                submit_time: get_block_timestamp(),
                stake: cfg.reputation_stake,
                stake_released: false,
                reward_released: false,
                final_score: 0,
                score_updated_at: 0,
            };
            self.proposals.entry(proposal_id).write(p);
            self.author_last_proposal_id.entry(caller).write(proposal_id);
            self.has_created_proposal.entry(caller).write(true);

            self.emit(ProposalCreated { proposal_id, author: caller });
            self.reentrancyguard.end();
        }

        fn calculate_reputation(ref self: ContractState, proposal_id: u256) {
            self.reentrancyguard.start();
            let count = self.global_proposal_count.read();
            assert(proposal_id < count, 'InvalidProposalId');

            let p = self.proposals.entry(proposal_id).read();
            assert(p.score_updated_at == 0, 'AlreadyCalculated');

            let cfg = self.config.read();
            assert(
                get_block_timestamp() >= p.submit_time + cfg.conviction_vote_duration + SCORE_BUFFER,
                'TooEarly',
            );

            let total_votes = self.proposal_total_votes.entry(proposal_id).read();
            let total_conviction = self.proposal_total_conviction.entry(proposal_id).read();
            let min_votes = self.min_total_votes.read();
            let min_conviction = self.min_total_conviction.read();

            if total_votes < min_votes || total_conviction < min_conviction {
                let mut pw = self.proposals.entry(proposal_id).read();
                pw.score_updated_at = get_block_timestamp();
                pw.final_score = 0;
                self.proposals.entry(proposal_id).write(pw);
                self.reentrancyguard.end();
                return;
            }

            let mut weighted_pos: u256 = 0;
            let mut weighted_neg: u256 = 0;
            let mut total: u256 = 0;
            let mut i: u8 = 0;
            loop {
                if i > 10 {
                    break;
                }
                let cnt = self.proposal_score_counts.entry((proposal_id, i)).read();
                // index 0 -> score -5 ... index 10 -> score +5
                if i >= 5 {
                    weighted_pos += cnt * (i - 5).into();
                } else {
                    weighted_neg += cnt * (5 - i).into();
                }
                total += cnt;
                i += 1;
            };

            // u256 has no direct TryInto<i64>, so we first bound the
            // magnitude to a u256 in [0, 5] and only then fold in the sign
            // using plain i64 literals (avoids relying on any u256<->iN
            // conversion trait that may not be implemented for this pair).
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
            let avg_score: i64 = if is_neg {
                -unsigned_score
            } else {
                unsigned_score
            };
            assert(avg_score >= -5 && avg_score <= 5, 'InvalidAvgScore');

            let mut pw = self.proposals.entry(proposal_id).read();
            pw.score_updated_at = get_block_timestamp();
            pw.final_score = avg_score;
            self.proposals.entry(proposal_id).write(pw);
            self.reentrancyguard.end();
        }

        fn release_reward(ref self: ContractState, proposal_id: u256) {
            self.reentrancyguard.start();
            let count = self.global_proposal_count.read();
            assert(proposal_id < count, 'InvalidProposalId');

            let mut p = self.proposals.entry(proposal_id).read();
            assert(!p.reward_released, 'AlreadyReleased');
            assert(p.score_updated_at != 0, 'ScoreMissing');
            assert(p.final_score >= MIN_SCORE_FOR_REWARD, 'ScoreTooLow');
            assert(p.final_score <= 5, 'InvalidScoreValue');

            // i64 has no direct TryInto<u256> either; final_score is already
            // proven to be in [1, 5] by the asserts above, so map it by hand.
            let score_as_u256: u256 = if p.final_score == 1 {
                1
            } else if p.final_score == 2 {
                2
            } else if p.final_score == 3 {
                3
            } else if p.final_score == 4 {
                4
            } else {
                5
            };
            let rm = self.reward_multiplier.read();
            let mrm = self.mini_reward_multiplier.read();

            let reward: u256 = if score_as_u256 <= 3 {
                score_as_u256 * mrm
            } else {
                score_as_u256 * rm
            };
            assert(reward <= MAX_REWARD_PER_PROPOSAL, 'TooHigh');

            p.reward_released = true;
            let funding_wallet = p.funding_wallet;
            self.proposals.entry(proposal_id).write(p);

            self._mint_checked(funding_wallet, reward);

            self.emit(RewardReleased { proposal_id, recipient: funding_wallet, amount: reward });
            self.reentrancyguard.end();
        }

        fn release_author_stake(ref self: ContractState, proposal_id: u256) {
            self.reentrancyguard.start();
            let count = self.global_proposal_count.read();
            assert(proposal_id < count, 'InvalidProposalId');

            let mut p = self.proposals.entry(proposal_id).read();
            let caller = get_caller_address();
            assert(caller == p.author, 'Unauthorized');
            assert(!p.stake_released, 'AlreadyReleased');
            assert(p.score_updated_at != 0, 'ScoreMissing');
            assert(p.final_score >= MIN_SCORE_FOR_REWARD, 'ScoreTooLow');
            assert(p.final_score <= 5, 'InvalidScoreValue');

            let stake_to_return = p.stake;
            p.stake_released = true;
            self.proposals.entry(proposal_id).write(p);

            self.erc20._transfer(get_contract_address(), caller, stake_to_return);
            self.reentrancyguard.end();
        }

        // ----------------------------------------------------------
                          // CONVICTION / VOTING
        // ----------------------------------------------------------

        fn create_conviction(ref self: ContractState, level: u8, stake: u256) {
            self.reentrancyguard.start();
            assert(level != 0 && level <= 10 && stake != 0, 'InvalidConviction');

            let caller = get_caller_address();
            self._apply_inactivity_decay(caller);

            self.erc20._transfer(caller, get_contract_address(), stake);

            let current_total = self.total_conviction_stake.entry(caller).read();
            let new_total = current_total + stake; // panics on overflow (== StakeOverflow)
            self.total_conviction_stake.entry(caller).write(new_total);

            let cfg = self.config.read();
            let lock_duration: u64 = cfg.conviction_lock_duration * level.into();
            assert(lock_duration <= MAX_LOCK_DURATION, 'TooHigh');

            let id = self.next_conviction_id.entry(caller).read();
            self.next_conviction_id.entry(caller).write(id + 1);

            let c = Conviction {
                owner: caller,
                id,
                level,
                stake,
                lock_duration,
                created_at: get_block_timestamp(),
                votes_cast: 0,
                released: false,
                exists: true,
            };
            self.convictions.entry((caller, id)).write(c);

            self.emit(ConvictionCreated { owner: caller, id, stake });
            self.reentrancyguard.end();
        }

        fn vote_with_conviction(
            ref self: ContractState, proposal_id: u256, conviction_id: u32, score: i8
        ) {
            self.reentrancyguard.start();
            assert(score >= -5 && score <= 5, 'InvalidScore');

            let count = self.global_proposal_count.read();
            assert(proposal_id < count, 'InvalidProposalId');

            let p = self.proposals.entry(proposal_id).read();
            let cfg = self.config.read();

            assert(
                get_block_timestamp() < p.submit_time + cfg.conviction_vote_duration,
                'VotingPeriodEnded',
            );
            assert(p.score_updated_at == 0, 'AlreadyCalculated');

            let caller = get_caller_address();
            let mut c = self.convictions.entry((caller, conviction_id)).read();
            assert(c.owner == caller, 'Unauthorized');
            assert(!c.released, 'AlreadyReleasedConviction');
            assert(
                get_block_timestamp() < c.created_at + c.lock_duration, 'LockExpired',
            );

            let voted_key = (caller, conviction_id, proposal_id);
            assert(!self.conviction_voted_on_proposal.entry(voted_key).read(), 'AlreadyVoted');
            assert(c.votes_cast < cfg.max_votes_per_conviction, 'MaxVotesReached');

            let weight: u256 = c.level.into() * c.stake;

            let bucket: u8 = (score + 5).try_into().unwrap();
            let cur = self.proposal_score_counts.entry((proposal_id, bucket)).read();
            let new_cnt = cur + weight; // panics on overflow (== CountOverflow)
            self.proposal_score_counts.entry((proposal_id, bucket)).write(new_cnt);

            c.votes_cast += 1;
            self.convictions.entry((caller, conviction_id)).write(c);
            self.conviction_voted_on_proposal.entry(voted_key).write(true);

            let tv = self.proposal_total_votes.entry(proposal_id).read();
            self.proposal_total_votes.entry(proposal_id).write(tv + 1);
            let tc = self.proposal_total_conviction.entry(proposal_id).read();
            self.proposal_total_conviction.entry(proposal_id).write(tc + weight);

            self._roll_activity_window(caller);
            let mut a = self.activity.entry(caller).read();
            a.current_votes += 1;
            self.activity.entry(caller).write(a);

            self
                .emit(
                    VoteCast { proposal_id, voter: caller, conviction_id, score, weight }
                );
            self.reentrancyguard.end();
        }

        fn release_conviction(ref self: ContractState, conviction_id: u32) {
            self.reentrancyguard.start();
            let caller = get_caller_address();
            let mut c = self.convictions.entry((caller, conviction_id)).read();
            assert(c.exists && c.owner == caller, 'ConvictionNotExist');
            assert(!c.released, 'AlreadyReleasedConviction');
            assert(
                get_block_timestamp() >= c.created_at + c.lock_duration, 'LockNotExpired',
            );

            let amount = c.stake;
            let current_total = self.total_conviction_stake.entry(caller).read();
            assert(current_total >= amount, 'StakeUnderflow');
            self.total_conviction_stake.entry(caller).write(current_total - amount);

            c.released = true;
            c.stake = 0;
            self.convictions.entry((caller, conviction_id)).write(c);

             self.erc20._transfer(get_contract_address(), caller, amount);

            self.emit(ConvictionReleased { owner: caller, id: conviction_id, stake: amount });
            self.reentrancyguard.end();
        }

        // ----------------------------------------------------------
                                // DECAY
        // ----------------------------------------------------------

        fn apply_decay(ref self: ContractState, user: ContractAddress) {
            self.reentrancyguard.start();
            assert(!self.is_protected_address.entry(user).read(), 'ProtectedAddress');
            self._apply_inactivity_decay(user);
            self.reentrancyguard.end();
        }

        fn batch_apply_decay(ref self: ContractState, users: Array<ContractAddress>) {
            self.reentrancyguard.start();
            assert(users.len() <= 50, 'TooManyUsers');
            let mut i: u32 = 0;
            loop {
                if i >= users.len() {
                    break;
                }
                let user = *users.at(i);
                if !self.is_protected_address.entry(user).read() {
                    self._apply_inactivity_decay(user);
                }
                i += 1;
            };
            self.reentrancyguard.end();
        }

        fn set_protected_address(ref self: ContractState, user: ContractAddress, protected: bool) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(user.is_non_zero(), 'ZeroAddress');
            self.is_protected_address.entry(user).write(protected);
            self.emit(ProtectedStatusUpdated { user, is_protected: protected });
        }

        // ----------------------------------------------------------
                          // CONFIG: ONE-SHOT INIT
        // ----------------------------------------------------------

        fn initialize_config(
            ref self: ContractState,
            initial_supply: u256,
            reputation_score_expiration: u64,
            reputation_stake: u256,
            conviction_lock_duration: u64,
            conviction_vote_duration: u64,
            max_votes_per_conviction: u64,
            inactivity_decay_bps: u16,
            min_votes_per_quarter: u64,
            conviction_protection_bps: u16,
            reward_multiplier_value: u256,
        ) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let cfg = self.config.read();
            assert(!cfg.initialized, 'AlreadyInitialized');
            assert(conviction_protection_bps <= 10_000, 'ProtectionTooHigh');

            self
                .config
                .write(
                    Config {
                        reputation_score_expiration,
                        reputation_stake,
                        conviction_lock_duration,
                        conviction_vote_duration,
                        max_votes_per_conviction,
                        inactivity_decay_bps,
                        min_votes_per_quarter,
                        conviction_protection_bps,
                        initialized: true,
                        config_frozen: false,
                        max_votes_per_conviction_frozen: false,
                    },
                );

            // mini_reward_multiplier used for scores 1-3, reward_multiplier for 4-5.
            self.reward_multiplier.write(reward_multiplier_value);
            self.mini_reward_multiplier.write(1_000_000_000_000_000_000); // 1e18

            // Thresholds that must be met for a proposal to be reward-eligible.
            self.min_total_votes.write(4);
            self.min_total_conviction.write(1_000_000_000_000_000_000); // 1e18

            self._mint_checked(get_caller_address(), initial_supply);
            self.emit(ConfigInitialized { initial_supply });
        }

        // ----------------------------------------------------------
                       // CONFIG: CORE TIMELOCK
        // ----------------------------------------------------------

        fn schedule_config_update(
            ref self: ContractState,
            reputation_score_expiration: u64,
            reputation_stake: u256,
            conviction_lock_duration: u64,
            conviction_vote_duration: u64,
        ) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let cfg = self.config.read();
            assert(cfg.initialized, 'NotInitialized');
            assert(!cfg.config_frozen, 'ConfigFrozen');

            let now = get_block_timestamp();
            self
                .pending_config
                .write(
                    PendingConfigUpdate {
                        reputation_score_expiration,
                        reputation_stake,
                        conviction_lock_duration,
                        conviction_vote_duration,
                        scheduled_at: now,
                        pending: true,
                    },
                );
            self.emit(ConfigUpdateScheduled { execute_after: now + CONFIG_TIMELOCK_DELAY });
        }

        fn execute_config_update(ref self: ContractState) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let pu = self.pending_config.read();
            assert(pu.pending, 'NoUpdatePending');
            assert(
                get_block_timestamp() >= pu.scheduled_at + CONFIG_TIMELOCK_DELAY,
                'TimelockNotElapsed',
            );
            let mut cfg = self.config.read();
            assert(cfg.initialized, 'NotInitialized');
            assert(!cfg.config_frozen, 'ConfigFrozen');

            cfg.reputation_score_expiration = pu.reputation_score_expiration;
            cfg.reputation_stake = pu.reputation_stake;
            cfg.conviction_lock_duration = pu.conviction_lock_duration;
            cfg.conviction_vote_duration = pu.conviction_vote_duration;
            self.config.write(cfg);

            self.pending_config.write(Default::default());
            self.emit(ConfigUpdateExecuted {});
        }

        fn cancel_config_update(ref self: ContractState) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(self.pending_config.read().pending, 'NoUpdatePending');
            self.pending_config.write(Default::default());
            self.emit(ConfigUpdateCancelled {});
        }

        // ----------------------------------------------------------
                       // CONFIG: THRESHOLDS TIMELOCK
        // ----------------------------------------------------------

        fn schedule_thresholds_update(
            ref self: ContractState, min_votes: u256, min_conviction: u256
        ) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let cfg = self.config.read();
            assert(cfg.initialized, 'NotInitialized');
            assert(!cfg.config_frozen, 'ConfigFrozen');

            let now = get_block_timestamp();
            self
                .pending_thresholds
                .write(
                    PendingThresholdsUpdate {
                        min_votes, min_conviction, scheduled_at: now, pending: true,
                    },
                );
            self.emit(ThresholdsUpdateScheduled { execute_after: now + CONFIG_TIMELOCK_DELAY });
        }

        fn execute_thresholds_update(ref self: ContractState) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let pu = self.pending_thresholds.read();
            assert(pu.pending, 'NoUpdatePending');
            assert(
                get_block_timestamp() >= pu.scheduled_at + CONFIG_TIMELOCK_DELAY,
                'TimelockNotElapsed',
            );
            self.min_total_votes.write(pu.min_votes);
            self.min_total_conviction.write(pu.min_conviction);
            self.pending_thresholds.write(Default::default());
            self.emit(ThresholdsUpdateExecuted {});
            self.emit(ConfigUpdated {});
        }

        fn cancel_thresholds_update(ref self: ContractState) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(self.pending_thresholds.read().pending, 'NoUpdatePending');
            self.pending_thresholds.write(Default::default());
            self.emit(ThresholdsUpdateCancelled {});
        }

        // ----------------------------------------------------------
                       // CONFIG: MAX VOTES TIMELOCK
        // ----------------------------------------------------------

        fn schedule_max_votes_update(ref self: ContractState, new_max: u64) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let cfg = self.config.read();
            assert(cfg.initialized, 'NotInitialized');
            assert(!cfg.max_votes_per_conviction_frozen, 'ConfigFrozen');
            assert(new_max != 0, 'InvalidMaxVotes');

            let now = get_block_timestamp();
            self
                .pending_max_votes
                .write(PendingMaxVotesUpdate { new_max, scheduled_at: now, pending: true });
            self.emit(MaxVotesUpdateScheduled { execute_after: now + CONFIG_TIMELOCK_DELAY });
        }

        fn execute_max_votes_update(ref self: ContractState) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let pu = self.pending_max_votes.read();
            assert(pu.pending, 'NoUpdatePending');
            assert(
                get_block_timestamp() >= pu.scheduled_at + CONFIG_TIMELOCK_DELAY,
                'TimelockNotElapsed',
            );
            let mut cfg = self.config.read();
            assert(!cfg.max_votes_per_conviction_frozen, 'ConfigFrozen');

            let old = cfg.max_votes_per_conviction;
            cfg.max_votes_per_conviction = pu.new_max;
            self.config.write(cfg);
            self.pending_max_votes.write(Default::default());
            self.emit(MaxVotesUpdateExecuted {});
            self.emit(MaxVotesPerConvictionUpdated { old_value: old, new_value: pu.new_max });
        }

        fn cancel_max_votes_update(ref self: ContractState) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(self.pending_max_votes.read().pending, 'NoUpdatePending');
            self.pending_max_votes.write(Default::default());
            self.emit(MaxVotesUpdateCancelled {});
        }

        // ----------------------------------------------------------
                    // CONFIG: INACTIVITY RULES TIMELOCK
        // ----------------------------------------------------------

        fn schedule_inactivity_update(
            ref self: ContractState, decay_bps: u16, min_votes: u64, protection_bps: u16
        ) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(decay_bps <= 1_000, 'TooHigh');
            assert(protection_bps <= 10_000, 'ProtectionTooHigh');

            let cfg = self.config.read();
            assert(!cfg.config_frozen, 'ConfigFrozen');

            let now = get_block_timestamp();
            self
                .pending_inactivity
                .write(
                    PendingInactivityUpdate {
                        decay_bps, min_votes, protection_bps, scheduled_at: now, pending: true,
                    },
                );
            self.emit(InactivityUpdateScheduled { execute_after: now + CONFIG_TIMELOCK_DELAY });
        }

        fn execute_inactivity_update(ref self: ContractState) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let pu = self.pending_inactivity.read();
            assert(pu.pending, 'NoUpdatePending');
            assert(
                get_block_timestamp() >= pu.scheduled_at + CONFIG_TIMELOCK_DELAY,
                'TimelockNotElapsed',
            );
            let mut cfg = self.config.read();
            assert(!cfg.config_frozen, 'ConfigFrozen');

            cfg.inactivity_decay_bps = pu.decay_bps;
            cfg.min_votes_per_quarter = pu.min_votes;
            cfg.conviction_protection_bps = pu.protection_bps;
            self.config.write(cfg);
            self.pending_inactivity.write(Default::default());
            self.emit(InactivityUpdateExecuted {});
        }

        fn cancel_inactivity_update(ref self: ContractState) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(self.pending_inactivity.read().pending, 'NoUpdatePending');
            self.pending_inactivity.write(Default::default());
            self.emit(InactivityUpdateCancelled {});
        }

        // ----------------------------------------------------------
                  // CONFIG: REWARD MULTIPLIER TIMELOCK
        // ----------------------------------------------------------

        fn schedule_reward_multiplier_update(
            ref self: ContractState, new_reward: u256, new_mini_reward: u256
        ) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let cfg = self.config.read();
            assert(cfg.initialized, 'NotInitialized');
            assert(!cfg.config_frozen, 'ConfigFrozen');
            let max_allowed: u256 = 1_000_000_000_000_000_000 * 10_000; // 1e18 * 10000
            assert(new_reward <= max_allowed && new_mini_reward <= max_allowed, 'TooHigh');
            assert(new_reward != 0 && new_mini_reward != 0, 'TooLow');

            let now = get_block_timestamp();
            self
                .pending_reward_multiplier
                .write(
                    PendingRewardMultiplierUpdate {
                        new_reward, new_mini_reward, scheduled_at: now, pending: true,
                    },
                );
            self
                .emit(
                    RewardMultiplierUpdateScheduled { execute_after: now + CONFIG_TIMELOCK_DELAY },
                );
        }

        fn execute_reward_multiplier_update(ref self: ContractState) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let pu = self.pending_reward_multiplier.read();
            assert(pu.pending, 'NoUpdatePending');
            assert(
                get_block_timestamp() >= pu.scheduled_at + CONFIG_TIMELOCK_DELAY,
                'TimelockNotElapsed',
            );
            let cfg = self.config.read();
            assert(cfg.initialized, 'NotInitialized');
            assert(!cfg.config_frozen, 'ConfigFrozen');

            self.reward_multiplier.write(pu.new_reward);
            self.mini_reward_multiplier.write(pu.new_mini_reward);
            self.pending_reward_multiplier.write(Default::default());
            self.emit(RewardMultiplierUpdateExecuted {});
            self.emit(ConfigUpdated {});
        }

        fn cancel_reward_multiplier_update(ref self: ContractState) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(self.pending_reward_multiplier.read().pending, 'NoUpdatePending');
            self.pending_reward_multiplier.write(Default::default());
            self.emit(RewardMultiplierUpdateCancelled {});
        }

        // ----------------------------------------------------------
                                // FREEZE
        // ----------------------------------------------------------

        fn freeze_config(ref self: ContractState) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let mut cfg = self.config.read();
            assert(cfg.initialized, 'NotInitialized');
            assert(!cfg.config_frozen, 'AlreadyFrozen');
            cfg.config_frozen = true;
            self.config.write(cfg);
            self.emit(ConfigFrozenDone {});
        }

        fn freeze_max_votes_per_conviction(ref self: ContractState) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let mut cfg = self.config.read();
            assert(cfg.initialized, 'NotInitialized');
            assert(!cfg.max_votes_per_conviction_frozen, 'AlreadyFrozen');
            cfg.max_votes_per_conviction_frozen = true;
            self.config.write(cfg);
            self.emit(MaxVotesPerConvictionFrozen {});
        }

        // ----------------------------------------------------------
                                // VIEWS
        // ----------------------------------------------------------

        fn get_config(self: @ContractState) -> Config {
            self.config.read()
        }

        fn get_proposal(self: @ContractState, id: u256) -> Proposal {
            self.proposals.entry(id).read()
        }

        fn get_conviction(self: @ContractState, owner: ContractAddress, id: u32) -> Conviction {
            self.convictions.entry((owner, id)).read()
        }

        fn get_activity(self: @ContractState, user: ContractAddress) -> Activity {
            self.activity.entry(user).read()
        }

        fn get_all_scores(self: @ContractState, proposal_id: u256) -> Array<u256> {
            let mut out: Array<u256> = ArrayTrait::new();
            let mut i: u8 = 0;
            loop {
                if i > 10 {
                    break;
                }
                out.append(self.proposal_score_counts.entry((proposal_id, i)).read());
                i += 1;
            };
            out
        }

        fn get_proposal_stats(self: @ContractState, id: u256) -> (u256, u256) {
            (
                self.proposal_total_votes.entry(id).read(),
                self.proposal_total_conviction.entry(id).read(),
            )
        }

        fn remaining_mintable(self: @ContractState) -> u256 {
            TOTAL_SUPPLY_CAP - self.erc20.total_supply()
        }
    }

    // //////////////////////////////////////////////////////////////
                          // INTERNAL HELPERS
    // //////////////////////////////////////////////////////////////

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        /// Mint `amount` to `to`, enforcing the global supply cap
        /// (mirrors `PushtiToken.mint`'s `SupplyCapExceeded` guard).
        fn _mint_checked(ref self: ContractState, to: ContractAddress, amount: u256) {
            assert(to.is_non_zero(), 'InvalidUserAddress');
            assert(self.erc20.total_supply() + amount <= TOTAL_SUPPLY_CAP, 'SupplyCapExceeded');
            self.erc20.mint(to, amount);
        }

        /// Port of `DecayController._applyInactivityDecay`.
        fn _apply_inactivity_decay(ref self: ContractState, user: ContractAddress) -> u256 {
            assert(!self.is_protected_address.entry(user).read(), 'ProtectedAddress');

            self._roll_activity_window(user);

            let mut a = self.activity.entry(user).read();
            let bal = self.erc20.balance_of(user);

            // First-ever interaction: initialise the clock only.
            if a.last_decay_timestamp == 0 {
                a.last_decay_timestamp = get_block_timestamp();
                self.activity.entry(user).write(a);
                return 0;
            }

            // Zero balance: clock keeps ticking, nothing to burn.
            if bal == 0 {
                return 0;
            }

            let cfg = self.config.read();
            let is_active = a.previous_votes >= cfg.min_votes_per_quarter.try_into().unwrap()
                || a.current_votes >= cfg.min_votes_per_quarter.try_into().unwrap();

            let decayable = self._get_decayable_balance(user, bal, is_active);
            if decayable == 0 {
                return 0;
            }

            let elapsed = get_block_timestamp() - a.last_decay_timestamp;
            if elapsed < MIN_DECAY_INTERVAL {
                return 0;
            }

            // burnAmount = decayable * decayBps * elapsed / (10_000 * YEAR)
            let numerator: u256 = decayable * cfg.inactivity_decay_bps.into() * elapsed.into();
            let denominator: u256 = 10_000_u256 * YEAR.into();
            let mut burn_amount: u256 = numerator / denominator;

            if burn_amount > 0 {
                if burn_amount > decayable {
                    burn_amount = decayable;
                }
                self.erc20.burn(user, burn_amount);

                a.last_decay_timestamp = get_block_timestamp();
                self.activity.entry(user).write(a);

                let caller = starknet::get_caller_address();
                if caller != user && burn_amount >= MIN_DECAY_FOR_REWARD {
                    let last_reward = self.last_caller_reward_at.entry(caller).read();
                    if get_block_timestamp() >= last_reward + MIN_DECAY_INTERVAL {
                        self.last_caller_reward_at.entry(caller).write(get_block_timestamp());
                        self._mint_checked(caller, CALLER_REWARD);
                    }
                }

                self.emit(DecayApplied { user, amount: burn_amount });
                return burn_amount;
            }

            0
        }

        /// Port of `DecayController._rollActivityWindow`.
        fn _roll_activity_window(ref self: ContractState, user: ContractAddress) {
            let mut a = self.activity.entry(user).read();
            let now = get_block_timestamp();
            let quarters_since_epoch = now / QUARTER;

            if a.window_start == 0 && a.last_decay_timestamp == 0 {
                a.window_start = quarters_since_epoch * QUARTER;
                self.activity.entry(user).write(a);
                return;
            }

            let elapsed = now - a.window_start;
            if elapsed < QUARTER {
                return;
            }

            let windows_passed = elapsed / QUARTER;

            if windows_passed == 1 {
                a.previous_votes = a.current_votes;
                a.current_votes = 0;
            } else if windows_passed == 2 {
                a.previous_votes = a.current_votes;
                a.current_votes = 0;
            } else {
                a.previous_votes = 0;
                a.current_votes = 0;
            }

            a.window_start = quarters_since_epoch * QUARTER;
            self.activity.entry(user).write(a);
        }

        /// Port of `DecayController._getDecayableBalance`.
        fn _get_decayable_balance(
            ref self: ContractState, user: ContractAddress, balance: u256, is_active: bool
        ) -> u256 {
            if !is_active {
                return balance;
            }

            let conviction_stake = self.total_conviction_stake.entry(user).read();
            if conviction_stake == 0 {
                return balance;
            }

            let cfg = self.config.read();
            let protected_threshold: u256 = conviction_stake
                * cfg.conviction_protection_bps.into()
                / 10_000_u256;

            if balance <= protected_threshold {
                0
            } else {
                balance - protected_threshold
            }
        }
    }

    // //////////////////////////////////////////////////////////////
                       // DEFAULT IMPLS FOR PENDING STRUCTS
    // //////////////////////////////////////////////////////////////

    impl PendingConfigUpdateDefault of Default<PendingConfigUpdate> {
        fn default() -> PendingConfigUpdate {
            PendingConfigUpdate {
                reputation_score_expiration: 0,
                reputation_stake: 0,
                conviction_lock_duration: 0,
                conviction_vote_duration: 0,
                scheduled_at: 0,
                pending: false,
            }
        }
    }

    impl PendingThresholdsUpdateDefault of Default<PendingThresholdsUpdate> {
        fn default() -> PendingThresholdsUpdate {
            PendingThresholdsUpdate {
                min_votes: 0, min_conviction: 0, scheduled_at: 0, pending: false,
            }
        }
    }

    impl PendingMaxVotesUpdateDefault of Default<PendingMaxVotesUpdate> {
        fn default() -> PendingMaxVotesUpdate {
            PendingMaxVotesUpdate { new_max: 0, scheduled_at: 0, pending: false }
        }
    }

    impl PendingInactivityUpdateDefault of Default<PendingInactivityUpdate> {
        fn default() -> PendingInactivityUpdate {
            PendingInactivityUpdate {
                decay_bps: 0, min_votes: 0, protection_bps: 0, scheduled_at: 0, pending: false,
            }
        }
    }

    impl PendingRewardMultiplierUpdateDefault of Default<PendingRewardMultiplierUpdate> {
        fn default() -> PendingRewardMultiplierUpdate {
            PendingRewardMultiplierUpdate {
                new_reward: 0, new_mini_reward: 0, scheduled_at: 0, pending: false,
            }
        }
    }
}
```



Old:

Make the code upgradable.

Provide time lock for upgrade 7 days.

Write an function to remove upgrabality in future

 **`add_admin`/`remove_admin` aren't timelocked**, make it timelocked.
 
 Set num_draws by admin, min 10
