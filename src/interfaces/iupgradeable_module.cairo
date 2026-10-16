// SPDX-License-Identifier: MIT
//! Upgrade surface implemented by every module. `AdminTimelock` holds the
//! pending class-hash and disable timelocks and calls these once matured.

use starknet::ClassHash;

/// A module whose class hash can be replaced, or whose upgrade path can be
/// permanently disabled, by `AdminTimelock`.
#[starknet::interface]
pub trait IUpgradeableModule<TContractState> {
    /// Replaces the module's class hash. Only callable by the module admin
    /// (the `AdminTimelock`), and only while upgrades remain enabled.
    fn upgrade(ref self: TContractState, new_class_hash: ClassHash);

    /// Permanently disables future upgrades for the module.
    fn disable_upgrades(ref self: TContractState);

    /// Reports whether the module's upgrade path has been disabled forever.
    fn is_upgrades_disabled(self: @TContractState) -> bool;
}
