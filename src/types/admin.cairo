// SPDX-License-Identifier: MIT
//! Timelocked-pending-change types shared by the admin engine and the
//! upgrades mechanism, plus their `Default` impls (used by storage reads).

use starknet::ClassHash;

/// A pending numeric or address-like administrative change.
#[derive(Drop, Serde, Copy, starknet::Store)]
pub struct PendingChange {
    /// Proposed value encoded for the parameter's storage representation.
    pub new_value: u256,
    /// Timestamp at which the change becomes executable.
    pub effective_at: u64,
    /// Whether a pending change exists.
    pub exists: bool,
}

/// A pending protected-address flag change.
#[derive(Drop, Serde, Copy, starknet::Store)]
pub struct PendingProtectedChange {
    /// Proposed protected-address value.
    pub new_value: bool,
    /// Timestamp at which the change becomes executable.
    pub effective_at: u64,
    /// Whether a pending change exists.
    pub exists: bool,
}

/// A pending class-hash upgrade.
#[derive(Drop, Serde, Copy, starknet::Store)]
pub struct PendingUpgrade {
    /// Proposed class hash for the upgraded contract.
    pub new_class_hash: ClassHash,
    /// Timestamp at which the upgrade becomes executable.
    pub effective_at: u64,
    /// Whether a pending upgrade exists.
    pub exists: bool,
}

/// A pending addition or removal from the admin roster.
#[derive(Drop, Serde, Copy, starknet::Store)]
pub struct PendingAdminChange {
    /// `true` for an addition and `false` for a removal.
    pub is_add: bool,
    /// Timestamp at which the roster change becomes executable.
    pub effective_at: u64,
    /// Whether a pending roster change exists.
    pub exists: bool,
}

/// Returns the zero-value representation used when no numeric change exists.
impl PendingChangeDefault of Default<PendingChange> {
    /// Creates an absent pending numeric change.
    fn default() -> PendingChange {
        PendingChange { new_value: 0, effective_at: 0, exists: false }
    }
}

/// Returns the false-value representation used when no protected change exists.
impl PendingProtectedChangeDefault of Default<PendingProtectedChange> {
    /// Creates an absent pending protected-address change.
    fn default() -> PendingProtectedChange {
        PendingProtectedChange { new_value: false, effective_at: 0, exists: false }
    }
}

/// Returns the zero-value representation used when no upgrade exists.
impl PendingUpgradeDefault of Default<PendingUpgrade> {
    /// Creates an absent pending class-hash upgrade.
    fn default() -> PendingUpgrade {
        PendingUpgrade { new_class_hash: 0.try_into().unwrap(), effective_at: 0, exists: false }
    }
}

/// Returns the false-value representation used when no roster change exists.
impl PendingAdminChangeDefault of Default<PendingAdminChange> {
    /// Creates an absent pending admin-roster change.
    fn default() -> PendingAdminChange {
        PendingAdminChange { is_add: false, effective_at: 0, exists: false }
    }
}
