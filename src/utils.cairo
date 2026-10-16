// SPDX-License-Identifier: MIT
//! Pure, storage-free helpers extracted from the contract's internal impl:
//! fixed-point math/scoring (`math`), Fenwick-tree bit tricks (`fenwick`),
//! and VRF seed derivation (`random`).

/// Math and scoring helpers.
mod math;
/// Fenwick-tree helper.
mod fenwick;
/// VRF seed-derivation helper.
mod random;

pub use math::{isqrt, round_scaled, score_to_i64, score_to_u256, governance_tokens_for_score};
pub use fenwick::lowbit;
pub use random::derive_draw_random;
