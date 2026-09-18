// SPDX-License-Identifier: MIT
//! Storage types for the StakeholderConviction contract. Grouped by domain:
//! `dispute` (Kleros-side), `governance` (proposals/convictions), and
//! `admin` (timelocked pending changes).

mod dispute;
mod governance;
mod admin;

pub use dispute::{Dispute, Grant};
pub use governance::{Conviction, FundingProposal, Supporter};
pub use admin::{PendingChange, PendingProtectedChange, PendingUpgrade, PendingAdminChange};