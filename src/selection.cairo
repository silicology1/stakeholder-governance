// SPDX-License-Identifier: MIT
//! Selection
//! =========
//! Reworked juror selection and dispute lifecycle.
//!
//! Key change from legacy Kleros code: juror stakes are represented by
//! stake IDs. Each evaluation ID has its own Fenwick tree. Jurors apply
//! stake IDs to evaluation IDs during an applying phase, then jurors are
//! drawn stake-weighted via VRF, followed by commit/reveal voting.

#[starknet::contract]
pub mod Selection {
    use cartridge_vrf::Source;
    use cartridge_vrf::vrf_consumer::vrf_consumer_component::VrfConsumerComponent;
    use core::array::ArrayTrait;
    use core::num::traits::Zero;
    use core::poseidon::poseidon_hash_span;
    use openzeppelin_introspection::src5::SRC5Component;
    use openzeppelin_security::reentrancyguard::ReentrancyGuardComponent;
    use openzeppelin_upgrades::upgradeable::UpgradeableComponent;
    use starknet::storage::{
        Map, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::syscalls::get_block_hash_syscall;
    use starknet::{
        ClassHash, ContractAddress, get_block_number, get_block_timestamp, get_caller_address,
        get_contract_address,
    };
    use crate::constants::*;
    use crate::events::*;
    use crate::interfaces::iconviction_token::{
        IConvictionTokenDispatcher, IConvictionTokenDispatcherTrait,
    };
    use crate::interfaces::igovernance::{IGovernanceDispatcher, IGovernanceDispatcherTrait};
    use crate::interfaces::iselection::ISelection;
    use crate::interfaces::iupgradeable_module::IUpgradeableModule;
    use crate::types::*;
    use crate::utils::{
        derive_draw_random, governance_tokens_for_score, isqrt, lowbit, round_scaled, score_to_i64,
    };

    component!(path: SRC5Component, storage: src5, event: SRC5Event);
    component!(
        path: ReentrancyGuardComponent, storage: reentrancyguard, event: ReentrancyGuardEvent,
    );
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);
    component!(path: VrfConsumerComponent, storage: vrf_consumer, event: VrfConsumerEvent);

    impl SRC5InternalImpl = SRC5Component::InternalImpl<ContractState>;
    #[abi(embed_v0)]
    impl SRC5Impl = SRC5Component::SRC5Impl<ContractState>;
    impl ReentrancyGuardInternalImpl = ReentrancyGuardComponent::InternalImpl<ContractState>;
    impl UpgradeableInternalImpl = UpgradeableComponent::InternalImpl<ContractState>;

    #[abi(embed_v0)]
    impl VrfConsumerImpl = VrfConsumerComponent::VrfConsumerImpl<ContractState>;
    impl VrfConsumerInternalImpl = VrfConsumerComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        #[substorage(v0)]
        reentrancyguard: ReentrancyGuardComponent::Storage,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,
        #[substorage(v0)]
        vrf_consumer: VrfConsumerComponent::Storage,
        admin: ContractAddress,
        token: ContractAddress,
        governance: ContractAddress,
        upgrades_disabled: bool,
        commit_duration: u64,
        reveal_duration: u64,
        non_reveal_slash_bps: u16,
        incoherence_slash_bps: u16,
        coherence_band: u8,
        evaluation_bond_amount: u256,
        evaluation_cooldown: u64,
        applying_duration: u64,
        min_stake_ids_per_evaluation: u32,
        min_jurors_per_evaluation: u32,
        max_evaluations_per_stake: u32,
        juror_reward_amount: u256,
        drawing_duration: u64,
        min_stake_amount: u256,
        stake_count: u256,
        stakes: Map<u256, Stake>,
        juror_stake_ids: Map<(ContractAddress, u32), u256>,
        juror_stake_count: Map<ContractAddress, u32>,
        stake_evaluation_count: Map<u256, u32>,
        stake_finalized_count: Map<u256, u32>,
        stake_applied_to_eval: Map<(u256, u256), bool>,
        evaluation_count: u256,
        evaluations: Map<u256, Evaluation>,
        evaluation_fenwick: Map<(u256, u32), u256>,
        evaluation_stake_to_index: Map<(u256, u256), u32>,
        evaluation_index_to_stake: Map<(u256, u32), u256>,
        evaluation_next_index: Map<u256, u32>,
        evaluation_applied_stakes: Map<(u256, u32), u256>,
        evaluation_applied_count: Map<u256, u32>,
        evaluation_applied_slot: Map<(u256, u256), u32>,
        evaluation_drawn_stakes: Map<(u256, u32), u256>,
        evaluation_draw_index: Map<u256, u32>,
        evaluation_is_drawn: Map<(u256, u256), bool>,
        evaluation_commit: Map<(u256, u256), felt252>,
        evaluation_committed: Map<(u256, u256), bool>,
        evaluation_revealed: Map<(u256, u256), bool>,
        evaluation_score: Map<(u256, u256), i8>,
        evaluation_coherent: Map<(u256, u256), bool>,
        evaluation_slashed: Map<(u256, u256), bool>,
        evaluation_reward_claimed: Map<(u256, u256), bool>,
        evaluation_juror_reward: Map<(u256, u256), u256>,
        stake_slashed_total: Map<(u256, u256), u256>,
        evaluation_evidence: Map<u256, ByteArray>,
        has_active_evaluation: Map<ContractAddress, bool>,
        active_evaluation_for_candidate: Map<ContractAddress, u256>,
        last_evaluation_finalized: Map<ContractAddress, u64>,
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
        #[flat]
        VrfConsumerEvent: VrfConsumerComponent::Event,
        AdminChanged: AdminChanged,
        Staked: Staked,
        Unstaked: Unstaked,
        StakeCreated: StakeCreated,
        StakeUnstaked: StakeUnstaked,
        StakeApplied: StakeApplied,
        StakeRemoved: StakeRemoved,
        EvaluationRequested: EvaluationRequested,
        EvaluationAdvanced: EvaluationAdvanced,
        EvaluationDismissed: EvaluationDismissed,
        JurorDrawn: JurorDrawn,
        VoteCommitted: VoteCommitted,
        VoteRevealed: VoteRevealed,
        JurorSlashed: JurorSlashed,
        IncoherentJurorSlashed: IncoherentJurorSlashed,
        SlashKeeperRewarded: SlashKeeperRewarded,
        DisputeFinalized: DisputeFinalized,
        JurorRewardClaimed: JurorRewardClaimed,
        GovernanceTokensMinted: GovernanceTokensMinted,
        BondRefunded: BondRefunded,
        BondSlashed: BondSlashed,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin: ContractAddress,
        token: ContractAddress,
        governance: ContractAddress,
        vrf_provider: ContractAddress,
        evaluation_bond_amount: u256,
    ) {
        assert(admin.is_non_zero(), 'ZeroAddress');
        assert(token.is_non_zero(), 'ZeroAddress');
        assert(governance.is_non_zero(), 'ZeroAddress');
        assert(vrf_provider.is_non_zero(), 'ZeroAddress');
        assert(evaluation_bond_amount > 0, 'ZeroAmount');

        self.admin.write(admin);
        self.token.write(token);
        self.governance.write(governance);

        self.vrf_consumer.initializer(vrf_provider);

        self.commit_duration.write(DEFAULT_COMMIT_DURATION);
        self.reveal_duration.write(DEFAULT_REVEAL_DURATION);
        self.non_reveal_slash_bps.write(DEFAULT_SLASH_BPS);
        self.incoherence_slash_bps.write(DEFAULT_INCOHERENCE_SLASH_BPS);
        self.coherence_band.write(DEFAULT_COHERENCE_BAND);
        self.evaluation_cooldown.write(DEFAULT_EVALUATION_COOLDOWN);
        self.evaluation_bond_amount.write(evaluation_bond_amount);

        self.applying_duration.write(DEFAULT_APPLYING_DURATION);
        self.min_stake_ids_per_evaluation.write(DEFAULT_MIN_STAKE_IDS);
        self.min_jurors_per_evaluation.write(DEFAULT_MIN_JURORS);
        self.max_evaluations_per_stake.write(DEFAULT_MAX_EVALUATIONS_PER_STAKE);
        self.juror_reward_amount.write(DEFAULT_JUROR_REWARD_AMOUNT);
        self.drawing_duration.write(DEFAULT_DRAWING_DURATION);
        self.min_stake_amount.write(DEFAULT_MIN_STAKE_AMOUNT);
    }

    #[abi(embed_v0)]
    impl SelectionImpl of ISelection<ContractState> {
        // ---- stake management ----

        fn create_stake(ref self: ContractState, amount: u256) -> u256 {
            self.reentrancyguard.start();
            assert(amount > 0, 'ZeroAmount');
            assert(amount >= self.min_stake_amount.read(), 'BelowMinStake');
            let caller = get_caller_address();

            self._token().escrow(caller, amount);

            let stake_id = self.stake_count.read();
            self.stake_count.write(stake_id + 1);

            let stake = Stake {
                owner: caller, amount, created_at: get_block_timestamp(), retired: false,
            };
            self.stakes.entry(stake_id).write(stake);

            let stake_count = self.juror_stake_count.entry(caller).read();
            self.juror_stake_ids.entry((caller, stake_count)).write(stake_id);
            self.juror_stake_count.entry(caller).write(stake_count + 1);

            self.emit(StakeCreated { stake_id, owner: caller, amount });

            self.reentrancyguard.end();
            stake_id
        }

        fn unstake_stake(ref self: ContractState, stake_id: u256, amount: u256) {
            self.reentrancyguard.start();
            assert(amount > 0, 'ZeroAmount');
            let caller = get_caller_address();

            let stake = self.stakes.entry(stake_id).read();
            assert(stake.owner == caller, 'NotStakeOwner');
            assert(stake.amount >= amount, 'InsufficientStake');

            let active_evals = self.stake_evaluation_count.entry(stake_id).read();
            assert(active_evals == 0, 'StakeLocked');

            let new_amount = stake.amount - amount;
            let fully_unstaked = new_amount == 0;
            self
                .stakes
                .entry(stake_id)
                .write(
                    Stake {
                        owner: stake.owner,
                        amount: new_amount,
                        created_at: stake.created_at,
                        retired: fully_unstaked || stake.retired,
                    },
                );

            self._token().release(caller, amount);

            self.emit(StakeUnstaked { stake_id, owner: caller, amount, new_total: new_amount });
            self.reentrancyguard.end();
        }

        // ---- evaluation lifecycle ----

        fn request_evaluation(ref self: ContractState, evidence: ByteArray) -> u256 {
            self.reentrancyguard.start();
            assert(evidence.len() > 0, 'EvidenceRequired');
            assert(evidence.len() <= MAX_EVIDENCE_LEN, 'EvidenceTooLong');

            let candidate = get_caller_address();
            assert(!self.has_active_evaluation.entry(candidate).read(), 'AlreadyUnderEvaluation');

            let last_evaluation = self.last_evaluation_finalized.entry(candidate).read();
            if last_evaluation != 0 {
                let cooldown = self.evaluation_cooldown.read();
                assert(get_block_timestamp() >= last_evaluation + cooldown, 'EvaluationCooldown');
            }

            let bond_amount = self.evaluation_bond_amount.read();
            self._token().escrow(candidate, bond_amount);

            let evaluation_id = self.evaluation_count.read();
            self.evaluation_count.write(evaluation_id + 1);

            let now = get_block_timestamp();
            let apply_deadline = now + self.applying_duration.read();

            let evaluation = Evaluation {
                candidate,
                requester: candidate,
                bond_amount,
                phase: PHASE_APPLYING,
                apply_deadline,
                draw_deadline: 0,
                commit_deadline: 0,
                reveal_deadline: 0,
                applied_count: 0,
                drawn_count: 0,
                min_jurors: self.min_jurors_per_evaluation.read(),
                final_score: 0,
                final_score_set: false,
                slash_pool: 0,
                governance_tokens_minted: 0,
                bond_settled: false,
            };
            self.evaluations.entry(evaluation_id).write(evaluation);
            self.evaluation_evidence.entry(evaluation_id).write(evidence);
            self.has_active_evaluation.entry(candidate).write(true);
            self.active_evaluation_for_candidate.entry(candidate).write(evaluation_id);

            self.emit(EvaluationRequested { evaluation_id, candidate, bond_amount });

            self.reentrancyguard.end();
            evaluation_id
        }

        fn apply_to_evaluation(ref self: ContractState, evaluation_id: u256, stake_id: u256) {
            self.reentrancyguard.start();
            let caller = get_caller_address();

            let mut e = self.evaluations.entry(evaluation_id).read();
            assert(e.phase == PHASE_APPLYING, 'NotApplyingPhase');
            assert(get_block_timestamp() < e.apply_deadline, 'ApplyClosed');

            let stake = self.stakes.entry(stake_id).read();
            assert(stake.owner == caller, 'NotStakeOwner');
            assert(!stake.retired, 'StakeRetired');

            let current_evals = self.stake_evaluation_count.entry(stake_id).read();
            let max_evals = self.max_evaluations_per_stake.read();
            assert(
                !self.stake_applied_to_eval.entry((stake_id, evaluation_id)).read(),
                'AlreadyApplied',
            );
            // lifetime cap: finalized participations are never freed, so the
            // combined count bounds all finalized evaluations ever entered
            let finalized_total = self.stake_finalized_count.entry(stake_id).read();
            assert(
                finalized_total + current_evals < max_evals,
                'StakeFinalizedLimitReached',
            );

            let next_idx = self.evaluation_next_index.entry(evaluation_id).read();
            assert(next_idx < EVAL_FENWICK_SIZE, 'EvaluationCapacityExceeded');
            let fenwick_index = next_idx + 1;
            self.evaluation_next_index.entry(evaluation_id).write(fenwick_index);

            self._fenwick_add_eval(evaluation_id, fenwick_index, stake.amount);

            self.evaluation_stake_to_index.entry((evaluation_id, stake_id)).write(fenwick_index);
            self.evaluation_index_to_stake.entry((evaluation_id, fenwick_index)).write(stake_id);
            self.evaluation_applied_stakes.entry((evaluation_id, e.applied_count)).write(stake_id);
            self.evaluation_applied_slot.entry((evaluation_id, stake_id)).write(e.applied_count);
            e.applied_count += 1;

            self.stake_applied_to_eval.entry((stake_id, evaluation_id)).write(true);
            let new_count = current_evals + 1;
            self.stake_evaluation_count.entry(stake_id).write(new_count);

            self.evaluations.entry(evaluation_id).write(e);
            self.evaluation_applied_count.entry(evaluation_id).write(e.applied_count);

            self.emit(StakeApplied { evaluation_id, stake_id, owner: caller });

            self.reentrancyguard.end();
        }

        fn remove_from_evaluation(ref self: ContractState, evaluation_id: u256, stake_id: u256) {
            self.reentrancyguard.start();
            let caller = get_caller_address();

            let mut e = self.evaluations.entry(evaluation_id).read();
            assert(
                e.phase == PHASE_APPLYING
                || e.phase == PHASE_COMMIT
                || e.phase == PHASE_DISMISSED
                || e.phase == PHASE_FINALIZED,
                'WrongPhaseForRemoval',
            );

            let stake = self.stakes.entry(stake_id).read();
            assert(stake.owner == caller, 'NotStakeOwner');

            assert(
                self.stake_applied_to_eval.entry((stake_id, evaluation_id)).read(), 'NotApplied',
            );

            if e.phase == PHASE_COMMIT {
                assert(
                    !self.evaluation_is_drawn.entry((evaluation_id, stake_id)).read(),
                    'StakeDrawn',
                );
            }

            let fenwick_index = self
                .evaluation_stake_to_index
                .entry((evaluation_id, stake_id))
                .read();
            if fenwick_index != 0 {
                self._fenwick_sub_eval(evaluation_id, fenwick_index, stake.amount);
                self.evaluation_stake_to_index.entry((evaluation_id, stake_id)).write(0);
                self.evaluation_index_to_stake.entry((evaluation_id, fenwick_index)).write(0);
            }

            let applied_count = e.applied_count;
            let slot = self.evaluation_applied_slot.entry((evaluation_id, stake_id)).read();
            assert(slot < applied_count, 'StakeNotInAppliedList');
            let sid = self.evaluation_applied_stakes.entry((evaluation_id, slot)).read();
            assert(sid == stake_id, 'StakeNotInAppliedList');

            let last_idx = applied_count - 1;
            if slot != last_idx {
                let last_sid = self.evaluation_applied_stakes.entry((evaluation_id, last_idx)).read();
                self.evaluation_applied_stakes.entry((evaluation_id, slot)).write(last_sid);
                // keep the moved stake's slot map entry in sync with its new position
                self.evaluation_applied_slot.entry((evaluation_id, last_sid)).write(slot);
            }
            self.evaluation_applied_stakes.entry((evaluation_id, last_idx)).write(0);
            self.evaluation_applied_slot.entry((evaluation_id, stake_id)).write(0);

            e.applied_count = applied_count - 1;
            self.evaluations.entry(evaluation_id).write(e);
            self.evaluation_applied_count.entry(evaluation_id).write(e.applied_count);

            self.stake_applied_to_eval.entry((stake_id, evaluation_id)).write(false);
            let current_count = self.stake_evaluation_count.entry(stake_id).read();
            assert(current_count > 0, 'CountUnderflow');
            self.stake_evaluation_count.entry(stake_id).write(current_count - 1);

            // finalized participation counts against the stake's lifetime cap
            if e.phase == PHASE_FINALIZED {
                let finalized_total = self.stake_finalized_count.entry(stake_id).read();
                self.stake_finalized_count.entry(stake_id).write(finalized_total + 1);
            }

            self.emit(StakeRemoved { evaluation_id, stake_id, owner: caller });

            self.reentrancyguard.end();
        }

        fn advance_evaluation(ref self: ContractState, evaluation_id: u256) {
            self.reentrancyguard.start();
            let now = get_block_timestamp();

            let mut e = self.evaluations.entry(evaluation_id).read();

            if e.phase == PHASE_APPLYING {
                if now < e.apply_deadline {
                    self.reentrancyguard.end();
                    return;
                }
                if e.applied_count >= self.min_stake_ids_per_evaluation.read() {
                    e.phase = PHASE_DRAWING;
                    e.draw_deadline = now + self.drawing_duration.read();
                    self.evaluations.entry(evaluation_id).write(e);
                    self.emit(EvaluationAdvanced { evaluation_id, phase: PHASE_DRAWING });
                } else {
                    e.apply_deadline = now + self.applying_duration.read();
                    self.evaluations.entry(evaluation_id).write(e);
                    self.emit(EvaluationAdvanced { evaluation_id, phase: PHASE_APPLYING });
                }
            } else if e.phase == PHASE_DRAWING {
                if now < e.draw_deadline {
                    self.reentrancyguard.end();
                    return;
                }
                let min_jurors = self.min_jurors_per_evaluation.read();
                if e.drawn_count >= min_jurors {
                    e.phase = PHASE_COMMIT;
                    e.commit_deadline = now + self.commit_duration.read();
                    self.evaluations.entry(evaluation_id).write(e);
                    self.emit(EvaluationAdvanced { evaluation_id, phase: PHASE_COMMIT });
                } else {
                    e.phase = PHASE_DISMISSED;
                    assert(!e.bond_settled, 'BondAlreadySettled');
                    e.bond_settled = true;
                    self.evaluations.entry(evaluation_id).write(e);
                    self.emit(EvaluationDismissed { evaluation_id, candidate: e.candidate });

                    self.has_active_evaluation.entry(e.requester).write(false);
                    self.active_evaluation_for_candidate.entry(e.requester).write(0);
                    self.last_evaluation_finalized.entry(e.requester).write(now);

                    if e.bond_amount > 0 && e.requester.is_non_zero() {
                        self._token().release(e.requester, e.bond_amount);
                        self
                            .emit(
                                BondRefunded {
                                    evaluation_id, requester: e.requester, amount: e.bond_amount,
                                },
                            );
                    }
                }
            } else if e.phase == PHASE_COMMIT {
                if now < e.commit_deadline {
                    self.reentrancyguard.end();
                    return;
                }
                e.phase = PHASE_REVEAL;
                e.reveal_deadline = now + self.reveal_duration.read();
                self.evaluations.entry(evaluation_id).write(e);
                self.emit(EvaluationAdvanced { evaluation_id, phase: PHASE_REVEAL });
            } else if e.phase == PHASE_REVEAL {
                if now < e.reveal_deadline {
                    self.reentrancyguard.end();
                    return;
                }
            }
            self.reentrancyguard.end();
        }

        fn draw_jurors(ref self: ContractState, evaluation_id: u256) {
            self.reentrancyguard.start();
            let mut e = self.evaluations.entry(evaluation_id).read();
            assert(e.phase == PHASE_DRAWING, 'NotDrawingPhase');

            let min_jurors = self.min_jurors_per_evaluation.read();

            let vrf_seed: felt252 = self
                .vrf_consumer
                .consume_random(Source::Nonce(get_contract_address()));
            let block_hash = self._recent_block_hash();

            let mut seed_input: Array<felt252> = ArrayTrait::new();
            seed_input.append(vrf_seed);
            seed_input.append(block_hash);
            let base_seed: felt252 = poseidon_hash_span(seed_input.span());

            let mut drawn: u32 = e.drawn_count;
            let mut draw_idx: u32 = self.evaluation_draw_index.entry(evaluation_id).read();

            loop {
                if drawn >= min_jurors {
                    break;
                }

                let total_weight = self._fenwick_total_eval(evaluation_id);
                if total_weight == 0 {
                    break;
                }

                let rand_felt = derive_draw_random(base_seed, evaluation_id, draw_idx);
                let rand_u256: u256 = rand_felt.try_into().unwrap_or(0);
                let target = rand_u256 % total_weight;

                let index = self._fenwick_find_eval(evaluation_id, target);
                let stake_id = self.evaluation_index_to_stake.entry((evaluation_id, index)).read();

                if stake_id == 0 {
                    draw_idx += 1;
                    continue;
                }

                let stake = self.stakes.entry(stake_id).read();
                let owner = stake.owner;

                self._fenwick_sub_eval(evaluation_id, index, stake.amount);
                self.evaluation_stake_to_index.entry((evaluation_id, stake_id)).write(0);
                self.evaluation_index_to_stake.entry((evaluation_id, index)).write(0);

                self.evaluation_drawn_stakes.entry((evaluation_id, drawn)).write(stake_id);
                self.evaluation_is_drawn.entry((evaluation_id, stake_id)).write(true);
                drawn += 1;

                self
                    .emit(
                        JurorDrawn { evaluation_id, stake_id, juror: owner, draw_index: draw_idx },
                    );
                draw_idx += 1;
            }

            e.drawn_count = drawn;
            self.evaluations.entry(evaluation_id).write(e);
            self.evaluation_draw_index.entry(evaluation_id).write(draw_idx);

            if drawn >= min_jurors {
                e.phase = PHASE_COMMIT;
                let now = get_block_timestamp();
                e.commit_deadline = now + self.commit_duration.read();
                self.evaluations.entry(evaluation_id).write(e);
                self.emit(EvaluationAdvanced { evaluation_id, phase: PHASE_COMMIT });
            }

            self.reentrancyguard.end();
        }

        fn commit_vote(
            ref self: ContractState, evaluation_id: u256, stake_id: u256, commit_hash: felt252,
        ) {
            self.reentrancyguard.start();
            let caller = get_caller_address();
            let e = self.evaluations.entry(evaluation_id).read();
            assert(e.phase == PHASE_COMMIT, 'NotCommitPhase');
            assert(get_block_timestamp() < e.commit_deadline, 'CommitClosed');

            let stake = self.stakes.entry(stake_id).read();
            assert(stake.owner == caller, 'NotStakeOwner');
            assert(
                self._is_stake_drawn(evaluation_id, stake_id),
                'NotDrawnStake',
            );
            assert(
                !self.evaluation_committed.entry((evaluation_id, stake_id)).read(),
                'AlreadyCommitted',
            );

            self.evaluation_commit.entry((evaluation_id, stake_id)).write(commit_hash);
            self.evaluation_committed.entry((evaluation_id, stake_id)).write(true);

            self.emit(VoteCommitted { evaluation_id, juror: caller });
            self.reentrancyguard.end();
        }

        fn reveal_vote(
            ref self: ContractState, evaluation_id: u256, stake_id: u256, score: i8, salt: felt252,
        ) {
            self.reentrancyguard.start();
            let caller = get_caller_address();
            let mut e = self.evaluations.entry(evaluation_id).read();
            assert(get_block_timestamp() >= e.commit_deadline, 'CommitStillOpen');
            assert(get_block_timestamp() < e.reveal_deadline, 'RevealClosed');
            assert(score >= -5 && score <= 5, 'InvalidScore');

            let stake = self.stakes.entry(stake_id).read();
            assert(stake.owner == caller, 'NotStakeOwner');
            assert(
                self._is_stake_drawn(evaluation_id, stake_id),
                'NotDrawnStake',
            );
            assert(self.evaluation_committed.entry((evaluation_id, stake_id)).read(), 'NoCommit');
            assert(
                !self.evaluation_revealed.entry((evaluation_id, stake_id)).read(),
                'AlreadyRevealed',
            );

            let mut hash_input: Array<felt252> = ArrayTrait::new();
            hash_input.append(score.try_into().unwrap_or(0));
            hash_input.append(salt);
            let computed = poseidon_hash_span(hash_input.span());
            let stored = self.evaluation_commit.entry((evaluation_id, stake_id)).read();
            assert(computed == stored, 'HashMismatch');

            self.evaluation_score.entry((evaluation_id, stake_id)).write(score);
            self.evaluation_revealed.entry((evaluation_id, stake_id)).write(true);

            self.emit(VoteRevealed { evaluation_id, juror: caller, score });
            self.reentrancyguard.end();
        }

        fn slash_non_revealer(ref self: ContractState, evaluation_id: u256, stake_id: u256) {
            self.reentrancyguard.start();
            let e = self.evaluations.entry(evaluation_id).read();
            assert(
                e.phase == PHASE_REVEAL || e.phase == PHASE_FINALIZED,
                'WrongPhaseForSlash',
            );
            assert(e.reveal_deadline != 0, 'RevealNotStarted');
            assert(get_block_timestamp() >= e.reveal_deadline, 'RevealStillOpen');

            assert(
                self._is_stake_drawn(evaluation_id, stake_id),
                'NotDrawnStake',
            );
            assert(!self.evaluation_revealed.entry((evaluation_id, stake_id)).read(), 'DidReveal');
            assert(
                !self.evaluation_slashed.entry((evaluation_id, stake_id)).read(), 'AlreadySlashed',
            );

            let stake = self.stakes.entry(stake_id).read();
            let owner = stake.owner;
            let bps: u256 = self.non_reveal_slash_bps.read().try_into().unwrap_or(0);
            let slash_amount = stake.amount * bps / BPS_DENOM;

            if slash_amount > 0 {
                self._apply_stake_slash(stake_id, slash_amount);

                let mut dm = self.evaluations.entry(evaluation_id).read();
                dm.slash_pool += slash_amount;
                self.evaluations.entry(evaluation_id).write(dm);

                self.stake_slashed_total.entry((stake_id, evaluation_id)).write(slash_amount);
            }

            self.evaluation_slashed.entry((evaluation_id, stake_id)).write(true);

            self.emit(JurorSlashed { evaluation_id, juror: owner, amount: slash_amount });

            let caller = get_caller_address();
            if caller != owner
                && SLASH_KEEPER_REWARD > 0
                && self._token().mint_from_budget(caller, SLASH_KEEPER_REWARD) {
                self
                    .emit(
                        SlashKeeperRewarded {
                            caller, juror: owner, evaluation_id, reward: SLASH_KEEPER_REWARD,
                        },
                    );
            }

            self.reentrancyguard.end();
        }

        fn finalize_evaluation(ref self: ContractState, evaluation_id: u256) {
            self.reentrancyguard.start();
            let mut e = self.evaluations.entry(evaluation_id).read();
            assert(!e.final_score_set, 'AlreadyFinalized');
            assert(e.phase == PHASE_REVEAL, 'NotRevealPhase');
            assert(get_block_timestamp() >= e.reveal_deadline, 'RevealStillOpen');

            let drawn_count = e.drawn_count;
            let coherence_band: i64 = self.coherence_band.read().try_into().unwrap_or(1);

            let mut sum_weighted: i64 = 0;
            let mut total_weight: u32 = 0;
            let mut i: u32 = 0;
            loop {
                if i >= drawn_count {
                    break;
                }
                let stake_id = self.evaluation_drawn_stakes.entry((evaluation_id, i)).read();
                if self.evaluation_revealed.entry((evaluation_id, stake_id)).read() {
                    let score = self.evaluation_score.entry((evaluation_id, stake_id)).read();
                    let score_i64 = score_to_i64(score);
                    sum_weighted += score_i64 * SCALE;
                    total_weight += 1;
                }
                i += 1;
            }

            if total_weight == 0 {
                e.final_score = 0;
                e.final_score_set = true;
                e.phase = PHASE_FINALIZED;
                e.bond_settled = true;

                let requester = e.requester;
                let bond_to_refund = e.bond_amount;
                self.evaluations.entry(evaluation_id).write(e);

                if requester.is_non_zero() {
                    self.has_active_evaluation.entry(requester).write(false);
                    self.active_evaluation_for_candidate.entry(requester).write(0);
                    self.last_evaluation_finalized.entry(requester).write(get_block_timestamp());
                }
                if bond_to_refund > 0 {
                    self._token().release(requester, bond_to_refund);
                    self.emit(BondRefunded { evaluation_id, requester, amount: bond_to_refund });
                }

                self
                    .emit(
                        DisputeFinalized { evaluation_id, candidate: e.candidate, final_score: 0 },
                    );
                self.reentrancyguard.end();
                return;
            }

            let total_weight_i64: i64 = total_weight.try_into().unwrap_or(0);
            let mean_scaled: i64 = sum_weighted / total_weight_i64;

            let mut sum_sq: u64 = 0;
            i = 0;
            loop {
                if i >= drawn_count {
                    break;
                }
                let stake_id = self.evaluation_drawn_stakes.entry((evaluation_id, i)).read();
                if self.evaluation_revealed.entry((evaluation_id, stake_id)).read() {
                    let score = self.evaluation_score.entry((evaluation_id, stake_id)).read();
                    let score_i64 = score_to_i64(score);
                    let diff = score_i64 * SCALE - mean_scaled;
                    let diff_sq: i64 = diff * diff;
                    let diff_sq_u64: u64 = diff_sq.try_into().unwrap_or(0);
                    sum_sq += diff_sq_u64;
                }
                i += 1;
            }
            let variance_scaled: u64 = sum_sq / total_weight.try_into().unwrap_or(1);
            let stdev_scaled_u256: u256 = isqrt(variance_scaled.try_into().unwrap_or(0));
            let stdev_scaled: u64 = stdev_scaled_u256.try_into().unwrap_or(0);

            let mut sum_filtered: i64 = 0;
            let mut filtered_weight: u32 = 0;
            i = 0;
            loop {
                if i >= drawn_count {
                    break;
                }
                let stake_id = self.evaluation_drawn_stakes.entry((evaluation_id, i)).read();
                if self.evaluation_revealed.entry((evaluation_id, stake_id)).read() {
                    let score = self.evaluation_score.entry((evaluation_id, stake_id)).read();
                    let score_i64 = score_to_i64(score);
                    let diff = score_i64 * SCALE - mean_scaled;
                    let abs_diff = if diff < 0 {
                        -diff
                    } else {
                        diff
                    };
                    let stdev_scaled_i64: i64 = stdev_scaled.try_into().unwrap_or(0);
                    if abs_diff <= stdev_scaled_i64 {
                        sum_filtered += score_i64 * SCALE;
                        filtered_weight += 1;
                    }
                }
                i += 1;
            }

            let final_mean_scaled: i64 = if filtered_weight > 0 {
                let fw_i64: i64 = filtered_weight.try_into().unwrap_or(0);
                sum_filtered / fw_i64
            } else {
                mean_scaled
            };
            let final_score: i64 = round_scaled(final_mean_scaled);

            e.final_score = final_score;
            e.final_score_set = true;
            e.phase = PHASE_FINALIZED;

            let mut total_coherent_weight: u32 = 0;
            i = 0;
            loop {
                if i >= drawn_count {
                    break;
                }
                let stake_id = self.evaluation_drawn_stakes.entry((evaluation_id, i)).read();
                if self.evaluation_revealed.entry((evaluation_id, stake_id)).read() {
                    let score = self.evaluation_score.entry((evaluation_id, stake_id)).read();
                    let score_i64 = score_to_i64(score);
                    let diff = if score_i64 >= final_score {
                        score_i64 - final_score
                    } else {
                        final_score - score_i64
                    };
                    if diff <= coherence_band {
                        self.evaluation_coherent.entry((evaluation_id, stake_id)).write(true);
                        total_coherent_weight += 1;
                    }
                }
                i += 1;
            }

            let incoherence_bps: u256 = self.incoherence_slash_bps.read().try_into().unwrap_or(0);
            i = 0;
            loop {
                if i >= drawn_count {
                    break;
                }
                let stake_id = self.evaluation_drawn_stakes.entry((evaluation_id, i)).read();
                if self.evaluation_revealed.entry((evaluation_id, stake_id)).read() {
                    if !self.evaluation_coherent.entry((evaluation_id, stake_id)).read() {
                        let stake = self.stakes.entry(stake_id).read();
                        let raw_slash = stake.amount * incoherence_bps / BPS_DENOM;
                        let current_stake = self.stakes.entry(stake_id).read().amount;
                        let slash_amount = if raw_slash <= current_stake {
                            raw_slash
                        } else {
                            current_stake
                        };
                        if slash_amount > 0 {
                            self._apply_stake_slash(stake_id, slash_amount);
                            e.slash_pool += slash_amount;
                            self
                                .stake_slashed_total
                                .entry((stake_id, evaluation_id))
                                .write(slash_amount);
                            self
                                .emit(
                                    IncoherentJurorSlashed {
                                        evaluation_id, juror: stake.owner, amount: slash_amount,
                                    },
                                );
                        }
                    }
                }
                i += 1;
            }

            let juror_reward_amount = self.juror_reward_amount.read();
            let total_coherent = total_coherent_weight;

            let from_budget: bool = e.slash_pool == 0;

            if total_coherent > 0 {
                let tc_u256: u256 = total_coherent.try_into().unwrap_or(0);
                i = 0;
                loop {
                    if i >= drawn_count {
                        break;
                    }
                    let stake_id = self.evaluation_drawn_stakes.entry((evaluation_id, i)).read();
                    if self.evaluation_coherent.entry((evaluation_id, stake_id)).read() {
                        let share: u256 = if from_budget {
                            juror_reward_amount / tc_u256
                        } else {
                            e.slash_pool / tc_u256
                        };
                        self.evaluation_juror_reward.entry((evaluation_id, stake_id)).write(share);
                    }
                    i += 1;
                };
            }

            let mint_amount = governance_tokens_for_score(final_score);
            e.governance_tokens_minted = mint_amount;

            let bond_amount = e.bond_amount;
            let requester = e.requester;
            let refund_bond = bond_amount > 0 && final_score >= 0;
            let slash_bond = bond_amount > 0 && final_score < 0;
            if slash_bond {
                e.slash_pool += bond_amount;
            }
            e.bond_settled = true;

            if requester.is_non_zero() {
                self.has_active_evaluation.entry(requester).write(false);
                self.last_evaluation_finalized.entry(requester).write(get_block_timestamp());
            }

            self.evaluations.entry(evaluation_id).write(e);
            self.emit(DisputeFinalized { evaluation_id, candidate: e.candidate, final_score });
            if mint_amount > 0 {
                self
                    .emit(
                        GovernanceTokensMinted {
                            evaluation_id, candidate: e.candidate, amount: mint_amount, final_score,
                        },
                    );
            }

            if mint_amount > 0 {
                IGovernanceDispatcher { contract_address: self.governance.read() }
                    .mint_governance_tokens(e.candidate, mint_amount);
            }

            if refund_bond {
                self._token().release(requester, bond_amount);
                self.emit(BondRefunded { evaluation_id, requester, amount: bond_amount });
            } else if slash_bond {
                self.emit(BondSlashed { evaluation_id, requester, amount: bond_amount });
            }

            self.reentrancyguard.end();
        }

        fn claim_juror_reward(ref self: ContractState, evaluation_id: u256, stake_id: u256) {
            self.reentrancyguard.start();
            let caller = get_caller_address();
            let e = self.evaluations.entry(evaluation_id).read();
            assert(e.final_score_set, 'NotFinalized');
            assert(self.evaluation_coherent.entry((evaluation_id, stake_id)).read(), 'NotCoherent');
            assert(
                !self.evaluation_reward_claimed.entry((evaluation_id, stake_id)).read(),
                'AlreadyClaimed',
            );
            let stake = self.stakes.entry(stake_id).read();
            assert(stake.owner == caller, 'NotStakeOwner');

            let reward = self.evaluation_juror_reward.entry((evaluation_id, stake_id)).read();
            self.evaluation_reward_claimed.entry((evaluation_id, stake_id)).write(true);

            if reward > 0 {
                let from_budget = e.slash_pool == 0;
                if from_budget {
                    if self._token().mint_from_budget(caller, reward) {
                        self
                            .emit(
                                JurorRewardClaimed { evaluation_id, juror: caller, amount: reward },
                            );
                    }
                } else {
                    self._token().release(caller, reward);
                    self.emit(JurorRewardClaimed { evaluation_id, juror: caller, amount: reward });
                }
            }

            self.reentrancyguard.end();
        }

        fn unstake_bond(ref self: ContractState, evaluation_id: u256) {
            self.reentrancyguard.start();
            let caller = get_caller_address();
            let mut e = self.evaluations.entry(evaluation_id).read();
            assert(e.final_score_set, 'NotFinalized');
            assert(e.requester == caller, 'NotRequester');
            assert(!e.bond_settled, 'BondAlreadySettled');
            assert(e.final_score >= 0, 'NegativeScore');

            let bond_amount = e.bond_amount;
            e.bond_settled = true;
            self.evaluations.entry(evaluation_id).write(e);

            if bond_amount > 0 {
                self._token().release(caller, bond_amount);
                self.emit(BondRefunded { evaluation_id, requester: caller, amount: bond_amount });
            }

            self.reentrancyguard.end();
        }

        // ---- ADMIN - timelocked parameter changes (executed by AdminTimelock) ----

        fn execute_set_admin(ref self: ContractState, new_admin: ContractAddress) {
            self._assert_admin();
            assert(new_admin.is_non_zero(), 'ZeroAddress');
            self.admin.write(new_admin);
            self.emit(AdminChanged { new_admin });
        }

        fn get_admin(self: @ContractState) -> ContractAddress {
            self.admin.read()
        }

        // ---- ADMIN - timelocked parameter changes (executed by AdminTimelock) ----

        fn execute_set_evaluation_bond_amount(ref self: ContractState, amount: u256) {
            self._assert_admin();
            self.evaluation_bond_amount.write(amount);
        }

        fn execute_set_commit_duration(ref self: ContractState, duration: u64) {
            self._assert_admin();
            self.commit_duration.write(duration);
        }

        fn execute_set_reveal_duration(ref self: ContractState, duration: u64) {
            self._assert_admin();
            self.reveal_duration.write(duration);
        }

        fn execute_set_non_reveal_slash_bps(ref self: ContractState, bps: u16) {
            self._assert_admin();
            self.non_reveal_slash_bps.write(bps);
        }

        fn execute_set_incoherence_slash_bps(ref self: ContractState, bps: u16) {
            self._assert_admin();
            self.incoherence_slash_bps.write(bps);
        }

        fn execute_set_coherence_band(ref self: ContractState, band: u8) {
            self._assert_admin();
            self.coherence_band.write(band);
        }

        fn execute_set_evaluation_cooldown(ref self: ContractState, cooldown: u64) {
            self._assert_admin();
            self.evaluation_cooldown.write(cooldown);
        }

        fn execute_set_applying_duration(ref self: ContractState, duration: u64) {
            self._assert_admin();
            self.applying_duration.write(duration);
        }

        fn execute_set_min_stake_ids(ref self: ContractState, count: u32) {
            self._assert_admin();
            self.min_stake_ids_per_evaluation.write(count);
        }

        fn execute_set_min_jurors(ref self: ContractState, count: u32) {
            self._assert_admin();
            self.min_jurors_per_evaluation.write(count);
        }

        fn execute_set_max_evaluations_per_stake(ref self: ContractState, count: u32) {
            self._assert_admin();
            self.max_evaluations_per_stake.write(count);
        }

        fn execute_set_juror_reward_amount(ref self: ContractState, amount: u256) {
            self._assert_admin();
            self.juror_reward_amount.write(amount);
        }

        fn execute_set_drawing_duration(ref self: ContractState, duration: u64) {
            self._assert_admin();
            self.drawing_duration.write(duration);
        }

        fn execute_set_vrf_provider(ref self: ContractState, provider: ContractAddress) {
            self._assert_admin();
            self.vrf_consumer.set_vrf_provider(provider);
        }

        fn execute_set_stake_amount(ref self: ContractState, amount: u256) {
            self._assert_admin();
            assert(amount > 0, 'ZeroAmount');
            assert(amount <= MAX_STAKE_AMOUNT, 'TooHigh');
            self.min_stake_amount.write(amount);
        }

        // ---- views ----

        fn get_dispute(self: @ContractState, dispute_id: u256) -> Dispute {
            let eval = self.evaluations.entry(dispute_id).read();
            Dispute {
                candidate: eval.candidate,
                unique_juror_count: eval.drawn_count,
                commit_deadline: eval.commit_deadline,
                reveal_deadline: eval.reveal_deadline,
                phase: eval.phase,
                final_score: eval.final_score,
                final_score_set: eval.final_score_set,
                total_weight_revealed: eval.drawn_count,
                total_coherent_weight: 0,
                slash_pool: eval.slash_pool,
                governance_tokens_minted: eval.governance_tokens_minted,
                requester: eval.requester,
                bond_amount: eval.bond_amount,
                bond_settled: eval.bond_settled,
            }
        }

        fn get_dispute_evidence(self: @ContractState, dispute_id: u256) -> ByteArray {
            let evidence: ByteArray = self.evaluation_evidence.entry(dispute_id).read();
            evidence
        }

        fn get_evaluation(self: @ContractState, evaluation_id: u256) -> Evaluation {
            self.evaluations.entry(evaluation_id).read()
        }

        fn get_evaluation_evidence(self: @ContractState, evaluation_id: u256) -> ByteArray {
            let evidence: ByteArray = self.evaluation_evidence.entry(evaluation_id).read();
            evidence
        }

        fn get_stake(self: @ContractState, stake_id: u256) -> Stake {
            self.stakes.entry(stake_id).read()
        }

        fn get_juror_stake(self: @ContractState, juror: ContractAddress) -> u256 {
            let count = self.juror_stake_count.entry(juror).read();
            let mut total: u256 = 0;
            let mut i: u32 = 0;
            loop {
                if i >= count {
                    break;
                }
                let sid = self.juror_stake_ids.entry((juror, i)).read();
                let stake = self.stakes.entry(sid).read();
                total += stake.amount;
                i += 1;
            }
            total
        }

        fn get_juror_stake_ids(self: @ContractState, juror: ContractAddress) -> Array<u256> {
            let count = self.juror_stake_count.entry(juror).read();
            let mut ids: Array<u256> = ArrayTrait::new();
            let mut i: u32 = 0;
            loop {
                if i >= count {
                    break;
                }
                let sid = self.juror_stake_ids.entry((juror, i)).read();
                ids.append(sid);
                i += 1;
            }
            ids
        }

        fn total_stake_weight(self: @ContractState) -> u256 {
            let mut total: u256 = 0;
            let count = self.stake_count.read();
            let mut i: u256 = 0;
            loop {
                if i >= count {
                    break;
                }
                let stake = self.stakes.entry(i).read();
                total += stake.amount;
                i += 1;
            }
            total
        }

        fn get_stake_evaluation_count(self: @ContractState, stake_id: u256) -> u32 {
            self.stake_evaluation_count.entry(stake_id).read()
        }

        fn get_stake_finalized_count(self: @ContractState, stake_id: u256) -> u32 {
            self.stake_finalized_count.entry(stake_id).read()
        }

        fn get_juror_locked_stake(self: @ContractState, juror: ContractAddress) -> u256 {
            let count = self.juror_stake_count.entry(juror).read();
            let mut total: u256 = 0;
            let mut i: u32 = 0;
            loop {
                if i >= count {
                    break;
                }
                let sid = self.juror_stake_ids.entry((juror, i)).read();
                let active = self.stake_evaluation_count.entry(sid).read();
                if active > 0 {
                    let stake = self.stakes.entry(sid).read();
                    total += stake.amount;
                }
                i += 1;
            }
            total
        }

        fn get_juror_unlocked_stake(self: @ContractState, juror: ContractAddress) -> u256 {
            let total = self.get_juror_stake(juror);
            let locked = self.get_juror_locked_stake(juror);
            if locked >= total {
                0
            } else {
                total - locked
            }
        }

        fn get_juror_open_evaluation_count(self: @ContractState, juror: ContractAddress) -> u32 {
            let count = self.juror_stake_count.entry(juror).read();
            let mut count_val: u32 = 0;
            let mut i: u32 = 0;
            loop {
                if i >= count {
                    break;
                }
                let sid = self.juror_stake_ids.entry((juror, i)).read();
                count_val += self.stake_evaluation_count.entry(sid).read();
                i += 1;
            }
            count_val
        }

        fn get_evaluation_bond_amount(self: @ContractState) -> u256 {
            self.evaluation_bond_amount.read()
        }

        fn get_active_evaluation_for_candidate(
            self: @ContractState, candidate: ContractAddress,
        ) -> u256 {
            self.active_evaluation_for_candidate.entry(candidate).read()
        }

        fn get_evaluation_cooldown(self: @ContractState) -> u64 {
            self.evaluation_cooldown.read()
        }

        fn get_last_evaluation_finalized(self: @ContractState, candidate: ContractAddress) -> u64 {
            self.last_evaluation_finalized.entry(candidate).read()
        }

        fn get_stake_slashed_total(
            self: @ContractState, stake_id: u256, evaluation_id: u256,
        ) -> u256 {
            self.stake_slashed_total.entry((stake_id, evaluation_id)).read()
        }

        // ---- parameter views ----

        fn get_incoherence_slash_bps(self: @ContractState) -> u16 {
            self.incoherence_slash_bps.read()
        }

        fn get_coherence_band(self: @ContractState) -> u8 {
            self.coherence_band.read()
        }

        fn get_commit_duration(self: @ContractState) -> u64 {
            self.commit_duration.read()
        }

        fn get_reveal_duration(self: @ContractState) -> u64 {
            self.reveal_duration.read()
        }

        fn get_non_reveal_slash_bps(self: @ContractState) -> u16 {
            self.non_reveal_slash_bps.read()
        }

        fn get_applying_duration(self: @ContractState) -> u64 {
            self.applying_duration.read()
        }

        fn get_min_stake_ids(self: @ContractState) -> u32 {
            self.min_stake_ids_per_evaluation.read()
        }

        fn get_min_jurors(self: @ContractState) -> u32 {
            self.min_jurors_per_evaluation.read()
        }

        fn get_max_evaluations_per_stake(self: @ContractState) -> u32 {
            self.max_evaluations_per_stake.read()
        }

        fn get_juror_reward_amount(self: @ContractState) -> u256 {
            self.juror_reward_amount.read()
        }

        fn get_drawing_duration(self: @ContractState) -> u64 {
            self.drawing_duration.read()
        }

        fn get_stake_amount(self: @ContractState) -> u256 {
            self.min_stake_amount.read()
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

        fn _u256_to_address(self: @ContractState, value: u256) -> ContractAddress {
            let value_felt: felt252 = value.try_into().unwrap();
            value_felt.try_into().unwrap()
        }

        fn _recent_block_hash(self: @ContractState) -> felt252 {
            let current = get_block_number();
            if current < BLOCK_HASH_LOOKBACK {
                return 0;
            }
            let target = current - BLOCK_HASH_LOOKBACK;
            match get_block_hash_syscall(target) {
                Result::Ok(hash) => hash,
                Result::Err(_) => 0,
            }
        }

        // ---- per-evaluation Fenwick tree ----

        fn _fenwick_add_eval(
            ref self: ContractState, evaluation_id: u256, index: u32, amount: u256,
        ) {
            let size = EVAL_FENWICK_SIZE;
            let mut i = index;
            loop {
                if i > size {
                    break;
                }
                let cur = self.evaluation_fenwick.entry((evaluation_id, i)).read();
                self.evaluation_fenwick.entry((evaluation_id, i)).write(cur + amount);
                i += lowbit(i);
            };
        }

        fn _fenwick_sub_eval(
            ref self: ContractState, evaluation_id: u256, index: u32, amount: u256,
        ) {
            let size = EVAL_FENWICK_SIZE;
            let mut i = index;
            loop {
                if i > size {
                    break;
                }
                let cur = self.evaluation_fenwick.entry((evaluation_id, i)).read();
                assert(cur >= amount, 'FenwickUnderflow');
                self.evaluation_fenwick.entry((evaluation_id, i)).write(cur - amount);
                i += lowbit(i);
            };
        }

        fn _fenwick_prefix_sum_eval(self: @ContractState, evaluation_id: u256, index: u32) -> u256 {
            let mut sum: u256 = 0;
            let mut i = index;
            loop {
                if i == 0 {
                    break;
                }
                sum += self.evaluation_fenwick.entry((evaluation_id, i)).read();
                i -= lowbit(i);
            }
            sum
        }

        fn _fenwick_total_eval(self: @ContractState, evaluation_id: u256) -> u256 {
            self._fenwick_prefix_sum_eval(evaluation_id, EVAL_FENWICK_SIZE)
        }

        fn _fenwick_find_eval(self: @ContractState, evaluation_id: u256, target: u256) -> u32 {
            let size = EVAL_FENWICK_SIZE;
            let mut log_size: u32 = 1;
            loop {
                if log_size * 2 > size {
                    break;
                }
                log_size = log_size * 2;
            }

            let mut pos: u32 = 0;
            let mut remaining = target;
            let mut step = log_size;
            loop {
                if step == 0 {
                    break;
                }
                let next = pos + step;
                if next <= size {
                    let val = self.evaluation_fenwick.entry((evaluation_id, next)).read();
                    if val <= remaining {
                        pos = next;
                        remaining -= val;
                    }
                }
                step = step / 2;
            }
            pos + 1
        }

        fn _is_stake_drawn(self: @ContractState, evaluation_id: u256, stake_id: u256) -> bool {
            self.evaluation_is_drawn.entry((evaluation_id, stake_id)).read()
        }

        fn _apply_stake_slash(ref self: ContractState, stake_id: u256, amount: u256) {
            let stake = self.stakes.entry(stake_id).read();
            assert(stake.amount >= amount, 'SlashExceedsStake');
            let new_amount = stake.amount - amount;
            self
                .stakes
                .entry(stake_id)
                .write(
                    Stake {
                        owner: stake.owner,
                        amount: new_amount,
                        created_at: stake.created_at,
                        retired: new_amount == 0 || stake.retired,
                    },
                );
        }
    }
}
