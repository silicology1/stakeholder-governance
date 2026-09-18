// SPDX-License-Identifier: MIT
//! Pure Fenwick tree helper: lowest-set-bit computation.

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