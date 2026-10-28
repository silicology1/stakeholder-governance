// SPDX-License-Identifier: MIT
//! Cross-contract interface for `ConvictionToken`, the ERC20 plus escrow
//! custody hub. `Selection` and `Governance` call the module-gated custody
//! entrypoints (`escrow`, `release`, `mint_from_budget`); `AdminTimelock`
//! calls the admin entrypoints (`set_param`, `set_protected`, `upgrade`,
//! `disable_upgrades`) and the shared parameter/upgrade traits.

use starknet::ContractAddress;

#[starknet::interface]
pub trait IConvictionToken<TContractState> {
    // ---- user-facing decay / burn ----

    /// Applies elapsed-time decay to one unprotected ERC20 balance.
    fn apply_decay(ref self: TContractState, user: ContractAddress);

    /// Applies decay to at most `MAX_BATCH_DECAY` addresses.
    fn batch_apply_decay(ref self: TContractState, users: Array<ContractAddress>);

    /// Burns `amount` of the caller's ERC20 and records it for recycling.
    fn burn(ref self: TContractState, amount: u256);

    // ---- module-gated custody ----

    /// Moves `amount` from `from` into contract custody on behalf of an
    /// authorized module.
    fn escrow(ref self: TContractState, from: ContractAddress, amount: u256);

    /// Moves `amount` out of contract custody to `to` on behalf of an
    /// authorized module.
    fn release(ref self: TContractState, to: ContractAddress, amount: u256);

    /// Best-effort budgeted mint invoked by an authorized module. Returns
    /// `true` only when tokens are actually minted.
    fn mint_from_budget(ref self: TContractState, to: ContractAddress, amount: u256) -> bool;

    // ---- admin ----

    /// Executed by AdminTimelock after timelock to change ConvictionToken's admin.
    fn execute_set_admin(ref self: TContractState, new_admin: ContractAddress);

    /// Executed by AdminTimelock after timelock to register Selection and Governance
    /// module addresses allowed to use the module-gated custody entrypoints.
    fn execute_set_modules(
        ref self: TContractState, selection: ContractAddress, governance: ContractAddress,
    );

    /// Sets the decay access-control protection flag for an address.
    fn set_protected(ref self: TContractState, target: ContractAddress, protected: bool);

    /// Returns the current module admin authority.
    fn get_admin(self: @TContractState) -> ContractAddress;

    /// Returns the registered `(selection, governance)` module addresses.
    fn get_modules(self: @TContractState) -> (ContractAddress, ContractAddress);

    // ---- ADMIN - timelocked parameter changes (executed by AdminTimelock) ----

    fn execute_set_decay_rate_bps(ref self: TContractState, bps: u16);
    fn execute_set_min_decay_for_reward(ref self: TContractState, amount: u256);
    fn execute_set_caller_reward_amount(ref self: TContractState, amount: u256);
    fn execute_set_inflation_rate_bps(ref self: TContractState, bps: u16);

    // ---- supply / budget / decay views ----

    fn token_max_supply(self: @TContractState) -> u256;
    fn token_remaining_mintable(self: @TContractState) -> u256;
    fn get_current_month(self: @TContractState) -> u64;
    fn get_month_start(self: @TContractState) -> u64;
    fn get_month_budget(self: @TContractState, month: u64) -> u256;
    fn get_month_budget_minted(self: @TContractState, month: u64) -> u256;
    fn get_month_burned(self: @TContractState, month: u64) -> u256;
    fn get_remaining_month_budget(self: @TContractState) -> u256;
    fn get_inflation_rate_bps(self: @TContractState) -> u16;
    fn get_decay_rate_bps(self: @TContractState) -> u16;
    fn get_min_decay_for_reward(self: @TContractState) -> u256;
    fn get_caller_reward_amount(self: @TContractState) -> u256;
    fn get_last_decay_at(self: @TContractState, user: ContractAddress) -> u64;
    fn is_protected_address(self: @TContractState, user: ContractAddress) -> bool;
}
