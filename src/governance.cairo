// SPDX-License-Identifier: MIT
//! Governance
//! ==========
//! Non-transferable governance-token grants, conviction voting, and funding
//! proposals for the modular stakeholder-governance system.
//!
//! Owns:
//! * the decaying non-transferable governance-token grant accounting
//!   (minted by `Selection` on positive finalization),
//! * convictions (level-based governance-token locks),
//! * funding proposals and their frozen `power_total` accumulator, and
//! * proposal execution (deposit refund/slash and best-effort score reward).
//!
//! ERC20 for proposal deposits and score rewards is held by `ConvictionToken`
//! (custody hub): Governance moves it through `escrow` / `release` /
//! `mint_from_budget`.

#[starknet::contract]
pub mod Governance {
    use core::num::traits::Zero;
    use openzeppelin_introspection::src5::SRC5Component;
    use openzeppelin_security::reentrancyguard::ReentrancyGuardComponent;
    use openzeppelin_upgrades::upgradeable::UpgradeableComponent;
    use starknet::storage::{
        Map, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::{ClassHash, ContractAddress, get_block_timestamp, get_caller_address};
    use crate::constants::*;
    use crate::events::*;
    use crate::interfaces::iconviction_token::{
        IConvictionTokenDispatcher, IConvictionTokenDispatcherTrait,
    };
    use crate::interfaces::igovernance::IGovernance;
    use crate::interfaces::iupgradeable_module::IUpgradeableModule;
    use crate::types::*;
    use crate::utils::{isqrt, score_to_u256};

    component!(path: SRC5Component, storage: src5, event: SRC5Event);
    component!(
        path: ReentrancyGuardComponent, storage: reentrancyguard, event: ReentrancyGuardEvent,
    );
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);

    impl SRC5InternalImpl = SRC5Component::InternalImpl<ContractState>;
    #[abi(embed_v0)]
    impl SRC5Impl = SRC5Component::SRC5Impl<ContractState>;
    impl ReentrancyGuardInternalImpl = ReentrancyGuardComponent::InternalImpl<ContractState>;
    impl UpgradeableInternalImpl = UpgradeableComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        /// SRC5 interface-support state.
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        /// Reentrancy lock state.
        #[substorage(v0)]
        reentrancyguard: ReentrancyGuardComponent::Storage,
        /// Upgradeable implementation state.
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,
        /// Module admin authority (the `AdminTimelock` contract).
        admin: ContractAddress,
        /// ERC20 custody hub address.
        token: ContractAddress,
        /// Authorized selection module allowed to mint governance grants.
        selection: ContractAddress,
        /// Whether the class-hash upgrade path is permanently disabled.
        upgrades_disabled: bool,
        // ---- timelocked admin parameters ----
        /// ERC20 reputation deposit required to create a proposal.
        reputation_stake: u256,
        /// Minimum frozen proposal power required for execution.
        conviction_threshold: u256,
        /// Multiplier for positive final scores 4 through 5.
        reward_multiplier: u256,
        /// Multiplier for positive final scores 1 through 3.
        mini_reward_multiplier: u256,
        /// Current per-level conviction lock duration in seconds.
        conviction_base_lock: u64,
        /// Current maximum distinct proposals per conviction.
        max_votes_per_conviction: u64,
        /// Minimum seconds a proposal stays open for voting before execution.
        proposal_voting_period: u64,
        // ---- non-transferable governance tokens ----
        governance_next_grant: Map<ContractAddress, u32>,
        governance_grant: Map<(ContractAddress, u32), Grant>,
        governance_locked_total: Map<ContractAddress, u256>,
        // ---- convictions ----
        next_conviction_id: Map<ContractAddress, u32>,
        convictions: Map<(ContractAddress, u32), Conviction>,
        conviction_voted_on: Map<(ContractAddress, u32, u256), bool>,
        // ---- proposals ----
        proposal_count: u256,
        proposals: Map<u256, FundingProposal>,
        proposal_score_counts: Map<(u256, u8), u256>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        SRC5Event: SRC5Component::Event,
        #[flat]
        ReentrancyGuardEvent: ReentrancyGuardComponent::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,
        AdminChanged: AdminChanged,
        SelectionSet: SelectionSet,
        GovernanceTokensMinted: GovernanceTokensMinted,
        ConvictionCreated: ConvictionCreated,
        ConvictionReleased: ConvictionReleased,
        SupportAdded: SupportAdded,
        ProposalCreated: ProposalCreated,
        ProposalExecuted: ProposalExecuted,
        ScoreRewardReleased: ScoreRewardReleased,
        ProposalDepositRefunded: ProposalDepositRefunded,
        ProposalDepositSlashed: ProposalDepositSlashed,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin: ContractAddress,
        token: ContractAddress,
        reputation_stake: u256,
        conviction_threshold: u256,
        reward_multiplier: u256,
        mini_reward_multiplier: u256,
    ) {
        assert(admin.is_non_zero(), 'ZeroAddress');
        assert(token.is_non_zero(), 'ZeroAddress');
        assert(reputation_stake > 0, 'ZeroAmount');
        assert(conviction_threshold > 0, 'ZeroAmount');
        assert(reward_multiplier > 0, 'ZeroAmount');
        assert(mini_reward_multiplier > 0, 'ZeroAmount');

        self.admin.write(admin);
        self.token.write(token);

        self.reputation_stake.write(reputation_stake);
        self.conviction_threshold.write(conviction_threshold);
        self.reward_multiplier.write(reward_multiplier);
        self.mini_reward_multiplier.write(mini_reward_multiplier);

        self.conviction_base_lock.write(DEFAULT_CONVICTION_BASE_LOCK);
        self.max_votes_per_conviction.write(DEFAULT_MAX_VOTES_PER_CONVICTION);
        self.proposal_voting_period.write(DEFAULT_PROPOSAL_VOTING_PERIOD);
    }

    // //////////////////////////////////////////////////////////////
    //                  EXTERNAL: IGovernance
    // //////////////////////////////////////////////////////////////

    #[abi(embed_v0)]
    impl GovernanceImpl of IGovernance<ContractState> {
        // ---- proposals / convictions ----

        fn create_proposal(
            ref self: ContractState, funding_wallet: ContractAddress, evidence: ByteArray,
        ) -> u256 {
            self.reentrancyguard.start();
            let caller = get_caller_address();
            assert(funding_wallet.is_non_zero(), 'ZeroAddress');
            assert(evidence.len() > 0, 'EvidenceRequired');
            assert(evidence.len() <= MAX_EVIDENCE_LEN, 'EvidenceTooLong');

            let deposit = self.reputation_stake.read();
            self._token().escrow(caller, deposit);

            let proposal_id = self.proposal_count.read();
            self.proposal_count.write(proposal_id + 1);

            let p = FundingProposal {
                author: caller,
                funding_wallet,
                evidence,
                created_at: get_block_timestamp(),
                executed: false,
                power_total: 0,
                deposit_amount: deposit,
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

            let level_u64: u64 = level.into();
            let lock_duration: u64 = level_u64 * self.conviction_base_lock.read();
            assert(lock_duration <= MAX_LOCK_DURATION, 'LockTooLong');

            let c = Conviction {
                owner: caller,
                id,
                level,
                amount,
                created_at: get_block_timestamp(),
                lock_duration,
                votes_cast: 0,
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
            assert(p.author != caller, 'SelfVotingNotAllowed');
            let mut c = self.convictions.entry((caller, conviction_id)).read();
            assert(c.owner == caller, 'Unauthorized');
            assert(!c.released, 'ConvictionReleased');
            let already = self
                .conviction_voted_on
                .entry((caller, conviction_id, proposal_id))
                .read();
            assert(!already, 'AlreadyVotedOnProposal');
            let lock_expiry = c.created_at + c.lock_duration;
            assert(get_block_timestamp() < lock_expiry, 'LockExpired');
            assert(c.votes_cast < self.max_votes_per_conviction.read(), 'MaxVotesReached');

            let weight = self._vote_weight(@c);

            let bucket: u8 = (score + 5).try_into().unwrap();
            let cur = self.proposal_score_counts.entry((proposal_id, bucket)).read();
            self.proposal_score_counts.entry((proposal_id, bucket)).write(cur + weight);

            let mut pm = self.proposals.entry(proposal_id).read();
            pm.power_total += weight;
            self.proposals.entry(proposal_id).write(pm);

            c.votes_cast += 1;
            self.convictions.entry((caller, conviction_id)).write(c);
            self.conviction_voted_on.entry((caller, conviction_id, proposal_id)).write(true);

            self.emit(SupportAdded { proposal_id, owner: caller, conviction_id });
            self.reentrancyguard.end();
        }

        fn release_conviction(ref self: ContractState, conviction_id: u32) {
            self.reentrancyguard.start();
            let caller = get_caller_address();
            let mut c = self.convictions.entry((caller, conviction_id)).read();
            assert(c.owner == caller, 'Unauthorized');
            assert(!c.released, 'AlreadyReleased');
            let lock_expiry = c.created_at + c.lock_duration;
            assert(get_block_timestamp() >= lock_expiry, 'LockNotExpired');

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

            let total_power = p.power_total;
            assert(total_power >= self.conviction_threshold.read(), 'ThresholdNotMet');

            let voting_period = self.proposal_voting_period.read();
            assert(get_block_timestamp() >= p.created_at + voting_period, 'VotingPeriodActive');

            let final_score = self._compute_weighted_score(proposal_id);
            p.final_score = final_score;
            p.final_score_set = true;
            p.executed = true;

            let funding_wallet = p.funding_wallet;
            let deposit_amount = p.deposit_amount;
            let author = p.author;
            self.proposals.entry(proposal_id).write(p);

            self.emit(ProposalExecuted { proposal_id, total_power, final_score });

            if final_score >= 0 {
                if deposit_amount > 0 {
                    self._token().release(author, deposit_amount);
                    self
                        .emit(
                            ProposalDepositRefunded {
                                proposal_id, requester: author, amount: deposit_amount,
                            },
                        );
                }

                let score_u256 = score_to_u256(final_score);
                let rm = self.reward_multiplier.read();
                let mrm = self.mini_reward_multiplier.read();
                let reward: u256 = if score_u256 <= 3 {
                    score_u256 * mrm
                } else {
                    score_u256 * rm
                };
                if reward > 0 && self._token().mint_from_budget(funding_wallet, reward) {
                    self
                        .emit(
                            ScoreRewardReleased {
                                proposal_id, recipient: funding_wallet, amount: reward,
                            },
                        );
                }
            } else {
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

        // ---- governance-token views ----

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

        fn get_conviction_power(
            self: @ContractState, owner: ContractAddress, conviction_id: u32,
        ) -> u256 {
            let c = self.convictions.entry((owner, conviction_id)).read();
            if c.votes_cast == 0 {
                0
            } else {
                self._vote_weight(@c)
            }
        }

        fn get_proposal_total_power(self: @ContractState, proposal_id: u256) -> u256 {
            let p = self.proposals.entry(proposal_id).read();
            p.power_total
        }

        fn get_conviction(self: @ContractState, owner: ContractAddress, id: u32) -> Conviction {
            self.convictions.entry((owner, id)).read()
        }

        fn get_proposal(self: @ContractState, proposal_id: u256) -> FundingProposal {
            self.proposals.entry(proposal_id).read()
        }

        // ---- selection-gated ----

        fn mint_governance_tokens(ref self: ContractState, holder: ContractAddress, amount: u256) {
            assert(get_caller_address() == self.selection.read(), 'NotSelection');
            if amount > 0 {
                self._mint_governance_tokens(holder, amount);
                self
                    .emit(
                        GovernanceTokensMinted {
                            evaluation_id: 0, candidate: holder, amount, final_score: 0,
                        },
                    );
            }
        }

        // ---- ADMIN - timelocked parameter changes (executed by AdminTimelock) ----

        fn execute_set_admin(ref self: ContractState, new_admin: ContractAddress) {
            self._assert_admin();
            assert(new_admin.is_non_zero(), 'ZeroAddress');
            self.admin.write(new_admin);
            self.emit(AdminChanged { new_admin });
        }

        fn execute_set_selection(ref self: ContractState, selection: ContractAddress) {
            self._assert_admin();
            self.selection.write(selection);
            self.emit(SelectionSet { selection });
        }

        fn get_admin(self: @ContractState) -> ContractAddress {
            self.admin.read()
        }

        fn get_selection(self: @ContractState) -> ContractAddress {
            self.selection.read()
        }

        // ---- parameter views ----

        fn get_conviction_threshold(self: @ContractState) -> u256 {
            self.conviction_threshold.read()
        }

        fn get_reputation_stake(self: @ContractState) -> u256 {
            self.reputation_stake.read()
        }

        fn get_reward_multiplier(self: @ContractState) -> u256 {
            self.reward_multiplier.read()
        }

        fn get_mini_reward_multiplier(self: @ContractState) -> u256 {
            self.mini_reward_multiplier.read()
        }

        fn get_conviction_base_lock(self: @ContractState) -> u64 {
            self.conviction_base_lock.read()
        }

        fn get_max_votes_per_conviction(self: @ContractState) -> u64 {
            self.max_votes_per_conviction.read()
        }

        fn get_proposal_voting_period(self: @ContractState) -> u64 {
            self.proposal_voting_period.read()
        }

        fn execute_set_reputation_stake(ref self: ContractState, amount: u256) {
            self._assert_admin();
            assert(amount > 0, 'ZeroAmount');
            assert(amount <= MAX_SUPPLY, 'TooHigh');
            self.reputation_stake.write(amount);
        }

        fn execute_set_conviction_threshold(ref self: ContractState, amount: u256) {
            self._assert_admin();
            assert(amount > 0, 'ZeroAmount');
            assert(amount <= MAX_SUPPLY, 'TooHigh');
            self.conviction_threshold.write(amount);
        }

        fn execute_set_reward_multiplier(ref self: ContractState, amount: u256) {
            self._assert_admin();
            assert(amount > 0, 'ZeroAmount');
            assert(amount <= MAX_SUPPLY, 'TooHigh');
            self.reward_multiplier.write(amount);
        }

        fn execute_set_mini_reward_multiplier(ref self: ContractState, amount: u256) {
            self._assert_admin();
            assert(amount > 0, 'ZeroAmount');
            assert(amount <= MAX_SUPPLY, 'TooHigh');
            self.mini_reward_multiplier.write(amount);
        }

        fn execute_set_conviction_base_lock(ref self: ContractState, duration: u64) {
            self._assert_admin();
            self.conviction_base_lock.write(duration);
        }

        fn execute_set_max_votes_per_conviction(ref self: ContractState, count: u64) {
            self._assert_admin();
            self.max_votes_per_conviction.write(count);
        }

        fn execute_set_proposal_voting_period(ref self: ContractState, period: u64) {
            self._assert_admin();
            self.proposal_voting_period.write(period);
        }
    }

    // //////////////////////////////////////////////////////////////
    //                  EXTERNAL: IUpgradeableModule
    // //////////////////////////////////////////////////////////////

    #[abi(embed_v0)]
    impl UpgradeableModuleImpl of IUpgradeableModule<ContractState> {
        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            self._assert_admin();
            assert(!self.upgrades_disabled.read(), 'UpgradesDisabledForever');
            self.upgradeable.upgrade(new_class_hash);
        }

        fn disable_upgrades(ref self: ContractState) {
            self._assert_admin();
            assert(!self.upgrades_disabled.read(), 'AlreadyDisabled');
            self.upgrades_disabled.write(true);
        }

        fn is_upgrades_disabled(self: @ContractState) -> bool {
            self.upgrades_disabled.read()
        }
    }

    // //////////////////////////////////////////////////////////////
    //                        INTERNAL HELPERS
    // //////////////////////////////////////////////////////////////

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn _token(self: @ContractState) -> IConvictionTokenDispatcher {
            IConvictionTokenDispatcher { contract_address: self.token.read() }
        }

        fn _assert_admin(self: @ContractState) {
            assert(get_caller_address() == self.admin.read(), 'NotAdmin');
        }

        /// Adds a non-transferable governance grant using the first reusable
        /// fully decayed slot, then an unused slot, or finally the most-decayed
        /// slot when the per-holder cap is reached.
        fn _mint_governance_tokens(ref self: ContractState, holder: ContractAddress, amount: u256) {
            let count = self.governance_next_grant.entry(holder).read();
            let slot = self._next_free_grant_slot(holder);
            if slot < count {
                self
                    .governance_grant
                    .entry((holder, slot))
                    .write(Grant { amount, minted_at: get_block_timestamp() });
            } else if count < MAX_GOV_GRANTS_PER_HOLDER {
                self.governance_next_grant.entry(holder).write(count + 1);
                self
                    .governance_grant
                    .entry((holder, count))
                    .write(Grant { amount, minted_at: get_block_timestamp() });
            } else {
                self._overwrite_most_decayed_grant(holder, amount);
            }
        }

        fn _next_free_grant_slot(self: @ContractState, holder: ContractAddress) -> u32 {
            let count = self.governance_next_grant.entry(holder).read();
            let mut i: u32 = 0;
            loop {
                if i >= count {
                    break;
                }
                let g = self.governance_grant.entry((holder, i)).read();
                if self._decayed_grant_amount(@g) == 0 {
                    return i;
                }
                i += 1;
            }
            count
        }

        fn _overwrite_most_decayed_grant(
            ref self: ContractState, holder: ContractAddress, amount: u256,
        ) {
            let count = self.governance_next_grant.entry(holder).read();
            let g0 = self.governance_grant.entry((holder, 0)).read();
            let mut target: u32 = 0;
            let mut min_remaining: u256 = self._decayed_grant_amount(@g0);
            let mut i: u32 = 1;
            loop {
                if i >= count {
                    break;
                }
                let g = self.governance_grant.entry((holder, i)).read();
                let remaining = self._decayed_grant_amount(@g);
                if remaining < min_remaining {
                    min_remaining = remaining;
                    target = i;
                }
                i += 1;
            }
            self
                .governance_grant
                .entry((holder, target))
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
            }
            total
        }

        fn _vote_weight(self: @ContractState, c: @Conviction) -> u256 {
            let level_u256: u256 = (*c.level).into();
            let amount_u256: u256 = (*c.amount).into();
            isqrt(level_u256 * amount_u256)
        }

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
            }

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
    }
}
