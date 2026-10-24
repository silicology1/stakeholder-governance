// SPDX-License-Identifier: MIT
//! AdminTimelock
//! =============
//! The central timelock and admin authority of the modular system.
//!
//! Owns:
//! * the generic parameter-timelock engine: `propose_param_change` stores a
//!   pending value, and after `TIMELOCK_DURATION` `execute_param_change`
//!   routes it to the owning module's `set_param`,
//! * timelocked decay protected-address changes (routed to `ConvictionToken`),
//! * the admin roster (add / remove, last admin guarded, all timelocked), and
//! * class-hash upgrade / permanent-disable orchestration for each module
//!   (and for AdminTimelock itself) under `UPGRADE_TIMELOCK_DURATION`.
//!
//! Modules trust this contract as their sole admin and reject `set_param` /
//! `upgrade` calls from anyone else.

#[starknet::contract]
pub mod AdminTimelock {
    use core::num::traits::Zero;
    use openzeppelin_access::accesscontrol::{AccessControlComponent, DEFAULT_ADMIN_ROLE};
    use openzeppelin_introspection::src5::SRC5Component;
    use openzeppelin_security::reentrancyguard::ReentrancyGuardComponent;
    use openzeppelin_upgrades::upgradeable::UpgradeableComponent;
    use starknet::storage::{
        Map, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::{
        ClassHash, ContractAddress, get_block_timestamp, get_caller_address, get_contract_address,
    };
    use crate::constants::*;
    use crate::interfaces::iadmin_timelock::IAdminTimelock;
    use crate::interfaces::iconviction_token::{
        IConvictionTokenDispatcher, IConvictionTokenDispatcherTrait,
    };
    use crate::interfaces::igovernance::{IGovernanceDispatcher, IGovernanceDispatcherTrait};
    use crate::interfaces::iselection::{ISelectionDispatcher, ISelectionDispatcherTrait};
    use crate::interfaces::iupgradeable_module::{
        IUpgradeableModuleDispatcher, IUpgradeableModuleDispatcherTrait,
    };
    use crate::types::*;

    component!(path: AccessControlComponent, storage: accesscontrol, event: AccessControlEvent);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);
    component!(
        path: ReentrancyGuardComponent, storage: reentrancyguard, event: ReentrancyGuardEvent,
    );
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);

    // NOTE: AccessControlMixinImpl is intentionally NOT `#[abi(embed_v0)]`, so no
    // unrestricted external grant_role / revoke_role entrypoint is exposed.
    impl AccessControlMixinImpl = AccessControlComponent::AccessControlMixinImpl<ContractState>;
    impl AccessControlInternalImpl = AccessControlComponent::InternalImpl<ContractState>;
    impl SRC5InternalImpl = SRC5Component::InternalImpl<ContractState>;
    #[abi(embed_v0)]
    impl SRC5Impl = SRC5Component::SRC5Impl<ContractState>;
    impl ReentrancyGuardInternalImpl = ReentrancyGuardComponent::InternalImpl<ContractState>;
    impl UpgradeableInternalImpl = UpgradeableComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        accesscontrol: AccessControlComponent::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        #[substorage(v0)]
        reentrancyguard: ReentrancyGuardComponent::Storage,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,
        /// ERC20 custody hub / token module address.
        token: ContractAddress,
        /// Selection module address.
        selection: ContractAddress,
        /// Governance module address.
        governance: ContractAddress,
        /// Current number of default admins.
        admin_count: u32,
        /// Whether AdminTimelock's own upgrade path is disabled forever.
        self_upgrades_disabled: bool,
        /// Pending ordinary parameter changes keyed by (target, param key).
        pending_changes: Map<(ContractAddress, felt252), PendingChange>,
        /// Pending protected-address changes keyed by target address.
        pending_protected: Map<ContractAddress, PendingProtectedChange>,
        /// Pending admin additions/removals keyed by target address.
        pending_admin_changes: Map<ContractAddress, PendingAdminChange>,
        /// Pending class-hash upgrades keyed by target module.
        pending_upgrade: Map<ContractAddress, PendingUpgrade>,
        /// Pending irreversible upgrade-disabling changes keyed by target.
        pending_upgrade_disable: Map<ContractAddress, PendingChange>,
    }

    // ---- events (target-aware) ----

    #[derive(Drop, starknet::Event)]
    pub struct ChangeProposed {
        #[key]
        pub target: ContractAddress,
        #[key]
        pub param_key: felt252,
        pub new_value: u256,
        pub effective_at: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ChangeExecuted {
        #[key]
        pub target: ContractAddress,
        #[key]
        pub param_key: felt252,
        pub new_value: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ProtectedAddressProposed {
        #[key]
        pub account: ContractAddress,
        pub new_value: bool,
        pub effective_at: u64,
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
        pub target: ContractAddress,
        #[key]
        pub new_class_hash: ClassHash,
        pub effective_at: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct UpgradeExecuted {
        #[key]
        pub target: ContractAddress,
        #[key]
        pub new_class_hash: ClassHash,
    }

    #[derive(Drop, starknet::Event)]
    pub struct UpgradeDisableProposed {
        #[key]
        pub target: ContractAddress,
        pub effective_at: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct TargetUpgradesDisabled {
        #[key]
        pub target: ContractAddress,
        pub by: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ModulesSet {
        pub token: ContractAddress,
        pub selection: ContractAddress,
        pub governance: ContractAddress,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        AccessControlEvent: AccessControlComponent::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
        #[flat]
        ReentrancyGuardEvent: ReentrancyGuardComponent::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,
        ChangeProposed: ChangeProposed,
        ChangeExecuted: ChangeExecuted,
        ProtectedAddressProposed: ProtectedAddressProposed,
        AdminAddProposed: AdminAddProposed,
        AdminAdded: AdminAdded,
        AdminRemoveProposed: AdminRemoveProposed,
        AdminRemoved: AdminRemoved,
        UpgradeProposed: UpgradeProposed,
        UpgradeExecuted: UpgradeExecuted,
        UpgradeDisableProposed: UpgradeDisableProposed,
        TargetUpgradesDisabled: TargetUpgradesDisabled,
        ModulesSet: ModulesSet,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin: ContractAddress,
        token: ContractAddress,
        selection: ContractAddress,
        governance: ContractAddress,
    ) {
        assert(admin.is_non_zero(), 'ZeroAddress');
        self.accesscontrol.initializer();
        self.accesscontrol._grant_role(DEFAULT_ADMIN_ROLE, admin);

        self.token.write(token);
        self.selection.write(selection);
        self.governance.write(governance);

        self.admin_count.write(1);
        self.self_upgrades_disabled.write(false);
    }

    // //////////////////////////////////////////////////////////////
    //                  EXTERNAL: IAdminTimelock
    // //////////////////////////////////////////////////////////////

    #[abi(embed_v0)]
    impl AdminTimelockImpl of IAdminTimelock<ContractState> {
        // ================================================================
        // ADMIN - timelocked parameter changes (Selection module)
        // ================================================================

        fn propose_set_evaluation_bond_amount(ref self: ContractState, amount: u256) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(amount > 0, 'ZeroAmount');
            assert(amount <= MAX_SUPPLY, 'TooHigh');
            let effective_at = get_block_timestamp() + TIMELOCK_DURATION;
            self
                .pending_changes
                .entry((self.selection.read(), PARAM_EVALUATION_BOND_AMOUNT))
                .write(PendingChange { new_value: amount, effective_at, exists: true });
            self
                .emit(
                    ChangeProposed {
                        target: self.selection.read(),
                        param_key: PARAM_EVALUATION_BOND_AMOUNT,
                        new_value: amount,
                        effective_at,
                    },
                );
        }

        fn execute_set_evaluation_bond_amount(ref self: ContractState) {
            self.reentrancyguard.start();
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let target = self.selection.read();
            let pc = self.pending_changes.entry((target, PARAM_EVALUATION_BOND_AMOUNT)).read();
            assert(pc.exists, 'NoPendingChange');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            self
                .pending_changes
                .entry((target, PARAM_EVALUATION_BOND_AMOUNT))
                .write(PendingChange { new_value: 0, effective_at: 0, exists: false });
            ISelectionDispatcher { contract_address: target }
                .execute_set_evaluation_bond_amount(pc.new_value);
            self
                .emit(
                    ChangeExecuted {
                        target, param_key: PARAM_EVALUATION_BOND_AMOUNT, new_value: pc.new_value,
                    },
                );
            self.reentrancyguard.end();
        }

        fn propose_set_commit_duration(ref self: ContractState, duration: u64) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(duration > 0, 'InvalidDuration');
            let effective_at = get_block_timestamp() + TIMELOCK_DURATION;
            self
                .pending_changes
                .entry((self.selection.read(), PARAM_COMMIT_DURATION))
                .write(PendingChange { new_value: duration.into(), effective_at, exists: true });
            self
                .emit(
                    ChangeProposed {
                        target: self.selection.read(),
                        param_key: PARAM_COMMIT_DURATION,
                        new_value: duration.into(),
                        effective_at,
                    },
                );
        }

        fn execute_set_commit_duration(ref self: ContractState) {
            self.reentrancyguard.start();
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let target = self.selection.read();
            let pc = self.pending_changes.entry((target, PARAM_COMMIT_DURATION)).read();
            assert(pc.exists, 'NoPendingChange');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            self
                .pending_changes
                .entry((target, PARAM_COMMIT_DURATION))
                .write(PendingChange { new_value: 0, effective_at: 0, exists: false });
            ISelectionDispatcher { contract_address: target }
                .execute_set_commit_duration(pc.new_value.try_into().unwrap());
            self
                .emit(
                    ChangeExecuted {
                        target, param_key: PARAM_COMMIT_DURATION, new_value: pc.new_value,
                    },
                );
            self.reentrancyguard.end();
        }

        fn propose_set_reveal_duration(ref self: ContractState, duration: u64) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(duration > 0, 'InvalidDuration');
            let effective_at = get_block_timestamp() + TIMELOCK_DURATION;
            self
                .pending_changes
                .entry((self.selection.read(), PARAM_REVEAL_DURATION))
                .write(PendingChange { new_value: duration.into(), effective_at, exists: true });
            self
                .emit(
                    ChangeProposed {
                        target: self.selection.read(),
                        param_key: PARAM_REVEAL_DURATION,
                        new_value: duration.into(),
                        effective_at,
                    },
                );
        }

        fn execute_set_reveal_duration(ref self: ContractState) {
            self.reentrancyguard.start();
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let target = self.selection.read();
            let pc = self.pending_changes.entry((target, PARAM_REVEAL_DURATION)).read();
            assert(pc.exists, 'NoPendingChange');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            self
                .pending_changes
                .entry((target, PARAM_REVEAL_DURATION))
                .write(PendingChange { new_value: 0, effective_at: 0, exists: false });
            ISelectionDispatcher { contract_address: target }
                .execute_set_reveal_duration(pc.new_value.try_into().unwrap());
            self
                .emit(
                    ChangeExecuted {
                        target, param_key: PARAM_REVEAL_DURATION, new_value: pc.new_value,
                    },
                );
            self.reentrancyguard.end();
        }

        fn propose_set_non_reveal_slash_bps(ref self: ContractState, bps: u16) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(bps <= 10_000, 'TooHigh');
            let effective_at = get_block_timestamp() + TIMELOCK_DURATION;
            self
                .pending_changes
                .entry((self.selection.read(), PARAM_NON_REVEAL_SLASH_BPS))
                .write(PendingChange { new_value: bps.into(), effective_at, exists: true });
            self
                .emit(
                    ChangeProposed {
                        target: self.selection.read(),
                        param_key: PARAM_NON_REVEAL_SLASH_BPS,
                        new_value: bps.into(),
                        effective_at,
                    },
                );
        }

        fn execute_set_non_reveal_slash_bps(ref self: ContractState) {
            self.reentrancyguard.start();
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let target = self.selection.read();
            let pc = self.pending_changes.entry((target, PARAM_NON_REVEAL_SLASH_BPS)).read();
            assert(pc.exists, 'NoPendingChange');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            self
                .pending_changes
                .entry((target, PARAM_NON_REVEAL_SLASH_BPS))
                .write(PendingChange { new_value: 0, effective_at: 0, exists: false });
            ISelectionDispatcher { contract_address: target }
                .execute_set_non_reveal_slash_bps(pc.new_value.try_into().unwrap());
            self
                .emit(
                    ChangeExecuted {
                        target, param_key: PARAM_NON_REVEAL_SLASH_BPS, new_value: pc.new_value,
                    },
                );
            self.reentrancyguard.end();
        }

        fn propose_set_incoherence_slash_bps(ref self: ContractState, bps: u16) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(bps <= 10_000, 'TooHigh');
            let effective_at = get_block_timestamp() + TIMELOCK_DURATION;
            self
                .pending_changes
                .entry((self.selection.read(), PARAM_INCOHERENCE_SLASH_BPS))
                .write(PendingChange { new_value: bps.into(), effective_at, exists: true });
            self
                .emit(
                    ChangeProposed {
                        target: self.selection.read(),
                        param_key: PARAM_INCOHERENCE_SLASH_BPS,
                        new_value: bps.into(),
                        effective_at,
                    },
                );
        }

        fn execute_set_incoherence_slash_bps(ref self: ContractState) {
            self.reentrancyguard.start();
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let target = self.selection.read();
            let pc = self.pending_changes.entry((target, PARAM_INCOHERENCE_SLASH_BPS)).read();
            assert(pc.exists, 'NoPendingChange');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            self
                .pending_changes
                .entry((target, PARAM_INCOHERENCE_SLASH_BPS))
                .write(PendingChange { new_value: 0, effective_at: 0, exists: false });
            ISelectionDispatcher { contract_address: target }
                .execute_set_incoherence_slash_bps(pc.new_value.try_into().unwrap());
            self
                .emit(
                    ChangeExecuted {
                        target, param_key: PARAM_INCOHERENCE_SLASH_BPS, new_value: pc.new_value,
                    },
                );
            self.reentrancyguard.end();
        }

        fn propose_set_coherence_band(ref self: ContractState, band: u8) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(band <= MAX_COHERENCE_BAND, 'TooHigh');
            let effective_at = get_block_timestamp() + TIMELOCK_DURATION;
            self
                .pending_changes
                .entry((self.selection.read(), PARAM_COHERENCE_BAND))
                .write(PendingChange { new_value: band.into(), effective_at, exists: true });
            self
                .emit(
                    ChangeProposed {
                        target: self.selection.read(),
                        param_key: PARAM_COHERENCE_BAND,
                        new_value: band.into(),
                        effective_at,
                    },
                );
        }

        fn execute_set_coherence_band(ref self: ContractState) {
            self.reentrancyguard.start();
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let target = self.selection.read();
            let pc = self.pending_changes.entry((target, PARAM_COHERENCE_BAND)).read();
            assert(pc.exists, 'NoPendingChange');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            self
                .pending_changes
                .entry((target, PARAM_COHERENCE_BAND))
                .write(PendingChange { new_value: 0, effective_at: 0, exists: false });
            ISelectionDispatcher { contract_address: target }
                .execute_set_coherence_band(pc.new_value.try_into().unwrap());
            self
                .emit(
                    ChangeExecuted {
                        target, param_key: PARAM_COHERENCE_BAND, new_value: pc.new_value,
                    },
                );
            self.reentrancyguard.end();
        }

        fn propose_set_evaluation_cooldown(ref self: ContractState, cooldown: u64) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(cooldown > 0, 'InvalidDuration');
            assert(cooldown <= MAX_EVALUATION_COOLDOWN, 'TooHigh');
            let effective_at = get_block_timestamp() + TIMELOCK_DURATION;
            self
                .pending_changes
                .entry((self.selection.read(), PARAM_EVALUATION_COOLDOWN))
                .write(PendingChange { new_value: cooldown.into(), effective_at, exists: true });
            self
                .emit(
                    ChangeProposed {
                        target: self.selection.read(),
                        param_key: PARAM_EVALUATION_COOLDOWN,
                        new_value: cooldown.into(),
                        effective_at,
                    },
                );
        }

        fn execute_set_evaluation_cooldown(ref self: ContractState) {
            self.reentrancyguard.start();
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let target = self.selection.read();
            let pc = self.pending_changes.entry((target, PARAM_EVALUATION_COOLDOWN)).read();
            assert(pc.exists, 'NoPendingChange');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            self
                .pending_changes
                .entry((target, PARAM_EVALUATION_COOLDOWN))
                .write(PendingChange { new_value: 0, effective_at: 0, exists: false });
            ISelectionDispatcher { contract_address: target }
                .execute_set_evaluation_cooldown(pc.new_value.try_into().unwrap());
            self
                .emit(
                    ChangeExecuted {
                        target, param_key: PARAM_EVALUATION_COOLDOWN, new_value: pc.new_value,
                    },
                );
            self.reentrancyguard.end();
        }

        fn propose_set_applying_duration(ref self: ContractState, duration: u64) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(duration > 0, 'InvalidDuration');
            assert(duration <= MAX_APPLYING_DURATION, 'TooHigh');
            let effective_at = get_block_timestamp() + TIMELOCK_DURATION;
            self
                .pending_changes
                .entry((self.selection.read(), PARAM_APPLYING_DURATION))
                .write(PendingChange { new_value: duration.into(), effective_at, exists: true });
            self
                .emit(
                    ChangeProposed {
                        target: self.selection.read(),
                        param_key: PARAM_APPLYING_DURATION,
                        new_value: duration.into(),
                        effective_at,
                    },
                );
        }

        fn execute_set_applying_duration(ref self: ContractState) {
            self.reentrancyguard.start();
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let target = self.selection.read();
            let pc = self.pending_changes.entry((target, PARAM_APPLYING_DURATION)).read();
            assert(pc.exists, 'NoPendingChange');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            self
                .pending_changes
                .entry((target, PARAM_APPLYING_DURATION))
                .write(PendingChange { new_value: 0, effective_at: 0, exists: false });
            ISelectionDispatcher { contract_address: target }
                .execute_set_applying_duration(pc.new_value.try_into().unwrap());
            self
                .emit(
                    ChangeExecuted {
                        target, param_key: PARAM_APPLYING_DURATION, new_value: pc.new_value,
                    },
                );
            self.reentrancyguard.end();
        }

        fn propose_set_min_stake_ids(ref self: ContractState, count: u32) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(count > 0, 'InvalidCount');
            let effective_at = get_block_timestamp() + TIMELOCK_DURATION;
            self
                .pending_changes
                .entry((self.selection.read(), PARAM_MIN_STAKE_IDS))
                .write(PendingChange { new_value: count.into(), effective_at, exists: true });
            self
                .emit(
                    ChangeProposed {
                        target: self.selection.read(),
                        param_key: PARAM_MIN_STAKE_IDS,
                        new_value: count.into(),
                        effective_at,
                    },
                );
        }

        fn execute_set_min_stake_ids(ref self: ContractState) {
            self.reentrancyguard.start();
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let target = self.selection.read();
            let pc = self.pending_changes.entry((target, PARAM_MIN_STAKE_IDS)).read();
            assert(pc.exists, 'NoPendingChange');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            self
                .pending_changes
                .entry((target, PARAM_MIN_STAKE_IDS))
                .write(PendingChange { new_value: 0, effective_at: 0, exists: false });
            ISelectionDispatcher { contract_address: target }
                .execute_set_min_stake_ids(pc.new_value.try_into().unwrap());
            self
                .emit(
                    ChangeExecuted {
                        target, param_key: PARAM_MIN_STAKE_IDS, new_value: pc.new_value,
                    },
                );
            self.reentrancyguard.end();
        }

        fn propose_set_min_jurors(ref self: ContractState, count: u32) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(count > 0, 'InvalidCount');
            assert(count <= MAX_MIN_JURORS, 'TooHigh');
            let effective_at = get_block_timestamp() + TIMELOCK_DURATION;
            self
                .pending_changes
                .entry((self.selection.read(), PARAM_MIN_JURORS))
                .write(PendingChange { new_value: count.into(), effective_at, exists: true });
            self
                .emit(
                    ChangeProposed {
                        target: self.selection.read(),
                        param_key: PARAM_MIN_JURORS,
                        new_value: count.into(),
                        effective_at,
                    },
                );
        }

        fn execute_set_min_jurors(ref self: ContractState) {
            self.reentrancyguard.start();
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let target = self.selection.read();
            let pc = self.pending_changes.entry((target, PARAM_MIN_JURORS)).read();
            assert(pc.exists, 'NoPendingChange');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            self
                .pending_changes
                .entry((target, PARAM_MIN_JURORS))
                .write(PendingChange { new_value: 0, effective_at: 0, exists: false });
            ISelectionDispatcher { contract_address: target }
                .execute_set_min_jurors(pc.new_value.try_into().unwrap());
            self
                .emit(
                    ChangeExecuted { target, param_key: PARAM_MIN_JURORS, new_value: pc.new_value },
                );
            self.reentrancyguard.end();
        }

        fn propose_set_max_evaluations_per_stake(ref self: ContractState, count: u32) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(count > 0, 'InvalidCount');
            assert(count <= MAX_MAX_EVALUATIONS_PER_STAKE, 'TooHigh');
            let effective_at = get_block_timestamp() + TIMELOCK_DURATION;
            self
                .pending_changes
                .entry((self.selection.read(), PARAM_MAX_EVALUATIONS_PER_STAKE))
                .write(PendingChange { new_value: count.into(), effective_at, exists: true });
            self
                .emit(
                    ChangeProposed {
                        target: self.selection.read(),
                        param_key: PARAM_MAX_EVALUATIONS_PER_STAKE,
                        new_value: count.into(),
                        effective_at,
                    },
                );
        }

        fn execute_set_max_evaluations_per_stake(ref self: ContractState) {
            self.reentrancyguard.start();
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let target = self.selection.read();
            let pc = self.pending_changes.entry((target, PARAM_MAX_EVALUATIONS_PER_STAKE)).read();
            assert(pc.exists, 'NoPendingChange');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            self
                .pending_changes
                .entry((target, PARAM_MAX_EVALUATIONS_PER_STAKE))
                .write(PendingChange { new_value: 0, effective_at: 0, exists: false });
            ISelectionDispatcher { contract_address: target }
                .execute_set_max_evaluations_per_stake(pc.new_value.try_into().unwrap());
            self
                .emit(
                    ChangeExecuted {
                        target, param_key: PARAM_MAX_EVALUATIONS_PER_STAKE, new_value: pc.new_value,
                    },
                );
            self.reentrancyguard.end();
        }

        fn propose_set_juror_reward_amount(ref self: ContractState, amount: u256) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(amount > 0, 'ZeroAmount');
            assert(amount <= MAX_JUROR_REWARD_AMOUNT, 'TooHigh');
            let effective_at = get_block_timestamp() + TIMELOCK_DURATION;
            self
                .pending_changes
                .entry((self.selection.read(), PARAM_JUROR_REWARD_AMOUNT))
                .write(PendingChange { new_value: amount, effective_at, exists: true });
            self
                .emit(
                    ChangeProposed {
                        target: self.selection.read(),
                        param_key: PARAM_JUROR_REWARD_AMOUNT,
                        new_value: amount,
                        effective_at,
                    },
                );
        }

        fn execute_set_juror_reward_amount(ref self: ContractState) {
            self.reentrancyguard.start();
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let target = self.selection.read();
            let pc = self.pending_changes.entry((target, PARAM_JUROR_REWARD_AMOUNT)).read();
            assert(pc.exists, 'NoPendingChange');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            self
                .pending_changes
                .entry((target, PARAM_JUROR_REWARD_AMOUNT))
                .write(PendingChange { new_value: 0, effective_at: 0, exists: false });
            ISelectionDispatcher { contract_address: target }
                .execute_set_juror_reward_amount(pc.new_value);
            self
                .emit(
                    ChangeExecuted {
                        target, param_key: PARAM_JUROR_REWARD_AMOUNT, new_value: pc.new_value,
                    },
                );
            self.reentrancyguard.end();
        }

        fn propose_set_drawing_duration(ref self: ContractState, duration: u64) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(duration > 0, 'InvalidDuration');
            assert(duration <= MAX_DRAWING_DURATION, 'TooHigh');
            let effective_at = get_block_timestamp() + TIMELOCK_DURATION;
            self
                .pending_changes
                .entry((self.selection.read(), PARAM_DRAWING_DURATION))
                .write(PendingChange { new_value: duration.into(), effective_at, exists: true });
            self
                .emit(
                    ChangeProposed {
                        target: self.selection.read(),
                        param_key: PARAM_DRAWING_DURATION,
                        new_value: duration.into(),
                        effective_at,
                    },
                );
        }

        fn execute_set_drawing_duration(ref self: ContractState) {
            self.reentrancyguard.start();
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let target = self.selection.read();
            let pc = self.pending_changes.entry((target, PARAM_DRAWING_DURATION)).read();
            assert(pc.exists, 'NoPendingChange');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            self
                .pending_changes
                .entry((target, PARAM_DRAWING_DURATION))
                .write(PendingChange { new_value: 0, effective_at: 0, exists: false });
            ISelectionDispatcher { contract_address: target }
                .execute_set_drawing_duration(pc.new_value.try_into().unwrap());
            self
                .emit(
                    ChangeExecuted {
                        target, param_key: PARAM_DRAWING_DURATION, new_value: pc.new_value,
                    },
                );
            self.reentrancyguard.end();
        }

        fn propose_set_vrf_provider(ref self: ContractState, provider: ContractAddress) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(provider.is_non_zero(), 'ZeroAddress');
            let provider_felt: felt252 = provider.try_into().unwrap();
            let provider_u256: u256 = provider_felt.try_into().unwrap();
            let effective_at = get_block_timestamp() + TIMELOCK_DURATION;
            self
                .pending_changes
                .entry((self.selection.read(), PARAM_VRF_PROVIDER))
                .write(PendingChange { new_value: provider_u256, effective_at, exists: true });
            self
                .emit(
                    ChangeProposed {
                        target: self.selection.read(),
                        param_key: PARAM_VRF_PROVIDER,
                        new_value: provider_u256,
                        effective_at,
                    },
                );
        }

        fn execute_set_vrf_provider(ref self: ContractState) {
            self.reentrancyguard.start();
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let target = self.selection.read();
            let pc = self.pending_changes.entry((target, PARAM_VRF_PROVIDER)).read();
            assert(pc.exists, 'NoPendingChange');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            self
                .pending_changes
                .entry((target, PARAM_VRF_PROVIDER))
                .write(PendingChange { new_value: 0, effective_at: 0, exists: false });
            let provider_felt: felt252 = pc.new_value.try_into().unwrap();
            let provider_addr: ContractAddress = provider_felt.try_into().unwrap();
            ISelectionDispatcher { contract_address: target }
                .execute_set_vrf_provider(provider_addr);
            self
                .emit(
                    ChangeExecuted {
                        target, param_key: PARAM_VRF_PROVIDER, new_value: pc.new_value,
                    },
                );
            self.reentrancyguard.end();
        }

        fn propose_set_stake_amount(ref self: ContractState, amount: u256) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(amount > 0, 'ZeroAmount');
            assert(amount <= MAX_STAKE_AMOUNT, 'TooHigh');
            let effective_at = get_block_timestamp() + TIMELOCK_DURATION;
            self
                .pending_changes
                .entry((self.selection.read(), PARAM_STAKE_AMOUNT))
                .write(PendingChange { new_value: amount, effective_at, exists: true });
            self
                .emit(
                    ChangeProposed {
                        target: self.selection.read(),
                        param_key: PARAM_STAKE_AMOUNT,
                        new_value: amount,
                        effective_at,
                    },
                );
        }

        fn execute_set_stake_amount(ref self: ContractState) {
            self.reentrancyguard.start();
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let target = self.selection.read();
            let pc = self.pending_changes.entry((target, PARAM_STAKE_AMOUNT)).read();
            assert(pc.exists, 'NoPendingChange');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            self
                .pending_changes
                .entry((target, PARAM_STAKE_AMOUNT))
                .write(PendingChange { new_value: 0, effective_at: 0, exists: false });
            ISelectionDispatcher { contract_address: target }
                .execute_set_stake_amount(pc.new_value);
            self
                .emit(
                    ChangeExecuted {
                        target, param_key: PARAM_STAKE_AMOUNT, new_value: pc.new_value,
                    },
                );
            self.reentrancyguard.end();
        }

        // ================================================================
        // ADMIN - timelocked parameter changes (ConvictionToken module)
        // ================================================================

        fn propose_set_decay_rate_bps(ref self: ContractState, bps: u16) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(bps <= 10_000, 'TooHigh');
            let effective_at = get_block_timestamp() + TIMELOCK_DURATION;
            self
                .pending_changes
                .entry((self.token.read(), PARAM_DECAY_RATE_BPS))
                .write(PendingChange { new_value: bps.into(), effective_at, exists: true });
            self
                .emit(
                    ChangeProposed {
                        target: self.token.read(),
                        param_key: PARAM_DECAY_RATE_BPS,
                        new_value: bps.into(),
                        effective_at,
                    },
                );
        }

        fn execute_set_decay_rate_bps(ref self: ContractState) {
            self.reentrancyguard.start();
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let target = self.token.read();
            let pc = self.pending_changes.entry((target, PARAM_DECAY_RATE_BPS)).read();
            assert(pc.exists, 'NoPendingChange');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            self
                .pending_changes
                .entry((target, PARAM_DECAY_RATE_BPS))
                .write(PendingChange { new_value: 0, effective_at: 0, exists: false });
            IConvictionTokenDispatcher { contract_address: target }
                .execute_set_decay_rate_bps(pc.new_value.try_into().unwrap());
            self
                .emit(
                    ChangeExecuted {
                        target, param_key: PARAM_DECAY_RATE_BPS, new_value: pc.new_value,
                    },
                );
            self.reentrancyguard.end();
        }

        fn propose_set_min_decay_for_reward(ref self: ContractState, amount: u256) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(amount <= MAX_SUPPLY, 'TooHigh');
            let effective_at = get_block_timestamp() + TIMELOCK_DURATION;
            self
                .pending_changes
                .entry((self.token.read(), PARAM_MIN_DECAY_FOR_REWARD))
                .write(PendingChange { new_value: amount, effective_at, exists: true });
            self
                .emit(
                    ChangeProposed {
                        target: self.token.read(),
                        param_key: PARAM_MIN_DECAY_FOR_REWARD,
                        new_value: amount,
                        effective_at,
                    },
                );
        }

        fn execute_set_min_decay_for_reward(ref self: ContractState) {
            self.reentrancyguard.start();
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let target = self.token.read();
            let pc = self.pending_changes.entry((target, PARAM_MIN_DECAY_FOR_REWARD)).read();
            assert(pc.exists, 'NoPendingChange');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            self
                .pending_changes
                .entry((target, PARAM_MIN_DECAY_FOR_REWARD))
                .write(PendingChange { new_value: 0, effective_at: 0, exists: false });
            IConvictionTokenDispatcher { contract_address: target }
                .execute_set_min_decay_for_reward(pc.new_value);
            self
                .emit(
                    ChangeExecuted {
                        target, param_key: PARAM_MIN_DECAY_FOR_REWARD, new_value: pc.new_value,
                    },
                );
            self.reentrancyguard.end();
        }

        fn propose_set_caller_reward_amount(ref self: ContractState, amount: u256) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(amount <= MAX_SUPPLY, 'TooHigh');
            let effective_at = get_block_timestamp() + TIMELOCK_DURATION;
            self
                .pending_changes
                .entry((self.token.read(), PARAM_CALLER_REWARD_AMOUNT))
                .write(PendingChange { new_value: amount, effective_at, exists: true });
            self
                .emit(
                    ChangeProposed {
                        target: self.token.read(),
                        param_key: PARAM_CALLER_REWARD_AMOUNT,
                        new_value: amount,
                        effective_at,
                    },
                );
        }

        fn execute_set_caller_reward_amount(ref self: ContractState) {
            self.reentrancyguard.start();
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let target = self.token.read();
            let pc = self.pending_changes.entry((target, PARAM_CALLER_REWARD_AMOUNT)).read();
            assert(pc.exists, 'NoPendingChange');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            self
                .pending_changes
                .entry((target, PARAM_CALLER_REWARD_AMOUNT))
                .write(PendingChange { new_value: 0, effective_at: 0, exists: false });
            IConvictionTokenDispatcher { contract_address: target }
                .execute_set_caller_reward_amount(pc.new_value);
            self
                .emit(
                    ChangeExecuted {
                        target, param_key: PARAM_CALLER_REWARD_AMOUNT, new_value: pc.new_value,
                    },
                );
            self.reentrancyguard.end();
        }

        fn propose_set_inflation_rate_bps(ref self: ContractState, bps: u16) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(bps <= MAX_INFLATION_BPS, 'TooHigh');
            let effective_at = get_block_timestamp() + TIMELOCK_DURATION;
            self
                .pending_changes
                .entry((self.token.read(), PARAM_INFLATION_RATE_BPS))
                .write(PendingChange { new_value: bps.into(), effective_at, exists: true });
            self
                .emit(
                    ChangeProposed {
                        target: self.token.read(),
                        param_key: PARAM_INFLATION_RATE_BPS,
                        new_value: bps.into(),
                        effective_at,
                    },
                );
        }

        fn execute_set_inflation_rate_bps(ref self: ContractState) {
            self.reentrancyguard.start();
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let target = self.token.read();
            let pc = self.pending_changes.entry((target, PARAM_INFLATION_RATE_BPS)).read();
            assert(pc.exists, 'NoPendingChange');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            self
                .pending_changes
                .entry((target, PARAM_INFLATION_RATE_BPS))
                .write(PendingChange { new_value: 0, effective_at: 0, exists: false });
            IConvictionTokenDispatcher { contract_address: target }
                .execute_set_inflation_rate_bps(pc.new_value.try_into().unwrap());
            self
                .emit(
                    ChangeExecuted {
                        target, param_key: PARAM_INFLATION_RATE_BPS, new_value: pc.new_value,
                    },
                );
            self.reentrancyguard.end();
        }

        // ================================================================
        // ADMIN - timelocked parameter changes (Governance module)
        // ================================================================

        fn propose_set_reputation_stake(ref self: ContractState, amount: u256) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(amount > 0, 'ZeroAmount');
            assert(amount <= MAX_SUPPLY, 'TooHigh');
            let effective_at = get_block_timestamp() + TIMELOCK_DURATION;
            self
                .pending_changes
                .entry((self.governance.read(), PARAM_REPUTATION_STAKE))
                .write(PendingChange { new_value: amount, effective_at, exists: true });
            self
                .emit(
                    ChangeProposed {
                        target: self.governance.read(),
                        param_key: PARAM_REPUTATION_STAKE,
                        new_value: amount,
                        effective_at,
                    },
                );
        }

        fn execute_set_reputation_stake(ref self: ContractState) {
            self.reentrancyguard.start();
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let target = self.governance.read();
            let pc = self.pending_changes.entry((target, PARAM_REPUTATION_STAKE)).read();
            assert(pc.exists, 'NoPendingChange');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            self
                .pending_changes
                .entry((target, PARAM_REPUTATION_STAKE))
                .write(PendingChange { new_value: 0, effective_at: 0, exists: false });
            IGovernanceDispatcher { contract_address: target }
                .execute_set_reputation_stake(pc.new_value);
            self
                .emit(
                    ChangeExecuted {
                        target, param_key: PARAM_REPUTATION_STAKE, new_value: pc.new_value,
                    },
                );
            self.reentrancyguard.end();
        }

        fn propose_set_conviction_threshold(ref self: ContractState, amount: u256) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(amount > 0, 'ZeroAmount');
            assert(amount <= MAX_SUPPLY, 'TooHigh');
            let effective_at = get_block_timestamp() + TIMELOCK_DURATION;
            self
                .pending_changes
                .entry((self.governance.read(), PARAM_CONVICTION_THRESHOLD))
                .write(PendingChange { new_value: amount, effective_at, exists: true });
            self
                .emit(
                    ChangeProposed {
                        target: self.governance.read(),
                        param_key: PARAM_CONVICTION_THRESHOLD,
                        new_value: amount,
                        effective_at,
                    },
                );
        }

        fn execute_set_conviction_threshold(ref self: ContractState) {
            self.reentrancyguard.start();
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let target = self.governance.read();
            let pc = self.pending_changes.entry((target, PARAM_CONVICTION_THRESHOLD)).read();
            assert(pc.exists, 'NoPendingChange');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            self
                .pending_changes
                .entry((target, PARAM_CONVICTION_THRESHOLD))
                .write(PendingChange { new_value: 0, effective_at: 0, exists: false });
            IGovernanceDispatcher { contract_address: target }
                .execute_set_conviction_threshold(pc.new_value);
            self
                .emit(
                    ChangeExecuted {
                        target, param_key: PARAM_CONVICTION_THRESHOLD, new_value: pc.new_value,
                    },
                );
            self.reentrancyguard.end();
        }

        fn propose_set_reward_multiplier(ref self: ContractState, amount: u256) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(amount > 0, 'ZeroAmount');
            assert(amount <= MAX_SUPPLY, 'TooHigh');
            let effective_at = get_block_timestamp() + TIMELOCK_DURATION;
            self
                .pending_changes
                .entry((self.governance.read(), PARAM_REWARD_MULTIPLIER))
                .write(PendingChange { new_value: amount, effective_at, exists: true });
            self
                .emit(
                    ChangeProposed {
                        target: self.governance.read(),
                        param_key: PARAM_REWARD_MULTIPLIER,
                        new_value: amount,
                        effective_at,
                    },
                );
        }

        fn execute_set_reward_multiplier(ref self: ContractState) {
            self.reentrancyguard.start();
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let target = self.governance.read();
            let pc = self.pending_changes.entry((target, PARAM_REWARD_MULTIPLIER)).read();
            assert(pc.exists, 'NoPendingChange');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            self
                .pending_changes
                .entry((target, PARAM_REWARD_MULTIPLIER))
                .write(PendingChange { new_value: 0, effective_at: 0, exists: false });
            IGovernanceDispatcher { contract_address: target }
                .execute_set_reward_multiplier(pc.new_value);
            self
                .emit(
                    ChangeExecuted {
                        target, param_key: PARAM_REWARD_MULTIPLIER, new_value: pc.new_value,
                    },
                );
            self.reentrancyguard.end();
        }

        fn propose_set_mini_reward_multiplier(ref self: ContractState, amount: u256) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(amount > 0, 'ZeroAmount');
            assert(amount <= MAX_SUPPLY, 'TooHigh');
            let effective_at = get_block_timestamp() + TIMELOCK_DURATION;
            self
                .pending_changes
                .entry((self.governance.read(), PARAM_MINI_REWARD_MULTIPLIER))
                .write(PendingChange { new_value: amount, effective_at, exists: true });
            self
                .emit(
                    ChangeProposed {
                        target: self.governance.read(),
                        param_key: PARAM_MINI_REWARD_MULTIPLIER,
                        new_value: amount,
                        effective_at,
                    },
                );
        }

        fn execute_set_mini_reward_multiplier(ref self: ContractState) {
            self.reentrancyguard.start();
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let target = self.governance.read();
            let pc = self.pending_changes.entry((target, PARAM_MINI_REWARD_MULTIPLIER)).read();
            assert(pc.exists, 'NoPendingChange');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            self
                .pending_changes
                .entry((target, PARAM_MINI_REWARD_MULTIPLIER))
                .write(PendingChange { new_value: 0, effective_at: 0, exists: false });
            IGovernanceDispatcher { contract_address: target }
                .execute_set_mini_reward_multiplier(pc.new_value);
            self
                .emit(
                    ChangeExecuted {
                        target, param_key: PARAM_MINI_REWARD_MULTIPLIER, new_value: pc.new_value,
                    },
                );
            self.reentrancyguard.end();
        }

        fn propose_set_conviction_base_lock(ref self: ContractState, duration: u64) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(duration > 0, 'InvalidDuration');
            assert(duration <= MAX_LOCK_DURATION, 'TooHigh');
            let effective_at = get_block_timestamp() + TIMELOCK_DURATION;
            self
                .pending_changes
                .entry((self.governance.read(), PARAM_CONVICTION_BASE_LOCK))
                .write(PendingChange { new_value: duration.into(), effective_at, exists: true });
            self
                .emit(
                    ChangeProposed {
                        target: self.governance.read(),
                        param_key: PARAM_CONVICTION_BASE_LOCK,
                        new_value: duration.into(),
                        effective_at,
                    },
                );
        }

        fn execute_set_conviction_base_lock(ref self: ContractState) {
            self.reentrancyguard.start();
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let target = self.governance.read();
            let pc = self.pending_changes.entry((target, PARAM_CONVICTION_BASE_LOCK)).read();
            assert(pc.exists, 'NoPendingChange');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            self
                .pending_changes
                .entry((target, PARAM_CONVICTION_BASE_LOCK))
                .write(PendingChange { new_value: 0, effective_at: 0, exists: false });
            IGovernanceDispatcher { contract_address: target }
                .execute_set_conviction_base_lock(pc.new_value.try_into().unwrap());
            self
                .emit(
                    ChangeExecuted {
                        target, param_key: PARAM_CONVICTION_BASE_LOCK, new_value: pc.new_value,
                    },
                );
            self.reentrancyguard.end();
        }

        fn propose_set_max_votes_per_conviction(ref self: ContractState, count: u64) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(count > 0, 'InvalidVotesCount');
            assert(count <= MAX_MAX_VOTES_PER_CONVICTION, 'TooHigh');
            let effective_at = get_block_timestamp() + TIMELOCK_DURATION;
            self
                .pending_changes
                .entry((self.governance.read(), PARAM_MAX_VOTES_PER_CONVICTION))
                .write(PendingChange { new_value: count.into(), effective_at, exists: true });
            self
                .emit(
                    ChangeProposed {
                        target: self.governance.read(),
                        param_key: PARAM_MAX_VOTES_PER_CONVICTION,
                        new_value: count.into(),
                        effective_at,
                    },
                );
        }

        fn execute_set_max_votes_per_conviction(ref self: ContractState) {
            self.reentrancyguard.start();
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let target = self.governance.read();
            let pc = self.pending_changes.entry((target, PARAM_MAX_VOTES_PER_CONVICTION)).read();
            assert(pc.exists, 'NoPendingChange');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            self
                .pending_changes
                .entry((target, PARAM_MAX_VOTES_PER_CONVICTION))
                .write(PendingChange { new_value: 0, effective_at: 0, exists: false });
            IGovernanceDispatcher { contract_address: target }
                .execute_set_max_votes_per_conviction(pc.new_value.try_into().unwrap());
            self
                .emit(
                    ChangeExecuted {
                        target, param_key: PARAM_MAX_VOTES_PER_CONVICTION, new_value: pc.new_value,
                    },
                );
            self.reentrancyguard.end();
        }

        fn propose_set_proposal_voting_period(ref self: ContractState, period: u64) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(period > 0, 'InvalidDuration');
            assert(period <= MAX_PROPOSAL_VOTING_PERIOD, 'TooHigh');
            let effective_at = get_block_timestamp() + TIMELOCK_DURATION;
            self
                .pending_changes
                .entry((self.governance.read(), PARAM_PROPOSAL_VOTING_PERIOD))
                .write(PendingChange { new_value: period.into(), effective_at, exists: true });
            self
                .emit(
                    ChangeProposed {
                        target: self.governance.read(),
                        param_key: PARAM_PROPOSAL_VOTING_PERIOD,
                        new_value: period.into(),
                        effective_at,
                    },
                );
        }

        fn execute_set_proposal_voting_period(ref self: ContractState) {
            self.reentrancyguard.start();
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let target = self.governance.read();
            let pc = self.pending_changes.entry((target, PARAM_PROPOSAL_VOTING_PERIOD)).read();
            assert(pc.exists, 'NoPendingChange');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            self
                .pending_changes
                .entry((target, PARAM_PROPOSAL_VOTING_PERIOD))
                .write(PendingChange { new_value: 0, effective_at: 0, exists: false });
            IGovernanceDispatcher { contract_address: target }
                .execute_set_proposal_voting_period(pc.new_value.try_into().unwrap());
            self
                .emit(
                    ChangeExecuted {
                        target, param_key: PARAM_PROPOSAL_VOTING_PERIOD, new_value: pc.new_value,
                    },
                );
            self.reentrancyguard.end();
        }

        fn get_pending_change(
            self: @ContractState, target: ContractAddress, param_key: felt252,
        ) -> PendingChange {
            self.pending_changes.entry((target, param_key)).read()
        }

        // ---- protected address (decay) ----

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
            self
                .emit(
                    ProtectedAddressProposed {
                        account: target, new_value: protected, effective_at,
                    },
                );
        }

        fn execute_set_protected_address(ref self: ContractState, target_address: ContractAddress) {
            self.reentrancyguard.start();
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let pc = self.pending_protected.entry(target_address).read();
            assert(pc.exists, 'NoPendingChange');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            self
                .pending_protected
                .entry(target_address)
                .write(PendingProtectedChange { new_value: false, effective_at: 0, exists: false });

            IConvictionTokenDispatcher { contract_address: self.token.read() }
                .set_protected(target_address, pc.new_value);
            self.reentrancyguard.end();
        }

        fn get_pending_protected(
            self: @ContractState, target_address: ContractAddress,
        ) -> PendingProtectedChange {
            self.pending_protected.entry(target_address).read()
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
            assert(self.accesscontrol.has_role(DEFAULT_ADMIN_ROLE, admin_to_remove), 'NotAnAdmin');
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
            assert(self.accesscontrol.has_role(DEFAULT_ADMIN_ROLE, admin_to_remove), 'NotAnAdmin');
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

        // ---- upgrade orchestration ----

        fn propose_upgrade(
            ref self: ContractState, target: ContractAddress, new_class_hash: ClassHash,
        ) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(self._is_upgrade_target(target), 'UnknownTarget');
            assert(!self._target_upgrades_disabled(target), 'UpgradesDisabledForever');
            let hash_felt: felt252 = new_class_hash.into();
            assert(hash_felt.is_non_zero(), 'ZeroClassHash');
            let effective_at = get_block_timestamp() + UPGRADE_TIMELOCK_DURATION;
            self
                .pending_upgrade
                .entry(target)
                .write(PendingUpgrade { new_class_hash, effective_at, exists: true });
            self.emit(UpgradeProposed { target, new_class_hash, effective_at });
        }

        fn execute_upgrade(ref self: ContractState, target: ContractAddress) {
            self.reentrancyguard.start();
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(!self._target_upgrades_disabled(target), 'UpgradesDisabledForever');
            let pu = self.pending_upgrade.entry(target).read();
            assert(pu.exists, 'NoPendingUpgrade');
            assert(get_block_timestamp() >= pu.effective_at, 'TimelockNotElapsed');
            self
                .pending_upgrade
                .entry(target)
                .write(
                    PendingUpgrade {
                        new_class_hash: 0.try_into().unwrap(), effective_at: 0, exists: false,
                    },
                );

            if target == get_contract_address() {
                self.upgradeable.upgrade(pu.new_class_hash);
            } else {
                IUpgradeableModuleDispatcher { contract_address: target }
                    .upgrade(pu.new_class_hash);
            }
            self.emit(UpgradeExecuted { target, new_class_hash: pu.new_class_hash });
            self.reentrancyguard.end();
        }

        fn propose_disable_upgrades(ref self: ContractState, target: ContractAddress) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(self._is_upgrade_target(target), 'UnknownTarget');
            assert(!self._target_upgrades_disabled(target), 'AlreadyDisabled');
            assert(!self.pending_upgrade_disable.entry(target).read().exists, 'AlreadyPending');
            let effective_at = get_block_timestamp() + UPGRADE_TIMELOCK_DURATION;
            self
                .pending_upgrade_disable
                .entry(target)
                .write(PendingChange { new_value: 1, effective_at, exists: true });
            self.emit(UpgradeDisableProposed { target, effective_at });
        }

        fn execute_disable_upgrades(ref self: ContractState, target: ContractAddress) {
            self.reentrancyguard.start();
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(!self._target_upgrades_disabled(target), 'AlreadyDisabled');
            let pc = self.pending_upgrade_disable.entry(target).read();
            assert(pc.exists, 'NoPendingChange');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            self
                .pending_upgrade_disable
                .entry(target)
                .write(PendingChange { new_value: 0, effective_at: 0, exists: false });
            self
                .pending_upgrade
                .entry(target)
                .write(
                    PendingUpgrade {
                        new_class_hash: 0.try_into().unwrap(), effective_at: 0, exists: false,
                    },
                );

            if target == get_contract_address() {
                self.self_upgrades_disabled.write(true);
            } else {
                IUpgradeableModuleDispatcher { contract_address: target }.disable_upgrades();
            }
            self.emit(TargetUpgradesDisabled { target, by: get_caller_address() });
            self.reentrancyguard.end();
        }

        fn is_upgrades_disabled(self: @ContractState, target: ContractAddress) -> bool {
            self._target_upgrades_disabled(target)
        }

        fn get_pending_upgrade(self: @ContractState, target: ContractAddress) -> PendingUpgrade {
            self.pending_upgrade.entry(target).read()
        }

        fn get_pending_upgrade_disable(
            self: @ContractState, target: ContractAddress,
        ) -> PendingChange {
            self.pending_upgrade_disable.entry(target).read()
        }
    }

    // //////////////////////////////////////////////////////////////
    //                        INTERNAL HELPERS
    // //////////////////////////////////////////////////////////////

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn _is_known_module(self: @ContractState, target: ContractAddress) -> bool {
            target == self.token.read()
                || target == self.selection.read()
                || target == self.governance.read()
        }

        fn _is_upgrade_target(self: @ContractState, target: ContractAddress) -> bool {
            target == get_contract_address() || self._is_known_module(target)
        }

        fn _target_upgrades_disabled(self: @ContractState, target: ContractAddress) -> bool {
            if target == get_contract_address() {
                self.self_upgrades_disabled.read()
            } else {
                IUpgradeableModuleDispatcher { contract_address: target }.is_upgrades_disabled()
            }
        }
    }
}
