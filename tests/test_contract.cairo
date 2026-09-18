// SPDX-License-Identifier: MIT
//! snforge test suite for `stakeholder_governance::StakeholderConviction`.
//!
//! NOTES
//! -----
//! * Cartridge VRF is exercised by mocking `consume_random` on a stub
//!   `vrf_provider` address via `start_mock_call`, keeping the juror draw
//!   deterministic (a single staked juror absorbs every draw).
//! * Balance assertions are done through the embedded ERC20 dispatcher
//!   (same contract address) and the contract's public view getters only,
//!   because the contract's events/structs inside `mod StakeholderConviction`
//!   are not `pub` and cannot be imported from the integration test crate.
//! * All amounts are in the ERC20's native 18-decimal unit ("wei").
//! * Time is driven with per-contract `start_cheat_block_timestamp`.

use core::poseidon::poseidon_hash_span;
use starknet::ContractAddress;

use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_block_timestamp,
    start_cheat_caller_address, start_mock_call,
};

use openzeppelin_interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use stakeholder_governance::{
    IStakeholderConvictionDispatcher, IStakeholderConvictionDispatcherTrait,
};

// ////////////////////////////////////////////////////////////////
                        // SHARED TEST CONSTANTS
// ////////////////////////////////////////////////////////////////

const ONE: u256 = 1_000_000_000_000_000_000;

// Constructor defaults used by most tests.
const BOND: u256 = 50 * ONE;
const DEPOSIT: u256 = 10 * ONE;
const THRESHOLD: u256 = 1 * ONE;
const REWARD_MULT: u256 = 100 * ONE;        // used for scores 4-5
const MINI_REWARD_MULT: u256 = 10 * ONE;    // used for scores 1-3

const STAKE: u256 = 100 * ONE;
const FUND: u256 = 1_000 * ONE;

const T0: u64 = 1_000_000;
const COMMIT_PHASE_TS: u64 = T0 + 100;
const REVEAL_PHASE_TS: u64 = T0 + 86_401;   // after 1-day commit deadline
const FINALIZE_TS: u64 = T0 + 172_801;      // after 1-day reveal deadline
const TIMELOCK_DURATION: u64 = 259_200;     // 3-day admin timelock

// ////////////////////////////////////////////////////////////////
                            // TEST FIXTURE
// ////////////////////////////////////////////////////////////////

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

fn gov_disp(contract: ContractAddress) -> IStakeholderConvictionDispatcher {
    IStakeholderConvictionDispatcher { contract_address: contract }
}

fn tok_disp(contract: ContractAddress) -> IERC20Dispatcher {
    IERC20Dispatcher { contract_address: contract }
}

/// Declares + deploys the contract and stubs VRF randomness.
fn deploy(
    threshold: u256, reward_multiplier: u256, mini_reward_multiplier: u256,
) -> ContractAddress {
    let contract_class = declare("StakeholderConviction").unwrap().contract_class();

    let mut calldata: Array<felt252> = array![];
    calldata.append(admin().into());
    let name: ByteArray = "StakeholderConviction";
    let symbol: ByteArray = "STK";
    name.serialize(ref calldata);
    symbol.serialize(ref calldata);
    calldata.append(whale().into());
    (32_u32).serialize(ref calldata);
    calldata.append(vrf_provider().into());
    (BOND).serialize(ref calldata);
    (DEPOSIT).serialize(ref calldata);
    threshold.serialize(ref calldata);
    reward_multiplier.serialize(ref calldata);
    mini_reward_multiplier.serialize(ref calldata);

    let (contract_address, _) = contract_class.deploy(@calldata).unwrap();

    // Deterministic randomness for the juror draw.
    start_mock_call::<felt252>(vrf_provider(), selector!("consume_random"), 0x1234abcd);

    contract_address
}

/// `from` (initially the whale) sends `amount` tokens to `to`.
fn fund(contract: ContractAddress, to: ContractAddress, amount: u256) {
    start_cheat_caller_address(contract, whale());
    tok_disp(contract).transfer(to, amount);
}

/// Juror approves the contract and stakes `STAKE`.
fn stake_juror(contract: ContractAddress) {
    start_cheat_caller_address(contract, juror());
    tok_disp(contract).approve(juror(), STAKE);
    gov_disp(contract).stake(STAKE);
}

/// Candidate requests evaluation (pays the bond). VRF draws the single juror.
fn request_evaluation(contract: ContractAddress) -> u256 {
    start_cheat_caller_address(contract, candidate());
    tok_disp(contract).approve(candidate(), BOND);
    gov_disp(contract).request_evaluation("evidence")
}

/// Drawn juror commits `score` then reveals it after the commit deadline.
fn disclose(contract: ContractAddress, dispute_id: u256, score: i8) {
    let salt: felt252 = 0xbeef;
    let mut hash_input: Array<felt252> = array![];
    hash_input.append(score.into());
    hash_input.append(salt);
    let commit_hash = poseidon_hash_span(hash_input.span());

    start_cheat_caller_address(contract, juror());
    start_cheat_block_timestamp(contract, COMMIT_PHASE_TS);
    gov_disp(contract).commit_vote(dispute_id, commit_hash);

    start_cheat_block_timestamp(contract, REVEAL_PHASE_TS);
    gov_disp(contract).reveal_vote(dispute_id, score, salt);
}

/// Anyone can finalize once the reveal window has closed.
fn finalize(contract: ContractAddress, dispute_id: u256) {
    start_cheat_block_timestamp(contract, FINALIZE_TS);
    gov_disp(contract).finalize_selection(dispute_id);
}

/// Full selection flow for one candidate; returns the positive/negative score outcome.
fn evaluate(contract: ContractAddress, score: i8) -> u256 {
    start_cheat_block_timestamp(contract, T0);
    fund(contract, juror(), FUND);
    fund(contract, candidate(), FUND);
    fund(contract, creator(), FUND);

    stake_juror(contract);
    let dispute_id = request_evaluation(contract);
    disclose(contract, dispute_id, score);
    finalize(contract, dispute_id);
    dispute_id
}

/// Creator approves the deposit and creates a proposal.
fn create_proposal(contract: ContractAddress, wallet: ContractAddress, evidence: ByteArray) -> u256 {
    start_cheat_caller_address(contract, creator());
    tok_disp(contract).approve(creator(), DEPOSIT);
    gov_disp(contract).create_proposal(wallet, evidence)
}

// ////////////////////////////////////////////////////////////////
            // STAGE 1: EVALUATION BOND REFUND / SLASH
// ////////////////////////////////////////////////////////////////

#[test]
fn test_positive_score_refunds_bond_and_mints_governance() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    let dispute_id = evaluate(contract, 5);

    let gov = gov_disp(contract);
    let tok = tok_disp(contract);

    // Governance tokens minted to the candidate (score 5 -> 50_000 tokens).
    assert(gov.governance_balance(candidate()) == 50_000 * ONE, 'gov should be minted');
    assert(gov.governance_available(candidate()) == 50_000 * ONE, 'gov should be free');

    // Bond refunded -> candidate is back to their full funded balance.
    assert(tok.balance_of(candidate()) == FUND, 'bond should be refunded');

    let d = gov.get_dispute(dispute_id);
    assert(d.bond_settled, 'bond should be settled');
    assert(d.final_score == 5, 'final score should be 5');
    assert(d.governance_tokens_minted == 50_000 * ONE, 'minted amount mismatch');
    assert(gov.get_active_dispute_for_candidate(candidate()) == 0, 'no active dispute expected');
}

#[test]
fn test_negative_score_slashes_bond_and_mints_nothing() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    let dispute_id = evaluate(contract, -5);

    let gov = gov_disp(contract);
    let tok = tok_disp(contract);

    assert(gov.governance_balance(candidate()) == 0, 'no gov for non-positive score');

    // Bond kept by the contract -> candidate keeps only the remainder.
    assert(tok.balance_of(candidate()) == FUND - BOND, 'bond should be slashed');

    let d = gov.get_dispute(dispute_id);
    assert(d.bond_settled, 'bond should be settled');
    assert(d.final_score == -5, 'final score should be -5');
    assert(d.slash_pool == BOND, 'bond in slash pool');
    assert(d.total_coherent_weight == 10, 'single juror should be coherent');

    // The only drawn juror was coherent (-5 vs -5), so they can claim the
    // slash pool (which equals the slashed bond).
    start_cheat_caller_address(contract, juror());
    gov.claim_juror_reward(dispute_id);
    assert(tok.balance_of(juror()) == FUND - STAKE + BOND, 'coherent juror paid');
}

// ////////////////////////////////////////////////////////////////
    // STAGE 3: CONVICTION VOTING + SCORE-BASED REWARDS
// ////////////////////////////////////////////////////////////////

#[test]
fn test_positive_score_rewards_and_refunds_deposit() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    evaluate(contract, 5);

    let gov = gov_disp(contract);
    let tok = tok_disp(contract);

    let proposal_id = create_proposal(contract, funding_wallet(), "proposal evidence");

    start_cheat_caller_address(contract, candidate());
    let conviction_id = gov.create_conviction(1, 1_000 * ONE);
    gov.vote_with_conviction(proposal_id, conviction_id, 5);

    // weight = level(1) * available(50_000 - 1_000 tokens).
    assert(gov.get_conviction_power(candidate(), conviction_id) == 49_000 * ONE, 'bad power');
    assert(gov.get_proposal_total_power(proposal_id) == 49_000 * ONE, 'bad total power');

    gov.execute_proposal(proposal_id);

    let p = gov.get_proposal(proposal_id);
    assert(p.executed, 'proposal should be executed');
    assert(p.final_score == 5, 'final score should be 5');

    // score 5 (>3) -> reward = score * reward_multiplier.
    assert(tok.balance_of(funding_wallet()) == 5 * REWARD_MULT, 'reward not minted');
    // Deposit refunded to the author.
    assert(tok.balance_of(creator()) == FUND, 'deposit should be refunded');
}

#[test]
fn test_score_1_to_3_uses_mini_reward_multiplier() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    evaluate(contract, 5);

    let gov = gov_disp(contract);
    let tok = tok_disp(contract);

    // Proposal 0 -> score 5 -> full reward multiplier.
    let p0 = create_proposal(contract, funding_wallet(), "proposal 0 evidence");
    start_cheat_caller_address(contract, candidate());
    let c0 = gov.create_conviction(1, 1_000 * ONE);
    gov.vote_with_conviction(p0, c0, 5);

    // Proposal 1 -> score 2 -> mini reward multiplier.
    let p1 = create_proposal(contract, funding_wallet(), "proposal 1 evidence");
    start_cheat_caller_address(contract, candidate());
    let c1 = gov.create_conviction(1, 1_000 * ONE);
    gov.vote_with_conviction(p1, c1, 2);

    gov.execute_proposal(p0);
    let w0 = gov.get_proposal(p0);
    assert(w0.final_score == 5, 'p0 score should be 5');

    gov.execute_proposal(p1);
    let w1 = gov.get_proposal(p1);
    assert(w1.final_score == 2, 'p1 score should be 2');

    // reward = 5 * REWARD_MULT + 2 * MINI_REWARD_MULT.
    assert(tok.balance_of(funding_wallet()) == 5 * REWARD_MULT + 2 * MINI_REWARD_MULT,
        'wrong total reward');
    // Both deposits refunded.
    assert(tok.balance_of(creator()) == FUND, 'both deposits refunded');
}

#[test]
fn test_negative_score_slashes_proposal_deposit() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    evaluate(contract, 5);

    let gov = gov_disp(contract);
    let tok = tok_disp(contract);

    let proposal_id = create_proposal(contract, funding_wallet(), "proposal evidence");

    start_cheat_caller_address(contract, candidate());
    let conviction_id = gov.create_conviction(1, 1_000 * ONE);
    gov.vote_with_conviction(proposal_id, conviction_id, -5);

    gov.execute_proposal(proposal_id);

    let p = gov.get_proposal(proposal_id);
    assert(p.executed, 'proposal should be executed');
    assert(p.final_score == -5, 'final score should be -5');

    assert(tok.balance_of(funding_wallet()) == 0, 'no reward on non-positive');
    assert(tok.balance_of(creator()) == FUND - DEPOSIT, 'deposit should be slashed');
}

#[test]
#[should_panic(expected: ('ThresholdNotMet',))]
fn test_execute_proposal_below_threshold_reverts() {
    let contract = deploy(200_000 * ONE, REWARD_MULT, MINI_REWARD_MULT);
    evaluate(contract, 5);

    let gov = gov_disp(contract);
    let proposal_id = create_proposal(contract, funding_wallet(), "proposal evidence");

    start_cheat_caller_address(contract, candidate());
    let conviction_id = gov.create_conviction(1, 1_000 * ONE);
    gov.vote_with_conviction(proposal_id, conviction_id, 5);

    // total power (49_000 tokens) < threshold (200_000 tokens).
    gov.execute_proposal(proposal_id);
}

// ////////////////////////////////////////////////////////////////
            // CONVICTION POWER & LOCK ACCOUNTING
// ////////////////////////////////////////////////////////////////

#[test]
fn test_conviction_power_and_release_accounting() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    evaluate(contract, 5);

    let gov = gov_disp(contract);
    let proposal_id = create_proposal(contract, funding_wallet(), "proposal evidence");

    start_cheat_caller_address(contract, candidate());
    let conviction_id = gov.create_conviction(3, 2_000 * ONE);

    assert(gov.governance_locked(candidate()) == 2_000 * ONE, 'locked should increase');
    assert(gov.governance_available(candidate()) == 48_000 * ONE, 'available should shrink');

    gov.vote_with_conviction(proposal_id, conviction_id, 5);
    assert(gov.get_conviction_power(candidate(), conviction_id) == 3 * 48_000 * ONE,
        'bad voting power');
    assert(gov.get_proposal_total_power(proposal_id) == 3 * 48_000 * ONE, 'bad total power');

    // remove_support resets power to zero.
    gov.remove_support(conviction_id);
    assert(gov.get_conviction_power(candidate(), conviction_id) == 0, 'power should reset');
    assert(gov.get_proposal_total_power(proposal_id) == 0, 'total power should reset');

    // release_conviction returns the locked governance, now released.
    gov.release_conviction(conviction_id);
    assert(gov.governance_locked(candidate()) == 0, 'locked should return to zero');
    assert(gov.governance_available(candidate()) == 50_000 * ONE, 'available should restore');

    let c = gov.get_conviction(candidate(), conviction_id);
    assert(c.released, 'conviction should be released');
}

// ////////////////////////////////////////////////////////////////
                    // ADMIN TIMELOCK ENGINE
// ////////////////////////////////////////////////////////////////

#[test]
fn test_num_draws_default_and_timelocked_change() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    let gov = gov_disp(contract);

    assert(gov.get_num_draws() == 10, 'default num_draws should be 10');

    start_cheat_block_timestamp(contract, T0);
    start_cheat_caller_address(contract, admin());
    gov.propose_set_num_draws(12);

    let pending = gov.get_pending_change('NUM_DRAWS');
    assert(pending.exists, 'change should be pending');
    assert(pending.new_value == 12, 'pending value mismatch');

    start_cheat_block_timestamp(contract, T0 + TIMELOCK_DURATION + 1);
    gov.execute_set_num_draws();

    assert(gov.get_num_draws() == 12, 'num_draws should update');

    let pending = gov.get_pending_change('NUM_DRAWS');
    assert(!pending.exists, 'pending entry should be cleared');
}

#[test]
#[should_panic(expected: ('TimelockNotElapsed',))]
fn test_execute_param_change_before_timelock_reverts() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    let gov = gov_disp(contract);

    start_cheat_block_timestamp(contract, T0);
    start_cheat_caller_address(contract, admin());
    gov.propose_set_evaluation_bond_amount(70 * ONE);

    start_cheat_block_timestamp(contract, T0 + 100);
    gov.execute_set_evaluation_bond_amount();
}

#[test]
fn test_evaluation_bond_timelocked_change_takes_effect() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    let gov = gov_disp(contract);

    assert(gov.get_evaluation_bond_amount() == BOND, 'default bond mismatch');

    start_cheat_block_timestamp(contract, T0);
    start_cheat_caller_address(contract, admin());
    gov.propose_set_evaluation_bond_amount(70 * ONE);

    let pending = gov.get_pending_change('EVAL_BOND_AMT');
    assert(pending.exists, 'change should be pending');
    assert(pending.new_value == 70 * ONE, 'pending value mismatch');
    assert(pending.effective_at == T0 + TIMELOCK_DURATION, 'effective_at mismatch');

    start_cheat_block_timestamp(contract, T0 + TIMELOCK_DURATION + 1);
    gov.execute_set_evaluation_bond_amount();

    assert(gov.get_evaluation_bond_amount() == 70 * ONE, 'bond updates after timelock');
}