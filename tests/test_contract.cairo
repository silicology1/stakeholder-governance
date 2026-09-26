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
use stakeholder_governance::utils::isqrt;
use stakeholder_governance::{
    IStakeholderConvictionDispatcher, IStakeholderConvictionDispatcherTrait,
};

// ////////////////////////////////////////////////////////////////
                        // SHARED TEST CONSTANTS
// ////////////////////////////////////////////////////////////////

/// One token expressed in the ERC20's 18-decimal base unit.
const ONE: u256 = 1_000_000_000_000_000_000;

/// Evaluation bond used by the standard test fixture.
const BOND: u256 = 50 * ONE;
/// Proposal deposit used by the standard test fixture.
const DEPOSIT: u256 = 10 * ONE;
/// Proposal execution threshold used by most tests.
const THRESHOLD: u256 = 1_000_000_000;
/// Full reward multiplier for scores four and five.
const REWARD_MULT: u256 = 100 * ONE;
/// Reduced reward multiplier for scores one through three.
const MINI_REWARD_MULT: u256 = 10 * ONE;

/// Juror stake used by the standard evaluation fixture.
const STAKE: u256 = 100 * ONE;
/// Number of distinct jurors used by the weighted multi-juror draw test.
const JUROR_COUNT: u32 = 50;
/// Token amount transferred to each fixture participant.
const FUND: u256 = 1_000 * ONE;

/// Base timestamp for deterministic phase transitions.
const T0: u64 = 1_000_000;
/// Timestamp at which the fixture commits its sole vote.
const COMMIT_PHASE_TS: u64 = T0 + 100;
/// Timestamp after the one-day commit deadline and during reveal.
const REVEAL_PHASE_TS: u64 = T0 + 86_401;
/// Timestamp after the one-day reveal deadline and eligible for finalization.
const FINALIZE_TS: u64 = T0 + 172_801;
/// Three-day delay enforced by parameter-change proposals.
const TIMELOCK_DURATION: u64 = 259_200;

/// Duration of one fixed 30-day budget month.
const MONTH_SECONDS: u64 = 2_592_000;
/// Basis-point denominator used by the monthly inflation calculation.
const BUDGET_BPS_DENOM: u256 = 10_000;
/// Number of monthly budget periods in a year.
const MONTHS_PER_YEAR: u256 = 12;

// ////////////////////////////////////////////////////////////////
                            // TEST FIXTURE
// ////////////////////////////////////////////////////////////////

/// Returns the deterministic default-admin address used by the test suite.
fn admin() -> ContractAddress {
    'admin'.try_into().unwrap()
}

/// Returns the address that receives the constructor's initial token supply.
fn whale() -> ContractAddress {
    'whale'.try_into().unwrap()
}

/// Returns the address used as the sole staked juror in deterministic tests.
fn juror() -> ContractAddress {
    'juror'.try_into().unwrap()
}

/// Returns the address used as the evaluated candidate and conviction owner.
fn candidate() -> ContractAddress {
    'candidate'.try_into().unwrap()
}

/// Returns the address used as the funding-proposal author.
fn creator() -> ContractAddress {
    'creator'.try_into().unwrap()
}

/// Returns the address that receives proposal rewards.
fn funding_wallet() -> ContractAddress {
    'funding_wallet'.try_into().unwrap()
}

/// Returns the address mocked as the Cartridge VRF provider.
fn vrf_provider() -> ContractAddress {
    'vrf_provider'.try_into().unwrap()
}

/// Creates a contract dispatcher for the governance ABI.
fn gov_disp(contract: ContractAddress) -> IStakeholderConvictionDispatcher {
    IStakeholderConvictionDispatcher { contract_address: contract }
}

/// Creates an ERC20 dispatcher targeting the contract's embedded token.
fn tok_disp(contract: ContractAddress) -> IERC20Dispatcher {
    IERC20Dispatcher { contract_address: contract }
}

/// Declares and deploys the contract with deterministic VRF randomness.
fn deploy(
    threshold: u256, reward_multiplier: u256, mini_reward_multiplier: u256,
) -> ContractAddress {
    deploy_with_capacity(threshold, reward_multiplier, mini_reward_multiplier, 32_u32)
}

/// Declares and deploys the contract with a selected Fenwick-tree capacity.
fn deploy_with_capacity(
    threshold: u256,
    reward_multiplier: u256,
    mini_reward_multiplier: u256,
    tree_capacity: u32,
) -> ContractAddress {
    let contract_class = declare("StakeholderConviction").unwrap().contract_class();

    let mut calldata: Array<felt252> = array![];
    calldata.append(admin().into());
    let name: ByteArray = "StakeholderConviction";
    let symbol: ByteArray = "STK";
    name.serialize(ref calldata);
    symbol.serialize(ref calldata);
    calldata.append(whale().into());
    tree_capacity.serialize(ref calldata);
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

/// Transfers `amount` tokens from the whale recipient to `to`.
fn fund(contract: ContractAddress, to: ContractAddress, amount: u256) {
    start_cheat_caller_address(contract, whale());
    tok_disp(contract).transfer(to, amount);
}

/// Has the default juror approve and deposit the standard test stake.
fn stake_juror(contract: ContractAddress) {
    start_cheat_caller_address(contract, juror());
    tok_disp(contract).approve(juror(), STAKE);
    gov_disp(contract).stake(STAKE);
}

/// Returns a distinct numeric address for a multi-juror test index.
fn juror_address(index: u32) -> ContractAddress {
    let raw: felt252 = (index + 1_000).into();
    raw.try_into().unwrap()
}

/// Requests a candidate evaluation with the standard bond and evidence.
fn request_evaluation(contract: ContractAddress) -> u256 {
    start_cheat_caller_address(contract, candidate());
    tok_disp(contract).approve(candidate(), BOND);
    gov_disp(contract).request_evaluation("evidence")
}

/// Commits and then reveals `score` as the deterministic sole juror.
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

/// Finalizes a dispute after the standard reveal-window timestamp.
fn finalize(contract: ContractAddress, dispute_id: u256) {
    start_cheat_block_timestamp(contract, FINALIZE_TS);
    gov_disp(contract).finalize_selection(dispute_id);
}

/// Runs the standard single-juror selection flow and returns its dispute ID.
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

/// Has the creator approve the standard deposit and create a proposal.
fn create_proposal(contract: ContractAddress, wallet: ContractAddress, evidence: ByteArray) -> u256 {
    start_cheat_caller_address(contract, creator());
    tok_disp(contract).approve(creator(), DEPOSIT);
    gov_disp(contract).create_proposal(wallet, evidence)
}

// ////////////////////////////////////////////////////////////////
            // STAGE 1: EVALUATION BOND REFUND / SLASH
// ////////////////////////////////////////////////////////////////

/// Verifies that a positive evaluation refunds the bond and mints governance tokens.
///
/// The sole juror reveals a score of five, and the test checks the candidate's
/// balances, governance state, dispute score, and active-dispute cleanup.
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

/// Verifies a 50-juror weighted selection pool and its 50 draw operations.
///
/// Each distinct address contributes the same stake, the configured draw
/// count is raised to 50, and every deduplicated selected juror receives one
/// open-dispute lock. Draws are weighted with replacement, so the test does
/// not require all 50 pool members to be selected.
#[test]
fn test_fifty_staked_jurors_participate_in_weighted_draw() {
    let contract = deploy_with_capacity(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT, 64_u32);
    let gov = gov_disp(contract);
    let tok = tok_disp(contract);

    start_cheat_block_timestamp(contract, T0);

    let mut index: u32 = 0;
    loop {
        if index >= JUROR_COUNT {
            break;
        }
        let address = juror_address(index);
        fund(contract, address, STAKE);
        start_cheat_caller_address(contract, address);
        tok.approve(address, STAKE);
        gov.stake(STAKE);
        index += 1;
    };

    let expected_total_weight: u256 = 50_u256 * STAKE;
    let total_weighted = gov.total_stake_weight() == expected_total_weight;
    assert(total_weighted, 'weight mismatch');

    fund(contract, candidate(), FUND);
    start_cheat_caller_address(contract, admin());
    gov.propose_set_num_draws(JUROR_COUNT);
    start_cheat_block_timestamp(contract, T0 + TIMELOCK_DURATION);
    gov.execute_set_num_draws();
    assert(gov.get_num_draws() == JUROR_COUNT, 'num draws should be configured');

    start_cheat_caller_address(contract, candidate());
    tok.approve(candidate(), BOND);
    let dispute_id = gov.request_evaluation("fifty-juror evidence");
    let d = gov.get_dispute(dispute_id);

    assert(d.num_draws == JUROR_COUNT, 'dispute should record 50 draws');
    let has_draws = d.unique_juror_count > 0_u32;
    assert(has_draws, 'no juror drawn');
    let draw_count_is_bounded = d.unique_juror_count <= JUROR_COUNT;
    assert(draw_count_is_bounded, 'too many unique');

    let mut locked_juror_count: u32 = 0;
    let mut check_index: u32 = 0;
    loop {
        if check_index >= JUROR_COUNT {
            break;
        }
        let address = juror_address(check_index);
        let stake_matches = gov.get_juror_stake(address) == STAKE;
        assert(stake_matches, 'stake missing');
        let open_disputes = gov.get_juror_open_dispute_count(address);
        let open_count_is_bounded = open_disputes <= 1_u32;
        assert(open_count_is_bounded, 'lock count high');
        if open_disputes == 1_u32 {
            let locked_stake_matches = gov.get_juror_locked_stake(address) == STAKE;
            assert(locked_stake_matches, 'wrong lock amount');
        } else {
            let unlocked_stake_matches = gov.get_juror_locked_stake(address) == 0_u256;
            assert(unlocked_stake_matches, 'unselected locked');
        }
        locked_juror_count += open_disputes;
        check_index += 1;
    };

    let lock_count_matches = locked_juror_count == d.unique_juror_count;
    assert(lock_count_matches, 'lock mismatch');
}

/// Verifies that a negative evaluation slashes the bond without minting governance.
///
/// The sole juror reveals a score of negative five, after which the coherent
/// juror claims the resulting slash-pool reward.
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

/// Verifies positive-score proposal execution, reward minting, and deposit refund.
///
/// A level-one conviction supplies enough power to pass the threshold, and the
/// test checks the frozen power, final score, recipient reward, and author refund.
#[test]
fn test_positive_score_rewards_and_refunds_deposit() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    evaluate(contract, 5);

    let gov = gov_disp(contract);
    let tok = tok_disp(contract);

    let proposal_id = create_proposal(contract, funding_wallet(), "proposal evidence");

    start_cheat_caller_address(contract, candidate());
    let conviction_id = gov.create_conviction(1, 1_000 * ONE);

    // Weight is STATIC: isqrt(level * amount), frozen at vote time.
    //   isqrt(1 * 1_000 tokens = 1e21 wei) = 31,622,776,601.
    start_cheat_block_timestamp(contract, FINALIZE_TS + 1000 * 3_600);
    gov.vote_with_conviction(proposal_id, conviction_id, 5);

    assert(gov.get_conviction_power(candidate(), conviction_id) == 31_622_776_601,
        'bad power');
    assert(gov.get_proposal_total_power(proposal_id) == 31_622_776_601, 'bad total power');

    gov.execute_proposal(proposal_id);

    let p = gov.get_proposal(proposal_id);
    assert(p.executed, 'proposal should be executed');
    assert(p.final_score == 5, 'final score should be 5');

    // score 5 (>3) -> reward = score * reward_multiplier.
    assert(tok.balance_of(funding_wallet()) == 5 * REWARD_MULT, 'reward not minted');
    // Deposit refunded to the author.
    assert(tok.balance_of(creator()) == FUND, 'deposit should be refunded');
}

/// Verifies the reduced reward multiplier for scores one through three.
///
/// Two proposals receive scores five and two, then the test confirms the full
/// and reduced payouts, final scores, and refunds for both deposits.
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

    // Proposal 1 -> score 2 -> mini reward multiplier.
    let p1 = create_proposal(contract, funding_wallet(), "proposal 1 evidence");
    start_cheat_caller_address(contract, candidate());
    let c1 = gov.create_conviction(1, 1_000 * ONE);

    // Both convictions were created at mint time; voting 1000 h later is still
    // inside each level-1 lock window (3.6M s < 9.46M s), so both accepted.
    start_cheat_block_timestamp(contract, FINALIZE_TS + 1000 * 3_600);
    gov.vote_with_conviction(p0, c0, 5);
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

/// Verifies that a negative proposal score slashes the author's deposit.
///
/// A conviction votes negative five, the proposal executes, and the test checks
/// that no reward is minted while the proposal deposit is forfeited.
#[test]
fn test_negative_score_slashes_proposal_deposit() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    evaluate(contract, 5);

    let gov = gov_disp(contract);
    let tok = tok_disp(contract);

    let proposal_id = create_proposal(contract, funding_wallet(), "proposal evidence");

    start_cheat_caller_address(contract, candidate());
    let conviction_id = gov.create_conviction(1, 1_000 * ONE);

    start_cheat_block_timestamp(contract, FINALIZE_TS + 1000 * 3_600);
    gov.vote_with_conviction(proposal_id, conviction_id, -5);

    gov.execute_proposal(proposal_id);

    let p = gov.get_proposal(proposal_id);
    assert(p.executed, 'proposal should be executed');
    assert(p.final_score == -5, 'final score should be -5');

    assert(tok.balance_of(funding_wallet()) == 0, 'no reward on non-positive');
    assert(tok.balance_of(creator()) == FUND - DEPOSIT, 'deposit should be slashed');
}

/// Verifies that proposal execution rejects power below the configured threshold.
///
/// A single small conviction votes on a proposal whose threshold is deliberately
/// high; voting succeeds, but execution must panic with `ThresholdNotMet`.
#[test]
#[should_panic(expected: ('ThresholdNotMet',))]
fn test_execute_proposal_below_threshold_reverts() {
    let contract = deploy(200_000 * ONE, REWARD_MULT, MINI_REWARD_MULT);
    evaluate(contract, 5);

    let gov = gov_disp(contract);
    let proposal_id = create_proposal(contract, funding_wallet(), "proposal evidence");

    start_cheat_caller_address(contract, candidate());
    let conviction_id = gov.create_conviction(1, 1_000 * ONE);

    // Static weight is isqrt(1 * 1e21 wei) = ~3.2e10, far below the
    // 200_000-token threshold, so execution must fail even though the vote
    // itself lands inside the conviction's level-1 lock window.
    start_cheat_block_timestamp(contract, FINALIZE_TS + 100 * 3_600);
    gov.vote_with_conviction(proposal_id, conviction_id, 5);

    gov.execute_proposal(proposal_id);
}

// ////////////////////////////////////////////////////////////////
            // CONVICTION POWER & LOCK ACCOUNTING
// ////////////////////////////////////////////////////////////////

/// Verifies conviction power, permanent votes, release eligibility, and re-locking.
///
/// A level-three conviction casts a vote, releases after its lock window, and
/// then locks the returned stake into a second conviction; both vote powers
/// remain frozen and the released vote continues to count.
#[test]
fn test_conviction_power_and_release_accounting() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    evaluate(contract, 5);

    let gov = gov_disp(contract);
    let proposal_id = create_proposal(contract, funding_wallet(), "proposal evidence");
    let proposal_id2 = create_proposal(contract, funding_wallet(), "proposal evidence 2");

    start_cheat_caller_address(contract, candidate());
    let conviction_id = gov.create_conviction(3, 2_000 * ONE);

    assert(gov.governance_locked(candidate()) == 2_000 * ONE, 'locked should increase');
    assert(gov.governance_available(candidate()) == 48_000 * ONE, 'available should shrink');

    // Level 3 -> lock window = 3 * conviction_base_lock. Weight is STATIC:
    //   isqrt(3 * 2_000 tokens = 6e21 wei) = 77,459,666,924, frozen at vote
    //   time and identical at any later read/execution.
    start_cheat_block_timestamp(contract, FINALIZE_TS + 500 * 3_600);
    gov.vote_with_conviction(proposal_id, conviction_id, 5);

    assert(gov.get_conviction_power(candidate(), conviction_id) == 77_459_666_924,
        'bad voting power');
    assert(gov.get_proposal_total_power(proposal_id) == 77_459_666_924, 'bad total power');

    // Votes are permanent commitments: a released conviction keeps its weight
    // on the ledger, but its stake only becomes free once the level-based
    // lock window has elapsed (`now >= created_at + 3 * conviction_base_lock`).
    let lock_expiry = FINALIZE_TS + 3 * 9_460_800;
    start_cheat_block_timestamp(contract, lock_expiry);
    let available_before = gov.governance_available(candidate());
    gov.release_conviction(conviction_id);
    assert(gov.governance_locked(candidate()) == 0, 'locked should return to zero');
    assert(
        gov.governance_available(candidate()) == available_before + 2_000 * ONE,
        'release should free the stake',
    );
    assert(gov.get_conviction_power(candidate(), conviction_id) == 77_459_666_924,
        'released vote must still count');
    assert(gov.get_proposal_total_power(proposal_id) == 77_459_666_924, 'power unchanged');

    let c = gov.get_conviction(candidate(), conviction_id);
    assert(c.released, 'conviction should be released');
    assert(c.votes_cast == 1, 'one vote on the ledger');

    // Rewind to grant mint time so decay reads revert to zero.
    start_cheat_block_timestamp(contract, FINALIZE_TS);
    assert(gov.governance_available(candidate()) == 50_000 * ONE, 'available should restore');

    // The unlocked stake can be committed to a fresh conviction that votes on
    // a different proposal.
    let conviction_id2 = gov.create_conviction(3, 2_000 * ONE);
    assert(gov.governance_locked(candidate()) == 2_000 * ONE, 're-locked after release');

    start_cheat_block_timestamp(contract, FINALIZE_TS + 500 * 3_600);
    gov.vote_with_conviction(proposal_id2, conviction_id2, 5);
    assert(gov.get_proposal_total_power(proposal_id2) == 77_459_666_924, 'new vote powers');
    assert(gov.get_proposal_total_power(proposal_id) == 77_459_666_924, 'old vote persists');
}

/// Verifies that one conviction cannot vote twice on the same proposal.
///
/// The first vote is accepted and the second identical vote must panic with
/// `AlreadyVotedOnProposal`.
#[should_panic(expected: ('AlreadyVotedOnProposal',))]
#[test]
fn test_conviction_cannot_vote_twice() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    evaluate(contract, 5);

    let gov = gov_disp(contract);
    let proposal_id = create_proposal(contract, funding_wallet(), "proposal evidence");

    start_cheat_caller_address(contract, candidate());
    let conviction_id = gov.create_conviction(1, 1_000 * ONE);

    start_cheat_block_timestamp(contract, FINALIZE_TS + 500 * 3_600);
    gov.vote_with_conviction(proposal_id, conviction_id, 5);
    gov.vote_with_conviction(proposal_id, conviction_id, 5);
}

// The old per-proposal supporter cap (MAX_PROPOSAL_SUPPORTERS = 200) is gone.
// A proposal's total power is a frozen accumulator bumped at vote time, so
// voting is unbounded: hundreds of backers cannot grief `execute_proposal`,
// which stays O(1) and passes at the very end. (The snforge VM limits the
// events a single test transaction may emit, so the raw emitter count here is
// capped at 400; the on-contract design itself scales without bound.)
/// Verifies unbounded supporter scaling with an O(1) proposal-power accumulator.
///
/// Four hundred convictions cast separate votes, after which the test checks the
/// exact aggregate and executes the proposal without iterating a supporter list.
#[test]
fn test_voting_scales_beyond_old_supporter_cap() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    evaluate(contract, 5);

    let gov = gov_disp(contract);
    let proposal_id = create_proposal(contract, funding_wallet(), "proposal evidence");

    start_cheat_caller_address(contract, candidate());
    let mut i: u32 = 0;
    loop {
        if i >= 400 {
            break;
        }
        // Each conviction locks 100 tokens and casts one +5 vote. In total the
        // candidate's entire 50_000-token governance balance is committed.
        let conviction_id = gov.create_conviction(1, 100 * ONE);
        gov.vote_with_conviction(proposal_id, conviction_id, 5);
        i += 1;
    };

    // power_total is the exact accumulator: 400 * isqrt(1 * 1e20 wei).
    let expected: u256 = 400 * 10_000_000_000;
    assert(gov.get_proposal_total_power(proposal_id) == expected, 'total power should scale');

    // O(1) execution: no supporter-list iteration, threshold check is direct.
    gov.execute_proposal(proposal_id);
    let p = gov.get_proposal(proposal_id);
    assert(p.executed, '400 backers execute');
}

// A single conviction may back multiple distinct proposals (not the same one
// twice) up to `max_votes_per_conviction`.
/// Verifies that one conviction can support multiple distinct proposals.
///
/// The same conviction votes with different scores on two proposals, and the
/// test checks the vote count, lock duration, and unchanged per-proposal power.
#[test]
fn test_single_conviction_votes_on_multiple_proposals() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    evaluate(contract, 5);

    let gov = gov_disp(contract);
    let p0 = create_proposal(contract, funding_wallet(), "proposal 0 evidence");
    let p1 = create_proposal(contract, funding_wallet(), "proposal 1 evidence");

    start_cheat_caller_address(contract, candidate());
    let conviction_id = gov.create_conviction(1, 1_000 * ONE);

    gov.vote_with_conviction(p0, conviction_id, 5);
    gov.vote_with_conviction(p1, conviction_id, -2);

    let c = gov.get_conviction(candidate(), conviction_id);
    assert(c.votes_cast == 2, 'should have voted twice');
    assert(c.lock_duration == 9_460_800, 'level-1 lock window wrong');

    assert(gov.get_proposal_total_power(p0) == 31_622_776_601, 'p0 power mismatch');
    assert(gov.get_proposal_total_power(p1) == 31_622_776_601, 'p1 power mismatch');
    assert(gov.get_conviction_power(candidate(), conviction_id) == 31_622_776_601,
        'conviction power mismatch');
}

/// Verifies enforcement of the per-conviction distinct-proposal vote limit.
///
/// Ten distinct proposals are accepted, while the eleventh vote must panic with
/// `MaxVotesReached`.
#[should_panic(expected: ('MaxVotesReached',))]
#[test]
fn test_max_votes_per_conviction_enforced() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    evaluate(contract, 5);

    let gov = gov_disp(contract);

    // 11 proposals; the creator pays the DEPOSIT from their FUND balance.
    let mut pids: Array<u256> = array![];
    let mut i: u32 = 0;
    loop {
        if i >= 11 {
            break;
        }
        let pid = create_proposal(contract, funding_wallet(), "proposal evidence");
        pids.append(pid);
        i += 1;
    };

    start_cheat_caller_address(contract, candidate());
    let conviction_id = gov.create_conviction(1, 1_000 * ONE);

    // Default max is 10 distinct proposals; the 11th vote must revert.
    let mut j: u32 = 0;
    loop {
        if j >= 11 {
            break;
        }
        gov.vote_with_conviction(*pids.at(j), conviction_id, 5);
        j += 1;
    };
}

/// Verifies that conviction voting is rejected after the lock window expires.
///
/// The clock advances beyond the level-one lock duration before the first vote,
/// which must panic with `LockExpired`.
#[should_panic(expected: ('LockExpired',))]
#[test]
fn test_vote_after_lock_expiry_reverts() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    evaluate(contract, 5);

    let gov = gov_disp(contract);
    let proposal_id = create_proposal(contract, funding_wallet(), "proposal evidence");

    start_cheat_caller_address(contract, candidate());
    let conviction_id = gov.create_conviction(1, 1_000 * ONE);

    // Jump past the level-1 lock window before voting.
    start_cheat_block_timestamp(contract, FINALIZE_TS + 9_460_800 + 1);
    gov.vote_with_conviction(proposal_id, conviction_id, 5);
}

/// Verifies that conviction stake cannot be released before lock expiry.
///
/// A level-three conviction attempts release during its active window and must
/// panic with `LockNotExpired`.
#[should_panic(expected: ('LockNotExpired',))]
#[test]
fn test_release_before_lock_expiry_reverts() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    evaluate(contract, 5);

    let gov = gov_disp(contract);
    start_cheat_caller_address(contract, candidate());
    let conviction_id = gov.create_conviction(3, 2_000 * ONE);

    // Still well inside the level-3 lock window (3 * ~9.46M s).
    start_cheat_block_timestamp(contract, FINALIZE_TS + 500 * 3_600);
    gov.release_conviction(conviction_id);
}

// ////////////////////////////////////////////////////////////////
                    // ADMIN TIMELOCK ENGINE
// ////////////////////////////////////////////////////////////////

/// Verifies the default draw count and its complete timelocked update flow.
///
/// The admin proposes a new value, the pending record is inspected, execution
/// is delayed beyond the timelock, and the applied value clears the record.
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

/// Verifies the default conviction base lock and its timelocked update flow.
///
/// The admin doubles the per-level lock, and the test checks both the pending
/// change and the value exposed after the three-day delay.
#[test]
fn test_conviction_base_lock_timelocked_change() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    let gov = gov_disp(contract);

    assert(gov.get_conviction_base_lock() == 9_460_800, 'default base lock mismatch');

    start_cheat_block_timestamp(contract, T0);
    start_cheat_caller_address(contract, admin());
    gov.propose_set_conviction_base_lock(2 * 9_460_800);

    let pending = gov.get_pending_change('CONVICTION_BASE_LOCK');
    assert(pending.exists, 'change should be pending');
    assert(pending.new_value == 2 * 9_460_800, 'pending value mismatch');

    start_cheat_block_timestamp(contract, T0 + TIMELOCK_DURATION + 1);
    gov.execute_set_conviction_base_lock();

    assert(gov.get_conviction_base_lock() == 2 * 9_460_800, 'base lock updated');
}

/// Verifies the default per-conviction vote limit and its timelocked update flow.
///
/// The admin proposes twenty-five votes, and the test checks the pending record
/// before confirming the new value after the timelock.
#[test]
fn test_max_votes_per_conviction_timelocked_change() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    let gov = gov_disp(contract);

    assert(gov.get_max_votes_per_conviction() == 10, 'default max votes mismatch');

    start_cheat_block_timestamp(contract, T0);
    start_cheat_caller_address(contract, admin());
    gov.propose_set_max_votes_per_conviction(25);

    let pending = gov.get_pending_change('MAX_VOTES_CONVICTION');
    assert(pending.exists, 'change should be pending');
    assert(pending.new_value == 25, 'pending value mismatch');

    start_cheat_block_timestamp(contract, T0 + TIMELOCK_DURATION + 1);
    gov.execute_set_max_votes_per_conviction();

    assert(gov.get_max_votes_per_conviction() == 25, 'max votes updated');
}

/// Verifies that conviction base-lock proposals cannot exceed the five-year cap.
///
/// An admin proposes one second beyond the maximum and must receive `TooHigh`.
#[test]
#[should_panic(expected: ('TooHigh',))]
fn test_propose_conviction_base_lock_above_max_reverts() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    let gov = gov_disp(contract);

    // MAX_LOCK_DURATION is 5 years (157,680,000 s).
    start_cheat_caller_address(contract, admin());
    gov.propose_set_conviction_base_lock(157_680_001);
}

/// Verifies that a conviction cannot create a lock exceeding the absolute cap.
///
/// The base lock is raised to the five-year limit, making a level-two
/// conviction exceed it and panic with `LockTooLong`.
#[test]
#[should_panic(expected: ('LockTooLong',))]
fn test_create_conviction_lock_too_long_reverts() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    evaluate(contract, 5);
    let gov = gov_disp(contract);

    // Raise the per-level base lock to the 5-year cap; level 2 then exceeds it.
    start_cheat_block_timestamp(contract, T0);
    start_cheat_caller_address(contract, admin());
    gov.propose_set_conviction_base_lock(157_680_000);

    start_cheat_block_timestamp(contract, T0 + TIMELOCK_DURATION + 1);
    gov.execute_set_conviction_base_lock();

    start_cheat_caller_address(contract, candidate());
    gov.create_conviction(2, 1_000 * ONE);
}

/// Verifies that parameter execution is rejected before its timelock elapses.
///
/// The admin proposes an evaluation-bond change and attempts execution early;
/// the call must panic with `TimelockNotElapsed`.
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

/// Verifies that a timelocked evaluation-bond update becomes effective.
///
/// The test checks the initial bond, pending value and effective timestamp,
/// then confirms execution after the delay applies the new amount.
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

// ////////////////////////////////////////////////////////////////
        // MONTHLY INFLATION / BURN-RECYCLING BUDGET
// ////////////////////////////////////////////////////////////////

/// Verifies initialization of the first monthly inflation budget.
///
/// Month zero starts with the five-percent annual inflation share divided across
/// twelve months, with no prior burns, mints, or rollover.
#[test]
fn test_initial_month_budget_is_inflation_share() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    let gov = gov_disp(contract);

    // Month 0 budget = 10M tokens * 5% / 12 = 10M / 240 tokens, recycle 0.
    let expected = 10_000_000 * ONE / 240;
    assert(gov.get_current_month() == 0, 'month should be 0');
    assert(gov.get_month_budget(0) == expected, 'month0 budget mismatch');
    assert(gov.get_remaining_month_budget() == expected, 'nothing minted yet');
    assert(gov.get_month_budget_minted(0) == 0, 'no mints yet');
    assert(gov.get_month_burned(0) == 0, 'no burns yet');
    assert(gov.get_inflation_rate_bps() == 500, 'default rate should be 5%');
}

/// Verifies that a successfully minted reward consumes the active monthly budget.
///
/// A positive proposal executes after the month boundary, and the test compares
/// remaining budget and month mints before and after the reward.
#[test]
fn test_reward_mints_consume_monthly_budget() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    evaluate(contract, 5);

    let gov = gov_disp(contract);
    let before = gov.get_remaining_month_budget();

    let proposal_id = create_proposal(contract, funding_wallet(), "proposal evidence");
    start_cheat_caller_address(contract, candidate());
    let conviction_id = gov.create_conviction(1, 1_000 * ONE);

    start_cheat_block_timestamp(contract, FINALIZE_TS + 1000 * 3_600);
    gov.vote_with_conviction(proposal_id, conviction_id, 5);
    gov.execute_proposal(proposal_id);

    // The 1000h vote timestamp pushes execution past the month boundary, so
    // the reward is counted against whatever month is current at mint time.
    let reward = 5 * REWARD_MULT; // score 5 * full multiplier = 500 tokens
    let month = gov.get_current_month();
    assert(gov.get_remaining_month_budget() == before - reward, 'budget should shrink');
    assert(gov.get_month_budget_minted(month) == reward, 'minted mismatch');
}

/// Verifies best-effort reward minting when the monthly budget is insufficient.
///
/// The configured reward exceeds the month's budget, so the payout is skipped
/// while proposal execution, score finalization, and deposit refund still occur.
#[test]
fn test_reward_exceeding_monthly_budget_skips_mint_but_executes() {
    let contract = deploy(THRESHOLD, 10_000 * ONE, MINI_REWARD_MULT);
    evaluate(contract, 5);

    let gov = gov_disp(contract);
    let tok = tok_disp(contract);
    let proposal_id = create_proposal(contract, funding_wallet(), "proposal evidence");

    start_cheat_caller_address(contract, candidate());
    let conviction_id = gov.create_conviction(1, 1_000 * ONE);

    start_cheat_block_timestamp(contract, FINALIZE_TS + 1000 * 3_600);
    gov.vote_with_conviction(proposal_id, conviction_id, 5);
    // 5 * 10,000 tokens = 50,000 > 10M/240 = ~41,667 token budget.
    // Best-effort minting: the proposal still executes and the author's
    // deposit is refunded; only the payout is skipped.
    gov.execute_proposal(proposal_id);

    let p = gov.get_proposal(proposal_id);
    assert(p.executed, 'proposal should execute');
    assert(p.final_score == 5, 'final score should be 5');
    assert(tok.balance_of(funding_wallet()) == 0, 'reward should be skipped');
    assert(tok.balance_of(creator()) == FUND, 'deposit should still refund');
    assert(gov.get_month_budget_minted(gov.get_current_month()) == 0, 'no budget spent');
}

// A-2 + B-1: in a zero-budget month (inflation 0, no burns), slashing, decay
// and proposal execution must all still work; only the bonus/reward mints are
// skipped instead of reverting the underlying operation.
/// Verifies core operations remain usable when the monthly budget is zero.
///
/// The test exercises juror slashing, positive evaluation, proposal execution,
/// and ERC20 decay, confirming that unavailable keeper and reward mints are
/// skipped without reverting the underlying operations.
#[test]
fn test_zero_budget_month_slash_decay_and_execution_still_work() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    let gov = gov_disp(contract);
    let tok = tok_disp(contract);
    let candidate2: ContractAddress = 'candidate2'.try_into().unwrap();

    start_cheat_block_timestamp(contract, T0);
    fund(contract, juror(), FUND);
    fund(contract, candidate(), FUND);
    fund(contract, creator(), FUND);
    fund(contract, candidate2, FUND);

    // The single staked juror absorbs every draw across both disputes.
    stake_juror(contract);

    // Dispute B (candidate): juror reveals 5 -> governance mint for the vote.
    let dispute_b = request_evaluation(contract);
    // Dispute A (candidate2): juror never reveals -> slash target below.
    start_cheat_caller_address(contract, candidate2);
    tok_disp(contract).approve(candidate2, BOND);
    let dispute_a = gov.request_evaluation("evidence a");

    disclose(contract, dispute_b, 5);

    // Set inflation to 0 (7-day-safe 3-day timelock) so month 1 budget = 0.
    start_cheat_block_timestamp(contract, T0 + TIMELOCK_DURATION + 1);
    start_cheat_caller_address(contract, admin());
    gov.propose_set_inflation_rate_bps(0);
    start_cheat_block_timestamp(contract, T0 + 2 * TIMELOCK_DURATION + 1);
    gov.execute_set_inflation_rate_bps();

    // Roll into month 1: budget is 0 (inflation 0, no prior burns).
    start_cheat_block_timestamp(contract, MONTH_SECONDS + 1);
    start_cheat_caller_address(contract, whale());
    gov.burn(1);
    assert(gov.get_current_month() == 1, 'month should roll');
    assert(gov.get_month_budget(1) == 0, 'month1 budget should be 0');

    // A-2: slash a non-revealing juror in a zero-budget month. The slash, the
    // lock release and the stake deduction must apply; only the keeper reward
    // is skipped (no revert).
    start_cheat_caller_address(contract, whale());
    gov.slash_non_revealer(dispute_a, juror());
    assert(gov.get_juror_stake(juror()) == STAKE - STAKE * 3000 / 10000, 'stake slashed');
    assert(gov.get_juror_open_dispute_count(juror()) == 0, 'lock released');
    assert(gov.get_juror_locked_stake(juror()) == 0, 'locked cleared');
    assert(gov.get_month_budget_minted(1) == 0, 'keeper reward skipped');

    // B (candidate) finalizes with score 5: governance minted, bond refunded.
    start_cheat_caller_address(contract, whale());
    gov.finalize_selection(dispute_b);
    assert(gov.governance_balance(candidate()) == 50_000 * ONE, 'gov minted');
    assert(tok.balance_of(candidate()) == FUND, 'bond refunded');

    // B-1: a positive-score proposal in a zero-budget month still executes
    // and refunds the author; only the funding payout is skipped.
    // (Month 2's budget is just the 1-wei recycle from `burn(1)` above.)
    start_cheat_block_timestamp(contract, MONTH_SECONDS + 1);
    let proposal_id = create_proposal(contract, funding_wallet(), "proposal evidence");
    start_cheat_caller_address(contract, candidate());
    let conviction_id = gov.create_conviction(1, 1_000 * ONE);
    start_cheat_block_timestamp(contract, MONTH_SECONDS + 1 + 1000 * 3_600);
    gov.vote_with_conviction(proposal_id, conviction_id, 5);
    gov.execute_proposal(proposal_id);

    let p = gov.get_proposal(proposal_id);
    assert(p.executed, 'proposal should execute');
    assert(p.final_score == 5, 'final score should be 5');
    assert(tok.balance_of(creator()) == FUND, 'deposit refunded');
    assert(tok.balance_of(funding_wallet()) == 0, 'reward skipped');
    assert(gov.get_month_budget_minted(1) == 0, 'nothing minted in month 1');
    assert(gov.get_month_budget_minted(2) == 0, 'nothing minted in month 2');

    // A-2: decay still burns even when the caller reward cannot be minted.
    start_cheat_caller_address(contract, candidate());
    gov.apply_decay(whale());
    let before = tok.balance_of(whale());
    start_cheat_block_timestamp(contract, MONTH_SECONDS + 1 + 1000 * 3_600 + 48 * 3_600);
    gov.apply_decay(whale());
    let after = tok.balance_of(whale());
    assert(after < before, 'decay must burn');
    assert(gov.get_month_budget_minted(2) == 0, 'caller reward skipped');
}

// C-2: disabling upgrades is a two-step, 7-day-timelocked admin action.
/// Verifies the complete two-step, seven-day upgrade-disable flow.
///
/// The admin proposes permanent upgrade disablement, the state remains enabled
/// before the deadline, and execution after seven days clears the pending flag.
#[test]
fn test_disable_upgrades_timelocked_flow() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    let gov = gov_disp(contract);

    start_cheat_block_timestamp(contract, T0);
    start_cheat_caller_address(contract, admin());
    gov.propose_disable_upgrades();

    assert(!gov.is_upgrades_disabled(), 'not disabled yet');
    let pending = gov.get_pending_upgrade_disable();
    assert(pending.exists, 'disable should be pending');
    assert(pending.effective_at == T0 + 604_800, '7-day timelock');

    start_cheat_block_timestamp(contract, T0 + 604_800 + 1);
    start_cheat_caller_address(contract, admin());
    gov.execute_disable_upgrades();

    assert(gov.is_upgrades_disabled(), 'should be disabled');
    assert(!gov.get_pending_upgrade_disable().exists, 'pending cleared');
}

// C-2: the two-step disable cannot be executed before the 7-day timelock.
/// Verifies that upgrade disablement cannot execute before seven days.
///
/// The admin proposes the change and attempts execution one second early; the
/// call must panic with `TimelockNotElapsed`.
#[test]
#[should_panic(expected: ('TimelockNotElapsed',))]
fn test_disable_upgrades_before_timelock_reverts() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    let gov = gov_disp(contract);

    start_cheat_block_timestamp(contract, T0);
    start_cheat_caller_address(contract, admin());
    gov.propose_disable_upgrades();

    start_cheat_block_timestamp(contract, T0 + 604_800 - 1);
    gov.execute_disable_upgrades();
}

// C-3: the conviction threshold cannot be set to zero (turns the gate off).
/// Verifies that the conviction execution threshold cannot be set to zero.
///
/// An admin proposal for zero is rejected to preserve the governance gate.
#[test]
#[should_panic(expected: ('ZeroAmount',))]
fn test_zero_conviction_threshold_reverts() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    let gov = gov_disp(contract);

    start_cheat_caller_address(contract, admin());
    gov.propose_set_conviction_threshold(0);
}

/// Verifies that recorded burns increase the following month's budget.
///
/// Tokens burned in month zero are tracked, a rollover is triggered, and the
/// next budget is checked against inflation plus the recycled burn amount.
#[test]
fn test_burned_tokens_recycle_into_next_month_budget() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    let gov = gov_disp(contract);
    let tok = tok_disp(contract);

    // Whale (initial recipient) burns 1,000 tokens during month 0.
    start_cheat_caller_address(contract, whale());
    gov.burn(1_000 * ONE);
    assert(gov.get_month_burned(0) == 1_000 * ONE, 'burn should be tracked');

    // Roll into month 1: budget = inflation share + last month's burns.
    start_cheat_block_timestamp(contract, MONTH_SECONDS + 1);
    gov.burn(1); // triggers month rollover

    assert(gov.get_current_month() == 1, 'month should roll');
    let supply_after_burn = tok.total_supply();
    let inflation_part = supply_after_burn * 500 / (BUDGET_BPS_DENOM * MONTHS_PER_YEAR);
    assert(gov.get_month_budget(1) == inflation_part + 1_000 * ONE, 'recycle mismatch');
}

/// Verifies that unused monthly budget is written off at rollover.
///
/// With no mint or burn usage in month zero, the test confirms the next budget
/// contains only the fresh inflation share and no leftover carry-forward.
#[test]
fn test_unused_budget_is_not_recycled() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    let gov = gov_disp(contract);

    // No usage at all in month 0: leftover == full budget.
    start_cheat_block_timestamp(contract, MONTH_SECONDS + 1);
    start_cheat_caller_address(contract, whale());
    gov.burn(1); // triggers month rollover

    assert(gov.get_current_month() == 1, 'month should roll');
    // Budget is written off (burned), never recycled, so month 1 equals the
    // same pure inflation share instead of budget0 + leftover.
    assert(gov.get_month_budget(1) == gov.get_month_budget(0), 'leftover should be burned');
    assert(gov.get_remaining_month_budget() == gov.get_month_budget(1) - 0, 'fresh budget');
    assert(gov.get_month_burned(0) == 0, 'leftover is not a recorded burn');
}

/// Verifies that the inflation rate changes only through the admin timelock.
///
/// The admin proposes three percent, inspects the pending value, and confirms
/// the new rate after the required delay.
#[test]
fn test_inflation_rate_timelocked_change() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    let gov = gov_disp(contract);

    start_cheat_block_timestamp(contract, T0);
    start_cheat_caller_address(contract, admin());
    gov.propose_set_inflation_rate_bps(300);

    let pending = gov.get_pending_change('INFLATION_RATE');
    assert(pending.exists, 'change should be pending');
    assert(pending.new_value == 300, 'pending value mismatch');

    start_cheat_block_timestamp(contract, T0 + TIMELOCK_DURATION + 1);
    gov.execute_set_inflation_rate_bps();

    assert(gov.get_inflation_rate_bps() == 300, 'rate updated');
}

/// Verifies that inflation-rate proposals above five percent are rejected.
///
/// An admin proposal for 501 basis points must panic with `TooHigh`.
#[test]
#[should_panic(expected: ('TooHigh',))]
fn test_inflation_rate_above_max_reverts() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    let gov = gov_disp(contract);

    start_cheat_caller_address(contract, admin());
    gov.propose_set_inflation_rate_bps(501);
}

// ////////////////////////////////////////////////////////////////
        // V2 SECURITY REGRESSION TESTS
// ////////////////////////////////////////////////////////////////

const MAX_SUPPLY_ONE: u256 = 50_000_000 * ONE; // contract MAX_SUPPLY = 50M tokens

// H2: the contract's own escrow must never be burnable via public decay.
/// Verifies that public decay cannot burn the contract's protected escrow address.
///
/// Calling `apply_decay` with the contract itself as the target must panic with
/// `ProtectedAddress`.
#[test]
#[should_panic(expected: ('ProtectedAddress',))]
fn test_apply_decay_on_contract_address_reverts() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    let gov = gov_disp(contract);

    start_cheat_caller_address(contract, whale());
    gov.apply_decay(contract);
}

/// Verifies that batched decay also protects the contract's escrow address.
///
/// A batch containing the contract address must panic with `ProtectedAddress`
/// rather than allowing protected funds to be burned.
#[test]
#[should_panic(expected: ('ProtectedAddress',))]
fn test_batch_apply_decay_with_contract_address_reverts() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    let gov = gov_disp(contract);

    let mut users: Array<ContractAddress> = array![contract];
    start_cheat_caller_address(contract, whale());
    gov.batch_apply_decay(users);
}

// H3: a dispute with zero reveals must settle score-neutral, refund the bond,
// and release the candidate instead of being stuck forever.
/// Verifies neutral settlement when the selected juror never reveals.
///
/// Finalization with zero reveals refunds the bond, records a zero score,
/// clears active-dispute state, and mints no governance tokens.
#[test]
fn test_zero_reveal_refunds_bond_and_clears_dispute() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    let gov = gov_disp(contract);
    let tok = tok_disp(contract);

    start_cheat_block_timestamp(contract, T0);
    fund(contract, juror(), FUND);
    fund(contract, candidate(), FUND);
    stake_juror(contract);
    let dispute_id = request_evaluation(contract);

    // The drawn juror never commits nor reveals.
    finalize(contract, dispute_id);

    // Bond refunded -> candidate is whole again.
    assert(tok.balance_of(candidate()) == FUND, 'bond should be refunded');
    // No governance minted for a signal-less dispute.
    assert(gov.governance_balance(candidate()) == 0, 'no gov on zero reveal');

    let d = gov.get_dispute(dispute_id);
    assert(d.bond_settled, 'bond should be settled');
    assert(d.final_score_set, 'should be finalized');
    assert(d.final_score == 0, 'score should be neutral');
    assert(
        gov.get_active_dispute_for_candidate(candidate()) == 0, 'active dispute cleared'
    );

    // The candidate is not permanently locked out and can be re-evaluated.
    assert(gov.get_active_dispute_for_candidate(candidate()) == 0, 'requester flag cleared');
}

// H4: num_draws must be bounded so a hostile propose cannot grief the draw loop.
/// Verifies that the juror draw-count parameter is bounded.
///
/// A proposal for 101 draws exceeds `MAX_NUM_DRAWS` and must panic with
/// `AboveMaxNumDraws` before any state is changed.
#[test]
#[should_panic(expected: ('AboveMaxNumDraws',))]
fn test_num_draws_above_max_reverts() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    let gov = gov_disp(contract);

    start_cheat_block_timestamp(contract, T0);
    start_cheat_caller_address(contract, admin());
    gov.propose_set_num_draws(101);
}

// M3: u256 admin parameters are capped at MAX_SUPPLY.
/// Verifies that u256 admin parameters are capped at the maximum token supply.
///
/// A conviction-threshold proposal one unit above `MAX_SUPPLY` must panic with
/// `TooHigh`.
#[test]
#[should_panic(expected: ('TooHigh',))]
fn test_param_amount_above_max_supply_reverts() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    let gov = gov_disp(contract);

    start_cheat_block_timestamp(contract, T0);
    start_cheat_caller_address(contract, admin());
    gov.propose_set_conviction_threshold(MAX_SUPPLY_ONE + 1);
}

// L1: a contract untouched for many months clamps the rollover instead of
// hard-reverting, so no single call can grief an old contract.
/// Verifies bounded month rollover after a long period without activity.
///
/// Advancing 130 months causes one call to settle at most the 120-month cap
/// instead of reverting or attempting an unbounded loop.
#[test]
fn test_far_future_rollover_clamps_instead_of_reverting() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    let gov = gov_disp(contract);

    // 130 months behind schedule (clamp cap is 120).
    start_cheat_block_timestamp(contract, 130 * MONTH_SECONDS);
    start_cheat_caller_address(contract, whale());
    gov.burn(1);

    assert(gov.get_current_month() == 120, 'month should clamp to 120');
}

// L6: evidence payloads are size-capped to keep calldata/gas predictable.
/// Verifies the maximum proposal evidence payload size.
///
/// A proposal whose evidence exceeds 1,024 bytes must panic with
/// `EvidenceTooLong` before proposal state is created.
#[test]
#[should_panic(expected: ('EvidenceTooLong',))]
fn test_create_proposal_evidence_too_long_reverts() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    let gov = gov_disp(contract);

    let mut evidence: ByteArray = "a";
    let mut i: usize = 1;
    loop {
        if i >= 1025 {
            break;
        }
        evidence.append_byte(97); // 'a'
        i += 1;
    };

    start_cheat_caller_address(contract, creator());
    tok_disp(contract).approve(creator(), DEPOSIT);
    gov.create_proposal(funding_wallet(), evidence);
}

// L7: a final score of exactly zero is treated as neutral - deposit refunded,
// no score-based reward minted.
/// Verifies neutral proposal settlement for an exact zero score.
///
/// A conviction votes zero, execution completes, the author's deposit is
/// refunded, and no score-based reward is minted.
#[test]
fn test_zero_score_refunds_deposit_and_mints_no_reward() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    evaluate(contract, 5); // mints governance to the candidate

    let gov = gov_disp(contract);
    let tok = tok_disp(contract);

    let proposal_id = create_proposal(contract, funding_wallet(), "proposal evidence");

    start_cheat_caller_address(contract, candidate());
    let conviction_id = gov.create_conviction(1, 1_000 * ONE);

    start_cheat_block_timestamp(contract, FINALIZE_TS + 1000 * 3_600);
    gov.vote_with_conviction(proposal_id, conviction_id, 0);

    gov.execute_proposal(proposal_id);

    let p = gov.get_proposal(proposal_id);
    assert(p.executed, 'proposal should be executed');
    assert(p.final_score == 0, 'score should be 0');

    assert(tok.balance_of(creator()) == FUND, 'deposit should be refunded');
    assert(tok.balance_of(funding_wallet()) == 0, 'no reward for score 0');
}

// Regression: a dust conviction's voting power is frozen at vote time and must
// never grow with time. Under the retired `level * sqrt(amount * hours_locked)`
// formula a 1-wei conviction parked for years would compound into real power
// ("dust voting to capture conviction voting"); the static isqrt(level * amount)
// weight keeps dust as dust forever, so neither its own power nor the proposal
// power_total moves across a 3-year jump.
/// Verifies that a dust conviction's vote power never compounds with time.
///
/// A one-wei conviction casts a positive vote, then the clock advances three
/// years; both the conviction and proposal accumulators must remain unchanged.
#[test]
fn test_dust_conviction_power_is_frozen_across_time() {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    evaluate(contract, 5);

    let gov = gov_disp(contract);
    let proposal_id = create_proposal(contract, funding_wallet(), "proposal evidence");

    start_cheat_caller_address(contract, candidate());
    // 1 raw token ("dust") at level 1 -> weight isqrt(1 * 1) = 1.
    let conviction_id = gov.create_conviction(1, 1);

    gov.vote_with_conviction(proposal_id, conviction_id, 5);
    assert(gov.get_conviction_power(candidate(), conviction_id) == 1, 'dust power');
    assert(gov.get_proposal_total_power(proposal_id) == 1, 'dust total');

    // Jump 3 years past the lock window; the frozen weight must not move.
    start_cheat_block_timestamp(contract, FINALIZE_TS + 3 * 365 * 86_400);
    assert(gov.get_conviction_power(candidate(), conviction_id) == 1, 'dust power frozen');
    assert(gov.get_proposal_total_power(proposal_id) == 1, 'total frozen');
}

// ////////////////////////////////////////////////////////////////
                // FUZZ / INVARIANT TESTS
// ////////////////////////////////////////////////////////////////

// Invariant: stake then partial-unstake must conserve the juror's total value
// (stake + free balance) exactly, for arbitrary amounts.
/// Fuzzes juror staking and partial unstaking for exact value conservation.
///
/// Inputs are bounded to the funded balance, and the final free ERC20 balance
/// plus locked juror stake must equal the original funded amount.
#[test]
#[fuzzer(runs: 250)]
fn test_fuzz_stake_unstake_conserves_value(stake_amount: u256, unstake_amount: u256) {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    let gov = gov_disp(contract);
    let tok = tok_disp(contract);

    start_cheat_block_timestamp(contract, T0);
    fund(contract, juror(), FUND);

    let stake = stake_amount % FUND + 1;
    let unstake = unstake_amount % stake + 1;

    start_cheat_caller_address(contract, juror());
    tok_disp(contract).approve(juror(), FUND);
    gov.stake(stake);
    gov.unstake(unstake);

    assert(tok.balance_of(juror()) == FUND - stake + unstake, 'balance must be conserved');
    assert(gov.get_juror_stake(juror()) == stake - unstake, 'stake must be conserved');
}

// Invariant: applying decay at arbitrary (possibly out-of-order) timestamps can
// never increase a user's balance or mint tokens to them.
/// Fuzzes decay at arbitrary timestamps for a non-increasing balance invariant.
///
/// Two bounded timestamps are applied in sequence, including out-of-order
/// values, and the user's balance must never increase.
#[test]
#[fuzzer(runs: 100)]
fn test_fuzz_apply_decay_is_non_increasing(t1: u64, t2: u64) {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    let gov = gov_disp(contract);
    let tok = tok_disp(contract);

    start_cheat_block_timestamp(contract, T0);
    fund(contract, juror(), FUND);

    let a = t1 % 100_000;
    let b = t2 % 100_000;

    start_cheat_block_timestamp(contract, T0 + a);
    start_cheat_caller_address(contract, juror());
    gov.apply_decay(juror());
    let before = tok.balance_of(juror());

    start_cheat_block_timestamp(contract, T0 + b);
    gov.apply_decay(juror());
    let after = tok.balance_of(juror());

    assert(after <= before, 'decay must never mint');
    assert(after == before || after < before, 'strict bound');
}

// Invariant: a proposal's frozen power_total is exactly the sum of the static
// vote weights (isqrt(level * amount)) regardless of the amounts committed.
/// Fuzzes aggregate conviction power against the exact sum of static weights.
///
/// Two bounded level-one convictions vote on one proposal, and the proposal
/// accumulator must equal the independently computed square-root weight sum.
#[test]
#[fuzzer(runs: 50)]
fn test_fuzz_power_total_matches_sum_of_vote_weights(a: u256, b: u256) {
    let contract = deploy(THRESHOLD, REWARD_MULT, MINI_REWARD_MULT);
    evaluate(contract, 5);
    let gov = gov_disp(contract);

    let proposal_id = create_proposal(contract, funding_wallet(), "proposal evidence");

    // Sanitize fuzz inputs to 1..=1_000 tokens per conviction.
    let amt_a = a % (1_000 * ONE) + 1;
    let amt_b = b % (1_000 * ONE) + 1;

    start_cheat_caller_address(contract, candidate());
    let cid_a = gov.create_conviction(1, amt_a);
    let cid_b = gov.create_conviction(1, amt_b);

    start_cheat_block_timestamp(contract, FINALIZE_TS + 1);
    gov.vote_with_conviction(proposal_id, cid_a, 5);
    gov.vote_with_conviction(proposal_id, cid_b, 5);

    let expected = isqrt(amt_a) + isqrt(amt_b);
    assert(gov.get_proposal_total_power(proposal_id) == expected, 'power_total mismatch');
    assert(gov.get_conviction_power(candidate(), cid_a) == isqrt(amt_a), 'a weight mismatch');
    assert(gov.get_conviction_power(candidate(), cid_b) == isqrt(amt_b), 'b weight mismatch');
}