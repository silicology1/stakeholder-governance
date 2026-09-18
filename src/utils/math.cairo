// SPDX-License-Identifier: MIT
//! Pure numeric helpers used by the contract's scoring and statistics
//! routines. All functions are stateless; constants come from the crate's
//! `constants` module.

use crate::constants::SCALE;

/// Manual digit-by-digit binary integer square root.
/// Equivalent to the former `InternalImpl::_isqrt`.
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

/// Round a SCALE-multiplied value back to a plain score integer.
pub fn round_scaled(scaled: i64) -> i64 {
    let half = SCALE / 2;
    if scaled >= 0 {
        (scaled + half) / SCALE
    } else {
        (scaled - half) / SCALE
    }
}

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

/// Non-transferable governance-token grant size for a positive final score.
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