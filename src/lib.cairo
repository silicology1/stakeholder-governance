// SPDX-License-Identifier: MIT
//! StakeholderConvictionGovernance
//! ================================
//! ONE Starknet/Cairo contract, ONE token, ONE minter: this file used to
//! ship as two contracts (this governance contract, plus a sibling
//! `StakeholderGovernanceToken` ERC20 that it held `MINTER_ROLE` on). That
//! split is gone. This contract now embeds OpenZeppelin's `ERC20Component`
//! directly, so it *is* the transferable token - there is no separate
//! address to deploy, no `MINTER_ROLE` to grant post-deploy, and no
//! external mint entrypoint at all. The only two places that can ever
//! increase total supply are both internal, both in this file:
//!   1. the constructor's one-time `INITIAL_SUPPLY` mint, and
//!   2. `_distribute_conviction_rewards`, called only from `execute_proposal`.
//!   3. the slash-keeper reward in `slash_non_revealer` (see "JUROR STAKE
//!      LOCKING" below).
//! Every mint - including the constructor's - goes through `_mint_capped`,
//! which asserts `total_supply() + amount <= MAX_SUPPLY` first.
//!
//!   STAGE 1 - SELECTION (Kleros-style Schelling game)
//!   ---------------------------------------------------
//!   A candidate puts themselves up for evaluation via `request_evaluation`
//!   (opt-in, bonded - see "OPT-IN EVALUATION WITH A BOND" below).
//!   Jurors stake this contract's own token (Fenwick-tree weighted
//!   sortition, exactly the mechanism from the reference KlerosSchelling
//!   contract this file was built alongside) and are drawn with
//!   replacement via Cartridge VRF. Each drawn juror commits, then
//!   reveals, a score in [-5, +5] for the candidate. On `finalize_selection`
//!   the contract computes a stake-weighted mean, drops outliers more than
//!   one (population) stdev away, and recomputes the mean over the
//!   remainder - the same trimmed-mean routine as the reference contract,
//!   applied here to "how good is this candidate", not "how good is this
//!   proposal".
//!
//!   STAGE 2 - EMPOWERMENT (non-transferable, decaying governance tokens)
//!   ---------------------------------------------------------------------
//!   The instant a dispute finalizes with a positive final score, the
//!   candidate is minted non-transferable ("soulbound") governance tokens
//!   according to the fixed schedule below. A score of zero or negative mints
//!   nothing - the candidate simply isn't empowered. IMPORTANT: this is a
//!   completely separate accounting system (a plain `Map` of decaying
//!   `Grant`s below) from the ERC20 embedded in this same contract. It is
//!   not minted through `_mint_capped`, has no supply cap, and can never be
//!   transferred - see `_mint_governance_tokens` / `_decayed_total`.
//!
//!       final_score   tokens minted
//!       -----------   -------------
//!            +1            100
//!            +2            200
//!            +3            300
//!            +4            400
//!            +5            500
//!         0, -1..-5           0
//!
//!   Every mint creates a fresh "grant" (amount + mint timestamp). A holder's
//!   balance is the sum of all their grants, each decaying *linearly, in
//!   discrete hourly steps* from its minted amount down to zero over exactly
//!   8_760 hours (365 days): `decayed = amount - amount * hours_elapsed /
//!   8760`, floored at zero once `hours_elapsed >= 8760`. There is no way to
//!   transfer these tokens between addresses - the only state-changing paths
//!   that touch a balance are `_mint_governance_tokens` (internal, called
//!   only from `finalize_selection`) and locking/unlocking into a conviction
//!   (which does not move value between holders, only between "free" and
//!   "locked" within the same holder).
//!
//!   STAGE 3 - CONVICTION VOTING (fund allocation)
//!   -----------------------------------------------
//!   An empowered stakeholder locks some of their *currently available*
//!   (decayed, unlocked) governance-token balance into a `Conviction` via
//!   `create_conviction`. That conviction can then `add_support` a single
//!   `FundingProposal` at a time. While supporting, its voting power grows
//!   with how long it has kept backing that same proposal, per the exact
//!   formula requested:
//!
//!       voting_power = floor( sqrt( locked_amount * seconds_supported ) )
//!
//!   `get_proposal_total_power` sums this over every conviction currently
//!   supporting a proposal. Once that sum clears the admin-set
//!   `conviction_threshold`, anyone can call `execute_proposal` to pay the
//!   proposal's `requested_amount` of `funding_token` out of the contract's
//!   treasury (filled via `deposit_funds`) to the proposal's
//!   `funding_wallet`. Withdrawing support (`remove_support`) resets that
//!   conviction's contribution to zero immediately - conviction voting is
//!   meant to reward *sustained* backing, so power does not persist once you
//!   stop backing a proposal, and restarting support begins accumulating
//!   from zero again.
//!
//!   REWARDING conviction voting - one token, capped supply
//!   ---------------------------------------------------------
//!   Voting power itself is computed purely from the non-transferable
//!   balance above (Stage 2) - that never changes and has nothing to do
//!   with the ERC20 below. What `execute_proposal` also does is *pay*
//!   participants for sustained, successful backing: it mints
//!   `conviction_reward_amount` of this contract's own transferable ERC20,
//!   split pro-rata by power among every conviction actively supporting the
//!   proposal at the moment it executes. That same ERC20 is also the token
//!   jurors stake to earn Kleros draw-weight in Stage 1 - one capped-supply
//!   tradable asset serving both "skin in the game to judge candidates" and
//!   "payout for successfully directing treasury funds" - kept strictly
//!   separate from the non-transferable balance that actually *is* the
//!   voting power.
//!
//!   SUPPLY: fixed cap, one-time initial mint
//!   -------------------------------------------
//!     - `MAX_SUPPLY`     = 50,000,000 tokens (18 decimals, OZ default).
//!     - `INITIAL_SUPPLY` = 10,000,000 tokens (18 decimals), minted in the
//!       constructor to the `initial_recipient` address passed in at
//!       deploy (a DAO treasury/multisig, an airdrop distributor, an
//!       initial-liquidity wallet, etc. - whatever the deployer wants).
//!   That leaves 40,000,000 tokens of headroom that can only ever enter
//!   circulation gradually, through `_mint_capped` calls inside
//!   `_distribute_conviction_rewards` as proposals execute (and, now, small
//!   slash-keeper rewards - see "JUROR STAKE LOCKING"). If that headroom is
//!   fully minted out, any further mint-triggering call will revert on the
//!   capped mint - lower or zero `conviction_reward_amount`
//!   (`set_conviction_reward_amount`) before that happens if you want
//!   proposals to keep executing without reward payouts once the cap is
//!   close.
//!
//! CAVEATS (read before deploying)
//! --------------------------------
//! * RANDOMNESS: exactly the same Cartridge VRF calling pattern as the
//!   reference KlerosSchelling contract - `request_evaluation` consumes
//!   ONE verified random felt252 and derives all `num_draws` per-draw values
//!   by Poseidon-hashing that seed with a draw index (and, now, a redraw
//!   attempt counter when the first-drawn juror is at their concurrent-lock
//!   cap - see "JUROR STAKE LOCKING"). Whoever calls
//!   `request_evaluation` MUST prefix that call, in the same
//!   multicall, with:
//!     VRF.request_random(caller: <this_contract>, source: Source::Nonce(<this_contract>))
//!   See https://www.starknet.io/cairo-book/ch103-05-02-randomness.html.
//! * FIXED-POINT MATH: exactly as in the reference contract, scores are
//!   integers in [-5, 5] and the mean/stdev pipeline uses an internal SCALE
//!   factor rather than floats (Cairo has none). `_isqrt` (used for voting
//!   power) is a floor integer square root, not the reference contract's
//!   `Sqrt` trait - it is implemented manually here (digit-by-digit binary
//!   method) purely to keep the u256 product `locked_amount * seconds`
//!   unambiguous across corelib versions; it is correct but not gas-golfed.
//! * SUPPLY CAP IS CHECKED ON EVERY MINT, NOT RESERVED: `_mint_capped` only
//!   asserts `total_supply() + amount <= MAX_SUPPLY` at call time. It does
//!   not reserve headroom for future reward payouts, so it's possible for
//!   many proposals to execute back-to-back and exhaust the cap; the next
//!   `execute_proposal` after that will revert the whole call (including
//!   its funding-token payout, since Starknet transactions are atomic and
//!   there is no try/catch around the reward mint) once the reward mint
//!   fails. See "SUPPLY" above for the operational mitigation.
//! * SUPPORTER LIST IS UNBOUNDED: `get_proposal_total_power` and
//!   `execute_proposal` iterate every (owner, conviction_id) pair that has
//!   *ever* called `add_support` on that proposal (skipping ones that are no
//!   longer actively supporting). This is fine for a governance proposal
//!   that realistically draws dozens-to-low-hundreds of distinct backers,
//!   but a pathological proposal with thousands of transient supporters
//!   could make `execute_proposal` expensive. A production version should
//!   cap distinct supporters per proposal or move to an incrementally
//!   maintained running total.
//! * DECAY IS LAZY: grants are never actively "swept" - `governance_balance`
//!   recomputes the decay of every grant a holder has ever received on every
//!   call. A holder who accumulates many small grants over years will have
//!   an increasingly expensive balance read. Fine for the expected
//!   cadence (one grant per successful selection dispute), worth capping in
//!   production if that assumption changes.
//! * NOT COMPILED: this file has not been run through `scarb build` in this
//!   environment. Read it as a careful structural draft, not an audited,
//!   deployed artifact. Compile, test (especially `_isqrt`, the decay math,
//!   the trimmed-mean scoring against a reference Python model, the
//!   supply-cap arithmetic in `_mint_capped`, and the new lock-accounting
//!   math below), and get it audited before deploying.
//!
//! JUROR STAKE LOCKING (added on top of the above - "stake once, serve many
//! disputes per month" without the slashing-evasion hole)
//! --------------------------------------------------------------------------
//! * THE BUG THIS CLOSES: previously, `juror_stake` was a single live
//!   balance with no link to "currently owed a reveal on some dispute". A
//!   juror could get drawn, immediately `unstake` everything, then ignore
//!   commit/reveal for every dispute they were drawn into - `slash_non_revealer`
//!   would compute `slash_amount` off a now-zero stake and slash nothing.
//! * THE FIX: every juror now has `juror_locked_total`, the SUM of
//!   stake-at-draw-time snapshots across every dispute they are currently
//!   drawn into and have not yet resolved. `unstake` asserts
//!   `current_stake - withdraw_amount >= juror_locked_total`. A snapshot is
//!   taken (and added to the sum) the first time a juror is drawn into a
//!   given dispute, in `request_evaluation`; it is released (and
//!   subtracted back out) exactly once, by whichever of `reveal_vote`
//!   (honest path) or `slash_non_revealer` (punished path) fires first,
//!   via the shared, idempotent `_release_dispute_lock` helper.
//! * THIS IS DELIBERATELY CONSERVATIVE: the lock is a SUM of draw-time
//!   snapshots across all open disputes, not the true worst-case slash
//!   exposure (which is bounded by *current* stake regardless of how many
//!   disputes are open, since `slash_non_revealer` slashes a bps of live
//!   stake, not the snapshot). A juror drawn into 5 concurrent disputes
//!   with 10k staked will show up to 50k locked even though at most
//!   `non_reveal_slash_bps` of the current 10k can ever actually be taken
//!   in one slash. This is intentionally simple and safe to reason about
//!   rather than trying to track a tighter, fluctuating bound.
//! * CONCURRENCY CAP: because locking is additive across open disputes, a
//!   juror who is drawn very often (the whole point of staking once for a
//!   month of disputes) can otherwise end up with all their stake
//!   immobilized. `MAX_CONCURRENT_JUROR_LOCKS` (15) caps how many
//!   simultaneously-open dispute locks a juror can carry; past that, they
//!   are skipped in `request_evaluation`'s draw (via a deterministic,
//!   VRF-free reseed/redraw - see `MAX_REDRAW_ATTEMPTS`) rather than seated,
//!   so draws route to jurors with unlocked capacity instead of reverting
//!   the whole dispute or exceeding the cap. Tune this constant (and
//!   `commit_duration`/`reveal_duration`, which bound how fast locks clear)
//!   against your expected disputes-per-month and active-juror count.
//! * KEEPER REWARD ON SLASH: `slash_non_revealer` is permissionless but was
//!   previously unrewarded, so a non-revealer's lock could sit stuck
//!   forever if nobody bothered to call it. `SLASH_KEEPER_REWARD` (minted
//!   through the same capped `_mint_capped` path as everything else) is
//!   paid to whoever successfully calls `slash_non_revealer` on someone
//!   else (self-slashing earns nothing), so locks reliably clear promptly.
//! * VIEWS: `get_juror_locked_stake`, `get_juror_unlocked_stake`, and
//!   `get_juror_open_dispute_count` expose this accounting for UIs/keepers
//!   deciding whether a juror can safely unstake or is near the
//!   concurrency cap.
//!
//! OPT-IN EVALUATION WITH A BOND (added on top of the above - Stage 1 is
//! now opt-in, not admin/anyone-initiated)
//! --------------------------------------------------------------------------
//! * THE PROBLEM THIS CLOSES: `create_selection_dispute` used to accept an
//!   arbitrary `candidate` address from an arbitrary caller. Nothing
//!   stopped (or discouraged) someone from spinning up a dispute - with its
//!   full juror draw, commit/reveal window, and VRF cost - for every one of
//!   hundreds of thousands of passive addresses that never asked to be
//!   evaluated and have no interest in Stage 3 conviction voting.
//! * THE FIX: `create_selection_dispute` is gone. The only way to start a
//!   Stage 1 dispute is now `request_evaluation`, which a candidate calls
//!   on their OWN address (there is no more "nominate someone else"
//!   surface) and which requires locking `EVALUATION_BOND_AMOUNT` (50 of
//!   this contract's own token, the same token jurors stake) up front, plus
//!   a non-empty `evidence` `ByteArray` describing why they should be
//!   empowered. Both requirements are enforced at call time: a zero-length
//!   `evidence` argument reverts immediately with `'EvidenceRequired'`
//!   rather than opening a dispute that is doomed to fail for a reason
//!   jurors never got to see.
//! * ONE OPEN REQUEST AT A TIME: `has_active_dispute` / `active_dispute_for_candidate`
//!   track, per candidate, whether they already have an unfinalized bonded
//!   dispute in flight; a second `request_evaluation` call while one is
//!   still open reverts with `'AlreadyUnderEvaluation'`. This is on top of
//!   (not a replacement for) the bond itself - the bond is what makes
//!   spamming *costly*, this mapping is what makes it *impossible* to
//!   double-dip a single evaluation window.
//! * SETTLEMENT, AT FINALIZATION, ONE-SHOT: `finalize_selection` now also
//!   settles the bond, exactly once (`Dispute.bond_settled`), using the
//!   same `final_score` it already computed for the Stage 2 mint decision:
//!     - `final_score > 0`  -> the bond is refunded in full, via a plain
//!       `erc20.transfer` back to the requester, in the SAME transaction
//!       that mints their Stage 2 governance tokens. Success pays for
//!       itself.
//!     - `final_score <= 0` -> the bond is *not* transferred anywhere; it
//!       is simply added to `Dispute.slash_pool`, the exact same pool
//!       `claim_juror_reward` already pays out of pro-rata to coherent
//!       jurors. This mirrors how a non-revealing juror's slashed stake
//!       already funds that same pool (see "JUROR STAKE LOCKING" `slash_pool`
//!       accounting) - no new token-custody path is introduced, the bond's
//!       tokens simply arrived in the contract earlier (at `request_evaluation`
//!       time, via `transfer_from`) and either leave (refund) or stay and
//!       get relabeled (slash) at finalize time.
//! * WHY NO SEPARATE "evidence" JUDGING: jurors still score purely via the
//!   existing commit/reveal Schelling game - `evidence` is stored
//!   (`dispute_evidence`) purely as on-chain context for jurors/observers to
//!   read before voting, exactly like `FundingProposal.evidence` already
//!   works for Stage 3. It has no on-chain scoring logic of its own beyond
//!   the non-empty check at request time.
//! * VIEWS: `get_evaluation_bond_amount`, `get_active_dispute_for_candidate`,
//!   and `get_dispute_evidence` expose this accounting to UIs.

#[starknet::interface]
pub trait IStakeholderConviction<TContractState> {
    // ---- juror staking (Kleros side) ----
    fn stake(ref self: TContractState, amount: u256);
    fn unstake(ref self: TContractState, amount: u256);

    // ---- stakeholder selection (Kleros dispute lifecycle) ----
    // num_draws is no longer caller-supplied - see module header,
    // "ADMIN-CONFIGURED num_draws". It always uses the admin-set,
    // timelocked `num_draws` parameter (min 10).
    //
    // Opt-in only, bonded - see module header, "OPT-IN EVALUATION WITH A
    // BOND". The caller IS the candidate; there is no more "nominate
    // someone else" path. Requires locking `EVALUATION_BOND_AMOUNT` of
    // this contract's own token (caller must `approve` first) and a
    // non-empty `evidence` argument.
    fn request_evaluation(ref self: TContractState, evidence: ByteArray) -> u256;
    fn commit_vote(ref self: TContractState, dispute_id: u256, commit_hash: felt252);
    fn reveal_vote(ref self: TContractState, dispute_id: u256, score: i8, salt: felt252);
    fn slash_non_revealer(ref self: TContractState, dispute_id: u256, juror: starknet::ContractAddress);
    fn finalize_selection(ref self: TContractState, dispute_id: u256);
    fn claim_juror_reward(ref self: TContractState, dispute_id: u256);

    // ---- non-transferable governance tokens (Stage 2, decaying, uncapped) ----
    fn governance_balance(self: @TContractState, holder: starknet::ContractAddress) -> u256;
    fn governance_available(self: @TContractState, holder: starknet::ContractAddress) -> u256;
    fn governance_locked(self: @TContractState, holder: starknet::ContractAddress) -> u256;

    // ---- conviction voting / fund allocation ----
    fn create_funding_proposal(
        ref self: TContractState,
        funding_wallet: starknet::ContractAddress,
        requested_amount: u256,
        evidence: ByteArray,
    ) -> u256;
    fn deposit_funds(ref self: TContractState, amount: u256);
    fn create_conviction(ref self: TContractState, amount: u256) -> u32;
    fn add_support(ref self: TContractState, proposal_id: u256, conviction_id: u32);
    fn remove_support(ref self: TContractState, conviction_id: u32);
    fn release_conviction(ref self: TContractState, conviction_id: u32);
    fn execute_proposal(ref self: TContractState, proposal_id: u256);

    fn get_conviction_power(
        self: @TContractState, owner: starknet::ContractAddress, conviction_id: u32
    ) -> u256;
    fn get_proposal_total_power(self: @TContractState, proposal_id: u256) -> u256;
    fn get_conviction_reward_amount(self: @TContractState) -> u256;

    // ---- this contract's own ERC20 (ERC20Impl/ERC20MetadataImpl cover
    // transfer/transfer_from/approve/balance_of/total_supply/name/symbol/
    // decimals automatically via embed_v0 - these two just expose the cap) ----
    fn token_max_supply(self: @TContractState) -> u256;
    fn token_remaining_mintable(self: @TContractState) -> u256;
    fn burn(ref self: TContractState, amount: u256);

    // ---- decay (this contract's own transferable ERC20 balances) ----
    fn apply_decay(ref self: TContractState, user: starknet::ContractAddress);
    fn batch_apply_decay(ref self: TContractState, users: Array<starknet::ContractAddress>);
    fn get_decay_rate_bps(self: @TContractState) -> u16;
    fn get_min_decay_for_reward(self: @TContractState) -> u256;
    fn get_caller_reward_amount(self: @TContractState) -> u256;
    fn get_last_decay_at(self: @TContractState, user: starknet::ContractAddress) -> u64;
    fn is_protected_address(self: @TContractState, user: starknet::ContractAddress) -> bool;

    // ---- juror stake locking (anti-evasion) - see module header,
    // "JUROR STAKE LOCKING" ----
    fn get_juror_locked_stake(self: @TContractState, juror: starknet::ContractAddress) -> u256;
    fn get_juror_unlocked_stake(self: @TContractState, juror: starknet::ContractAddress) -> u256;
    fn get_juror_open_dispute_count(self: @TContractState, juror: starknet::ContractAddress) -> u32;

    // ---- opt-in evaluation bond - see module header, "OPT-IN EVALUATION
    // WITH A BOND" ----
    fn get_evaluation_bond_amount(self: @TContractState) -> u256;
    fn get_active_dispute_for_candidate(
        self: @TContractState, candidate: starknet::ContractAddress
    ) -> u256;
    fn get_dispute_evidence(self: @TContractState, dispute_id: u256) -> ByteArray;

    // ---- admin: every parameter below is timelocked - propose now,
    // execute only once TIMELOCK_DURATION (3 days) has elapsed ----
    fn propose_set_funding_token(ref self: TContractState, token: starknet::ContractAddress);
    fn execute_set_funding_token(ref self: TContractState);
    fn propose_set_conviction_threshold(ref self: TContractState, threshold: u256);
    fn execute_set_conviction_threshold(ref self: TContractState);
    fn propose_set_conviction_reward_amount(ref self: TContractState, amount: u256);
    fn execute_set_conviction_reward_amount(ref self: TContractState);
    fn propose_set_vrf_provider(ref self: TContractState, new_vrf_provider: starknet::ContractAddress);
    fn execute_set_vrf_provider(ref self: TContractState);
    fn propose_set_commit_duration(ref self: TContractState, commit_duration: u64);
    fn execute_set_commit_duration(ref self: TContractState);
    fn propose_set_reveal_duration(ref self: TContractState, reveal_duration: u64);
    fn execute_set_reveal_duration(ref self: TContractState);
    fn propose_set_non_reveal_slash_bps(ref self: TContractState, bps: u16);
    fn execute_set_non_reveal_slash_bps(ref self: TContractState);
    fn propose_set_decay_rate_bps(ref self: TContractState, bps: u16);
    fn execute_set_decay_rate_bps(ref self: TContractState);
    fn propose_set_min_decay_for_reward(ref self: TContractState, amount: u256);
    fn execute_set_min_decay_for_reward(ref self: TContractState);
    fn propose_set_caller_reward_amount(ref self: TContractState, amount: u256);
    fn execute_set_caller_reward_amount(ref self: TContractState);
    /// Minimum enforceable value is MIN_NUM_DRAWS (10) - see module header.
    fn propose_set_num_draws(ref self: TContractState, num_draws: u32);
    fn execute_set_num_draws(ref self: TContractState);
    fn get_num_draws(self: @TContractState) -> u32;
    fn propose_set_protected_address(ref self: TContractState, target: starknet::ContractAddress, protected: bool);
    fn execute_set_protected_address(ref self: TContractState, target: starknet::ContractAddress);
    fn get_pending_change(self: @TContractState, param_key: felt252) -> StakeholderConviction::PendingChange;
    fn get_pending_protected(
        self: @TContractState, target: starknet::ContractAddress
    ) -> StakeholderConviction::PendingProtectedChange;

    // ---- admin roster (timelocked - see module header, "ADMIN ROSTER IS
    // NOW TIMELOCKED TOO") ----
    fn propose_add_admin(ref self: TContractState, new_admin: starknet::ContractAddress);
    fn execute_add_admin(ref self: TContractState, new_admin: starknet::ContractAddress);
    fn propose_remove_admin(ref self: TContractState, admin_to_remove: starknet::ContractAddress);
    fn execute_remove_admin(ref self: TContractState, admin_to_remove: starknet::ContractAddress);
    fn get_pending_admin_change(
        self: @TContractState, target: starknet::ContractAddress
    ) -> StakeholderConviction::PendingAdminChange;
    fn admin_count(self: @TContractState) -> u32;

    // ---- upgradeability (see module header, "UPGRADEABILITY") ----
    fn propose_upgrade(ref self: TContractState, new_class_hash: starknet::ClassHash);
    fn execute_upgrade(ref self: TContractState);
    /// One-way switch: once called, upgrades are disabled permanently and
    /// this cannot be reversed by any function in this contract.
    fn disable_upgrades_forever(ref self: TContractState);
    fn is_upgrades_disabled(self: @TContractState) -> bool;
    fn get_pending_upgrade(self: @TContractState) -> StakeholderConviction::PendingUpgrade;

    // ---- views ----
    fn get_dispute(self: @TContractState, dispute_id: u256) -> StakeholderConviction::Dispute;
    fn get_proposal(self: @TContractState, proposal_id: u256) -> StakeholderConviction::FundingProposal;
    fn get_conviction(
        self: @TContractState, owner: starknet::ContractAddress, id: u32
    ) -> StakeholderConviction::Conviction;
    fn get_juror_stake(self: @TContractState, juror: starknet::ContractAddress) -> u256;
    fn total_stake_weight(self: @TContractState) -> u256;
}

#[starknet::contract]
pub mod StakeholderConviction {
    use core::array::ArrayTrait;
    use core::num::traits::Zero;
    use core::poseidon::poseidon_hash_span;
    use starknet::{ContractAddress, ClassHash, get_caller_address, get_block_timestamp, get_contract_address};
    use starknet::storage::{
        Map, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess,
    };

    use openzeppelin_interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use openzeppelin_token::erc20::{ERC20Component, ERC20HooksEmptyImpl, DefaultConfig};
    use openzeppelin_access::accesscontrol::AccessControlComponent;
    use openzeppelin_access::accesscontrol::DEFAULT_ADMIN_ROLE;
    use openzeppelin_introspection::src5::SRC5Component;
    use openzeppelin_security::reentrancyguard::ReentrancyGuardComponent;
    // Upgradeability: gives this contract `UpgradeableComponent::InternalImpl::upgrade`,
    // a thin wrapper around Starknet's native `replace_class_syscall`. No
    // external entrypoint is embedded from the component itself - this
    // contract exposes its own `propose_upgrade` / `execute_upgrade` pair
    // (below) that calls the internal `upgrade` only once the 7-day
    // timelock has elapsed - see module header, "UPGRADEABILITY".
    use openzeppelin_upgrades::upgradeable::UpgradeableComponent;

    // Cartridge VRF: synchronous, onchain-verified randomness.
    // Scarb.toml needs: cartridge_vrf = { git = "https://github.com/cartridge-gg/vrf" }
    use cartridge_vrf::Source;
    use cartridge_vrf::vrf_consumer::vrf_consumer_component::VrfConsumerComponent;

    component!(path: ERC20Component, storage: erc20, event: ERC20Event);
    component!(path: AccessControlComponent, storage: accesscontrol, event: AccessControlEvent);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);
    component!(
        path: ReentrancyGuardComponent, storage: reentrancyguard, event: ReentrancyGuardEvent
    );
    component!(path: VrfConsumerComponent, storage: vrf_consumer, event: VrfConsumerEvent);
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);

    // Standard IERC20 surface (transfer, transfer_from, approve, balance_of,
    // total_supply, allowance) - embedded straight into this contract's ABI.
    // NOTE: there is deliberately no embedded "mint" here. OZ's ERC20Impl
    // never exposes one; the only mint paths are the internal
    // `_mint_capped` helper below, reachable only from the constructor,
    // `_distribute_conviction_rewards`, and the slash-keeper reward in
    // `slash_non_revealer`.
    #[abi(embed_v0)]
    impl ERC20Impl = ERC20Component::ERC20Impl<ContractState>;
    #[abi(embed_v0)]
    impl ERC20MetadataImpl = ERC20Component::ERC20MetadataImpl<ContractState>;
    impl ERC20InternalImpl = ERC20Component::InternalImpl<ContractState>;

    #[abi(embed_v0)]
    impl AccessControlMixinImpl =
        AccessControlComponent::AccessControlMixinImpl<ContractState>;
    impl AccessControlInternalImpl = AccessControlComponent::InternalImpl<ContractState>;
    impl ReentrancyGuardInternalImpl = ReentrancyGuardComponent::InternalImpl<ContractState>;

    #[abi(embed_v0)]
    impl VrfConsumerImpl = VrfConsumerComponent::VrfConsumerImpl<ContractState>;
    impl VrfConsumerInternalImpl = VrfConsumerComponent::InternalImpl<ContractState>;

    // No embed_v0 here deliberately: the component's internal `upgrade` is
    // only ever called from this contract's own timelocked `execute_upgrade`
    // below, never exposed as a raw entrypoint on its own.
    impl UpgradeableInternalImpl = UpgradeableComponent::InternalImpl<ContractState>;

    // //////////////////////////////////////////////////////////////
                              // CONSTANTS
    // //////////////////////////////////////////////////////////////

    /// Fixed-point scale for the mean/stdev scoring arithmetic.
    const SCALE: i64 = 1000;
    /// Coherence tolerance band for juror rewards (raw score units).
    const COHERENCE_BAND: i64 = 1;
    /// Default non-reveal slash: 3000 bps = 30%.
    const DEFAULT_SLASH_BPS: u16 = 3000;
    const BPS_DENOM: u256 = 10_000;

    const DEFAULT_COMMIT_DURATION: u64 = 86_400; // 1 day
    const DEFAULT_REVEAL_DURATION: u64 = 86_400; // 1 day

    const PHASE_COMMIT: u8 = 1;
    const PHASE_REVEAL: u8 = 2;
    const PHASE_FINALIZED: u8 = 3;

    /// Governance-token decay: linear to zero over exactly one year,
    /// stepped hourly (decay is recomputed, not re-applied, on every read -
    /// see `_decayed_grant_amount`).
    const SECONDS_PER_HOUR: u64 = 3_600;
    const HOURS_PER_YEAR: u64 = 8_760; // 365 * 24

    /// This contract's own ERC20 (see module header): OZ `DefaultConfig`
    /// gives it the standard 18 decimals, so both figures below are
    /// whole-token counts times 10^18.
    ///   MAX_SUPPLY     = 50,000,000 * 10^18 = 5 followed by 25 zeros.
    ///   INITIAL_SUPPLY = 10,000,000 * 10^18 = 1 followed by 25 zeros.
    /// Written as explicit literals rather than a const expression since
    /// u256 const-arithmetic support varies across corelib versions - see
    /// module CAVEATS re: this file not being compiled in this environment.
    const MAX_SUPPLY: u256 = 50_000_000_000_000_000_000_000_000;
    const INITIAL_SUPPLY: u256 = 10_000_000_000_000_000_000_000_000;

    /// Every admin-configurable parameter (including the admin roster and
    /// num_draws) must be proposed, then can only be executed after this
    /// delay has elapsed - see module header, "ADMIN TIMELOCK".
    const TIMELOCK_DURATION: u64 = 259_200; // 3 days

    /// Class-hash upgrades use a longer, separate timelock than ordinary
    /// parameters - see module header, "UPGRADEABILITY".
    const UPGRADE_TIMELOCK_DURATION: u64 = 604_800; // 7 days

    /// Floor enforced on the admin-configurable `num_draws` value used by
    /// every `request_evaluation` call - see module header,
    /// "ADMIN-CONFIGURED num_draws".
    const MIN_NUM_DRAWS: u32 = 10;
    /// Constructor default for `num_draws`, itself admin-adjustable
    /// afterwards (timelocked, floor MIN_NUM_DRAWS) via
    /// propose/execute_set_num_draws.
    const DEFAULT_NUM_DRAWS: u32 = 10;

    /// Default hourly-stepped annual decay rate applied to holders of this
    /// contract's own transferable ERC20 via `apply_decay` /
    /// `batch_apply_decay` - see `_apply_decay`. 500 bps = 5%/year.
    /// Admin-adjustable (timelocked) via propose/execute_set_decay_rate_bps.
    const DEFAULT_DECAY_RATE_BPS: u16 = 500;
    const DECAY_BPS_DENOM: u256 = 10_000;

    /// Minimum single-call burn (in this contract's own token, 18 decimals)
    /// before the caller of `apply_decay`/`batch_apply_decay` earns a
    /// reward for triggering it - keeps dust-sized decays from being worth
    /// farming. Admin-adjustable (timelocked).
    const DEFAULT_MIN_DECAY_FOR_REWARD: u256 = 1_000_000_000_000_000_000; // 1 token

    /// Reward minted (through the same `_mint_capped` cap as everything
    /// else) to whoever successfully triggers a qualifying decay on
    /// someone else's balance. Admin-adjustable (timelocked).
    const DEFAULT_CALLER_REWARD_AMOUNT: u256 = 1_000_000_000_000_000; // 0.001 token

    /// Per-caller cooldown on earning decay-trigger rewards, so a single
    /// address can't farm the reward by spamming `apply_decay` calls.
    const CALLER_REWARD_COOLDOWN: u64 = 86_400; // 1 day

    /// Max addresses per `batch_apply_decay` call - gas griefing protection.
    const MAX_BATCH_DECAY: u32 = 50;

    /// Cap on how many disputes a single juror can be simultaneously
    /// locked into (see module header, "JUROR STAKE LOCKING"). Past this,
    /// a juror is skipped in the draw rather than seated, since locking is
    /// additive across open disputes and an unbounded juror would end up
    /// with all their stake permanently immobilized.
    const MAX_CONCURRENT_JUROR_LOCKS: u32 = 15;

    /// Cap on deterministic, VRF-free redraw attempts per draw slot when
    /// the first-drawn juror is at their concurrency cap. Bounds worst-case
    /// gas in `request_evaluation`; hitting this means essentially
    /// every stake-weighted juror is maxed out, which should be treated as
    /// an operational signal to raise MAX_CONCURRENT_JUROR_LOCKS or recruit
    /// more jurors, not something to silently paper over.
    const MAX_REDRAW_ATTEMPTS: u32 = 20;

    /// Keeper reward (minted through `_mint_capped`, same cap as every
    /// other mint) for calling `slash_non_revealer` on someone else. Keeps
    /// locks from rotting indefinitely when a non-reveal isn't
    /// self-interestedly punished by another juror's coherence reward.
    /// Self-slashing (juror == caller) earns nothing.
    const SLASH_KEEPER_REWARD: u256 = 500_000_000_000_000; // 0.0005 token

    /// Bond a stakeholder must lock (in this contract's own token) to
    /// request their own selection dispute via `request_evaluation` - see
    /// module header, "OPT-IN EVALUATION WITH A BOND". Refunded in full on
    /// a positive final score, alongside the Stage 2 governance-token
    /// mint; otherwise added to the dispute's `slash_pool` (the same pool
    /// `claim_juror_reward` pays coherent jurors from).
    const EVALUATION_BOND_AMOUNT: u256 = 50_000_000_000_000_000_000; // 50 tokens

    // ---- timelocked-parameter keys: short strings packed into felt252,
    // one per scalar/address admin parameter, used as the key into
    // `pending_changes` by the generic `_propose_change`/`_execute_change`
    // engine below. ----
    const PARAM_FUNDING_TOKEN: felt252 = 'FUNDING_TOKEN';
    const PARAM_CONVICTION_THRESHOLD: felt252 = 'CONVICTION_THRESHOLD';
    const PARAM_CONVICTION_REWARD_AMOUNT: felt252 = 'CONVICTION_REWARD_AMT';
    const PARAM_VRF_PROVIDER: felt252 = 'VRF_PROVIDER';
    const PARAM_COMMIT_DURATION: felt252 = 'COMMIT_DURATION';
    const PARAM_REVEAL_DURATION: felt252 = 'REVEAL_DURATION';
    const PARAM_NON_REVEAL_SLASH_BPS: felt252 = 'NON_REVEAL_SLASH_BPS';
    const PARAM_DECAY_RATE_BPS: felt252 = 'DECAY_RATE_BPS';
    const PARAM_MIN_DECAY_FOR_REWARD: felt252 = 'MIN_DECAY_FOR_REWARD';
    const PARAM_CALLER_REWARD_AMOUNT: felt252 = 'CALLER_REWARD_AMOUNT';
    const PARAM_NUM_DRAWS: felt252 = 'NUM_DRAWS';

    // //////////////////////////////////////////////////////////////
                              // STRUCTS
    // //////////////////////////////////////////////////////////////

    #[derive(Drop, Serde, Copy, starknet::Store)]
    pub struct Dispute {
        pub candidate: ContractAddress,
        pub num_draws: u32,
        pub unique_juror_count: u32,
        pub commit_deadline: u64,
        pub reveal_deadline: u64,
        pub phase: u8,
        pub final_score: i64,        // unscaled, only valid once final_score_set
        pub final_score_set: bool,
        pub total_weight_revealed: u32,
        pub total_coherent_weight: u32,
        pub slash_pool: u256,
        pub governance_tokens_minted: u256, // 0 until finalized (and may stay 0 if score <= 0)
        // ---- opt-in evaluation bond - see module header, "OPT-IN
        // EVALUATION WITH A BOND" ----
        pub requester: ContractAddress, // who posted the bond (== candidate)
        pub bond_amount: u256,          // EVALUATION_BOND_AMOUNT at request time
        pub bond_settled: bool,         // true once finalize_selection has refunded/slashed it
    }

    /// A single non-transferable mint. Balance = sum of `_decayed_grant_amount`
    /// over every grant a holder has ever received. Wholly separate from the
    /// embedded ERC20's balances - see module header.
    #[derive(Drop, Serde, Copy, starknet::Store)]
    struct Grant {
        amount: u256,
        minted_at: u64,
    }

    #[derive(Drop, Serde, Copy, starknet::Store)]
    pub struct Conviction {
        pub owner: ContractAddress,
        pub id: u32,
        pub amount: u256,          // locked amount backing this conviction's voting power
        pub created_at: u64,
        pub is_supporting: bool,
        pub active_proposal: u256, // only meaningful while is_supporting == true
        pub support_start: u64,    // only meaningful while is_supporting == true
        pub released: bool,        // true once unlocked back to available balance
    }

    #[derive(Drop, Serde, starknet::Store)]
    pub struct FundingProposal {
        pub funding_wallet: ContractAddress,
        pub requested_amount: u256,
        pub evidence: ByteArray,
        pub created_at: u64,
        pub executed: bool,
        pub supporter_count: u32,
    }

    #[derive(Drop, Serde, Copy, starknet::Store)]
    struct Supporter {
        owner: ContractAddress,
        conviction_id: u32,
    }

    /// A queued change to a scalar or address-valued admin parameter.
    /// Addresses and small integers are all cast to/from `u256` at the call
    /// site so one generic engine (`_propose_change` / `_execute_change`)
    /// can serve every timelocked parameter - see module header, "ADMIN
    /// TIMELOCK".
    #[derive(Drop, Serde, Copy, starknet::Store)]
    pub struct PendingChange {
        pub new_value: u256,
        pub effective_at: u64,
        pub exists: bool,
    }

    /// Same idea as `PendingChange` but for `is_protected_address`, which is
    /// keyed by the target address itself rather than a fixed parameter key.
    #[derive(Drop, Serde, Copy, starknet::Store)]
    pub struct PendingProtectedChange {
        pub new_value: bool,
        pub effective_at: u64,
        pub exists: bool,
    }

    /// A queued class-hash upgrade, subject to `UPGRADE_TIMELOCK_DURATION`
    /// (7 days) rather than the ordinary `TIMELOCK_DURATION` - see module
    /// header, "UPGRADEABILITY".
    #[derive(Drop, Serde, Copy, starknet::Store)]
    pub struct PendingUpgrade {
        pub new_class_hash: ClassHash,
        pub effective_at: u64,
        pub exists: bool,
    }

    /// A queued admin-roster change, keyed by the target address.
    /// `is_add == true` means "grant DEFAULT_ADMIN_ROLE to `target` on
    /// execute", `is_add == false` means "revoke it" - see module header,
    /// "ADMIN ROSTER IS NOW TIMELOCKED TOO".
    #[derive(Drop, Serde, Copy, starknet::Store)]
    pub struct PendingAdminChange {
        pub is_add: bool,
        pub effective_at: u64,
        pub exists: bool,
    }

    // //////////////////////////////////////////////////////////////
                              // STORAGE
    // //////////////////////////////////////////////////////////////

    #[storage]
    struct Storage {
        #[substorage(v0)]
        erc20: ERC20Component::Storage,
        #[substorage(v0)]
        accesscontrol: AccessControlComponent::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        #[substorage(v0)]
        reentrancyguard: ReentrancyGuardComponent::Storage,
        #[substorage(v0)]
        vrf_consumer: VrfConsumerComponent::Storage,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,

        // ---- upgradeability - see module header, "UPGRADEABILITY" ----
        pending_upgrade: PendingUpgrade,
        /// One-way: once true, nothing in this contract can set it back to
        /// false. See `disable_upgrades_forever`.
        upgrades_disabled: bool,

        // stake_token is gone: jurors now stake THIS contract's own ERC20
        // balance (self.erc20), so no external stake-token address is
        // stored anymore. funding_token is still a separate external
        // ERC20 - it's what the treasury pays proposals out in, and has
        // nothing to do with this contract's own token or its supply cap.
        funding_token: ContractAddress,

        commit_duration: u64,
        reveal_duration: u64,
        non_reveal_slash_bps: u16,
        conviction_threshold: u256,
        /// Amount of this contract's own token minted and split pro-rata
        /// by power among a proposal's active supporters each time
        /// `execute_proposal` succeeds. Zero disables conviction-voting
        /// rewards entirely. Every mint it triggers is capped by
        /// `_mint_capped` against `MAX_SUPPLY`.
        conviction_reward_amount: u256,
        /// Number of jurors drawn per selection dispute. Admin-set only
        /// (no longer caller-supplied), timelocked, floor MIN_NUM_DRAWS
        /// (10) - see module header, "ADMIN-CONFIGURED num_draws".
        num_draws: u32,

        // ---- staking / Fenwick tree over juror slots (identical mechanism
        // to the reference KlerosSchelling contract) ----
        tree_size: u32,
        next_index: u32,
        juror_index: Map<ContractAddress, u32>,
        index_juror: Map<u32, ContractAddress>,
        fenwick_tree: Map<u32, u256>,
        juror_stake: Map<ContractAddress, u256>,

        // ---- juror stake locking (anti-evasion) - see module header,
        // "JUROR STAKE LOCKING" ----
        /// Sum of stake-at-draw-time snapshots across every dispute this
        /// juror is currently drawn into and has not yet resolved (revealed
        /// or been slashed). `unstake` must leave at least this much behind.
        juror_locked_total: Map<ContractAddress, u256>,
        /// Count of currently-open dispute obligations for this juror -
        /// used only to enforce MAX_CONCURRENT_JUROR_LOCKS at draw time,
        /// not for unstake accounting (juror_locked_total handles that).
        juror_open_lock_count: Map<ContractAddress, u32>,
        /// Per-(dispute, juror) snapshot amount, taken the first time a
        /// juror is drawn into that dispute.
        dispute_juror_locked_snapshot: Map<(u256, ContractAddress), u256>,
        /// Per-(dispute, juror) one-shot release flag. Reveal and slash are
        /// mutually exclusive and each individually single-fire (existing
        /// asserts on dispute_revealed / dispute_slashed), so this flag is
        /// enough to make `_release_dispute_lock` idempotent regardless of
        /// which path fires first.
        dispute_juror_lock_released: Map<(u256, ContractAddress), bool>,

        // ---- selection disputes ----
        dispute_count: u256,
        disputes: Map<u256, Dispute>,
        dispute_juror_draws: Map<(u256, ContractAddress), u32>,
        dispute_juror_list: Map<(u256, u32), ContractAddress>,
        dispute_commit: Map<(u256, ContractAddress), felt252>,
        dispute_committed: Map<(u256, ContractAddress), bool>,
        dispute_revealed: Map<(u256, ContractAddress), bool>,
        dispute_score: Map<(u256, ContractAddress), i8>,
        dispute_coherent: Map<(u256, ContractAddress), bool>,
        dispute_slashed: Map<(u256, ContractAddress), bool>,
        dispute_reward_claimed: Map<(u256, ContractAddress), bool>,

        // ---- opt-in evaluation bond - see module header, "OPT-IN
        // EVALUATION WITH A BOND" ----
        /// Free-text (URI, hash, or inline text) evidence a candidate
        /// submits with `request_evaluation`. Purely informational context
        /// for jurors/observers, mirroring `FundingProposal.evidence`.
        dispute_evidence: Map<u256, ByteArray>,
        /// True while `candidate` has an unfinalized bonded dispute open -
        /// blocks a second concurrent `request_evaluation` for the same
        /// candidate.
        has_active_dispute: Map<ContractAddress, bool>,
        /// The dispute_id of `candidate`'s currently open bonded dispute,
        /// if `has_active_dispute` is true. Purely a convenience view.
        active_dispute_for_candidate: Map<ContractAddress, u256>,

        // ---- non-transferable governance tokens ----
        governance_next_grant: Map<ContractAddress, u32>,
        governance_grant: Map<(ContractAddress, u32), Grant>,
        governance_locked_total: Map<ContractAddress, u256>, // sum of amount across un-released convictions

        // ---- convictions ----
        next_conviction_id: Map<ContractAddress, u32>,
        convictions: Map<(ContractAddress, u32), Conviction>,

        // ---- funding proposals ----
        proposal_count: u256,
        proposals: Map<u256, FundingProposal>,
        proposal_supporters: Map<(u256, u32), Supporter>, // 0-indexed, append-only per proposal
        treasury_balance: u256,

        // ---- ERC20 balance decay (hourly-stepped, admin-tunable annual
        // rate) - see `_apply_decay` and the module header ----
        decay_rate_bps: u16,
        min_decay_for_reward: u256,
        caller_reward_amount: u256,
        last_decay_at: Map<ContractAddress, u64>,
        last_caller_reward_at: Map<ContractAddress, u64>,
        is_protected: Map<ContractAddress, bool>,

        // ---- 3-day timelock on every admin-configurable parameter ----
        pending_changes: Map<felt252, PendingChange>,
        pending_protected: Map<ContractAddress, PendingProtectedChange>,

        // ---- admin roster - timelocked, keyed per-target-address; see
        // module header, "ADMIN ROSTER IS NOW TIMELOCKED TOO". admin_count
        // is tracked so `execute_remove_admin` can refuse to drop the last
        // remaining admin. ----
        pending_admin_changes: Map<ContractAddress, PendingAdminChange>,
        admin_count: u32,
    }

    // //////////////////////////////////////////////////////////////
                              // EVENTS
    // //////////////////////////////////////////////////////////////

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        ERC20Event: ERC20Component::Event,
        #[flat]
        AccessControlEvent: AccessControlComponent::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
        #[flat]
        ReentrancyGuardEvent: ReentrancyGuardComponent::Event,
        #[flat]
        VrfConsumerEvent: VrfConsumerComponent::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,

        Staked: Staked,
        Unstaked: Unstaked,
        DisputeCreated: DisputeCreated,
        EvaluationRequested: EvaluationRequested,
        JurorDrawn: JurorDrawn,
        VoteCommitted: VoteCommitted,
        VoteRevealed: VoteRevealed,
        JurorSlashed: JurorSlashed,
        SlashKeeperRewarded: SlashKeeperRewarded,
        DisputeFinalized: DisputeFinalized,
        JurorRewardClaimed: JurorRewardClaimed,
        GovernanceTokensMinted: GovernanceTokensMinted,
        BondRefunded: BondRefunded,
        BondSlashed: BondSlashed,
        ConvictionCreated: ConvictionCreated,
        ConvictionReleased: ConvictionReleased,
        SupportAdded: SupportAdded,
        SupportRemoved: SupportRemoved,
        FundingProposalCreated: FundingProposalCreated,
        TreasuryDeposited: TreasuryDeposited,
        ProposalExecuted: ProposalExecuted,
        ConvictionRewardDistributed: ConvictionRewardDistributed,
        DecayApplied: DecayApplied,
        DecayCallerRewarded: DecayCallerRewarded,
        ChangeProposed: ChangeProposed,
        ChangeExecuted: ChangeExecuted,
        ProtectedAddressProposed: ProtectedAddressProposed,
        ProtectedAddressSet: ProtectedAddressSet,
        AdminAddProposed: AdminAddProposed,
        AdminAdded: AdminAdded,
        AdminRemoveProposed: AdminRemoveProposed,
        AdminRemoved: AdminRemoved,
        UpgradeProposed: UpgradeProposed,
        UpgradeExecuted: UpgradeExecuted,
        UpgradesDisabledForever: UpgradesDisabledForever,
    }

    #[derive(Drop, starknet::Event)]
    struct Staked {
        #[key]
        juror: ContractAddress,
        amount: u256,
        new_total: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct Unstaked {
        #[key]
        juror: ContractAddress,
        amount: u256,
        new_total: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct DisputeCreated {
        #[key]
        dispute_id: u256,
        #[key]
        candidate: ContractAddress,
        num_draws: u32,
    }

    #[derive(Drop, starknet::Event)]
    struct EvaluationRequested {
        #[key]
        dispute_id: u256,
        #[key]
        candidate: ContractAddress,
        bond_amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct JurorDrawn {
        #[key]
        dispute_id: u256,
        #[key]
        juror: ContractAddress,
        total_draws_for_juror: u32,
    }

    #[derive(Drop, starknet::Event)]
    struct VoteCommitted {
        #[key]
        dispute_id: u256,
        #[key]
        juror: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct VoteRevealed {
        #[key]
        dispute_id: u256,
        #[key]
        juror: ContractAddress,
        score: i8,
    }

    #[derive(Drop, starknet::Event)]
    struct JurorSlashed {
        #[key]
        dispute_id: u256,
        #[key]
        juror: ContractAddress,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct SlashKeeperRewarded {
        #[key]
        caller: ContractAddress,
        #[key]
        juror: ContractAddress,
        #[key]
        dispute_id: u256,
        reward: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct DisputeFinalized {
        #[key]
        dispute_id: u256,
        #[key]
        candidate: ContractAddress,
        final_score: i64,
    }

    #[derive(Drop, starknet::Event)]
    struct JurorRewardClaimed {
        #[key]
        dispute_id: u256,
        #[key]
        juror: ContractAddress,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct GovernanceTokensMinted {
        #[key]
        dispute_id: u256,
        #[key]
        candidate: ContractAddress,
        amount: u256,
        final_score: i64,
    }

    #[derive(Drop, starknet::Event)]
    struct BondRefunded {
        #[key]
        dispute_id: u256,
        #[key]
        requester: ContractAddress,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct BondSlashed {
        #[key]
        dispute_id: u256,
        #[key]
        requester: ContractAddress,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct ConvictionCreated {
        #[key]
        owner: ContractAddress,
        #[key]
        conviction_id: u32,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct ConvictionReleased {
        #[key]
        owner: ContractAddress,
        #[key]
        conviction_id: u32,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct SupportAdded {
        #[key]
        proposal_id: u256,
        #[key]
        owner: ContractAddress,
        conviction_id: u32,
    }

    #[derive(Drop, starknet::Event)]
    struct SupportRemoved {
        #[key]
        proposal_id: u256,
        #[key]
        owner: ContractAddress,
        conviction_id: u32,
        power_at_removal: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct FundingProposalCreated {
        #[key]
        proposal_id: u256,
        funding_wallet: ContractAddress,
        requested_amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct TreasuryDeposited {
        #[key]
        depositor: ContractAddress,
        amount: u256,
        new_treasury_balance: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct ProposalExecuted {
        #[key]
        proposal_id: u256,
        total_power: u256,
        amount_paid: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct ConvictionRewardDistributed {
        #[key]
        proposal_id: u256,
        #[key]
        recipient: ContractAddress,
        conviction_id: u32,
        power: u256,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct DecayApplied {
        #[key]
        user: ContractAddress,
        amount: u256,
        caller: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct DecayCallerRewarded {
        #[key]
        caller: ContractAddress,
        #[key]
        user: ContractAddress,
        reward: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct ChangeProposed {
        #[key]
        param_key: felt252,
        new_value: u256,
        effective_at: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct ChangeExecuted {
        #[key]
        param_key: felt252,
        new_value: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct ProtectedAddressProposed {
        #[key]
        target: ContractAddress,
        new_value: bool,
        effective_at: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct ProtectedAddressSet {
        #[key]
        target: ContractAddress,
        new_value: bool,
    }

    #[derive(Drop, starknet::Event)]
    struct AdminAddProposed {
        #[key]
        new_admin: ContractAddress,
        effective_at: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct AdminAdded {
        #[key]
        admin: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct AdminRemoveProposed {
        #[key]
        admin_to_remove: ContractAddress,
        effective_at: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct AdminRemoved {
        #[key]
        admin: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct UpgradeProposed {
        #[key]
        new_class_hash: ClassHash,
        effective_at: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct UpgradeExecuted {
        #[key]
        new_class_hash: ClassHash,
    }

    #[derive(Drop, starknet::Event)]
    struct UpgradesDisabledForever {
        #[key]
        by: ContractAddress,
    }

    // //////////////////////////////////////////////////////////////
                            // CONSTRUCTOR
    // //////////////////////////////////////////////////////////////

    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin: ContractAddress,
        name: ByteArray,
        symbol: ByteArray,
        initial_recipient: ContractAddress,
        funding_token: ContractAddress,
        tree_capacity: u32,
        vrf_provider: ContractAddress,
        conviction_threshold: u256,
        conviction_reward_amount: u256,
    ) {
        assert(admin.is_non_zero(), 'ZeroAddress');
        assert(initial_recipient.is_non_zero(), 'ZeroAddress');
        assert(funding_token.is_non_zero(), 'ZeroAddress');
        assert(tree_capacity > 0, 'InvalidCapacity');
        assert(vrf_provider.is_non_zero(), 'ZeroAddress');

        self.erc20.initializer(name, symbol);
        self.accesscontrol.initializer();
        self.accesscontrol._grant_role(DEFAULT_ADMIN_ROLE, admin);
        self.vrf_consumer.initializer(vrf_provider);

        self.funding_token.write(funding_token);
        self.tree_size.write(tree_capacity);
        self.next_index.write(0);
        self.commit_duration.write(DEFAULT_COMMIT_DURATION);
        self.reveal_duration.write(DEFAULT_REVEAL_DURATION);
        self.non_reveal_slash_bps.write(DEFAULT_SLASH_BPS);
        self.conviction_threshold.write(conviction_threshold);
        self.conviction_reward_amount.write(conviction_reward_amount);

        // num_draws default - admin-adjustable afterwards (timelocked,
        // floor MIN_NUM_DRAWS) via propose/execute_set_num_draws. See
        // module header, "ADMIN-CONFIGURED num_draws".
        self.num_draws.write(DEFAULT_NUM_DRAWS);

        // Upgrades start enabled; only `disable_upgrades_forever` can ever
        // flip this, and it can never flip back - see module header,
        // "UPGRADEABILITY".
        self.upgrades_disabled.write(false);

        // Decay defaults - all admin-adjustable afterwards via the
        // timelocked propose/execute_set_* pairs, see module header.
        self.decay_rate_bps.write(DEFAULT_DECAY_RATE_BPS);
        self.min_decay_for_reward.write(DEFAULT_MIN_DECAY_FOR_REWARD);
        self.caller_reward_amount.write(DEFAULT_CALLER_REWARD_AMOUNT);

        // The deployer-supplied `admin` above is the one and only admin at
        // deploy time - see `propose_add_admin`/`execute_add_admin` and
        // `propose_remove_admin`/`execute_remove_admin`.
        self.admin_count.write(1);

        // One-time initial mint, routed through the same capped mint path
        // as every other mint this contract ever performs - see
        // `_mint_capped`. INITIAL_SUPPLY (10M) is comfortably under
        // MAX_SUPPLY (50M) given the constants above, but the assert stays
        // so that relationship is enforced in code, not just in comments.
        self._mint_capped(initial_recipient, INITIAL_SUPPLY);
    }

    // //////////////////////////////////////////////////////////////
                          // EXTERNAL IMPL
    // //////////////////////////////////////////////////////////////

    #[abi(embed_v0)]
    impl StakeholderConvictionImpl of super::IStakeholderConviction<ContractState> {
        // ----------------------------------------------------------
                                // STAKING
        // ----------------------------------------------------------

        fn stake(ref self: ContractState, amount: u256) {
            self.reentrancyguard.start();
            assert(amount > 0, 'ZeroAmount');
            let caller = get_caller_address();

            // This contract's own token - self-transfer via the embedded
            // ERC20 component, same as any ERC20 staking pattern: the
            // caller must `approve` this contract for `amount` first.
            let ok = self.erc20.transfer_from(caller, get_contract_address(), amount);
            assert(ok, 'TransferFailed');

            let index = self._get_or_create_index(caller);
            self._fenwick_add(index, amount);

            let new_total = self.juror_stake.entry(caller).read() + amount;
            self.juror_stake.entry(caller).write(new_total);

            self.emit(Staked { juror: caller, amount, new_total });
            self.reentrancyguard.end();
        }

        /// See module header, "JUROR STAKE LOCKING": a juror can never
        /// withdraw below `juror_locked_total`, the sum of stake-at-draw-time
        /// snapshots across every open dispute they've been drawn into and
        /// not yet resolved (by reveal or by being slashed). This is what
        /// closes the "unstake immediately after being drawn, then ignore
        /// commit/reveal" evasion.
        fn unstake(ref self: ContractState, amount: u256) {
            self.reentrancyguard.start();
            assert(amount > 0, 'ZeroAmount');
            let caller = get_caller_address();

            let current = self.juror_stake.entry(caller).read();
            assert(current >= amount, 'InsufficientStake');

            let locked = self.juror_locked_total.entry(caller).read();
            assert(current - amount >= locked, 'InsufficientUnlockedStake');

            let index = self.juror_index.entry(caller).read();
            assert(index != 0, 'NotRegistered');
            self._fenwick_sub(index, amount);

            let new_total = current - amount;
            self.juror_stake.entry(caller).write(new_total);

            let ok = self.erc20.transfer(caller, amount);
            assert(ok, 'TransferFailed');

            self.emit(Unstaked { juror: caller, amount, new_total });
            self.reentrancyguard.end();
        }

        // ----------------------------------------------------------
                    // STAKEHOLDER SELECTION (Kleros dispute)
        // ----------------------------------------------------------

        /// Opt-in, bonded - see module header, "OPT-IN EVALUATION WITH A
        /// BOND". Replaces the old caller-supplied-candidate
        /// `create_selection_dispute`: the caller IS the candidate, must
        /// lock `EVALUATION_BOND_AMOUNT` of this contract's own token
        /// (`approve` this contract first), and must supply non-empty
        /// `evidence`. Reverts if the candidate already has an unfinalized
        /// bonded dispute open.
        fn request_evaluation(ref self: ContractState, evidence: ByteArray) -> u256 {
            self.reentrancyguard.start();
            assert(evidence.len() > 0, 'EvidenceRequired');

            let candidate = get_caller_address();
            assert(!self.has_active_dispute.entry(candidate).read(), 'AlreadyUnderEvaluation');

            // Bond is this contract's own token, exactly like juror stake -
            // pulled into the contract now, refunded or relabeled as slash
            // pool at finalize_selection time. See module header.
            let bond_amount = EVALUATION_BOND_AMOUNT;
            let ok = self.erc20.transfer_from(candidate, get_contract_address(), bond_amount);
            assert(ok, 'TransferFailed');

            // Admin-configured, timelocked, floor MIN_NUM_DRAWS (10) - see
            // module header, "ADMIN-CONFIGURED num_draws".
            let num_draws = self.num_draws.read();

            // Computed once, reused for every draw - see module CAVEATS.
            let total_weight = self._fenwick_total();
            assert(total_weight > 0, 'NoStake');

            let dispute_id = self.dispute_count.read();
            self.dispute_count.write(dispute_id + 1);

            let now = get_block_timestamp();
            let commit_deadline = now + self.commit_duration.read();
            let reveal_deadline = commit_deadline + self.reveal_duration.read();

            let dispute = Dispute {
                candidate,
                num_draws,
                unique_juror_count: 0,
                commit_deadline,
                reveal_deadline,
                phase: PHASE_COMMIT,
                final_score: 0,
                final_score_set: false,
                total_weight_revealed: 0,
                total_coherent_weight: 0,
                slash_pool: 0,
                governance_tokens_minted: 0,
                requester: candidate,
                bond_amount,
                bond_settled: false,
            };
            self.disputes.entry(dispute_id).write(dispute);
            self.dispute_evidence.entry(dispute_id).write(evidence);
            self.has_active_dispute.entry(candidate).write(true);
            self.active_dispute_for_candidate.entry(candidate).write(dispute_id);

            self.emit(DisputeCreated { dispute_id, candidate, num_draws });
            self.emit(EvaluationRequested { dispute_id, candidate, bond_amount });

            // Exactly one Cartridge VRF value per dispute. Caller MUST
            // prefix this call, in the same multicall, with:
            //   VRF.request_random(caller: <this_contract>, source: Source::Nonce(<this_contract>))
            let base_seed: felt252 = self
                .vrf_consumer
                .consume_random(Source::Nonce(get_contract_address()));

            let mut unique_juror_count: u32 = 0;
            let mut i: u32 = 0;
            loop {
                if i >= num_draws {
                    break;
                }

                // ---- draw, with a deterministic redraw if the first pick
                // is not yet drawn in THIS dispute AND is already at their
                // concurrent-lock cap - see module header, "JUROR STAKE
                // LOCKING". A juror already drawn in this dispute is always
                // accepted (no new lock created, just more weight). ----
                let mut rand_felt = self._derive_draw_random(base_seed, dispute_id, i);
                let mut attempt: u32 = 0;
                let juror = loop {
                    let rand_u256: u256 = rand_felt.into();
                    let target = rand_u256 % total_weight;
                    let index = self._fenwick_find(target);
                    let candidate_juror = self.index_juror.entry(index).read();
                    assert(candidate_juror.is_non_zero(), 'DrawFailed');

                    let already_drawn_here = self
                        .dispute_juror_draws
                        .entry((dispute_id, candidate_juror))
                        .read() > 0;
                    let open_locks = self.juror_open_lock_count.entry(candidate_juror).read();

                    if already_drawn_here || open_locks < MAX_CONCURRENT_JUROR_LOCKS {
                        break candidate_juror;
                    }

                    // Deterministic reseed, no extra VRF call - stays
                    // reproducible from base_seed alone.
                    attempt += 1;
                    assert(attempt < MAX_REDRAW_ATTEMPTS, 'NoEligibleJurors');
                    let mut redraw_input: Array<felt252> = ArrayTrait::new();
                    redraw_input.append(rand_felt);
                    redraw_input.append(attempt.into());
                    rand_felt = poseidon_hash_span(redraw_input.span());
                };

                let prior_draws = self.dispute_juror_draws.entry((dispute_id, juror)).read();
                self.dispute_juror_draws.entry((dispute_id, juror)).write(prior_draws + 1);

                if prior_draws == 0 {
                    self.dispute_juror_list.entry((dispute_id, unique_juror_count)).write(juror);
                    unique_juror_count += 1;

                    // NEW: lock this juror's current stake as collateral
                    // for this dispute - see module header, "JUROR STAKE
                    // LOCKING".
                    let stake_at_draw = self.juror_stake.entry(juror).read();
                    self
                        .dispute_juror_locked_snapshot
                        .entry((dispute_id, juror))
                        .write(stake_at_draw);
                    let prior_locked = self.juror_locked_total.entry(juror).read();
                    self.juror_locked_total.entry(juror).write(prior_locked + stake_at_draw);
                    let prior_open = self.juror_open_lock_count.entry(juror).read();
                    self.juror_open_lock_count.entry(juror).write(prior_open + 1);
                }

                self.emit(JurorDrawn { dispute_id, juror, total_draws_for_juror: prior_draws + 1 });
                i += 1;
            };

            if unique_juror_count > 0 {
                let mut d = self.disputes.entry(dispute_id).read();
                d.unique_juror_count = unique_juror_count;
                self.disputes.entry(dispute_id).write(d);
            }

            self.reentrancyguard.end();
            dispute_id
        }

        fn commit_vote(ref self: ContractState, dispute_id: u256, commit_hash: felt252) {
            let caller = get_caller_address();
            let d = self.disputes.entry(dispute_id).read();
            assert(d.phase == PHASE_COMMIT, 'NotCommitPhase');
            assert(get_block_timestamp() < d.commit_deadline, 'CommitClosed');

            let draws = self.dispute_juror_draws.entry((dispute_id, caller)).read();
            assert(draws > 0, 'NotDrawn');
            assert(!self.dispute_committed.entry((dispute_id, caller)).read(), 'AlreadyCommitted');

            self.dispute_commit.entry((dispute_id, caller)).write(commit_hash);
            self.dispute_committed.entry((dispute_id, caller)).write(true);

            self.emit(VoteCommitted { dispute_id, juror: caller });
        }

        fn reveal_vote(ref self: ContractState, dispute_id: u256, score: i8, salt: felt252) {
            let caller = get_caller_address();
            let mut d = self.disputes.entry(dispute_id).read();
            assert(get_block_timestamp() >= d.commit_deadline, 'CommitStillOpen');
            assert(get_block_timestamp() < d.reveal_deadline, 'RevealClosed');
            assert(score >= -5 && score <= 5, 'InvalidScore');

            if d.phase == PHASE_COMMIT {
                d.phase = PHASE_REVEAL;
                self.disputes.entry(dispute_id).write(d);
            }

            assert(self.dispute_committed.entry((dispute_id, caller)).read(), 'NoCommit');
            assert(!self.dispute_revealed.entry((dispute_id, caller)).read(), 'AlreadyRevealed');

            let mut hash_input: Array<felt252> = ArrayTrait::new();
            hash_input.append(score.into());
            hash_input.append(salt);
            let computed = poseidon_hash_span(hash_input.span());
            let stored = self.dispute_commit.entry((dispute_id, caller)).read();
            assert(computed == stored, 'HashMismatch');

            self.dispute_score.entry((dispute_id, caller)).write(score);
            self.dispute_revealed.entry((dispute_id, caller)).write(true);
            // NEW: honest path - release this dispute's lock immediately.
            self._release_dispute_lock(dispute_id, caller);

            self.emit(VoteRevealed { dispute_id, juror: caller, score });
        }

        /// See module header, "JUROR STAKE LOCKING". Now also: (a) releases
        /// the juror's lock for this dispute (punished path), and (b) pays
        /// a keeper reward to whoever calls this on someone else, so a
        /// non-reveal doesn't rot unslashed and its lock doesn't stay stuck.
        fn slash_non_revealer(ref self: ContractState, dispute_id: u256, juror: ContractAddress) {
            self.reentrancyguard.start();
            let d = self.disputes.entry(dispute_id).read();
            assert(get_block_timestamp() >= d.reveal_deadline, 'RevealStillOpen');

            let draws = self.dispute_juror_draws.entry((dispute_id, juror)).read();
            assert(draws > 0, 'NotDrawn');
            assert(!self.dispute_revealed.entry((dispute_id, juror)).read(), 'DidReveal');
            assert(!self.dispute_slashed.entry((dispute_id, juror)).read(), 'AlreadySlashed');

            let stake = self.juror_stake.entry(juror).read();
            let bps: u256 = self.non_reveal_slash_bps.read().into();
            let slash_amount = stake * bps / BPS_DENOM;

            if slash_amount > 0 {
                let index = self.juror_index.entry(juror).read();
                self._fenwick_sub(index, slash_amount);
                self.juror_stake.entry(juror).write(stake - slash_amount);

                let mut dm = self.disputes.entry(dispute_id).read();
                dm.slash_pool += slash_amount;
                self.disputes.entry(dispute_id).write(dm);
            }

            self.dispute_slashed.entry((dispute_id, juror)).write(true);
            // NEW: punished path - release this dispute's lock.
            self._release_dispute_lock(dispute_id, juror);

            self.emit(JurorSlashed { dispute_id, juror, amount: slash_amount });

            // NEW: keeper reward, minted through the same capped path as
            // every other mint. No reward for self-slashing.
            let caller = get_caller_address();
            if caller != juror && SLASH_KEEPER_REWARD > 0 {
                self._mint_capped(caller, SLASH_KEEPER_REWARD);
                self
                    .emit(
                        SlashKeeperRewarded {
                            caller, juror, dispute_id, reward: SLASH_KEEPER_REWARD,
                        },
                    );
            }

            self.reentrancyguard.end();
        }

        fn finalize_selection(ref self: ContractState, dispute_id: u256) {
            self.reentrancyguard.start();
            let mut d = self.disputes.entry(dispute_id).read();
            assert(!d.final_score_set, 'AlreadyFinalized');
            assert(get_block_timestamp() >= d.reveal_deadline, 'RevealStillOpen');

            // ---- pass 1: weighted mean over all revealed scores ----
            let mut sum_weighted_scaled: i64 = 0;
            let mut total_weight: u32 = 0;
            let mut i: u32 = 0;
            loop {
                if i >= d.unique_juror_count {
                    break;
                }
                let juror = self.dispute_juror_list.entry((dispute_id, i)).read();
                if self.dispute_revealed.entry((dispute_id, juror)).read() {
                    let weight = self.dispute_juror_draws.entry((dispute_id, juror)).read();
                    let score = self.dispute_score.entry((dispute_id, juror)).read();
                    let score_i64 = self._score_to_i64(score);
                    sum_weighted_scaled += score_i64 * SCALE * weight.into();
                    total_weight += weight;
                }
                i += 1;
            };

            assert(total_weight > 0, 'NoReveals');
            let total_weight_i64: i64 = total_weight.into();
            let mean_scaled: i64 = sum_weighted_scaled / total_weight_i64;

            // ---- pass 2: weighted (population) variance -> stdev ----
            let mut sum_weighted_sq: u64 = 0;
            i = 0;
            loop {
                if i >= d.unique_juror_count {
                    break;
                }
                let juror = self.dispute_juror_list.entry((dispute_id, i)).read();
                if self.dispute_revealed.entry((dispute_id, juror)).read() {
                    let weight = self.dispute_juror_draws.entry((dispute_id, juror)).read();
                    let score = self.dispute_score.entry((dispute_id, juror)).read();
                    let score_i64 = self._score_to_i64(score);
                    let diff = score_i64 * SCALE - mean_scaled;
                    let diff_sq: i64 = diff * diff;
                    let diff_sq_u64: u64 = diff_sq.try_into().unwrap();
                    sum_weighted_sq += diff_sq_u64 * weight.into();
                }
                i += 1;
            };
            let variance_scaled: u64 = sum_weighted_sq / total_weight.into();
            let stdev_scaled_u256: u256 = self._isqrt(variance_scaled.into());
            // No direct TryInto<u256, i64> in corelib - go through u64 first
            // (u256 -> u64 and u64 -> i64 are both implemented; u256 -> i64
            // directly is not), same defensive two-step style used for the
            // manual i8/u256 <-> i64 mappings elsewhere in this file.
            let stdev_scaled_u64: u64 = stdev_scaled_u256.try_into().unwrap();
            let stdev_scaled: i64 = stdev_scaled_u64.try_into().unwrap();

            // ---- pass 3: drop outliers (> 1 stdev from mean), recompute mean ----
            let mut sum_filtered_scaled: i64 = 0;
            let mut filtered_weight: u32 = 0;
            i = 0;
            loop {
                if i >= d.unique_juror_count {
                    break;
                }
                let juror = self.dispute_juror_list.entry((dispute_id, i)).read();
                if self.dispute_revealed.entry((dispute_id, juror)).read() {
                    let weight = self.dispute_juror_draws.entry((dispute_id, juror)).read();
                    let score = self.dispute_score.entry((dispute_id, juror)).read();
                    let score_i64 = self._score_to_i64(score);
                    let diff = score_i64 * SCALE - mean_scaled;
                    let abs_diff = if diff < 0 { -diff } else { diff };
                    if abs_diff <= stdev_scaled {
                        sum_filtered_scaled += score_i64 * SCALE * weight.into();
                        filtered_weight += weight;
                    }
                }
                i += 1;
            };

            let final_mean_scaled: i64 = if filtered_weight > 0 {
                sum_filtered_scaled / filtered_weight.into()
            } else {
                mean_scaled
            };

            let final_score: i64 = self._round_scaled(final_mean_scaled);

            d.final_score = final_score;
            d.final_score_set = true;
            d.total_weight_revealed = total_weight;
            d.phase = PHASE_FINALIZED;

            // ---- coherence pass (for juror rewards, not stakeholder scoring) ----
            let mut total_coherent_weight: u32 = 0;
            i = 0;
            loop {
                if i >= d.unique_juror_count {
                    break;
                }
                let juror = self.dispute_juror_list.entry((dispute_id, i)).read();
                if self.dispute_revealed.entry((dispute_id, juror)).read() {
                    let weight = self.dispute_juror_draws.entry((dispute_id, juror)).read();
                    let score = self.dispute_score.entry((dispute_id, juror)).read();
                    let score_i64 = self._score_to_i64(score);
                    let diff = if score_i64 >= final_score { score_i64 - final_score } else { final_score - score_i64 };
                    if diff <= COHERENCE_BAND {
                        self.dispute_coherent.entry((dispute_id, juror)).write(true);
                        total_coherent_weight += weight;
                    }
                }
                i += 1;
            };
            d.total_coherent_weight = total_coherent_weight;

            // ---- empowerment: mint non-transferable governance tokens ----
            // NOTE: this is the Stage 2 decaying Grant system, NOT this
            // contract's ERC20 - it is not subject to MAX_SUPPLY.
            let mint_amount = self._governance_tokens_for_score(final_score);
            if mint_amount > 0 {
                self._mint_governance_tokens(d.candidate, mint_amount);
                d.governance_tokens_minted = mint_amount;
            }

            // ---- bond settlement (opt-in evaluation) - see module header,
            // "OPT-IN EVALUATION WITH A BOND". `bond_amount` is nonzero
            // only for disputes opened through `request_evaluation`, so
            // this is a no-op both ways for a zero bond. Positive score ->
            // refund the requester in full, in the SAME transaction that
            // mints their Stage 2 governance tokens. Zero-or-negative ->
            // no transfer at all: the bond's tokens are already sitting in
            // this contract (pulled in at request_evaluation time), so
            // "slashing" it is just relabeling it into `slash_pool`,
            // exactly like a non-revealing juror's slashed stake already
            // does for that same pool.
            let bond_amount = d.bond_amount;
            let requester = d.requester;
            let refund_bond = bond_amount > 0 && final_score > 0;
            let slash_bond = bond_amount > 0 && final_score <= 0;
            if slash_bond {
                d.slash_pool += bond_amount;
            }
            d.bond_settled = true;
            if requester.is_non_zero() {
                self.has_active_dispute.entry(requester).write(false);
            }

            self.disputes.entry(dispute_id).write(d);
            self.emit(DisputeFinalized { dispute_id, candidate: d.candidate, final_score });
            if mint_amount > 0 {
                self
                    .emit(
                        GovernanceTokensMinted {
                            dispute_id, candidate: d.candidate, amount: mint_amount, final_score,
                        },
                    );
            }

            if refund_bond {
                let ok = self.erc20.transfer(requester, bond_amount);
                assert(ok, 'TransferFailed');
                self.emit(BondRefunded { dispute_id, requester, amount: bond_amount });
            } else if slash_bond {
                self.emit(BondSlashed { dispute_id, requester, amount: bond_amount });
            }

            self.reentrancyguard.end();
        }

        fn claim_juror_reward(ref self: ContractState, dispute_id: u256) {
            self.reentrancyguard.start();
            let caller = get_caller_address();
            let mut d = self.disputes.entry(dispute_id).read();
            assert(d.final_score_set, 'NotFinalized');
            assert(self.dispute_coherent.entry((dispute_id, caller)).read(), 'NotCoherent');
            assert(!self.dispute_reward_claimed.entry((dispute_id, caller)).read(), 'AlreadyClaimed');
            assert(d.total_coherent_weight > 0, 'NoCoherentWeight');

            let weight = self.dispute_juror_draws.entry((dispute_id, caller)).read();
            let amount = d.slash_pool * weight.into() / d.total_coherent_weight.into();

            self.dispute_reward_claimed.entry((dispute_id, caller)).write(true);

            if amount > 0 {
                // Paid out of the slash pool, which is already this
                // contract's own token (jurors staked and got slashed in
                // it, and non-refunded evaluation bonds are added here too
                // - see "bond settlement" above) - a plain transfer, not a
                // mint, so it never touches MAX_SUPPLY.
                let ok = self.erc20.transfer(caller, amount);
                assert(ok, 'TransferFailed');
            }

            self.emit(JurorRewardClaimed { dispute_id, juror: caller, amount });
            self.reentrancyguard.end();
        }

        // ----------------------------------------------------------
                        // GOVERNANCE TOKEN VIEWS
        // ----------------------------------------------------------

        fn governance_balance(self: @ContractState, holder: ContractAddress) -> u256 {
            self._decayed_total(holder)
        }

        fn governance_available(self: @ContractState, holder: ContractAddress) -> u256 {
            let total = self._decayed_total(holder);
            let locked = self.governance_locked_total.entry(holder).read();
            if locked >= total {
                0
            } else {
                total - locked
            }
        }

        fn governance_locked(self: @ContractState, holder: ContractAddress) -> u256 {
            self.governance_locked_total.entry(holder).read()
        }

        // ----------------------------------------------------------
                      // CONVICTION VOTING / FUND ALLOCATION
        // ----------------------------------------------------------

        fn create_funding_proposal(
            ref self: ContractState,
            funding_wallet: ContractAddress,
            requested_amount: u256,
            evidence: ByteArray,
        ) -> u256 {
            assert(funding_wallet.is_non_zero(), 'ZeroAddress');
            assert(requested_amount > 0, 'ZeroAmount');

            let proposal_id = self.proposal_count.read();
            self.proposal_count.write(proposal_id + 1);

            let p = FundingProposal {
                funding_wallet,
                requested_amount,
                evidence,
                created_at: get_block_timestamp(),
                executed: false,
                supporter_count: 0,
            };
            self.proposals.entry(proposal_id).write(p);

            self.emit(FundingProposalCreated { proposal_id, funding_wallet, requested_amount });
            proposal_id
        }

        fn deposit_funds(ref self: ContractState, amount: u256) {
            self.reentrancyguard.start();
            assert(amount > 0, 'ZeroAmount');
            let caller = get_caller_address();

            // funding_token is still a separate external ERC20 (the
            // treasury payout currency) - unrelated to this contract's own
            // capped token, so it still goes through an external dispatcher.
            let token = IERC20Dispatcher { contract_address: self.funding_token.read() };
            let ok = token.transfer_from(caller, get_contract_address(), amount);
            assert(ok, 'TransferFailed');

            let new_total = self.treasury_balance.read() + amount;
            self.treasury_balance.write(new_total);

            self.emit(TreasuryDeposited { depositor: caller, amount, new_treasury_balance: new_total });
            self.reentrancyguard.end();
        }

        fn create_conviction(ref self: ContractState, amount: u256) -> u32 {
            assert(amount > 0, 'ZeroAmount');
            let caller = get_caller_address();

            let total = self._decayed_total(caller);
            let locked = self.governance_locked_total.entry(caller).read();
            let available = if locked >= total { 0 } else { total - locked };
            assert(amount <= available, 'InsufficientGovBalance');

            self.governance_locked_total.entry(caller).write(locked + amount);

            let id = self.next_conviction_id.entry(caller).read();
            self.next_conviction_id.entry(caller).write(id + 1);

            let c = Conviction {
                owner: caller,
                id,
                amount,
                created_at: get_block_timestamp(),
                is_supporting: false,
                active_proposal: 0,
                support_start: 0,
                released: false,
            };
            self.convictions.entry((caller, id)).write(c);

            self.emit(ConvictionCreated { owner: caller, conviction_id: id, amount });
            id
        }

        fn add_support(ref self: ContractState, proposal_id: u256, conviction_id: u32) {
            let caller = get_caller_address();
            assert(proposal_id < self.proposal_count.read(), 'InvalidProposalId');

            let p = self.proposals.entry(proposal_id).read();
            assert(!p.executed, 'AlreadyExecuted');

            let mut c = self.convictions.entry((caller, conviction_id)).read();
            assert(c.owner == caller, 'Unauthorized');
            assert(!c.released, 'ConvictionReleased');
            assert(!c.is_supporting, 'AlreadySupportingAProposal');

            c.is_supporting = true;
            c.active_proposal = proposal_id;
            c.support_start = get_block_timestamp();
            self.convictions.entry((caller, conviction_id)).write(c);

            let idx = p.supporter_count;
            self.proposal_supporters.entry((proposal_id, idx)).write(Supporter { owner: caller, conviction_id });
            let mut pm = self.proposals.entry(proposal_id).read();
            pm.supporter_count = idx + 1;
            self.proposals.entry(proposal_id).write(pm);

            self.emit(SupportAdded { proposal_id, owner: caller, conviction_id });
        }

        fn remove_support(ref self: ContractState, conviction_id: u32) {
            let caller = get_caller_address();
            let mut c = self.convictions.entry((caller, conviction_id)).read();
            assert(c.owner == caller, 'Unauthorized');
            assert(c.is_supporting, 'NotSupporting');

            let power = self._conviction_power(@c);
            let proposal_id = c.active_proposal;

            c.is_supporting = false;
            c.active_proposal = 0;
            c.support_start = 0;
            self.convictions.entry((caller, conviction_id)).write(c);

            self.emit(SupportRemoved { proposal_id, owner: caller, conviction_id, power_at_removal: power });
        }

        fn release_conviction(ref self: ContractState, conviction_id: u32) {
            let caller = get_caller_address();
            let mut c = self.convictions.entry((caller, conviction_id)).read();
            assert(c.owner == caller, 'Unauthorized');
            assert(!c.is_supporting, 'StillSupporting');
            assert(!c.released, 'AlreadyReleased');

            let amount = c.amount;
            let locked = self.governance_locked_total.entry(caller).read();
            assert(locked >= amount, 'LockAccountingError');
            self.governance_locked_total.entry(caller).write(locked - amount);

            c.released = true;
            self.convictions.entry((caller, conviction_id)).write(c);

            self.emit(ConvictionReleased { owner: caller, conviction_id, amount });
        }

        fn execute_proposal(ref self: ContractState, proposal_id: u256) {
            self.reentrancyguard.start();
            assert(proposal_id < self.proposal_count.read(), 'InvalidProposalId');
            let mut p = self.proposals.entry(proposal_id).read();
            assert(!p.executed, 'AlreadyExecuted');

            let total_power = self._proposal_total_power(proposal_id, p.supporter_count);
            assert(total_power >= self.conviction_threshold.read(), 'ThresholdNotMet');

            let treasury = self.treasury_balance.read();
            assert(treasury >= p.requested_amount, 'InsufficientTreasury');

            self.treasury_balance.write(treasury - p.requested_amount);
            p.executed = true;
            let funding_wallet = p.funding_wallet;
            let amount = p.requested_amount;
            let supporter_count = p.supporter_count; // snapshot before p moves into write() below
            self.proposals.entry(proposal_id).write(p);

            let token = IERC20Dispatcher { contract_address: self.funding_token.read() };
            let ok = token.transfer(funding_wallet, amount);
            assert(ok, 'TransferFailed');

            self.emit(ProposalExecuted { proposal_id, total_power, amount_paid: amount });

            // Pay conviction-voting rewards, pro-rata by power, by minting
            // this contract's own token - see module header, "REWARDING
            // conviction voting". Runs after the treasury payout above so
            // that payout is only ever reverted alongside a reward-mint
            // failure, never blocked from happening in the first place;
            // note Starknet transactions are still atomic, so a capped-mint
            // revert here does roll the whole call back - see CAVEATS.
            let reward_total = self.conviction_reward_amount.read();
            if reward_total > 0 && total_power > 0 {
                self._distribute_conviction_rewards(
                    proposal_id, supporter_count, total_power, reward_total,
                );
            }

            self.reentrancyguard.end();
        }

        fn get_conviction_power(
            self: @ContractState, owner: ContractAddress, conviction_id: u32
        ) -> u256 {
            let c = self.convictions.entry((owner, conviction_id)).read();
            self._conviction_power(@c)
        }

        fn get_proposal_total_power(self: @ContractState, proposal_id: u256) -> u256 {
            let p = self.proposals.entry(proposal_id).read();
            self._proposal_total_power(proposal_id, p.supporter_count)
        }

        fn get_conviction_reward_amount(self: @ContractState) -> u256 {
            self.conviction_reward_amount.read()
        }

        // ----------------------------------------------------------
                        // THIS CONTRACT'S OWN ERC20
        // ----------------------------------------------------------

        fn token_max_supply(self: @ContractState) -> u256 {
            MAX_SUPPLY
        }

        fn token_remaining_mintable(self: @ContractState) -> u256 {
            MAX_SUPPLY - self.erc20.total_supply()
        }

        /// Standard OZ pattern: any holder may burn their own balance.
        /// Burning frees up headroom under MAX_SUPPLY for future
        /// conviction-reward mints, same as the old sibling token's burn.
        fn burn(ref self: ContractState, amount: u256) {
            assert(amount > 0, 'ZeroAmount');
            self.erc20.burn(get_caller_address(), amount);
        }

        // ----------------------------------------------------------
                    // DECAY (this contract's own ERC20 balances)
        // ----------------------------------------------------------
        // Hourly-stepped, linear annual decay applied lazily per address -
        // see `_apply_decay` for the exact formula and its caveats (in
        // particular: the decay clock is per-holder-address, not
        // per-token, so it does not reset on transfer - see module header).

        fn apply_decay(ref self: ContractState, user: ContractAddress) {
            self.reentrancyguard.start();
            assert(!self.is_protected.entry(user).read(), 'ProtectedAddress');
            self._apply_decay(user);
            self.reentrancyguard.end();
        }

        /// Batch version, capped at MAX_BATCH_DECAY (50) addresses per call
        /// as gas-griefing protection. Protected addresses in the list are
        /// silently skipped rather than reverting the whole batch.
        fn batch_apply_decay(ref self: ContractState, users: Array<ContractAddress>) {
            self.reentrancyguard.start();
            assert(users.len() <= MAX_BATCH_DECAY, 'TooManyUsers');
            let mut i: u32 = 0;
            loop {
                if i >= users.len() {
                    break;
                }
                let user = *users.at(i);
                if !self.is_protected.entry(user).read() {
                    self._apply_decay(user);
                }
                i += 1;
            };
            self.reentrancyguard.end();
        }

        fn get_decay_rate_bps(self: @ContractState) -> u16 {
            self.decay_rate_bps.read()
        }

        fn get_min_decay_for_reward(self: @ContractState) -> u256 {
            self.min_decay_for_reward.read()
        }

        fn get_caller_reward_amount(self: @ContractState) -> u256 {
            self.caller_reward_amount.read()
        }

        fn get_last_decay_at(self: @ContractState, user: ContractAddress) -> u64 {
            self.last_decay_at.entry(user).read()
        }

        fn is_protected_address(self: @ContractState, user: ContractAddress) -> bool {
            self.is_protected.entry(user).read()
        }

        // ----------------------------------------------------------
              // JUROR STAKE LOCKING (anti-evasion) VIEWS
        // ----------------------------------------------------------

        fn get_juror_locked_stake(self: @ContractState, juror: ContractAddress) -> u256 {
            self.juror_locked_total.entry(juror).read()
        }

        fn get_juror_unlocked_stake(self: @ContractState, juror: ContractAddress) -> u256 {
            let total = self.juror_stake.entry(juror).read();
            let locked = self.juror_locked_total.entry(juror).read();
            if locked >= total {
                0
            } else {
                total - locked
            }
        }

        fn get_juror_open_dispute_count(self: @ContractState, juror: ContractAddress) -> u32 {
            self.juror_open_lock_count.entry(juror).read()
        }

        // ----------------------------------------------------------
              // OPT-IN EVALUATION BOND VIEWS
        // ----------------------------------------------------------

        fn get_evaluation_bond_amount(self: @ContractState) -> u256 {
            EVALUATION_BOND_AMOUNT
        }

        fn get_active_dispute_for_candidate(self: @ContractState, candidate: ContractAddress) -> u256 {
            self.active_dispute_for_candidate.entry(candidate).read()
        }

        fn get_dispute_evidence(self: @ContractState, dispute_id: u256) -> ByteArray {
            self.dispute_evidence.entry(dispute_id).read()
        }

        // ----------------------------------------------------------
              // ADMIN - every parameter change is timelocked
        // ----------------------------------------------------------
        // Pattern for every parameter below: `propose_set_X` (admin-only)
        // queues `new_value`, stamping `effective_at = now + 3 days` and
        // overwriting any earlier not-yet-executed proposal for that same
        // parameter; `execute_set_X` (admin-only) applies it, reverting
        // with 'TimelockNotElapsed' if called too early or 'NoPendingChange'
        // if nothing is queued. See `_propose_change` / `_execute_change`.
        // Durations, bps figures and addresses are all round-tripped
        // through u256 so one generic engine can serve every parameter.

        fn propose_set_funding_token(ref self: ContractState, token: ContractAddress) {
            assert(token.is_non_zero(), 'ZeroAddress');
            self._propose_change(PARAM_FUNDING_TOKEN, self._address_to_u256(token));
        }

        fn execute_set_funding_token(ref self: ContractState) {
            let value = self._execute_change(PARAM_FUNDING_TOKEN);
            self.funding_token.write(self._u256_to_address(value));
        }

        fn propose_set_conviction_threshold(ref self: ContractState, threshold: u256) {
            self._propose_change(PARAM_CONVICTION_THRESHOLD, threshold);
        }

        fn execute_set_conviction_threshold(ref self: ContractState) {
            let value = self._execute_change(PARAM_CONVICTION_THRESHOLD);
            self.conviction_threshold.write(value);
        }

        fn propose_set_conviction_reward_amount(ref self: ContractState, amount: u256) {
            self._propose_change(PARAM_CONVICTION_REWARD_AMOUNT, amount);
        }

        fn execute_set_conviction_reward_amount(ref self: ContractState) {
            let value = self._execute_change(PARAM_CONVICTION_REWARD_AMOUNT);
            self.conviction_reward_amount.write(value);
        }

        fn propose_set_vrf_provider(ref self: ContractState, new_vrf_provider: ContractAddress) {
            assert(new_vrf_provider.is_non_zero(), 'ZeroAddress');
            self._propose_change(PARAM_VRF_PROVIDER, self._address_to_u256(new_vrf_provider));
        }

        fn execute_set_vrf_provider(ref self: ContractState) {
            let value = self._execute_change(PARAM_VRF_PROVIDER);
            self.vrf_consumer.set_vrf_provider(self._u256_to_address(value));
        }

        fn propose_set_commit_duration(ref self: ContractState, commit_duration: u64) {
            assert(commit_duration > 0, 'InvalidDuration');
            self._propose_change(PARAM_COMMIT_DURATION, commit_duration.into());
        }

        fn execute_set_commit_duration(ref self: ContractState) {
            let value = self._execute_change(PARAM_COMMIT_DURATION);
            let value_u64: u64 = value.try_into().unwrap();
            self.commit_duration.write(value_u64);
        }

        fn propose_set_reveal_duration(ref self: ContractState, reveal_duration: u64) {
            assert(reveal_duration > 0, 'InvalidDuration');
            self._propose_change(PARAM_REVEAL_DURATION, reveal_duration.into());
        }

        fn execute_set_reveal_duration(ref self: ContractState) {
            let value = self._execute_change(PARAM_REVEAL_DURATION);
            let value_u64: u64 = value.try_into().unwrap();
            self.reveal_duration.write(value_u64);
        }

        fn propose_set_non_reveal_slash_bps(ref self: ContractState, bps: u16) {
            assert(bps <= 10_000, 'TooHigh');
            self._propose_change(PARAM_NON_REVEAL_SLASH_BPS, bps.into());
        }

        fn execute_set_non_reveal_slash_bps(ref self: ContractState) {
            let value = self._execute_change(PARAM_NON_REVEAL_SLASH_BPS);
            // No direct TryInto<u256, u16> in corelib - go through u64
            // first, same defensive two-step style used elsewhere in this
            // file (see `finalize_selection`'s stdev cast).
            let value_u64: u64 = value.try_into().unwrap();
            let value_u16: u16 = value_u64.try_into().unwrap();
            self.non_reveal_slash_bps.write(value_u16);
        }

        fn propose_set_decay_rate_bps(ref self: ContractState, bps: u16) {
            assert(bps <= 10_000, 'TooHigh');
            self._propose_change(PARAM_DECAY_RATE_BPS, bps.into());
        }

        fn execute_set_decay_rate_bps(ref self: ContractState) {
            let value = self._execute_change(PARAM_DECAY_RATE_BPS);
            let value_u64: u64 = value.try_into().unwrap();
            let value_u16: u16 = value_u64.try_into().unwrap();
            self.decay_rate_bps.write(value_u16);
        }

        fn propose_set_min_decay_for_reward(ref self: ContractState, amount: u256) {
            self._propose_change(PARAM_MIN_DECAY_FOR_REWARD, amount);
        }

        fn execute_set_min_decay_for_reward(ref self: ContractState) {
            let value = self._execute_change(PARAM_MIN_DECAY_FOR_REWARD);
            self.min_decay_for_reward.write(value);
        }

        fn propose_set_caller_reward_amount(ref self: ContractState, amount: u256) {
            self._propose_change(PARAM_CALLER_REWARD_AMOUNT, amount);
        }

        fn execute_set_caller_reward_amount(ref self: ContractState) {
            let value = self._execute_change(PARAM_CALLER_REWARD_AMOUNT);
            self.caller_reward_amount.write(value);
        }

        /// Enforces the MIN_NUM_DRAWS (10) floor at propose time - see
        /// module header, "ADMIN-CONFIGURED num_draws".
        fn propose_set_num_draws(ref self: ContractState, num_draws: u32) {
            assert(num_draws >= MIN_NUM_DRAWS, 'BelowMinNumDraws');
            self._propose_change(PARAM_NUM_DRAWS, num_draws.into());
        }

        fn execute_set_num_draws(ref self: ContractState) {
            let value = self._execute_change(PARAM_NUM_DRAWS);
            let value_u32: u32 = value.try_into().unwrap();
            self.num_draws.write(value_u32);
        }

        fn get_num_draws(self: @ContractState) -> u32 {
            self.num_draws.read()
        }

        fn propose_set_protected_address(ref self: ContractState, target: ContractAddress, protected: bool) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(target.is_non_zero(), 'ZeroAddress');
            let effective_at = get_block_timestamp() + TIMELOCK_DURATION;
            self
                .pending_protected
                .entry(target)
                .write(PendingProtectedChange { new_value: protected, effective_at, exists: true });
            self.emit(ProtectedAddressProposed { target, new_value: protected, effective_at });
        }

        fn execute_set_protected_address(ref self: ContractState, target: ContractAddress) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let pc = self.pending_protected.entry(target).read();
            assert(pc.exists, 'NoPendingChange');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            self
                .pending_protected
                .entry(target)
                .write(PendingProtectedChange { new_value: false, effective_at: 0, exists: false });
            self.is_protected.entry(target).write(pc.new_value);
            self.emit(ProtectedAddressSet { target, new_value: pc.new_value });
        }

        fn get_pending_change(self: @ContractState, param_key: felt252) -> PendingChange {
            self.pending_changes.entry(param_key).read()
        }

        fn get_pending_protected(self: @ContractState, target: ContractAddress) -> PendingProtectedChange {
            self.pending_protected.entry(target).read()
        }

        // ---- admin roster ----
        // Now timelocked (TIMELOCK_DURATION, 3 days) - see module header,
        // "ADMIN ROSTER IS NOW TIMELOCKED TOO".

        fn propose_add_admin(ref self: ContractState, new_admin: ContractAddress) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(new_admin.is_non_zero(), 'ZeroAddress');
            assert(!self.accesscontrol.has_role(DEFAULT_ADMIN_ROLE, new_admin), 'AlreadyAdmin');
            let effective_at = get_block_timestamp() + TIMELOCK_DURATION;
            self
                .pending_admin_changes
                .entry(new_admin)
                .write(PendingAdminChange { is_add: true, effective_at, exists: true });
            self.emit(AdminAddProposed { new_admin, effective_at });
        }

        fn execute_add_admin(ref self: ContractState, new_admin: ContractAddress) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let pc = self.pending_admin_changes.entry(new_admin).read();
            assert(pc.exists, 'NoPendingChange');
            assert(pc.is_add, 'NotAnAddProposal');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            assert(!self.accesscontrol.has_role(DEFAULT_ADMIN_ROLE, new_admin), 'AlreadyAdmin');
            self
                .pending_admin_changes
                .entry(new_admin)
                .write(PendingAdminChange { is_add: false, effective_at: 0, exists: false });
            self.accesscontrol._grant_role(DEFAULT_ADMIN_ROLE, new_admin);
            self.admin_count.write(self.admin_count.read() + 1);
            self.emit(AdminAdded { admin: new_admin });
        }

        fn propose_remove_admin(ref self: ContractState, admin_to_remove: ContractAddress) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(self.accesscontrol.has_role(DEFAULT_ADMIN_ROLE, admin_to_remove), 'NotAnAdmin');
            let effective_at = get_block_timestamp() + TIMELOCK_DURATION;
            self
                .pending_admin_changes
                .entry(admin_to_remove)
                .write(PendingAdminChange { is_add: false, effective_at, exists: true });
            self.emit(AdminRemoveProposed { admin_to_remove, effective_at });
        }

        /// Revokes DEFAULT_ADMIN_ROLE from `admin_to_remove` once the
        /// timelock has elapsed. Reverts with 'CannotRemoveLastAdmin' if
        /// that would leave the contract with zero admins - use
        /// `propose_add_admin`/`execute_add_admin` to install a successor
        /// first. The last-admin check is re-verified here (not just at
        /// propose time) in case other removals executed in the meantime.
        fn execute_remove_admin(ref self: ContractState, admin_to_remove: ContractAddress) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let pc = self.pending_admin_changes.entry(admin_to_remove).read();
            assert(pc.exists, 'NoPendingChange');
            assert(!pc.is_add, 'NotARemoveProposal');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            assert(self.accesscontrol.has_role(DEFAULT_ADMIN_ROLE, admin_to_remove), 'NotAnAdmin');
            let count = self.admin_count.read();
            assert(count > 1, 'CannotRemoveLastAdmin');
            self
                .pending_admin_changes
                .entry(admin_to_remove)
                .write(PendingAdminChange { is_add: false, effective_at: 0, exists: false });
            self.accesscontrol._revoke_role(DEFAULT_ADMIN_ROLE, admin_to_remove);
            self.admin_count.write(count - 1);
            self.emit(AdminRemoved { admin: admin_to_remove });
        }

        fn get_pending_admin_change(self: @ContractState, target: ContractAddress) -> PendingAdminChange {
            self.pending_admin_changes.entry(target).read()
        }

        fn admin_count(self: @ContractState) -> u32 {
            self.admin_count.read()
        }

        // ----------------------------------------------------------
                          // UPGRADEABILITY
        // ----------------------------------------------------------
        // See module header, "UPGRADEABILITY". propose_upgrade queues a
        // class hash with a 7-day timelock (UPGRADE_TIMELOCK_DURATION,
        // deliberately longer than the 3-day TIMELOCK_DURATION used for
        // ordinary parameters); execute_upgrade applies it via the
        // embedded UpgradeableComponent's internal `upgrade`, which itself
        // wraps Starknet's native `replace_class_syscall`.
        // disable_upgrades_forever is a one-way switch - see its own
        // docstring below.

        fn propose_upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(!self.upgrades_disabled.read(), 'UpgradesDisabledForever');
            let hash_felt: felt252 = new_class_hash.into();
            assert(hash_felt.is_non_zero(), 'ZeroClassHash');
            let effective_at = get_block_timestamp() + UPGRADE_TIMELOCK_DURATION;
            self
                .pending_upgrade
                .write(PendingUpgrade { new_class_hash, effective_at, exists: true });
            self.emit(UpgradeProposed { new_class_hash, effective_at });
        }

        fn execute_upgrade(ref self: ContractState) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(!self.upgrades_disabled.read(), 'UpgradesDisabledForever');
            let pu = self.pending_upgrade.read();
            assert(pu.exists, 'NoPendingUpgrade');
            assert(get_block_timestamp() >= pu.effective_at, 'TimelockNotElapsed');
            self
                .pending_upgrade
                .write(
                    PendingUpgrade {
                        new_class_hash: 0.try_into().unwrap(), effective_at: 0, exists: false,
                    },
                );
            self.upgradeable.upgrade(pu.new_class_hash);
            self.emit(UpgradeExecuted { new_class_hash: pu.new_class_hash });
        }

        /// ONE-WAY: once called, `upgrades_disabled` is permanently `true`.
        /// Both `propose_upgrade` and `execute_upgrade` revert forever
        /// after this, any not-yet-executed pending upgrade is discarded,
        /// and no function in this contract can ever set
        /// `upgrades_disabled` back to `false` - see module header,
        /// "UPGRADEABILITY". Use only once governance is confident the
        /// deployed code is final.
        fn disable_upgrades_forever(ref self: ContractState) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(!self.upgrades_disabled.read(), 'AlreadyDisabled');
            self
                .pending_upgrade
                .write(
                    PendingUpgrade {
                        new_class_hash: 0.try_into().unwrap(), effective_at: 0, exists: false,
                    },
                );
            self.upgrades_disabled.write(true);
            self.emit(UpgradesDisabledForever { by: get_caller_address() });
        }

        fn is_upgrades_disabled(self: @ContractState) -> bool {
            self.upgrades_disabled.read()
        }

        fn get_pending_upgrade(self: @ContractState) -> PendingUpgrade {
            self.pending_upgrade.read()
        }

        // ----------------------------------------------------------
                                // VIEWS
        // ----------------------------------------------------------

        fn get_dispute(self: @ContractState, dispute_id: u256) -> Dispute {
            self.disputes.entry(dispute_id).read()
        }

        fn get_proposal(self: @ContractState, proposal_id: u256) -> FundingProposal {
            self.proposals.entry(proposal_id).read()
        }

        fn get_conviction(self: @ContractState, owner: ContractAddress, id: u32) -> Conviction {
            self.convictions.entry((owner, id)).read()
        }

        fn get_juror_stake(self: @ContractState, juror: ContractAddress) -> u256 {
            self.juror_stake.entry(juror).read()
        }

        fn total_stake_weight(self: @ContractState) -> u256 {
            self._fenwick_total()
        }
    }

    // //////////////////////////////////////////////////////////////
                          // INTERNAL HELPERS
    // //////////////////////////////////////////////////////////////

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        // ---- this contract's own capped ERC20 mint - the ONLY path that
        // can ever increase total_supply(). Called from exactly three
        // places in this whole file: the constructor,
        // _distribute_conviction_rewards, and the slash-keeper reward
        // inside slash_non_revealer. There is no other mint function,
        // public or admin-gated, anywhere in this contract. ----

        fn _mint_capped(ref self: ContractState, to: ContractAddress, amount: u256) {
            assert(amount > 0, 'ZeroAmount');
            let current_supply = self.erc20.total_supply();
            assert(current_supply + amount <= MAX_SUPPLY, 'SupplyCapExceeded');
            self.erc20.mint(to, amount);
        }

        // ---- juror slot registry ----

        fn _get_or_create_index(ref self: ContractState, juror: ContractAddress) -> u32 {
            let existing = self.juror_index.entry(juror).read();
            if existing != 0 {
                return existing;
            }
            let next = self.next_index.read() + 1;
            assert(next <= self.tree_size.read(), 'CapacityExceeded');
            self.next_index.write(next);
            self.juror_index.entry(juror).write(next);
            self.index_juror.entry(next).write(juror);
            next
        }

        // ---- Fenwick (Binary Indexed) tree over stake weight ----
        // Identical mechanism to the reference KlerosSchelling contract.

        fn _lowbit(self: @ContractState, i: u32) -> u32 {
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

        fn _fenwick_add(ref self: ContractState, index: u32, amount: u256) {
            let size = self.tree_size.read();
            let mut i = index;
            loop {
                if i > size {
                    break;
                }
                let cur = self.fenwick_tree.entry(i).read();
                self.fenwick_tree.entry(i).write(cur + amount);
                i += self._lowbit(i);
            };
        }

        fn _fenwick_sub(ref self: ContractState, index: u32, amount: u256) {
            let size = self.tree_size.read();
            let mut i = index;
            loop {
                if i > size {
                    break;
                }
                let cur = self.fenwick_tree.entry(i).read();
                assert(cur >= amount, 'FenwickUnderflow');
                self.fenwick_tree.entry(i).write(cur - amount);
                i += self._lowbit(i);
            };
        }

        fn _fenwick_prefix_sum(self: @ContractState, index: u32) -> u256 {
            let mut sum: u256 = 0;
            let mut i = index;
            loop {
                if i == 0 {
                    break;
                }
                sum += self.fenwick_tree.entry(i).read();
                i -= self._lowbit(i);
            };
            sum
        }

        fn _fenwick_total(self: @ContractState) -> u256 {
            self._fenwick_prefix_sum(self.tree_size.read())
        }

        fn _fenwick_find(self: @ContractState, target: u256) -> u32 {
            let size = self.tree_size.read();
            let mut log_size: u32 = 1;
            loop {
                if log_size * 2 > size {
                    break;
                }
                log_size = log_size * 2;
            };

            let mut pos: u32 = 0;
            let mut remaining = target;
            let mut step = log_size;
            loop {
                if step == 0 {
                    break;
                }
                let next = pos + step;
                if next <= size {
                    let val = self.fenwick_tree.entry(next).read();
                    if val <= remaining {
                        pos = next;
                        remaining -= val;
                    }
                }
                step = step / 2;
            };
            pos + 1
        }

        // ---- randomness (Cartridge VRF) ----

        fn _derive_draw_random(
            self: @ContractState, base_seed: felt252, dispute_id: u256, draw_index: u32
        ) -> felt252 {
            let mut input: Array<felt252> = ArrayTrait::new();
            input.append(base_seed);
            let dispute_id_felt: felt252 = dispute_id.try_into().unwrap();
            input.append(dispute_id_felt);
            let draw_index_felt: felt252 = draw_index.into();
            input.append(draw_index_felt);
            poseidon_hash_span(input.span())
        }

        // ---- score helpers ----

        fn _score_to_i64(self: @ContractState, v: i8) -> i64 {
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

        fn _round_scaled(self: @ContractState, scaled: i64) -> i64 {
            let half = SCALE / 2;
            if scaled >= 0 {
                (scaled + half) / SCALE
            } else {
                (scaled - half) / SCALE
            }
        }

        /// Empowerment schedule: +1..+5 -> 100..500 tokens, everything else -> 0.
        fn _governance_tokens_for_score(self: @ContractState, final_score: i64) -> u256 {
            if final_score == 1 {
                100
            } else if final_score == 2 {
                200
            } else if final_score == 3 {
                300
            } else if final_score == 4 {
                400
            } else if final_score == 5 {
                500
            } else {
                0
            }
        }

        // ---- non-transferable governance token accounting ----
        // (Stage 2 - completely separate from the embedded ERC20 above.)

        fn _mint_governance_tokens(ref self: ContractState, holder: ContractAddress, amount: u256) {
            let id = self.governance_next_grant.entry(holder).read();
            self.governance_next_grant.entry(holder).write(id + 1);
            self
                .governance_grant
                .entry((holder, id))
                .write(Grant { amount, minted_at: get_block_timestamp() });
        }

        /// Linear decay to zero over `HOURS_PER_YEAR` hours, stepped hourly:
        /// `decayed = amount - amount * hours_elapsed / HOURS_PER_YEAR`,
        /// floored at zero once `hours_elapsed >= HOURS_PER_YEAR`.
        fn _decayed_grant_amount(self: @ContractState, grant: @Grant) -> u256 {
            let now = get_block_timestamp();
            if now <= *grant.minted_at {
                return *grant.amount;
            }
            let elapsed_seconds = now - *grant.minted_at;
            let hours_elapsed: u64 = elapsed_seconds / SECONDS_PER_HOUR;
            if hours_elapsed >= HOURS_PER_YEAR {
                return 0;
            }
            let amount = *grant.amount;
            amount - (amount * hours_elapsed.into() / HOURS_PER_YEAR.into())
        }

        /// Sum of decayed amounts across every grant `holder` has ever
        /// received - see module CAVEATS re: unbounded iteration.
        fn _decayed_total(self: @ContractState, holder: ContractAddress) -> u256 {
            let count = self.governance_next_grant.entry(holder).read();
            let mut total: u256 = 0;
            let mut i: u32 = 0;
            loop {
                if i >= count {
                    break;
                }
                let g = self.governance_grant.entry((holder, i)).read();
                total += self._decayed_grant_amount(@g);
                i += 1;
            };
            total
        }

        // ---- conviction voting math ----

        /// voting_power = floor( sqrt( locked_amount * seconds_supported ) ),
        /// or 0 if the conviction is not currently supporting anything.
        fn _conviction_power(self: @ContractState, c: @Conviction) -> u256 {
            if !*c.is_supporting {
                return 0;
            }
            let now = get_block_timestamp();
            if now <= *c.support_start {
                return 0;
            }
            let elapsed: u256 = (now - *c.support_start).into();
            let product: u256 = *c.amount * elapsed;
            self._isqrt(product)
        }

        fn _proposal_total_power(self: @ContractState, proposal_id: u256, supporter_count: u32) -> u256 {
            let mut total: u256 = 0;
            let mut i: u32 = 0;
            loop {
                if i >= supporter_count {
                    break;
                }
                let s = self.proposal_supporters.entry((proposal_id, i)).read();
                let c = self.convictions.entry((s.owner, s.conviction_id)).read();
                if c.is_supporting && c.active_proposal == proposal_id {
                    total += self._conviction_power(@c);
                }
                i += 1;
            };
            total
        }

        /// Splits `reward_total` of this contract's own token pro-rata by
        /// power among every conviction actively supporting `proposal_id`
        /// at the moment this runs, minting directly to each supporter's
        /// owner address via `_mint_capped`. `total_power` must be the same
        /// value `_proposal_total_power` would return right now (the caller
        /// in `execute_proposal` computed it immediately before this call,
        /// inside the same transaction, so no conviction's support could
        /// have changed in between).
        ///
        /// No cross-contract MINTER_ROLE grant is needed anymore - this is
        /// just an internal call within the same contract. If a share
        /// would push total supply over MAX_SUPPLY, `_mint_capped` reverts
        /// the whole `execute_proposal` transaction (the treasury payout
        /// above is rolled back too) - keep `conviction_reward_amount`
        /// sized with the cap in mind, see module CAVEATS.
        fn _distribute_conviction_rewards(
            ref self: ContractState,
            proposal_id: u256,
            supporter_count: u32,
            total_power: u256,
            reward_total: u256,
        ) {
            let mut i: u32 = 0;
            loop {
                if i >= supporter_count {
                    break;
                }
                let s = self.proposal_supporters.entry((proposal_id, i)).read();
                let c = self.convictions.entry((s.owner, s.conviction_id)).read();
                if c.is_supporting && c.active_proposal == proposal_id {
                    let power = self._conviction_power(@c);
                    if power > 0 {
                        let share = reward_total * power / total_power;
                        if share > 0 {
                            self._mint_capped(s.owner, share);
                            self
                                .emit(
                                    ConvictionRewardDistributed {
                                        proposal_id,
                                        recipient: s.owner,
                                        conviction_id: s.conviction_id,
                                        power,
                                        amount: share,
                                    },
                                );
                        }
                    }
                }
                i += 1;
            };
        }

        // ---- ERC20 balance decay ----
        //
        // Design: each holder has a `last_decay_at` checkpoint. Calling
        // `apply_decay`/`batch_apply_decay` measures whole hours elapsed
        // since that checkpoint and burns
        //   balance * decay_rate_bps/10000 * hours_elapsed/HOURS_PER_YEAR
        // (linear, same style as the Stage 2 grant decay above), capped at
        // the holder's current balance, then advances the checkpoint by
        // exactly `hours_elapsed` hours (not to `now`) so any leftover
        // sub-hour seconds aren't lost between calls.
        //
        // CAVEAT: the checkpoint is per-address, not per-token, and this
        // contract has no ERC20 transfer hooks wired up (ERC20HooksEmptyImpl
        // above), so a transfer neither resets nor pro-rates the
        // recipient's clock. An address that receives a large transfer
        // right before a long-overdue `apply_decay` call will have that
        // incoming balance decay too, as if it had been sitting there the
        // whole time. A production deployment that wants decay to track
        // per-acquisition time would need real transfer hooks (which
        // changes the economics: a recipient who keeps receiving funds
        // would never decay on them) - left as-is here because that's a
        // product decision, not a bug, and is easy to get wrong silently.
        //
        // CAVEAT: the very first `apply_decay`/`batch_apply_decay` call for
        // a given address only sets its checkpoint - it burns nothing,
        // since there is no prior checkpoint to measure elapsed time from.
        // Decay for that address starts accruing from that call onward.
        // (Mirrors the "not swept until touched" nature of the Stage 2
        // grant decay above, just applied to a live checkpoint instead of
        // a read-time computation.)

        fn _apply_decay(ref self: ContractState, user: ContractAddress) {
            let caller = get_caller_address();
            let now = get_block_timestamp();
            let last = self.last_decay_at.entry(user).read();

            if last == 0 {
                self.last_decay_at.entry(user).write(now);
                return;
            }
            if now <= last {
                return;
            }

            let elapsed_seconds = now - last;
            let hours_elapsed: u64 = elapsed_seconds / SECONDS_PER_HOUR;
            if hours_elapsed == 0 {
                return;
            }

            // Advance the checkpoint by whole hours consumed regardless of
            // balance, so leftover sub-hour seconds carry forward correctly
            // even when there's nothing to burn this call.
            self.last_decay_at.entry(user).write(last + hours_elapsed * SECONDS_PER_HOUR);

            let balance = self.erc20.balance_of(user);
            if balance == 0 {
                return;
            }

            let rate_bps: u256 = self.decay_rate_bps.read().into();
            let numerator: u256 = balance * rate_bps * hours_elapsed.into();
            let denominator: u256 = DECAY_BPS_DENOM * HOURS_PER_YEAR.into();
            let mut burn_amount: u256 = numerator / denominator;
            if burn_amount > balance {
                burn_amount = balance;
            }

            if burn_amount > 0 {
                self.erc20.burn(user, burn_amount);
                self.emit(DecayApplied { user, amount: burn_amount, caller });
            }

            // Reward the caller for triggering a meaningful decay on
            // someone else's balance. Self-farming is blocked by requiring
            // caller != user; spam-farming across many small accounts is
            // blocked by the per-caller cooldown.
            if caller != user && burn_amount >= self.min_decay_for_reward.read() {
                let last_reward = self.last_caller_reward_at.entry(caller).read();
                if now >= last_reward + CALLER_REWARD_COOLDOWN {
                    self.last_caller_reward_at.entry(caller).write(now);
                    let reward = self.caller_reward_amount.read();
                    if reward > 0 {
                        self._mint_capped(caller, reward);
                        self.emit(DecayCallerRewarded { caller, user, reward });
                    }
                }
            }
        }

        // ---- juror stake locking (anti-evasion) ----
        // See module header, "JUROR STAKE LOCKING".

        /// Releases a juror's lock for one dispute, exactly once, from
        /// whichever path fires first (honest reveal or punished slash).
        /// No-ops if already released, so callers (reveal_vote and
        /// slash_non_revealer) don't need to coordinate which path runs
        /// first - they're mutually exclusive by the existing
        /// dispute_revealed / dispute_slashed asserts anyway, but the flag
        /// makes this helper itself safe to call from either without extra
        /// bookkeeping at the call sites.
        fn _release_dispute_lock(ref self: ContractState, dispute_id: u256, juror: ContractAddress) {
            if self.dispute_juror_lock_released.entry((dispute_id, juror)).read() {
                return;
            }
            let snapshot = self.dispute_juror_locked_snapshot.entry((dispute_id, juror)).read();
            let total = self.juror_locked_total.entry(juror).read();
            // snapshot <= total always holds here: it was added exactly
            // once (in request_evaluation, on first draw for this
            // dispute) and this is the only release path, guarded by the
            // flag above.
            self.juror_locked_total.entry(juror).write(total - snapshot);

            let open = self.juror_open_lock_count.entry(juror).read();
            if open > 0 {
                self.juror_open_lock_count.entry(juror).write(open - 1);
            }

            self.dispute_juror_lock_released.entry((dispute_id, juror)).write(true);
        }

        // ---- generic 3-day timelock engine for scalar/address admin
        // params - see module header, "ADMIN TIMELOCK" ----

        fn _propose_change(ref self: ContractState, param_key: felt252, new_value: u256) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let effective_at = get_block_timestamp() + TIMELOCK_DURATION;
            self
                .pending_changes
                .entry(param_key)
                .write(PendingChange { new_value, effective_at, exists: true });
            self.emit(ChangeProposed { param_key, new_value, effective_at });
        }

        fn _execute_change(ref self: ContractState, param_key: felt252) -> u256 {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let pc = self.pending_changes.entry(param_key).read();
            assert(pc.exists, 'NoPendingChange');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            self
                .pending_changes
                .entry(param_key)
                .write(PendingChange { new_value: 0, effective_at: 0, exists: false });
            self.emit(ChangeExecuted { param_key, new_value: pc.new_value });
            pc.new_value
        }

        /// Widening cast (always safe): a ContractAddress always fits in a
        /// felt252, which always fits in a u256.
        fn _address_to_u256(self: @ContractState, addr: ContractAddress) -> u256 {
            let addr_felt: felt252 = addr.into();
            addr_felt.into()
        }

        /// Narrowing cast: panics if `value` doesn't fit in a felt252 (it
        /// always will in practice here, since it only ever comes from a
        /// prior `_address_to_u256` round-trip) or isn't a valid address.
        fn _u256_to_address(self: @ContractState, value: u256) -> ContractAddress {
            let value_felt: felt252 = value.try_into().unwrap();
            value_felt.try_into().unwrap()
        }

        /// Floor integer square root of a u256, via the standard
        /// digit-by-digit binary method (no reliance on a generic `Sqrt`
        /// trait impl for u256 - see module CAVEATS).
        fn _isqrt(self: @ContractState, x: u256) -> u256 {
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
    }
}
