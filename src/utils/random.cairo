// SPDX-License-Identifier: MIT
//! Randomness derivation used by the juror draw. The caller consumes one
//! verified random felt252 from the Cartridge VRF and derives a
//! per-dispute, per-draw seed here.

use core::array::ArrayTrait;
use core::poseidon::poseidon_hash_span;

/// Derives a deterministic draw seed from a verified VRF base seed, a dispute
/// identifier, and a draw index. The three inputs are hashed with Poseidon so
/// a distinct draw index cannot reuse the same base randomness directly.
/// `dispute_id` must fit the felt252 conversion used by the contract.
pub fn derive_draw_random(
    base_seed: felt252, dispute_id: u256, draw_index: u32,
) -> felt252 {
    let mut input: Array<felt252> = ArrayTrait::new();
    input.append(base_seed);
    let dispute_id_felt: felt252 = dispute_id.try_into().unwrap();
    input.append(dispute_id_felt);
    let draw_index_felt: felt252 = draw_index.into();
    input.append(draw_index_felt);
    poseidon_hash_span(input.span())
}
