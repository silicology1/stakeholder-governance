// SPDX-License-Identifier: MIT
//! Pure numeric helpers used by the contract's scoring and statistics
//! routines. All functions are stateless; constants come from the crate's
//! `constants` module.

use crate::constants::SCALE;

/// Computes the integer square root of `x` by a manual digit-by-digit binary
/// algorithm. The result is the greatest integer `r` such that `r * r <= x`.
/// It is used for vote-weight arithmetic and expects the protocol's `u256`
/// amounts to remain within the checked arithmetic domain.
pub fn isqrt(x: u256) -> u256 {
    if x == 0 {
        return 0;
    }
    let mut bit: u256 = 1;
    loop {
        if bit * 4 > x {
            break;
        }
        bit = bit * 4;
    };

    let mut result: u256 = 0;
    let mut rem: u256 = x;
    loop {
        if bit == 0 {
            break;
        }
        if rem >= result + bit {
            rem -= result + bit;
            result = result / 2 + bit;
        } else {
            result = result / 2;
        }
        bit = bit / 4;
    };
    result
}

/// Converts a `SCALE`-multiplied signed score back to a plain score integer.
/// The implementation rounds by adding or subtracting half of `SCALE` before
/// division; callers should use it only with values in the protocol score range.
pub fn round_scaled(scaled: i64) -> i64 {
    let half = SCALE / 2;
    if scaled >= 0 {
        (scaled + half) / SCALE
    } else {
        (scaled - half) / SCALE
    }
}

/// Converts a protocol score represented as `i8` to the signed integer used
/// by the weighted statistics calculations. Scores are intended to be within
/// the inclusive range -5 through 5.
pub fn score_to_i64(v: i8) -> i64 {
    if v == -5 {
        -5
    } else if v == -4 {
        -4
    } else if v == -3 {
        -3
    } else if v == -2 {
        -2
    } else if v == -1 {
        -1
    } else if v == 0 {
        0
    } else if v == 1 {
        1
    } else if v == 2 {
        2
    } else if v == 3 {
        3
    } else if v == 4 {
        4
    } else {
        5
    }
}

/// Maps a positive protocol score to its non-negative `u256` representation.
/// Scores outside the positive 1-through-5 range map to zero.
pub fn score_to_u256(score: i64) -> u256 {
    if score == 1 {
        1
    } else if score == 2 {
        2
    } else if score == 3 {
        3
    } else if score == 4 {
        4
    } else if score == 5 {
        5
    } else {
        0
    }
}

/// Returns the non-transferable governance-token grant size for a positive
/// final score. Scores 1-3 grant 1,000 tokens per score unit, while scores
/// 4-5 grant 40,000 or 50,000 tokens respectively. Zero and negative scores
/// grant nothing.
pub fn governance_tokens_for_score(final_score: i64) -> u256 {
    if final_score == 1 {
        1_000_000_000_000_000_000_000
    } else if final_score == 2 {
        2_000_000_000_000_000_000_000
    } else if final_score == 3 {
        3_000_000_000_000_000_000_000
    } else if final_score == 4 {
        40_000_000_000_000_000_000_000
    } else if final_score == 5 {
        50_000_000_000_000_000_000_000
    } else {
        0
    }
}
