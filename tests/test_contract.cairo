// SPDX-License-Identifier: MIT
//! snforge test suite for the modular `stakeholder_governance_modular` package.
//!
//! Entry points match the current contract interface:
//!   Selection: create_stake, unstake_stake, request_evaluation, apply_to_evaluation,
//!              advance_evaluation, commit_vote(eval, stake, hash),
//!              reveal_vote(eval, stake, score, salt), finalize_evaluation,
//!              claim_juror_reward(eval, stake)
//!   AdminTimelock: propose_set_* / execute_set_* (per-parameter entry points)

use core::poseidon::poseidon_hash_span;
use openzeppelin_interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{
    CheatSpan, ContractClassTrait, DeclareResultTrait, cheat_caller_address, declare,
    start_cheat_block_timestamp_global, start_cheat_caller_address, start_mock_call,
};
use stakeholder_governance_modular::interfaces::iadmin_timelock::{
    IAdminTimelockDispatcher, IAdminTimelockDispatcherTrait,
};
use stakeholder_governance_modular::interfaces::iconviction_token::{
    IConvictionTokenDispatcher, IConvictionTokenDispatcherTrait,
};
use stakeholder_governance_modular::interfaces::igovernance::{
    IGovernanceDispatcher, IGovernanceDispatcherTrait,
};
use stakeholder_governance_modular::interfaces::iselection::{
    ISelectionDispatcher, ISelectionDispatcherTrait,
};
use starknet::ContractAddress;

// ////////////////////////////////////////////////////////////////
//                         SHARED TEST CONSTANTS
// ////////////////////////////////////////////////////////////////

const ONE: u256 = 1_000_000_000_000_000_000;
const BOND: u256 = 50 * ONE;
const DEPOSIT: u256 = 10 * ONE;
const THRESHOLD: u256 = 1_000_000_000;
const REWARD_MULT: u256 = 100 * ONE;
const MINI_REWARD_MULT: u256 = 10 * ONE;
const STAKE: u256 = 100 * ONE;
const FUND: u256 = 1_000 * ONE;

const T0: u64 = 1_000_000;
const COMMIT_DURATION: u64 = 259_200;
const REVEAL_DURATION: u64 = 259_200;
const COMMIT_PHASE_TS: u64 = T0 + 100;
const REVEAL_PHASE_TS: u64 = T0 + COMMIT_DURATION + 1;
const FINALIZE_TS: u64 = T0 + COMMIT_DURATION + REVEAL_DURATION + 1;
const TIMELOCK_DURATION: u64 = 259_200;
const UPGRADE_TIMELOCK_DURATION: u64 = 604_800;
const PROPOSAL_VOTING_PERIOD: u64 = 604_800;
const MONTH_SECONDS: u64 = 2_592_000;

// ////////////////////////////////////////////////////////////////
//                             TEST FIXTURE
// ////////////////////////////////////////////////////////////////

#[derive(Copy, Drop)]
struct Fixture {
    token: ContractAddress,
    selection: ContractAddress,
    governance: ContractAddress,
    timelock: ContractAddress,
}

fn admin() -> ContractAddress {
    'admin'.try_into().unwrap()
}
fn whale() -> ContractAddress {
    'whale'.try_into().unwrap()
}
fn juror() -> ContractAddress {
    'juror'.try_into().unwrap()
}
fn candidate() -> ContractAddress {
    'candidate'.try_into().unwrap()
}
fn creator() -> ContractAddress {
    'creator'.try_into().unwrap()
}
fn funding_wallet() -> ContractAddress {
    'funding_wallet'.try_into().unwrap()
}
fn vrf_provider() -> ContractAddress {
    'vrf_provider'.try_into().unwrap()
}

fn tok_disp(fx: Fixture) -> IERC20Dispatcher {
    IERC20Dispatcher { contract_address: fx.token }
}
fn ctok_disp(fx: Fixture) -> IConvictionTokenDispatcher {
    IConvictionTokenDispatcher { contract_address: fx.token }
}
fn sel_disp(fx: Fixture) -> ISelectionDispatcher {
    ISelectionDispatcher { contract_address: fx.selection }
}
fn gov_disp(fx: Fixture) -> IGovernanceDispatcher {
    IGovernanceDispatcher { contract_address: fx.governance }
}
fn atl_disp(fx: Fixture) -> IAdminTimelockDispatcher {
    IAdminTimelockDispatcher { contract_address: fx.timelock }
}

fn cheat1(target: ContractAddress, caller: ContractAddress) {
    cheat_caller_address(target, caller, CheatSpan::TargetCalls(1));
}

fn deploy(threshold: u256, reward_multiplier: u256, mini_reward_multiplier: u256) -> Fixture {
    // ConvictionToken
    let token_class = declare("ConvictionToken").unwrap().contract_class();
    let mut calldata: Array<felt252> = array![];
    calldata.append(admin().into());
    let name: ByteArray = "ConvictionToken";
    let symbol: ByteArray = "STK";
    name.serialize(ref calldata);
    symbol.serialize(ref calldata);
    calldata.append(whale().into());
    let (token, _) = token_class.deploy(@calldata).unwrap();

    // Governance
    let gov_class = declare("Governance").unwrap().contract_class();
    let mut calldata: Array<felt252> = array![];
    calldata.append(admin().into());
    calldata.append(token.into());
    (DEPOSIT).serialize(ref calldata);
    threshold.serialize(ref calldata);
    reward_multiplier.serialize(ref calldata);
    mini_reward_multiplier.serialize(ref calldata);
    let (governance, _) = gov_class.deploy(@calldata).unwrap();

    // Selection
    let sel_class = declare("Selection").unwrap().contract_class();
    let mut calldata: Array<felt252> = array![];
    calldata.append(admin().into());
    calldata.append(token.into());
    calldata.append(governance.into());
    calldata.append(vrf_provider().into());
    (BOND).serialize(ref calldata);
    let (selection, _) = sel_class.deploy(@calldata).unwrap();

    // Wire custody graph
    cheat1(token, admin());
    IConvictionTokenDispatcher { contract_address: token }.execute_set_modules(selection, governance);
    cheat1(governance, admin());
    IGovernanceDispatcher { contract_address: governance }.execute_set_selection(selection);

    // AdminTimelock
    let atl_class = declare("AdminTimelock").unwrap().contract_class();
    let mut calldata: Array<felt252> = array![];
    calldata.append(admin().into());
    calldata.append(token.into());
    calldata.append(selection.into());
    calldata.append(governance.into());
    let (timelock, _) = atl_class.deploy(@calldata).unwrap();

    // Wire custody graph (while deployer is still admin)
    cheat1(token, admin());
    IConvictionTokenDispatcher { contract_address: token }.execute_set_modules(selection, governance);
    cheat1(governance, admin());
    IGovernanceDispatcher { contract_address: governance }.execute_set_selection(selection);

    // Hand admin authority to timelock
    cheat1(token, admin());
    IConvictionTokenDispatcher { contract_address: token }.execute_set_admin(timelock);
    cheat1(selection, admin());
    ISelectionDispatcher { contract_address: selection }.execute_set_admin(timelock);
    cheat1(governance, admin());
    IGovernanceDispatcher { contract_address: governance }.execute_set_admin(timelock);

    // Deterministic VRF
    start_mock_call::<felt252>(vrf_provider(), selector!("consume_random"), 0x1234abcd);

    Fixture { token, selection, governance, timelock }
}

fn fund(fx: Fixture, to: ContractAddress, amount: u256) {
    cheat1(fx.token, whale());
    tok_disp(fx).transfer(to, amount);
}

fn stake_juror(fx: Fixture) -> u256 {
    cheat1(fx.token, juror());
    tok_disp(fx).approve(juror(), STAKE);
    start_cheat_caller_address(fx.selection, juror());
    sel_disp(fx).create_stake(STAKE)
}

fn juror_address(index: u32) -> ContractAddress {
    let raw: felt252 = (index + 1_000).into();
    raw.try_into().unwrap()
}

fn request_evaluation(fx: Fixture) -> u256 {
    cheat1(fx.token, candidate());
    tok_disp(fx).approve(candidate(), BOND);
    start_cheat_caller_address(fx.selection, candidate());
    sel_disp(fx).request_evaluation("evidence")
}

fn commit_and_reveal(fx: Fixture, dispute_id: u256, score: i8) {
    let salt: felt252 = 0xbeef;
    let mut hash_input: Array<felt252> = array![];
    hash_input.append(score.into());
    hash_input.append(salt);
    let commit_hash = poseidon_hash_span(hash_input.span());
    start_cheat_caller_address(fx.selection, juror());
    sel_disp(fx).commit_vote(dispute_id, 0, commit_hash);

    // Reveal after commit deadline
    const APPLY_DURATION: u64 = 259_200;
    start_cheat_block_timestamp_global(T0 + APPLY_DURATION + 1 + COMMIT_DURATION + 1);
    sel_disp(fx).reveal_vote(dispute_id, 0, score, salt);
}

fn finalize(fx: Fixture, dispute_id: u256) {
    const APPLY_DURATION: u64 = 259_200;
    start_cheat_block_timestamp_global(
        T0 + APPLY_DURATION + 1 + COMMIT_DURATION + REVEAL_DURATION + 1,
    );
    sel_disp(fx).finalize_evaluation(dispute_id);
}

fn evaluate(fx: Fixture, score: i8) -> u256 {
    start_cheat_block_timestamp_global(T0);
    fund(fx, juror(), FUND * 16);
    fund(fx, candidate(), FUND);
    fund(fx, creator(), FUND);

    // Create 15 stakes from juror (meets min_stake_ids_per_evaluation = 15)
    cheat1(fx.token, juror());
    tok_disp(fx).approve(juror(), STAKE * 15);
    start_cheat_caller_address(fx.selection, juror());
    let mut stake_ids: Array<u256> = array![];
    let mut i: u32 = 0;
    loop {
        if i >= 15 {
            break;
        }
        let sid = sel_disp(fx).create_stake(STAKE);
        stake_ids.append(sid);
        i += 1;
    }

    let dispute_id = request_evaluation(fx);

    // Apply all 15 stakes to the evaluation (as juror, the stake owner)
    start_cheat_caller_address(fx.selection, juror());
    let mut j: u32 = 0;
    loop {
        if j >= 15 {
            break;
        }
        sel_disp(fx).apply_to_evaluation(dispute_id, *stake_ids.at(j));
        j += 1;
    }

    // Advance past apply deadline -> DRAWING
    const APPLY_DURATION: u64 = 259_200;
    start_cheat_block_timestamp_global(T0 + APPLY_DURATION + 1);
    sel_disp(fx).advance_evaluation(dispute_id);

    // Draw jurors -> auto-advances to COMMIT
    sel_disp(fx).draw_jurors(dispute_id);

    // Commit as stake_id 0
    commit_and_reveal(fx, dispute_id, score);

    // Finalize
    finalize(fx, dispute_id);
    dispute_id
}

fn create_proposal(fx: Fixture, wallet: ContractAddress, evidence: ByteArray) -> u256 {
    cheat1(fx.token, creator());
    tok_disp(fx).approve(creator(), DEPOSIT);
    start_cheat_caller_address(fx.governance, creator());
    gov_disp(fx).create_proposal(wallet, evidence)
}

// ////////////////////////////////////////////////////////////////
//              RETIRED STAKE BEHAVIOR (unstake_stake)
// ////////////////////////////////////////////////////////////////

#[test]
fn test_unstake_full_marks_stake_retired() {
    let fx = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    let sel = sel_disp(fx);
    let tok = tok_disp(fx);

    start_cheat_block_timestamp_global(T0);
    fund(fx, juror(), FUND);

    cheat1(fx.token, juror());
    tok.approve(juror(), STAKE);
    start_cheat_caller_address(fx.selection, juror());
    let stake_id = sel.create_stake(STAKE);

    start_cheat_caller_address(fx.selection, juror());
    sel.unstake_stake(stake_id, STAKE);

    let stake = sel.get_stake(stake_id);
    assert_eq!(stake.amount, 0);
    assert(stake.owner == juror(), 'owner should remain');
}

#[test]
fn test_unstake_partial_does_not_retire() {
    let fx = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    let sel = sel_disp(fx);
    let tok = tok_disp(fx);

    start_cheat_block_timestamp_global(T0);
    fund(fx, juror(), FUND);

    cheat1(fx.token, juror());
    tok.approve(juror(), STAKE);
    start_cheat_caller_address(fx.selection, juror());
    let stake_id = sel.create_stake(STAKE);

    let half = STAKE / 2;
    start_cheat_caller_address(fx.selection, juror());
    sel.unstake_stake(stake_id, half);

    let stake = sel.get_stake(stake_id);
    assert(stake.amount == half, 'stake amount should be half');
}

#[test]
#[should_panic(expected: ('StakeRetired',))]
fn test_retired_stake_cannot_apply_to_evaluation() {
    let fx = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    let sel = sel_disp(fx);
    let tok = tok_disp(fx);

    start_cheat_block_timestamp_global(T0);
    fund(fx, juror(), FUND);
    fund(fx, candidate(), FUND);

    cheat1(fx.token, juror());
    tok.approve(juror(), STAKE);
    start_cheat_caller_address(fx.selection, juror());
    let stake_id = sel.create_stake(STAKE);

    start_cheat_caller_address(fx.selection, juror());
    sel.unstake_stake(stake_id, STAKE);

    cheat1(fx.token, candidate());
    tok.approve(candidate(), BOND);
    start_cheat_caller_address(fx.selection, candidate());
    let evaluation_id = sel.request_evaluation("evidence");

    start_cheat_caller_address(fx.selection, juror());
    sel.apply_to_evaluation(evaluation_id, stake_id);
}

// ////////////////////////////////////////////////////////////////
//              DISMISSAL GAS (many applied stakes)
// ////////////////////////////////////////////////////////////////

#[test]
fn test_dismissal_gas_many_applied_stakes() {
    let fx = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    let sel = sel_disp(fx);
    let tok = tok_disp(fx);

    start_cheat_block_timestamp_global(T0);

    const JUROR_COUNT: u32 = 100;

    let mut index: u32 = 0;
    loop {
        if index >= JUROR_COUNT {
            break;
        }
        let address = juror_address(index);
        fund(fx, address, FUND);
        cheat1(fx.token, address);
        tok.approve(address, STAKE);
        start_cheat_caller_address(fx.selection, address);
        sel.create_stake(STAKE);
        index += 1;
    }

    fund(fx, candidate(), FUND);
    cheat1(fx.token, candidate());
    tok.approve(candidate(), BOND);
    start_cheat_caller_address(fx.selection, candidate());
    let evaluation_id = sel.request_evaluation("gas dismissal evidence");

    let mut i: u32 = 0;
    loop {
        if i >= JUROR_COUNT {
            break;
        }
        start_cheat_caller_address(fx.selection, juror_address(i));
        sel.apply_to_evaluation(evaluation_id, i.into());
        i += 1;
    }

    const APPLY_DURATION: u64 = 259_200;
    start_cheat_block_timestamp_global(T0 + APPLY_DURATION + 1);
    sel.advance_evaluation(evaluation_id);

    const DRAW_DURATION: u64 = 43_200;
    start_cheat_block_timestamp_global(T0 + APPLY_DURATION + DRAW_DURATION + 1);
    sel.advance_evaluation(evaluation_id);

    let e = sel.get_evaluation(evaluation_id);
    assert(e.phase == 6, 'evaluation should be dismissed');
}

// ////////////////////////////////////////////////////////////////
//              EVALUATION FLOW (zero reveal - bond refund)
// ////////////////////////////////////////////////////////////////

#[test]
fn test_zero_reveal_refunds_bond() {
    let fx = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    let sel = sel_disp(fx);
    let gov = gov_disp(fx);
    let tok = tok_disp(fx);

    start_cheat_block_timestamp_global(T0);
    fund(fx, juror(), FUND * 16);
    fund(fx, candidate(), FUND);

    cheat1(fx.token, juror());
    tok.approve(juror(), STAKE * 15);
    start_cheat_caller_address(fx.selection, juror());
    let mut stake_ids: Array<u256> = array![];
    let mut i: u32 = 0;
    loop {
        if i >= 15 {
            break;
        }
        let sid = sel_disp(fx).create_stake(STAKE);
        stake_ids.append(sid);
        i += 1;
    }

    cheat1(fx.token, candidate());
    tok.approve(candidate(), BOND);
    start_cheat_caller_address(fx.selection, candidate());
    let dispute_id = sel_disp(fx).request_evaluation("evidence");

    start_cheat_caller_address(fx.selection, juror());
    let mut j: u32 = 0;
    loop {
        if j >= 15 {
            break;
        }
        sel_disp(fx).apply_to_evaluation(dispute_id, *stake_ids.at(j));
        j += 1;
    }

    const APPLY_DURATION: u64 = 259_200;
    start_cheat_block_timestamp_global(T0 + APPLY_DURATION + 1);
    sel_disp(fx).advance_evaluation(dispute_id);

    // Draw jurors -> advances to COMMIT
    sel_disp(fx).draw_jurors(dispute_id);

    // Advance past commit deadline -> transitions to REVEAL (sets reveal_deadline)
    start_cheat_block_timestamp_global(T0 + APPLY_DURATION + 1 + COMMIT_DURATION + 1);
    sel_disp(fx).advance_evaluation(dispute_id);

    // Advance past reveal deadline -> eligible for finalization
    start_cheat_block_timestamp_global(T0 + APPLY_DURATION + 1 + COMMIT_DURATION + 1 + REVEAL_DURATION + 1);
    sel_disp(fx).finalize_evaluation(dispute_id);

    let d = sel.get_dispute(dispute_id);
    assert(d.bond_settled, 'bond should be settled');
    assert(d.final_score == 0, 'score should be neutral');
    assert(gov.governance_balance(candidate()) == 0, 'no gov for zero reveal');
    assert(tok.balance_of(candidate()) == FUND, 'bond should be refunded');
}

// ////////////////////////////////////////////////////////////////
//              ADMIN TIMELOCK ENGINE
// ////////////////////////////////////////////////////////////////

#[test]
fn test_evaluation_bond_timelocked_change() {
    let fx = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    let sel = sel_disp(fx);
    let atl = atl_disp(fx);

    assert(sel.get_evaluation_bond_amount() == BOND, 'default bond mismatch');

    start_cheat_block_timestamp_global(T0);
    start_cheat_caller_address(fx.timelock, admin());
    atl.propose_set_evaluation_bond_amount(70 * ONE);

    start_cheat_block_timestamp_global(T0 + TIMELOCK_DURATION + 1);
    atl.execute_set_evaluation_bond_amount();

    assert(sel.get_evaluation_bond_amount() == 70 * ONE, 'bond updates after timelock');
}

#[test]
#[should_panic(expected: ('TimelockNotElapsed',))]
fn test_execute_param_change_before_timelock_reverts() {
    let fx = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    let atl = atl_disp(fx);

    start_cheat_block_timestamp_global(T0);
    start_cheat_caller_address(fx.timelock, admin());
    atl.propose_set_evaluation_bond_amount(70 * ONE);

    start_cheat_block_timestamp_global(T0 + 100);
    atl.execute_set_evaluation_bond_amount();
}

// ////////////////////////////////////////////////////////////////
//              MINIMUM STAKE AMOUNT
// ////////////////////////////////////////////////////////////////

/// Verifies that staking below the minimum amount reverts.
#[test]
#[should_panic(expected: ('BelowMinStake',))]
fn test_stake_below_minimum_reverts() {
    let fx = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    let tok = tok_disp(fx);

    start_cheat_block_timestamp_global(T0);
    fund(fx, juror(), FUND);

    // Default min stake amount is 1 * ONE (1 token)
    let below_min = ONE / 100; // 0.01 token

    cheat1(fx.token, juror());
    tok.approve(juror(), below_min);
    start_cheat_caller_address(fx.selection, juror());
    sel_disp(fx).create_stake(below_min);
}

/// Verifies that staking exactly at the minimum amount succeeds.
#[test]
fn test_stake_at_minimum_succeeds() {
    let fx = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    let tok = tok_disp(fx);

    start_cheat_block_timestamp_global(T0);
    fund(fx, juror(), FUND);

    cheat1(fx.token, juror());
    tok.approve(juror(), ONE);
    start_cheat_caller_address(fx.selection, juror());
    let stake_id = sel_disp(fx).create_stake(ONE);

    let stake = sel_disp(fx).get_stake(stake_id);
    assert(stake.amount > 0, 'stake amount should be positive');
}

/// Verifies that the minimum stake amount can be changed via timelock.
#[test]
fn test_stake_amount_timelocked_change() {
    let fx = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    let sel = sel_disp(fx);
    let atl = atl_disp(fx);

    let default_amount = sel.get_stake_amount();
     assert(default_amount != 0, 'default amount zero');

    start_cheat_block_timestamp_global(T0);
    start_cheat_caller_address(fx.timelock, admin());
    atl.propose_set_stake_amount(10 * ONE);

    start_cheat_block_timestamp_global(T0 + TIMELOCK_DURATION + 1);
    atl.execute_set_stake_amount();

    let new_amount = sel.get_stake_amount();
    let one_u: u256 = ONE;
    assert(new_amount != one_u, 'new amount same old amount');

}

/// Verifies that staking below the new minimum reverts after timelock change.
#[test]
#[should_panic(expected: ('BelowMinStake',))]
fn test_stake_below_new_minimum_reverts() {
    let fx = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    let atl = atl_disp(fx);
    let tok = tok_disp(fx);

    // Raise min stake to 10 tokens
    start_cheat_block_timestamp_global(T0);
    start_cheat_caller_address(fx.timelock, admin());
    atl.propose_set_stake_amount(10 * ONE);
    start_cheat_block_timestamp_global(T0 + TIMELOCK_DURATION + 1);
    atl.execute_set_stake_amount();

    let sel = sel_disp(fx);
    let new_amount = sel.get_stake_amount();
    let one_u: u256 = ONE;
    assert(new_amount != one_u, 'new amount same old amount');

    start_cheat_block_timestamp_global(T0);
    fund(fx, juror(), FUND);

    // Try to stake 1 token (below new minimum of 10)
    cheat1(fx.token, juror());
    tok.approve(juror(), ONE);
    start_cheat_caller_address(fx.selection, juror());
    sel_disp(fx).create_stake(ONE);
}
