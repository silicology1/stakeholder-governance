// SPDX-License-Identifier: MIT
//! StakeholderGovernanceModular
//! ============================
//! Modular split of the monolithic `stakeholder_governance` package. Four
//! `#[starknet::contract]` classes are built from this single package, each
//! with its own class-hash limit:
//!
//! * `ConvictionToken` - transferable ERC20, balance decay, monthly
//!   inflation/burn-recycling budget, burn tracking, and the escrow custody
//!   hub (juror stakes, evaluation bonds, proposal deposits).
//! * `Selection`       - juror staking + Fenwick-tree weighted sortition,
//!   VRF-backed disputes, commit/reveal, incoherence slashing.
//! * `Governance`      - non-transferable decaying governance-token grants,
//!   convictions, funding proposals, execution and reward minting.
//! * `AdminTimelock`   - central parameter timelock, decay protection
//!   changes, admin roster, and per-module upgrade/disable orchestration.
//!
//! Shared, storage-free material lives in sibling modules:
//!   - `constants` : all consts + timelocked-parameter keys
//!   - `types/`    : storage structs (dispute, governance, admin)
//!   - `events`    : event payload structs
//!   - `utils/`    : pure helpers (math, fenwick, random)
//!   - `interfaces`: cross-contract dispatcher traits

pub mod admin_timelock;
pub mod constants;

pub mod conviction_token;
pub mod events;
pub mod governance;
pub mod interfaces;
pub mod selection;
pub mod types;
pub mod utils;
