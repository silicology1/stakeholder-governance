// SPDX-License-Identifier: MIT
//! Storage types for the StakeholderConviction contract. Grouped by domain:
//! `dispute` (Kleros-side), `governance` (proposals/convictions), and
//! `admin` (timelocked pending changes).

/// Re-export the timelock and upgrade pending-change records.
mod admin;
/// Re-export the dispute-side storage records.
mod dispute;
/// Re-export the governance-side storage records.
mod governance;
pub use admin::{PendingAdminChange, PendingChange, PendingProtectedChange, PendingUpgrade};

pub use dispute::{Dispute, Evaluation, Grant, Stake};
pub use governance::{Conviction, FundingProposal};
