// SPDX-License-Identifier: MIT
//! Pure, storage-free helpers extracted from the contract's internal impl:
//! fixed-point math/scoring (`math`), Fenwick-tree bit tricks (`fenwick`),
//! and VRF seed derivation (`random`).

/// Fenwick-tree helper.
mod fenwick;
/// Math and scoring helpers.
mod math;
/// VRF seed-derivation helper.
mod random;
pub use fenwick::lowbit;

pub use math::{governance_tokens_for_score, isqrt, round_scaled, score_to_i64, score_to_u256};
pub use random::derive_draw_random;
