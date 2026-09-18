// SPDX-License-Identifier: MIT
//! Timelocked-pending-change types shared by the admin engine and the
//! upgrades mechanism, plus their `Default` impls (used by storage reads).

use starknet::ClassHash;

#[derive(Drop, Serde, Copy, starknet::Store)]
pub struct PendingChange {
    pub new_value: u256,
    pub effective_at: u64,
    pub exists: bool,
}

#[derive(Drop, Serde, Copy, starknet::Store)]
pub struct PendingProtectedChange {
    pub new_value: bool,
    pub effective_at: u64,
    pub exists: bool,
}

#[derive(Drop, Serde, Copy, starknet::Store)]
pub struct PendingUpgrade {
    pub new_class_hash: ClassHash,
    pub effective_at: u64,
    pub exists: bool,
}

#[derive(Drop, Serde, Copy, starknet::Store)]
pub struct PendingAdminChange {
    pub is_add: bool,
    pub effective_at: u64,
    pub exists: bool,
}

impl PendingChangeDefault of Default<PendingChange> {
    fn default() -> PendingChange {
        PendingChange { new_value: 0, effective_at: 0, exists: false }
    }
}

impl PendingProtectedChangeDefault of Default<PendingProtectedChange> {
    fn default() -> PendingProtectedChange {
        PendingProtectedChange { new_value: false, effective_at: 0, exists: false }
    }
}

impl PendingUpgradeDefault of Default<PendingUpgrade> {
    fn default() -> PendingUpgrade {
        PendingUpgrade { new_class_hash: 0.try_into().unwrap(), effective_at: 0, exists: false }
    }
}

impl PendingAdminChangeDefault of Default<PendingAdminChange> {
    fn default() -> PendingAdminChange {
        PendingAdminChange { is_add: false, effective_at: 0, exists: false }
    }
}