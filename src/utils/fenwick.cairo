// SPDX-License-Identifier: MIT
//! Pure Fenwick tree helper: lowest-set-bit computation.

/// Returns the lowest set bit of a positive Fenwick index `i`, equivalently
/// `i & -i` for unsigned powers-of-two bit arithmetic. Callers must provide
/// `i > 0`; zero has no lowest set bit and the loop would not terminate.
pub fn lowbit(i: u32) -> u32 {
    let mut x = i;
    let mut bit: u32 = 1;
    loop {
        if x % 2 == 1 {
            break;
        }
        x = x / 2;
        bit = bit * 2;
    };
    bit
}
