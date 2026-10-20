// SPDX-License-Identifier: MIT
//! ConvictionToken
//! ===============
//! The transferable ERC20 plus the escrow custody hub of the modular
//! stakeholder-governance system.
//!
//! Owns:
//! * the OZ `ERC20Component` (transferable token),
//! * hourly ERC20 balance decay (`apply_decay`, `batch_apply_decay`) with an
//!   optional caller reward,
//! * the monthly inflation + burn-recycling budget engine, and
//! * all physically escrowed ERC20 (juror stakes, evaluation bonds, proposal
//!   deposits). `Selection` and `Governance` keep their own accounting and
//!   move tokens through the module-gated `escrow` / `release` /
//!   `mint_from_budget` entrypoints.
//!
//! Admin authority (timelocked params, protected addresses, upgrades) is held
//! by the `AdminTimelock` contract, which calls `set_param`, `set_protected`,
//! and the shared upgrade trait.

#[starknet::contract]
pub mod ConvictionToken {
    use core::num::traits::Zero;
    use openzeppelin_introspection::src5::SRC5Component;
    use openzeppelin_security::reentrancyguard::ReentrancyGuardComponent;
    use openzeppelin_token::erc20::{DefaultConfig, ERC20Component, ERC20HooksEmptyImpl};
    use openzeppelin_upgrades::upgradeable::UpgradeableComponent;
    use starknet::storage::{
        Map, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::{
        ClassHash, ContractAddress, get_block_timestamp, get_caller_address, get_contract_address,
    };
    use crate::constants::*;
    use crate::events::*;
    use crate::interfaces::iconviction_token::IConvictionToken;
    use crate::interfaces::iupgradeable_module::IUpgradeableModule;

    component!(path: ERC20Component, storage: erc20, event: ERC20Event);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);
    component!(
        path: ReentrancyGuardComponent, storage: reentrancyguard, event: ReentrancyGuardEvent,
    );
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);

    #[abi(embed_v0)]
    impl ERC20Impl = ERC20Component::ERC20Impl<ContractState>;
    #[abi(embed_v0)]
    impl ERC20MetadataImpl = ERC20Component::ERC20MetadataImpl<ContractState>;
    impl ERC20InternalImpl = ERC20Component::InternalImpl<ContractState>;

    impl SRC5InternalImpl = SRC5Component::InternalImpl<ContractState>;
    #[abi(embed_v0)]
    impl SRC5Impl = SRC5Component::SRC5Impl<ContractState>;
    impl ReentrancyGuardInternalImpl = ReentrancyGuardComponent::InternalImpl<ContractState>;
    impl UpgradeableInternalImpl = UpgradeableComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        /// ERC20 balances, allowances, supply, and token metadata.
        #[substorage(v0)]
        erc20: ERC20Component::Storage,
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
        /// Authorized selection module allowed to escrow / release / mint.
        selection: ContractAddress,
        /// Authorized governance module allowed to escrow / release / mint.
        governance: ContractAddress,
        /// Whether the class-hash upgrade path is permanently disabled.
        upgrades_disabled: bool,
        // ---- ERC20 balance decay ----
        /// Hourly ERC20 balance-decay rate in basis points.
        decay_rate_bps: u16,
        /// Minimum decay amount eligible for a caller reward.
        min_decay_for_reward: u256,
        /// Reward amount for a qualifying external decay caller.
        caller_reward_amount: u256,
        /// Last timestamp at which each user's balance was decay-accounted.
        last_decay_at: Map<ContractAddress, u64>,
        /// Last timestamp at which each caller earned a decay reward.
        last_caller_reward_at: Map<ContractAddress, u64>,
        /// Addresses excluded from decay.
        is_protected: Map<ContractAddress, bool>,
        // ---- monthly inflation / burn-recycling budget ----
        /// Monthly inflation rate in basis points.
        inflation_rate_bps: u16,
        /// Timestamp at which the currently stored month began.
        month_start: u64,
        /// Index of the currently stored budget month.
        month_index: u64,
        /// Total budget allocated to each month.
        month_budget: Map<u64, u256>,
        /// Budget consumed by rewards in each month.
        month_minted: Map<u64, u256>,
        /// ERC20 burns recorded for recycling into each month's successor.
        month_burned: Map<u64, u256>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        ERC20Event: ERC20Component::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
        #[flat]
        ReentrancyGuardEvent: ReentrancyGuardComponent::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,
        AdminChanged: AdminChanged,
        ModulesSet: ModulesSet,
        ProtectedAddressSet: ProtectedAddressSet,
        DecayApplied: DecayApplied,
        DecayCallerRewarded: DecayCallerRewarded,
        MonthlyBudgetSet: MonthlyBudgetSet,
        MonthlyBudgetBurned: MonthlyBudgetBurned,
        BudgetRewardMinted: BudgetRewardMinted,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin: ContractAddress,
        name: ByteArray,
        symbol: ByteArray,
        initial_recipient: ContractAddress,
    ) {
        assert(admin.is_non_zero(), 'ZeroAddress');
        assert(initial_recipient.is_non_zero(), 'ZeroAddress');

        self.erc20.initializer(name, symbol);

        self.admin.write(admin);

        // Decay defaults
        self.decay_rate_bps.write(DEFAULT_DECAY_RATE_BPS);
        self.min_decay_for_reward.write(DEFAULT_MIN_DECAY_FOR_REWARD);
        self.caller_reward_amount.write(DEFAULT_CALLER_REWARD_AMOUNT);

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
    //                  EXTERNAL: IConvictionToken
    // //////////////////////////////////////////////////////////////

    #[abi(embed_v0)]
    impl ConvictionTokenImpl of IConvictionToken<ContractState> {
        // ---- user-facing decay / burn ----

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
            }
            self.reentrancyguard.end();
        }

        fn burn(ref self: ContractState, amount: u256) {
            self.reentrancyguard.start();
            assert(amount > 0, 'ZeroAmount');
            self.erc20.burn(get_caller_address(), amount);
            self._track_burn(amount);
            self.reentrancyguard.end();
        }

        // ---- module-gated custody ----

        fn escrow(ref self: ContractState, from: ContractAddress, amount: u256) {
            self._assert_module();
            assert(amount > 0, 'ZeroAmount');
            self.erc20._transfer(from, get_contract_address(), amount);
        }

        fn release(ref self: ContractState, to: ContractAddress, amount: u256) {
            self._assert_module();
            if amount > 0 {
                self.erc20._transfer(get_contract_address(), to, amount);
            }
        }

        fn mint_from_budget(ref self: ContractState, to: ContractAddress, amount: u256) -> bool {
            self._assert_module();
            self._mint_from_budget(to, amount)
        }

        // ---- admin ----

        fn set_admin(ref self: ContractState, new_admin: ContractAddress) {
            self._assert_admin();
            assert(new_admin.is_non_zero(), 'ZeroAddress');
            self.admin.write(new_admin);
            self.emit(AdminChanged { new_admin });
        }

        fn set_modules(
            ref self: ContractState, selection: ContractAddress, governance: ContractAddress,
        ) {
            self._assert_admin();
            self.selection.write(selection);
            self.governance.write(governance);
            self.emit(ModulesSet { selection, governance });
        }

        fn set_protected(ref self: ContractState, target: ContractAddress, protected: bool) {
            self._assert_admin();
            assert(target.is_non_zero(), 'ZeroAddress');
            self.is_protected.entry(target).write(protected);
            self.emit(ProtectedAddressSet { target, new_value: protected });
        }

        fn get_admin(self: @ContractState) -> ContractAddress {
            self.admin.read()
        }

        fn get_modules(self: @ContractState) -> (ContractAddress, ContractAddress) {
            (self.selection.read(), self.governance.read())
        }

        // ---- views ----

        fn token_max_supply(self: @ContractState) -> u256 {
            MAX_SUPPLY
        }

        fn token_remaining_mintable(self: @ContractState) -> u256 {
            MAX_SUPPLY - self.erc20.total_supply()
        }

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

        fn execute_set_decay_rate_bps(ref self: ContractState, bps: u16) {
            self._assert_admin();
            self.decay_rate_bps.write(bps);
        }

        fn execute_set_min_decay_for_reward(ref self: ContractState, amount: u256) {
            self._assert_admin();
            assert(amount <= MAX_SUPPLY, 'TooHigh');
            self.min_decay_for_reward.write(amount);
        }

        fn execute_set_caller_reward_amount(ref self: ContractState, amount: u256) {
            self._assert_admin();
            assert(amount <= MAX_SUPPLY, 'TooHigh');
            self.caller_reward_amount.write(amount);
        }

        fn execute_set_inflation_rate_bps(ref self: ContractState, bps: u16) {
            self._assert_admin();
            self.inflation_rate_bps.write(bps);
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
        fn _assert_admin(self: @ContractState) {
            assert(get_caller_address() == self.admin.read(), 'NotAdmin');
        }

        fn _assert_module(self: @ContractState) {
            let caller = get_caller_address();
            assert(
                caller == self.selection.read() || caller == self.governance.read(), 'NotModule',
            );
        }

        /// Mints ERC20 tokens after enforcing the global supply cap. Used for
        /// the one-time constructor mint; budgeted rewards use
        /// `_mint_from_budget`.
        fn _mint_capped(ref self: ContractState, to: ContractAddress, amount: u256) {
            assert(amount > 0, 'ZeroAmount');
            let current_supply = self.erc20.total_supply();
            assert(current_supply + amount <= MAX_SUPPLY, 'SupplyCapExceeded');
            self.erc20.mint(to, amount);
        }

        /// Computes a month's inflation share plus burns recycled from the
        /// previous month, capped by the remaining `MAX_SUPPLY` headroom.
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
            let inflation_part = if inflation > headroom {
                headroom
            } else {
                inflation
            };
            inflation_part + recycle
        }

        /// Advances stale monthly budget state up to `MAX_ROLLOVER_MONTHS`
        /// months in one call.
        fn _ensure_current_month(ref self: ContractState) {
            let now = get_block_timestamp();
            let mut start = self.month_start.read();
            if now < start + MONTH_SECONDS {
                return;
            }

            let elapsed = (now - start) / MONTH_SECONDS;
            let mut settle = elapsed;
            if settle > MAX_ROLLOVER_MONTHS {
                settle = MAX_ROLLOVER_MONTHS;
            }

            let mut idx = self.month_index.read();
            let mut i: u64 = 0;
            loop {
                if i >= settle {
                    break;
                }

                let budget = self.month_budget.entry(idx).read();
                let minted = self.month_minted.entry(idx).read();
                if minted < budget {
                    let leftover = budget - minted;
                    self.emit(MonthlyBudgetBurned { month: idx, amount: leftover });
                }

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
            }

            self.month_index.write(idx);
            self.month_start.write(start);
        }

        /// Attempts to mint a reward from the current month's budget,
        /// best-effort (never reverts the enclosing operation).
        fn _mint_from_budget(ref self: ContractState, to: ContractAddress, amount: u256) -> bool {
            if amount == 0 {
                return false;
            }
            self._ensure_current_month();

            let month = self.month_index.read();
            let budget = self.month_budget.entry(month).read();
            let minted = self.month_minted.entry(month).read();
            if minted + amount > budget {
                return false;
            }
            if self.erc20.total_supply() + amount > MAX_SUPPLY {
                return false;
            }

            self.erc20.mint(to, amount);
            self.month_minted.entry(month).write(minted + amount);
            self.emit(BudgetRewardMinted { month, recipient: to, amount });
            true
        }

        /// Records an ERC20 burn in the current month after lazily advancing
        /// month state.
        fn _track_burn(ref self: ContractState, amount: u256) {
            assert(amount > 0, 'ZeroAmount');
            self._ensure_current_month();

            let month = self.month_index.read();
            let burned = self.month_burned.entry(month).read();
            self.month_burned.entry(month).write(burned + amount);
        }

        /// Applies elapsed-time ERC20 balance decay and optional caller reward.
        fn _apply_decay(ref self: ContractState, user: ContractAddress) {
            assert(user != get_contract_address(), 'ProtectedAddress');
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
                    if reward > 0 && self._mint_from_budget(caller, reward) {
                        self.emit(DecayCallerRewarded { caller, user, reward });
                    }
                }
            }
        }
    }
}
