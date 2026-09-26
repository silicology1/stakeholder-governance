// SPDX-License-Identifier: MIT
//! StakeholderConvictionGovernance
//! ================================
//! ONE Starknet/Cairo contract, ONE token: this contract embeds
//! OpenZeppelin's `ERC20Component` directly, so it *is* the transferable
//! token - there is no separate address to deploy, no `MINTER_ROLE` to
//! grant post-deploy, and no external mint entrypoint at all. The only
//! places that can ever increase total supply are:
//!   1. the constructor's one-time `INITIAL_SUPPLY` mint, and
//!   2. score-based reward minting in `execute_proposal`.
//!   3. the slash-keeper reward in `slash_non_revealer`.
//! The constructor's initial mint uses `_mint_capped`, while operational
//! reward mints use `_mint_from_budget`, which checks both the monthly budget
//! and `MAX_SUPPLY` headroom and is best-effort.
//!
//!   STAGE 1 - SELECTION (Kleros-style Schelling game)
//!   ---------------------------------------------------
//!   A candidate puts themselves up for evaluation via `request_evaluation`
//!   (opt-in, bonded - see "OPT-IN EVALUATION WITH A BOND" below).
//!   Jurors stake this contract's own token (Fenwick-tree weighted
//!   sortition) and are drawn with replacement via Cartridge VRF. Each
//!   drawn juror commits, then reveals, a score in [-5, +5] for the
//!   candidate. On `finalize_selection` the contract computes a
//!   stake-weighted mean, drops outliers more than one (population) stdev
//!   away, and recomputes the mean over the remainder - the trimmed-mean
//!   routine. A positive final score mints non-transferable governance
//!   tokens to the candidate.
//!
//!   STAGE 2 - EMPOWERMENT (non-transferable, decaying governance tokens)
//!   ---------------------------------------------------------------------
//!   The instant a dispute finalizes with a positive final score, the
//!   candidate is minted non-transferable ("soulbound") governance tokens.
//!   A score of zero or negative mints nothing. These tokens are completely
//!   separate from the ERC20 embedded in this same contract - not minted
//!   through `_mint_capped`, not subject to MAX_SUPPLY, and cannot be
//!   transferred. A holder's balance is the sum of all their grants, each
//!   decaying linearly, in discrete hourly steps, from its minted amount
//!   down to zero over exactly 8_760 hours (365 days).
//!
//!   STAGE 3 - SCORE VOTING (proposal scoring via governance tokens)
//!   ----------------------------------------------------------------
//!   An empowered stakeholder creates a conviction: locks some of their
//!   *currently available* (decayed, unlocked) governance-token balance
//!   with a chosen level (1-10). The level fixes the lock window
//!   (`lock_duration = level * conviction_base_lock`) during which the
//!   stake is frozen. While the conviction is live (`now < created_at +
//!   lock_duration`) it may vote on up to `max_votes_per_conviction`
//!   distinct proposals, each time casting a score in [-5, +5]. Voting
//!   power for a vote is STATIC (frozen at vote time):
//!       weight = isqrt(level * locked_amount)
//!   so a conviction's power never grows or decays with lock time and
//!   cannot be re-arbitraged after the votes are cast.
//!   Votes are PERMANENT (commitments): there is no `remove_support`, and a
//!   conviction can never change or retract an already-cast vote. A proposal's
//!   total power (`power_total`) is a frozen accumulator bumped at vote time,
//!   so the weighted final score cannot be manipulated after the fact and
//!   `execute_proposal` is O(1) regardless of how many backers voted. Once its
//!   lock window has elapsed, a conviction can be `release_conviction`d to
//!   free the locked stake for a new conviction without touching old votes.
//!   Multiple supporters accumulate weighted scores in a histogram.
//!   Once the admin-set `conviction_threshold` of total voting power is
//!   cleared, anyone can call `execute_proposal` which:
//!     - Computes the weighted final score from the histogram
//!     - If final_score >= 0: refunds the proposal deposit and, when
//!       score > 0, mints a score-based reward to the funding_wallet
//!     - If final_score < 0: slashes the proposal deposit
//!
//!   ANTI-SYBIL: PROPOSAL DEPOSIT
//!   --------------------------------
//!   Creating a proposal requires depositing `reputation_stake` of this
//!   contract's own ERC20 (must `approve` first). This filters out spam.
//!   The deposit is refunded on zero or positive final score, slashed to
//!   the slash_pool on negative.
//!
//!   MONTHLY INFLATION + BURN RECYCLING BUDGET
//!   ---------------------------------------------
//!   All ERC20 reward mints (proposal score rewards, slash-keeper reward,
//!   decay-caller reward) are capped by a per-month budget:
//!       budget_month[N] = inflation_part + recycle_part
//!     - inflation_part = total_supply() * inflation_rate_bps / (10000 * 12),
//!       i.e. at most 5%/12 of current supply per fixed 30-day month
//!       (MONTH_SECONDS). It is 0 once supply reaches MAX_SUPPLY.
//!     - recycle_part   = total ERC20 tokens actually burned during the
//!       previous month (decay burns + explicit `burn` calls).
//!   A month's unutilized budget is burned (written off) at rollover; it is
//!   NOT recycled. Reward mints are BEST-EFFORT: a reward that exceeds the
//!   remaining budget (or the MAX_SUPPLY headroom) is skipped rather than
//!   reverted, so the underlying operation (execution, slash, decay) always
//!   succeeds. Whether a reward was paid is observable: `BudgetRewardMinted`
//!   and the reward-specific event are emitted only on an actual mint.
//!
//!   SUPPLY: fixed cap, one-time initial mint
//!   -------------------------------------------
//!     - `MAX_SUPPLY`     = 50,000,000 tokens (18 decimals).
//!     - `INITIAL_SUPPLY` = 10,000,000 tokens (18 decimals), minted in
//!       the constructor.
//!   Reward mints go through `_mint_from_budget`, which enforces the monthly
//!   budget and `MAX_SUPPLY` headroom before minting directly through ERC20.
//!
//!   ADMIN TIMELOCK
//!   ----------------
//!   Every admin parameter (bond amount, reputation stake, conviction
//!   threshold, reward multipliers, decay rates, etc.) uses a two-step
//!   `propose_*` / `execute_*` pair with a 3-day timelock
//!   (`TIMELOCK_DURATION = 259_200` seconds). Class-hash upgrades use a
//!   separate 7-day timelock (`UPGRADE_TIMELOCK_DURATION = 604_800`), as does
//!   the two-step `propose_disable_upgrades` / `execute_disable_upgrades`
//!   permanent cut of the upgrade path (a single compromised key cannot brick
//!   the recovery path instantly).
//!
//! JUROR STAKE LOCKING (anti-evasion)
//! ----------------------------------
//! * Every juror has `juror_locked_total`, the SUM of stake-at-draw-time
//!   snapshots across every dispute they are currently drawn into and have
//!   not yet resolved. `unstake` asserts
//!   `current_stake - withdraw_amount >= juror_locked_total`.
//! * `MAX_CONCURRENT_JUROR_LOCKS` (15) caps how many simultaneously-open
//!   dispute locks a juror can carry; past that, they are skipped in the
//!   draw via deterministic redraw.
//!
//! OPT-IN EVALUATION WITH A BOND
//! ------------------------------
//! * `request_evaluation` requires locking `evaluation_bond_amount`
//!   (admin-timelocked, default 50 tokens) of this contract's own token.
//!   Refunded on score zero or positive (`final_score >= 0`), otherwise
//!   added to `slash_pool`.
//! * One open request at a time per candidate.
//!
//! SCORE VOTING POWER
//! -------------------
//! * weight = isqrt(level (1-10) * governance_tokens_locked), STATIC: fixed
//!   at vote time and frozen on the live proposal histogram + `power_total`,
//!   so it never drifts with elapsed lock time.
//! * A conviction is votable only while `now < created_at + lock_duration`
//!   (`LockExpired`), where `lock_duration = level * conviction_base_lock`.
//! * A live conviction may vote on up to `max_votes_per_conviction` distinct
//!   proposals (never the same proposal twice) before `release_conviction`.
//! * Multiple convictions per holder are allowed (each with own level).
//! * No per-proposal supporter registry: `FundingProposal.power_total` is the
//!   frozen accumulator at vote time, so voting is unbounded and
//!   `execute_proposal` is O(1).
//!
//! REWARD MINTING
//! ---------------
//! * `reward_multiplier` (for scores 4-5) and `mini_reward_multiplier`
//!   (for scores 1-3) are admin-timelocked.
//! * reward = final_score * multiplier, minted to funding_wallet on
//!   positive final score, subject to the monthly inflation budget
//!   (see "MONTHLY INFLATION + BURN RECYCLING BUDGET" above). Best-effort:
//!   the proposal always executes and refunds the author's deposit; only the
//!   payout is skipped when the budget/supply cap has no room.
//!
//! CODE ORGANIZATION
//! -----------------
//! This file keeps everything that must touch the contract's generated
//! `ContractState` (storage, `#[event]` enum, constructor, and both impls).
//! Declarations that need no plugin context live in sibling modules:
//!   - `constants.cairo`  : all consts + timelocked-parameter keys
//!   - `types/`           : storage structs (dispute, governance, admin)
//!   - `events.cairo`     : event payload structs
//!   - `utils/`           : pure, storage-free helpers (math, fenwick, random)

mod constants;
mod events;
mod types;
pub mod utils;

#[starknet::interface]
pub trait IStakeholderConviction<TContractState> {
    // ---- juror staking (Kleros side) ----

    /// Adds `amount` of the contract's ERC20 to the caller's juror stake.
    /// The caller must approve this contract before invoking the method.
    ///
    /// The amount is added to the Fenwick selection tree and `Staked` is emitted.
    /// Reverts for a zero amount, a failed transfer, or exhausted tree capacity.
    fn stake(ref self: TContractState, amount: u256);

    /// Withdraws `amount` from the caller's currently unlocked juror stake.
    /// Stake locked by open disputes cannot be withdrawn.
    ///
    /// The amount is removed from the Fenwick tree, transferred back to the
    /// caller, and reported through `Unstaked`. Reverts when the caller's
    /// total or unlocked stake is insufficient or no index is registered.
    fn unstake(ref self: TContractState, amount: u256);

    // ---- stakeholder selection (Kleros dispute lifecycle) ----

    /// Opens a bonded selection dispute for the caller and returns its ID.
    /// Evidence must be non-empty and no longer than `MAX_EVIDENCE_LEN`.
    /// The caller must approve the current evaluation bond; a verified VRF
    /// random value must be supplied in the same multicall before this call.
    /// The draw seed is the Poseidon hash of that VRF value and a recent
    /// on-chain block hash read directly by the contract.
    ///
    /// The contract records the dispute, draws weighted jurors with replacement,
    /// snapshots their stakes into dispute locks, and emits `DisputeCreated`,
    /// `EvaluationRequested`, and one `JurorDrawn` event per draw. Reverts for
    /// an active dispute, invalid evidence, failed bond transfer, no staked
    /// weight, or exhausted redraw attempts..
    fn request_evaluation(ref self: TContractState, evidence: ByteArray) -> u256;

    /// Stores a drawer's Poseidon commitment for a dispute vote.
    /// The caller must be a drawn juror, the dispute must be in its commit
    /// phase, and the commit deadline must not have passed. A juror may commit
    /// only once. `VoteCommitted` is emitted on success.
    fn commit_vote(ref self: TContractState, dispute_id: u256, commit_hash: felt252);

    /// Reveals a score in the inclusive range -5 through 5 for a committed vote.
    /// The commitment must equal the Poseidon hash of `(score, salt)`, the
    /// commit phase must have ended, and the reveal deadline must not have
    /// passed. The caller's dispute stake lock is released exactly once.
    fn reveal_vote(ref self: TContractState, dispute_id: u256, score: i8, salt: felt252);

    /// Reports a drawn juror who failed to reveal and applies the configured slash.
    /// Anyone may call this after the reveal deadline. The reported juror must
    /// not have revealed or been slashed already. A non-reporter may receive
    /// the best-effort slash-keeper reward when the monthly budget permits.
    fn slash_non_revealer(
        ref self: TContractState, dispute_id: u256, juror: starknet::ContractAddress,
    );

    /// Finalizes a dispute after its reveal deadline and stores its trimmed score.
    /// The routine computes a stake-weighted mean, removes votes more than one
    /// population standard deviation away, recomputes the mean, mints
    /// governance tokens for positive scores, and settles the evaluation bond.
    /// A dispute with no reveals settles at score zero and refunds its bond.
    fn finalize_selection(ref self: TContractState, dispute_id: u256);

    /// Claims the caller's proportional share of a dispute's coherent-juror
    /// slash pool. The dispute must be finalized, the caller coherent, and the
    /// reward not previously claimed. The reward is transferred from escrow.
    fn claim_juror_reward(ref self: TContractState, dispute_id: u256);

    // ---- non-transferable governance tokens (Stage 2, decaying) ----

    /// Returns the caller's current decayed governance-token balance.
    /// The result is calculated from all bounded grant slots and includes
    /// tokens currently locked in convictions until their grants decay.
    fn governance_balance(self: @TContractState, holder: starknet::ContractAddress) -> u256;

    /// Returns the holder's decayed governance tokens not locked in convictions.
    fn governance_available(self: @TContractState, holder: starknet::ContractAddress) -> u256;

    /// Returns the holder's governance-token amount currently locked by convictions.
    fn governance_locked(self: @TContractState, holder: starknet::ContractAddress) -> u256;

    // ---- score voting / proposal lifecycle ----

    /// Creates a funding proposal and escrows the current reputation deposit.
    /// The caller must approve the contract for the deposit. Evidence must be
    /// non-empty and bounded. Returns the new proposal ID and emits
    /// `ProposalCreated`.
    fn create_proposal(
        ref self: TContractState,
        funding_wallet: starknet::ContractAddress,
        evidence: ByteArray,
    ) -> u256;

    /// Locks available governance tokens in a new level-1-through-10 conviction.
    /// The lock duration is `level * conviction_base_lock` and may not exceed
    /// `MAX_LOCK_DURATION`. Returns the per-owner conviction ID and emits
    /// `ConvictionCreated`.
    fn create_conviction(ref self: TContractState, level: u8, amount: u256) -> u32;

    /// Permanently records one score vote from a live conviction on a proposal.
    /// The conviction must belong to the caller, remain inside its lock window,
    /// have not voted on this proposal before, and remain below the configured
    /// distinct-vote limit. The static weight is added to the score histogram
    /// and the proposal's O(1) `power_total` accumulator.
    fn vote_with_conviction(
        ref self: TContractState, proposal_id: u256, conviction_id: u32, score: i8,
    );

    /// Releases a conviction's governance stake after its lock window ends.
    /// Votes already cast remain permanent and continue contributing their
    /// frozen weight. A conviction cannot be released twice.
    fn release_conviction(ref self: TContractState, conviction_id: u32);

    /// Executes a proposal once its frozen voting power reaches the threshold.
    /// Non-negative scores refund the author's deposit and may mint a
    /// best-effort score reward; negative scores slash the deposit. The
    /// operation always reaches settlement even when reward budget or supply
    /// headroom is insufficient.
    fn execute_proposal(ref self: TContractState, proposal_id: u256);

    /// Returns the static vote weight of a conviction after its first vote.
    /// A conviction with no recorded votes reports zero power.
    fn get_conviction_power(
        self: @TContractState, owner: starknet::ContractAddress, conviction_id: u32,
    ) -> u256;

    /// Returns a proposal's frozen accumulated voting power in O(1).
    fn get_proposal_total_power(self: @TContractState, proposal_id: u256) -> u256;

    // ---- this contract's own ERC20 ----

    /// Returns the protocol's hard ERC20 supply cap.
    fn token_max_supply(self: @TContractState) -> u256;

    /// Returns the amount that can still be minted under the supply cap.
    fn token_remaining_mintable(self: @TContractState) -> u256;

    /// Burns `amount` of the caller's ERC20 and records it for next-month recycling.
    /// Reverts for a zero amount or insufficient caller balance.
    fn burn(ref self: TContractState, amount: u256);

    // ---- monthly inflation / burn-recycling budget ----

    /// Returns the currently stored month index; rollover is lazy and may lag
    /// wall-clock time until a state-changing operation calls the month engine.
    fn get_current_month(self: @TContractState) -> u64;

    /// Returns the stored timestamp at which the current month began.
    fn get_month_start(self: @TContractState) -> u64;

    /// Returns the total budget recorded for a month.
    fn get_month_budget(self: @TContractState, month: u64) -> u256;

    /// Returns the amount of a month's budget already consumed by rewards.
    fn get_month_budget_minted(self: @TContractState, month: u64) -> u256;

    /// Returns the ERC20 burn amount recorded for a month.
    fn get_month_burned(self: @TContractState, month: u64) -> u256;

    /// Returns the currently stored month's unconsumed budget without forcing
    /// month rollover.
    fn get_remaining_month_budget(self: @TContractState) -> u256;

    /// Returns the configured monthly inflation rate in basis points.
    fn get_inflation_rate_bps(self: @TContractState) -> u16;

    // ---- ERC20 balance decay ----

    /// Applies elapsed-time decay to one unprotected ERC20 balance.
    /// Decay is recorded in whole hours, burns at most the configured rate,
    /// and may reward a different caller when the minimum threshold and
    /// cooldown are satisfied. Reverts for a protected address.
    fn apply_decay(ref self: TContractState, user: starknet::ContractAddress);

    /// Applies decay to at most `MAX_BATCH_DECAY` addresses in array order.
    /// Addresses marked in the timelocked protection map are skipped; the
    /// contract's own escrow address is intrinsically rejected by the internal
    /// decay path. All other addresses are processed under one reentrancy guard.
    fn batch_apply_decay(ref self: TContractState, users: Array<starknet::ContractAddress>);

    /// Returns the configured hourly decay rate in basis points.
    fn get_decay_rate_bps(self: @TContractState) -> u16;

    /// Returns the minimum burned amount required for a caller reward.
    fn get_min_decay_for_reward(self: @TContractState) -> u256;

    /// Returns the configured decay caller reward amount.
    fn get_caller_reward_amount(self: @TContractState) -> u256;

    /// Returns the timestamp at which an address was last decay-accounted.
    fn get_last_decay_at(self: @TContractState, user: starknet::ContractAddress) -> u64;

    /// Reports the configured protection flag for an address. The contract's
    /// own escrow address is also intrinsically protected by the decay helper,
    /// even when this separately stored flag is false.
    fn is_protected_address(self: @TContractState, user: starknet::ContractAddress) -> bool;

    // ---- juror stake-locking views ----

    /// Returns the sum of juror stake snapshots locked by open disputes.
    fn get_juror_locked_stake(
        self: @TContractState, juror: starknet::ContractAddress,
    ) -> u256;

    /// Returns the portion of a juror's stake not locked by open disputes.
    fn get_juror_unlocked_stake(
        self: @TContractState, juror: starknet::ContractAddress,
    ) -> u256;

    /// Returns the number of open disputes currently locking a juror.
    fn get_juror_open_dispute_count(
        self: @TContractState, juror: starknet::ContractAddress,
    ) -> u32;

    // ---- opt-in evaluation bond views ----

    /// Returns the current evaluation bond required to request a dispute.
    fn get_evaluation_bond_amount(self: @TContractState) -> u256;

    /// Returns the stored active-dispute ID for a candidate. Because dispute
    /// IDs start at zero, a returned zero is ambiguous: it can mean no active
    /// dispute or the first dispute ID.
    fn get_active_dispute_for_candidate(
        self: @TContractState, candidate: starknet::ContractAddress,
    ) -> u256;

    /// Returns the evidence bytes stored for a dispute.
    fn get_dispute_evidence(self: @TContractState, dispute_id: u256) -> ByteArray;

    // ---- admin: timelocked parameter changes ----

    /// Proposes a new evaluation bond. Only the default admin may call it; the
    /// amount must be positive and no greater than `MAX_SUPPLY`. The change
    /// becomes executable after `TIMELOCK_DURATION`.
    fn propose_set_evaluation_bond_amount(ref self: TContractState, amount: u256);

    /// Executes the pending evaluation-bond change after its timelock.
    fn execute_set_evaluation_bond_amount(ref self: TContractState);

    /// Proposes a new proposal reputation deposit, subject to the same admin
    /// authorization, positive-value check, supply cap, and three-day timelock.
    fn propose_set_reputation_stake(ref self: TContractState, amount: u256);

    /// Executes the pending reputation-deposit change after its timelock.
    fn execute_set_reputation_stake(ref self: TContractState);

    /// Proposes the minimum proposal voting power required for execution.
    /// The threshold must be positive and no greater than `MAX_SUPPLY`.
    fn propose_set_conviction_threshold(ref self: TContractState, threshold: u256);

    /// Executes the pending conviction-threshold change after its timelock.
    fn execute_set_conviction_threshold(ref self: TContractState);

    /// Proposes the reward multiplier for final scores 4 through 5.
    fn propose_set_reward_multiplier(ref self: TContractState, amount: u256);

    /// Executes the pending score-4-to-5 reward multiplier after its timelock.
    fn execute_set_reward_multiplier(ref self: TContractState);

    /// Proposes the reward multiplier for final scores 1 through 3.
    fn propose_set_mini_reward_multiplier(ref self: TContractState, amount: u256);

    /// Executes the pending score-1-to-3 reward multiplier after its timelock.
    fn execute_set_mini_reward_multiplier(ref self: TContractState);

    /// Proposes a non-zero Cartridge VRF provider address.
    /// The address is encoded as a felt value and becomes active after the
    /// ordinary administrative timelock.
    fn propose_set_vrf_provider(
        ref self: TContractState, new_vrf_provider: starknet::ContractAddress,
    );

    /// Executes the pending VRF provider change after its timelock.
    fn execute_set_vrf_provider(ref self: TContractState);

    /// Proposes a positive commitment-phase duration in seconds.
    fn propose_set_commit_duration(ref self: TContractState, commit_duration: u64);

    /// Executes the pending commitment-duration change after its timelock.
    fn execute_set_commit_duration(ref self: TContractState);

    /// Proposes a positive reveal-phase duration in seconds.
    fn propose_set_reveal_duration(ref self: TContractState, reveal_duration: u64);

    /// Executes the pending reveal-duration change after its timelock.
    fn execute_set_reveal_duration(ref self: TContractState);

    /// Proposes the non-reveal slash rate in basis points, from zero through
    /// 10,000 (one hundred percent).
    fn propose_set_non_reveal_slash_bps(ref self: TContractState, bps: u16);

    /// Executes the pending non-reveal slash-rate change after its timelock.
    fn execute_set_non_reveal_slash_bps(ref self: TContractState);

    /// Proposes the ERC20 decay rate in basis points, from zero through 10,000.
    fn propose_set_decay_rate_bps(ref self: TContractState, bps: u16);

    /// Executes the pending ERC20 decay-rate change after its timelock.
    fn execute_set_decay_rate_bps(ref self: TContractState);

    /// Proposes the minimum decay amount for a caller reward, capped at
    /// `MAX_SUPPLY`; zero disables the effective minimum.
    fn propose_set_min_decay_for_reward(ref self: TContractState, amount: u256);

    /// Executes the pending minimum-decay threshold after its timelock.
    fn execute_set_min_decay_for_reward(ref self: TContractState);

    /// Proposes the decay caller reward amount, capped at `MAX_SUPPLY`; zero
    /// disables the reward mint.
    fn propose_set_caller_reward_amount(ref self: TContractState, amount: u256);

    /// Executes the pending decay caller reward after its timelock.
    fn execute_set_caller_reward_amount(ref self: TContractState);

    /// Proposes the juror draw count between `MIN_NUM_DRAWS` and
    /// `MAX_NUM_DRAWS`, using the ordinary administrative timelock.
    fn propose_set_num_draws(ref self: TContractState, num_draws: u32);

    /// Executes the pending juror draw-count change after its timelock.
    fn execute_set_num_draws(ref self: TContractState);

    /// Returns the current configured juror draw count.
    fn get_num_draws(self: @TContractState) -> u32;

    /// Proposes the per-level conviction base lock in seconds. The value must
    /// be positive and no greater than `MAX_LOCK_DURATION`.
    fn propose_set_conviction_base_lock(ref self: TContractState, lock_duration: u64);

    /// Executes the pending conviction base-lock change after its timelock.
    fn execute_set_conviction_base_lock(ref self: TContractState);

    /// Returns the current per-level conviction base lock in seconds.
    fn get_conviction_base_lock(self: @TContractState) -> u64;

    /// Proposes the maximum number of distinct proposals one conviction may
    /// vote on. The value must be positive and no greater than
    /// `MAX_MAX_VOTES_PER_CONVICTION`.
    fn propose_set_max_votes_per_conviction(ref self: TContractState, max_votes: u64);

    /// Executes the pending per-conviction vote-limit change after its timelock.
    fn execute_set_max_votes_per_conviction(ref self: TContractState);

    /// Returns the current distinct-proposal vote limit per conviction.
    fn get_max_votes_per_conviction(self: @TContractState) -> u64;

    /// Proposes the monthly inflation rate in basis points, up to
    /// `MAX_INFLATION_BPS`.
    fn propose_set_inflation_rate_bps(ref self: TContractState, bps: u16);

    /// Executes the pending monthly inflation-rate change after its timelock.
    fn execute_set_inflation_rate_bps(ref self: TContractState);

    /// Proposes a timelocked protected-address flag change. Only the default
    /// admin may call it, the target must be non-zero, and the change becomes
    /// executable after `TIMELOCK_DURATION`.
    fn propose_set_protected_address(
        ref self: TContractState,
        target: starknet::ContractAddress,
        protected: bool,
    );

    /// Executes a pending protected-address change after its timelock.
    fn execute_set_protected_address(
        ref self: TContractState, target: starknet::ContractAddress,
    );

    /// Returns the pending ordinary parameter-change record for `param_key`.
    fn get_pending_change(
        self: @TContractState, param_key: felt252,
    ) -> StakeholderConviction::PendingChange;

    /// Returns the pending protected-address change record for `target`.
    fn get_pending_protected(
        self: @TContractState, target: starknet::ContractAddress,
    ) -> StakeholderConviction::PendingProtectedChange;

    // ---- admin roster (timelocked) ----

    /// Proposes adding a non-zero address to the admin roster. The current
    /// default admin must authorize the proposal, and it becomes executable
    /// after `TIMELOCK_DURATION`.
    fn propose_add_admin(ref self: TContractState, new_admin: starknet::ContractAddress);

    /// Executes a pending admin addition after its timelock. The address must
    /// still not be an admin when execution occurs.
    fn execute_add_admin(ref self: TContractState, new_admin: starknet::ContractAddress);

    /// Proposes removing an existing admin from the roster after the ordinary
    /// administrative timelock.
    fn propose_remove_admin(
        ref self: TContractState, admin_to_remove: starknet::ContractAddress,
    );

    /// Executes a pending admin removal after its timelock. The last remaining
    /// admin cannot be removed.
    fn execute_remove_admin(
        ref self: TContractState, admin_to_remove: starknet::ContractAddress,
    );

    /// Returns the pending admin-roster change for an address.
    fn get_pending_admin_change(
        self: @TContractState, target: starknet::ContractAddress,
    ) -> StakeholderConviction::PendingAdminChange;

    /// Returns the number of addresses in the admin roster.
    fn admin_count(self: @TContractState) -> u32;

    // ---- upgradeability ----

    /// Proposes a non-zero class-hash upgrade. Only the default admin may
    /// propose it, upgrades must not already be disabled, and execution waits
    /// for `UPGRADE_TIMELOCK_DURATION`.
    fn propose_upgrade(ref self: TContractState, new_class_hash: starknet::ClassHash);

    /// Executes a pending class-hash upgrade after its seven-day timelock.
    fn execute_upgrade(ref self: TContractState);

    /// Proposes permanently disabling all future upgrades. The irreversible
    /// change waits for `UPGRADE_TIMELOCK_DURATION` and can have only one
    /// pending proposal at a time.
    fn propose_disable_upgrades(ref self: TContractState);

    /// Executes the pending permanent upgrade-disabling change after its
    /// seven-day timelock and clears any pending class-hash upgrade.
    fn execute_disable_upgrades(ref self: TContractState);

    /// Reports whether the upgrade path has been permanently disabled.
    fn is_upgrades_disabled(self: @TContractState) -> bool;

    /// Returns the pending class-hash upgrade record.
    fn get_pending_upgrade(
        self: @TContractState,
    ) -> StakeholderConviction::PendingUpgrade;

    /// Returns the pending permanent-upgrade-disabling record.
    fn get_pending_upgrade_disable(
        self: @TContractState,
    ) -> StakeholderConviction::PendingChange;

    // ---- views ----

    /// Returns the stored selection-dispute record for `dispute_id`.
    fn get_dispute(self: @TContractState, dispute_id: u256) -> StakeholderConviction::Dispute;

    /// Returns the stored funding-proposal record for `proposal_id`.
    fn get_proposal(
        self: @TContractState, proposal_id: u256,
    ) -> StakeholderConviction::FundingProposal;

    /// Returns a conviction record by owner and per-owner ID.
    fn get_conviction(
        self: @TContractState, owner: starknet::ContractAddress, id: u32,
    ) -> StakeholderConviction::Conviction;

    /// Returns a juror's total transferable-token stake.
    fn get_juror_stake(self: @TContractState, juror: starknet::ContractAddress) -> u256;

    /// Returns the total weighted stake represented in the Fenwick tree.
    fn total_stake_weight(self: @TContractState) -> u256;
}

#[starknet::contract]
pub mod StakeholderConviction {
    use core::array::ArrayTrait;
    use core::num::traits::Zero;
    use core::poseidon::poseidon_hash_span;
    use starknet::{
        ContractAddress, ClassHash, get_caller_address, get_block_timestamp, get_block_number,
        get_contract_address,
    };
    use starknet::syscalls::get_block_hash_syscall;
    use starknet::storage::{
        Map, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess,
    };

    use openzeppelin_token::erc20::{ERC20Component, ERC20HooksEmptyImpl, DefaultConfig};
    use openzeppelin_access::accesscontrol::AccessControlComponent;
    use openzeppelin_access::accesscontrol::DEFAULT_ADMIN_ROLE;
    use openzeppelin_introspection::src5::SRC5Component;
    use openzeppelin_security::reentrancyguard::ReentrancyGuardComponent;
    use openzeppelin_upgrades::upgradeable::UpgradeableComponent;

    use cartridge_vrf::Source;
    use cartridge_vrf::vrf_consumer::vrf_consumer_component::VrfConsumerComponent;

    // ---- crate-local modules (constants, storage types, events, pure helpers) ----
    use crate::constants::*;
    use crate::utils::{
        derive_draw_random, governance_tokens_for_score, isqrt, lowbit, round_scaled, score_to_i64,
        score_to_u256,
    };
    // Types must be re-exported (not just imported) because the crate-root
    // interface trait references them as `StakeholderConviction::PendingChange`.
    pub use crate::types::*;
    use crate::events::*;

    component!(path: ERC20Component, storage: erc20, event: ERC20Event);
    component!(path: AccessControlComponent, storage: accesscontrol, event: AccessControlEvent);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);
    component!(
        path: ReentrancyGuardComponent, storage: reentrancyguard, event: ReentrancyGuardEvent
    );
    component!(path: VrfConsumerComponent, storage: vrf_consumer, event: VrfConsumerEvent);
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);

    #[abi(embed_v0)]
    impl ERC20Impl = ERC20Component::ERC20Impl<ContractState>;
    #[abi(embed_v0)]
    impl ERC20MetadataImpl = ERC20Component::ERC20MetadataImpl<ContractState>;
    impl ERC20InternalImpl = ERC20Component::InternalImpl<ContractState>;

    // NOTE: AccessControlMixinImpl is intentionally NOT `#[abi(embed_v0)]`.
    // Embedding it would expose unrestricted external grant_role / revoke_role /
    // renounce_role entrypoints that bypass the timelocked admin roster and the
    // last-admin guard. The impl is kept (unembedded) so that internal code can
    // still call `self.accesscontrol.has_role(...)` via trait method resolution.
    impl AccessControlMixinImpl =
        AccessControlComponent::AccessControlMixinImpl<ContractState>;
    impl AccessControlInternalImpl = AccessControlComponent::InternalImpl<ContractState>;
    impl SRC5InternalImpl = SRC5Component::InternalImpl<ContractState>;
    #[abi(embed_v0)]
    impl SRC5Impl = SRC5Component::SRC5Impl<ContractState>;
    impl ReentrancyGuardInternalImpl = ReentrancyGuardComponent::InternalImpl<ContractState>;

    #[abi(embed_v0)]
    impl VrfConsumerImpl = VrfConsumerComponent::VrfConsumerImpl<ContractState>;
    impl VrfConsumerInternalImpl = VrfConsumerComponent::InternalImpl<ContractState>;

    impl UpgradeableInternalImpl = UpgradeableComponent::InternalImpl<ContractState>;

    // //////////////////////////////////////////////////////////////
                              // STORAGE
    // //////////////////////////////////////////////////////////////

    #[storage]
    struct Storage {
        /// ERC20 balances, allowances, supply, and token metadata.
        #[substorage(v0)]
        erc20: ERC20Component::Storage,
        /// Internal role membership used by the timelocked admin paths.
        #[substorage(v0)]
        accesscontrol: AccessControlComponent::Storage,
        /// SRC5 interface-support state.
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        /// Reentrancy lock state for state-changing contract operations.
        #[substorage(v0)]
        reentrancyguard: ReentrancyGuardComponent::Storage,
        /// Cartridge VRF provider and pending randomness state.
        #[substorage(v0)]
        vrf_consumer: VrfConsumerComponent::Storage,
        /// Upgradeable contract implementation state.
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,

        /// Pending class-hash upgrade and its execution timestamp.
        pending_upgrade: PendingUpgrade,
        /// Pending irreversible upgrade-disabling change.
        pending_upgrade_disable: PendingChange,
        /// Whether the class-hash upgrade path has been permanently disabled.
        upgrades_disabled: bool,

        /// Duration of the juror commitment phase in seconds.
        commit_duration: u64,
        /// Duration of the juror reveal phase in seconds.
        reveal_duration: u64,
        /// Fraction of a non-revealing juror's stake to slash, in basis points.
        non_reveal_slash_bps: u16,

        // ---- timelocked admin parameters ----

        /// ERC20 bond required to request candidate evaluation.
        evaluation_bond_amount: u256,
        /// ERC20 reputation deposit required to create a proposal.
        reputation_stake: u256,
        /// Minimum frozen proposal power required for execution.
        conviction_threshold: u256,
        /// Multiplier for positive final scores 4 through 5.
        reward_multiplier: u256,
        /// Multiplier for positive final scores 1 through 3.
        mini_reward_multiplier: u256,
        /// Number of weighted draws requested per evaluation dispute.
        num_draws: u32,

        // ---- staking / Fenwick tree ----

        /// Maximum number of juror slots in the selection tree.
        tree_size: u32,
        /// Highest juror slot allocated so far.
        next_index: u32,
        /// Reverse mapping from juror address to Fenwick slot.
        juror_index: Map<ContractAddress, u32>,
        /// Forward mapping from Fenwick slot to juror address.
        index_juror: Map<u32, ContractAddress>,
        /// Fenwick tree cells containing weighted juror stake.
        fenwick_tree: Map<u32, u256>,
        /// Total transferable-token stake registered for each juror.
        juror_stake: Map<ContractAddress, u256>,

        // ---- juror stake locking ----

        /// Sum of stake snapshots currently locked by a juror's open disputes.
        juror_locked_total: Map<ContractAddress, u256>,
        /// Number of open disputes contributing to a juror's lock.
        juror_open_lock_count: Map<ContractAddress, u32>,
        /// Stake snapshot captured when a juror is first drawn into a dispute.
        dispute_juror_locked_snapshot: Map<(u256, ContractAddress), u256>,
        /// Whether a dispute-specific juror lock has already been released.
        dispute_juror_lock_released: Map<(u256, ContractAddress), bool>,

        // ---- selection disputes ----

        /// Number of evaluation disputes ever created.
        dispute_count: u256,
        /// Durable lifecycle state indexed by dispute ID.
        disputes: Map<u256, Dispute>,
        /// Number of times each juror was drawn into a dispute.
        dispute_juror_draws: Map<(u256, ContractAddress), u32>,
        /// Deduplicated juror list used by finalization loops.
        dispute_juror_list: Map<(u256, u32), ContractAddress>,
        /// Poseidon commitment stored for each dispute juror.
        dispute_commit: Map<(u256, ContractAddress), felt252>,
        /// Whether each dispute juror has committed a vote.
        dispute_committed: Map<(u256, ContractAddress), bool>,
        /// Whether each dispute juror has revealed a vote.
        dispute_revealed: Map<(u256, ContractAddress), bool>,
        /// Revealed score for each dispute juror.
        dispute_score: Map<(u256, ContractAddress), i8>,
        /// Whether each revealed juror is coherent with the final score.
        dispute_coherent: Map<(u256, ContractAddress), bool>,
        /// Whether each non-revealing juror has been slashed.
        dispute_slashed: Map<(u256, ContractAddress), bool>,
        /// Whether each coherent juror has claimed the slash-pool reward.
        dispute_reward_claimed: Map<(u256, ContractAddress), bool>,

        // ---- opt-in evaluation bond ----

        /// Candidate-supplied evidence for each dispute.
        dispute_evidence: Map<u256, ByteArray>,
        /// Whether a candidate currently has an unresolved evaluation dispute.
        has_active_dispute: Map<ContractAddress, bool>,
        /// Stored active-dispute ID for each candidate.
        active_dispute_for_candidate: Map<ContractAddress, u256>,

        // ---- non-transferable governance tokens ----

        /// Number of grant slots allocated for each holder.
        governance_next_grant: Map<ContractAddress, u32>,
        /// Grant records indexed by holder and bounded slot number.
        governance_grant: Map<(ContractAddress, u32), Grant>,
        /// Sum of governance tokens locked by live convictions.
        governance_locked_total: Map<ContractAddress, u256>,

        // ---- score voting / convictions ----

        /// Next per-owner conviction identifier.
        next_conviction_id: Map<ContractAddress, u32>,
        /// Conviction records indexed by owner and identifier.
        convictions: Map<(ContractAddress, u32), Conviction>,
        /// Permanent one-vote marker for owner, conviction, and proposal.
        conviction_voted_on: Map<(ContractAddress, u32, u256), bool>,
        /// Current per-level conviction lock duration in seconds.
        conviction_base_lock: u64,
        /// Current maximum distinct proposals per conviction.
        max_votes_per_conviction: u64,

        // ---- proposals ----

        /// Number of funding proposals ever created.
        proposal_count: u256,
        /// Funding proposal records indexed by proposal ID.
        proposals: Map<u256, FundingProposal>,
        /// Weighted score histogram indexed by proposal and score bucket.
        proposal_score_counts: Map<(u256, u8), u256>,

        // ---- ERC20 balance decay ----

        /// Hourly ERC20 balance-decay rate in basis points.
        decay_rate_bps: u16,
        /// Minimum decay amount eligible for a caller reward.
        min_decay_for_reward: u256,
        /// Reward amount for a qualifying external decay caller.
        caller_reward_amount: u256,
        /// Last timestamp at which each user's balance was decay-accounted.
        last_decay_at: Map<ContractAddress, u64>,
        /// Last timestamp at which each caller earned a decay reward.
        last_caller_reward_at: Map<ContractAddress, u64>,
        /// Addresses excluded from single-address decay.
        is_protected: Map<ContractAddress, bool>,

        // ---- timelock engine ----

        /// Pending ordinary parameter changes keyed by parameter felt.
        pending_changes: Map<felt252, PendingChange>,
        /// Pending protected-address changes keyed by target address.
        pending_protected: Map<ContractAddress, PendingProtectedChange>,

        // ---- admin roster ----

        /// Pending admin additions/removals keyed by target address.
        pending_admin_changes: Map<ContractAddress, PendingAdminChange>,
        /// Current number of default admins.
        admin_count: u32,

        // ---- monthly inflation / burn-recycling budget ----

        /// Monthly inflation rate in basis points.
        inflation_rate_bps: u16,
        /// Timestamp at which the currently stored month began.
        month_start: u64,
        /// Index of the currently stored budget month.
        month_index: u64,
        /// Total budget allocated to each month.
        month_budget: Map<u64, u256>,
        /// Budget consumed by rewards in each month.
        month_minted: Map<u64, u256>,
        /// ERC20 burns recorded for recycling into each month's successor.
        month_burned: Map<u64, u256>,
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
        ProposalCreated: ProposalCreated,
        ProposalExecuted: ProposalExecuted,
        ScoreRewardReleased: ScoreRewardReleased,
        ProposalDepositRefunded: ProposalDepositRefunded,
        ProposalDepositSlashed: ProposalDepositSlashed,
        DecayApplied: DecayApplied,
        DecayCallerRewarded: DecayCallerRewarded,
        MonthlyBudgetSet: MonthlyBudgetSet,
        MonthlyBudgetBurned: MonthlyBudgetBurned,
        BudgetRewardMinted: BudgetRewardMinted,
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
        UpgradeDisableProposed: UpgradeDisableProposed,
        UpgradesDisabledForever: UpgradesDisabledForever,
    }

    // //////////////////////////////////////////////////////////////
                            // CONSTRUCTOR
    // //////////////////////////////////////////////////////////////

    /// Initializes the token, access-control, VRF, staking, admin, and budget state.
    ///
    /// The constructor validates all non-zero address and amount inputs, grants
    /// the initial default-admin role to `admin`, initializes the Fenwick tree
    /// capacity, writes protocol defaults, mints `INITIAL_SUPPLY` once to
    /// `initial_recipient`, and creates month zero's inflation-only budget.
    /// Construction reverts for zero addresses, zero economic parameters, or a
    /// zero tree capacity.
    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin: ContractAddress,
        name: ByteArray,
        symbol: ByteArray,
        initial_recipient: ContractAddress,
        tree_capacity: u32,
        vrf_provider: ContractAddress,
        evaluation_bond_amount: u256,
        reputation_stake: u256,
        conviction_threshold: u256,
        reward_multiplier: u256,
        mini_reward_multiplier: u256,
    ) {
        assert(admin.is_non_zero(), 'ZeroAddress');
        assert(initial_recipient.is_non_zero(), 'ZeroAddress');
        assert(tree_capacity > 0, 'InvalidCapacity');
        assert(vrf_provider.is_non_zero(), 'ZeroAddress');
        assert(evaluation_bond_amount > 0, 'ZeroAmount');
        assert(reputation_stake > 0, 'ZeroAmount');
        assert(conviction_threshold > 0, 'ZeroAmount');
        assert(reward_multiplier > 0, 'ZeroAmount');
        assert(mini_reward_multiplier > 0, 'ZeroAmount');

        self.erc20.initializer(name, symbol);
        self.accesscontrol.initializer();
        self.accesscontrol._grant_role(DEFAULT_ADMIN_ROLE, admin);
        self.vrf_consumer.initializer(vrf_provider);

        self.tree_size.write(tree_capacity);
        self.next_index.write(0);
        self.commit_duration.write(DEFAULT_COMMIT_DURATION);
        self.reveal_duration.write(DEFAULT_REVEAL_DURATION);
        self.non_reveal_slash_bps.write(DEFAULT_SLASH_BPS);
        self.num_draws.write(DEFAULT_NUM_DRAWS);
        self.conviction_base_lock.write(DEFAULT_CONVICTION_BASE_LOCK);
        self.max_votes_per_conviction.write(DEFAULT_MAX_VOTES_PER_CONVICTION);

        // Timelocked admin parameters
        self.evaluation_bond_amount.write(evaluation_bond_amount);
        self.reputation_stake.write(reputation_stake);
        self.conviction_threshold.write(conviction_threshold);
        self.reward_multiplier.write(reward_multiplier);
        self.mini_reward_multiplier.write(mini_reward_multiplier);

        self.upgrades_disabled.write(false);

        // Decay defaults
        self.decay_rate_bps.write(DEFAULT_DECAY_RATE_BPS);
        self.min_decay_for_reward.write(DEFAULT_MIN_DECAY_FOR_REWARD);
        self.caller_reward_amount.write(DEFAULT_CALLER_REWARD_AMOUNT);

        self.admin_count.write(1);

        // Monthly inflation / burn-recycling budget defaults
        self.inflation_rate_bps.write(DEFAULT_INFLATION_RATE_BPS);
        self.month_start.write(get_block_timestamp());
        self.month_index.write(0);

        // One-time initial mint
        self._mint_capped(initial_recipient, INITIAL_SUPPLY);

        // Month-0 budget = inflation share only (no prior-month burns yet).
        let month0_budget = self._compute_month_budget(0);
        self.month_budget.entry(0).write(month0_budget);
        self
            .emit(
                MonthlyBudgetSet {
                    month: 0, budget: month0_budget, inflation_part: month0_budget, recycle_part: 0,
                },
            );
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

            let ok = self.erc20.transfer_from(caller, get_contract_address(), amount);
            assert(ok, 'TransferFailed');

            let index = self._get_or_create_index(caller);
            self._fenwick_add(index, amount);

            let new_total = self.juror_stake.entry(caller).read() + amount;
            self.juror_stake.entry(caller).write(new_total);

            self.emit(Staked { juror: caller, amount, new_total });
            self.reentrancyguard.end();
        }

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

            self.erc20._transfer(get_contract_address(), caller, amount);

            self.emit(Unstaked { juror: caller, amount, new_total });
            self.reentrancyguard.end();
        }

        // ----------------------------------------------------------
                    // STAKEHOLDER SELECTION (Kleros dispute)
        // ----------------------------------------------------------

        fn request_evaluation(ref self: ContractState, evidence: ByteArray) -> u256 {
            self.reentrancyguard.start();
            assert(evidence.len() > 0, 'EvidenceRequired');
            assert(evidence.len() <= MAX_EVIDENCE_LEN, 'EvidenceTooLong');

            let candidate = get_caller_address();
            assert(!self.has_active_dispute.entry(candidate).read(), 'AlreadyUnderEvaluation');

            let bond_amount = self.evaluation_bond_amount.read();
            let ok = self.erc20.transfer_from(candidate, get_contract_address(), bond_amount);
            assert(ok, 'TransferFailed');

            let num_draws = self.num_draws.read();
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

            let vrf_seed: felt252 = self
                .vrf_consumer
                .consume_random(Source::Nonce(get_contract_address()));
            let block_hash = self._recent_block_hash();

            let mut seed_input: Array<felt252> = ArrayTrait::new();
            seed_input.append(vrf_seed);
            seed_input.append(block_hash);
            let base_seed: felt252 = poseidon_hash_span(seed_input.span());

            let mut unique_juror_count: u32 = 0;
            let mut i: u32 = 0;
            loop {
                if i >= num_draws {
                    break;
                }

                let mut rand_felt = derive_draw_random(base_seed, dispute_id, i);
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
                        .read()
                        > 0;
                    let open_locks = self.juror_open_lock_count.entry(candidate_juror).read();

                    if already_drawn_here || open_locks < MAX_CONCURRENT_JUROR_LOCKS {
                        break candidate_juror;
                    }

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
                    self
                        .dispute_juror_list
                        .entry((dispute_id, unique_juror_count))
                        .write(juror);
                    unique_juror_count += 1;

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

                self
                    .emit(
                        JurorDrawn { dispute_id, juror, total_draws_for_juror: prior_draws + 1 },
                    );
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
            self.reentrancyguard.start();
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
            self.reentrancyguard.end();
        }

        fn reveal_vote(ref self: ContractState, dispute_id: u256, score: i8, salt: felt252) {
            self.reentrancyguard.start();
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
            self._release_dispute_lock(dispute_id, caller);

            self.emit(VoteRevealed { dispute_id, juror: caller, score });
            self.reentrancyguard.end();
        }

        fn slash_non_revealer(
            ref self: ContractState, dispute_id: u256, juror: ContractAddress,
        ) {
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
            self._release_dispute_lock(dispute_id, juror);

            self.emit(JurorSlashed { dispute_id, juror, amount: slash_amount });

            let caller = get_caller_address();
            if caller != juror
                && SLASH_KEEPER_REWARD > 0
                && self._mint_from_budget(caller, SLASH_KEEPER_REWARD) {
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

            // pass 1: weighted mean
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
                    let score_i64 = score_to_i64(score);
                    sum_weighted_scaled += score_i64 * SCALE * weight.into();
                    total_weight += weight;
                }
                i += 1;
            };

            if total_weight == 0 {
                // Zero reveals: no juror participated, so there is no signal to
                // grade. Settle the dispute as score-neutral (final score 0),
                // refund the evaluation bond, and clear the active-dispute flags
                // so the candidate is not permanently locked out.
                d.final_score = 0;
                d.final_score_set = true;
                d.total_weight_revealed = 0;
                d.total_coherent_weight = 0;
                d.phase = PHASE_FINALIZED;
                d.bond_settled = true;

                let requester = d.requester;
                let bond_to_refund = d.bond_amount;
                self.disputes.entry(dispute_id).write(d);

                if requester.is_non_zero() {
                    self.has_active_dispute.entry(requester).write(false);
                    self.active_dispute_for_candidate.entry(requester).write(0);
                }
                if bond_to_refund > 0 {
                    self.erc20._transfer(get_contract_address(), requester, bond_to_refund);
                    self.emit(BondRefunded { dispute_id, requester, amount: bond_to_refund });
                }

                self.emit(DisputeFinalized { dispute_id, candidate: d.candidate, final_score: 0 });
                self.reentrancyguard.end();
                return;
            }

            let total_weight_i64: i64 = total_weight.into();
            let mean_scaled: i64 = sum_weighted_scaled / total_weight_i64;

            // pass 2: stdev
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
                    let score_i64 = score_to_i64(score);
                    let diff = score_i64 * SCALE - mean_scaled;
                    let diff_sq: i64 = diff * diff;
                    let diff_sq_u64: u64 = diff_sq.try_into().unwrap();
                    sum_weighted_sq += diff_sq_u64 * weight.into();
                }
                i += 1;
            };
            let variance_scaled: u64 = sum_weighted_sq / total_weight.into();
            let stdev_scaled_u256: u256 = isqrt(variance_scaled.into());
            let stdev_scaled_u64: u64 = stdev_scaled_u256.try_into().unwrap();
            let stdev_scaled: i64 = stdev_scaled_u64.try_into().unwrap();

            // pass 3: drop outliers, recompute mean
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
                    let score_i64 = score_to_i64(score);
                    let diff = score_i64 * SCALE - mean_scaled;
                    let abs_diff = if diff < 0 {
                        -diff
                    } else {
                        diff
                    };
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
            let final_score: i64 = round_scaled(final_mean_scaled);

            d.final_score = final_score;
            d.final_score_set = true;
            d.total_weight_revealed = total_weight;
            d.phase = PHASE_FINALIZED;

            // coherence pass (for juror rewards)
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
                    let score_i64 = score_to_i64(score);
                    let diff = if score_i64 >= final_score {
                        score_i64 - final_score
                    } else {
                        final_score - score_i64
                    };
                    if diff <= COHERENCE_BAND {
                        self.dispute_coherent.entry((dispute_id, juror)).write(true);
                        total_coherent_weight += weight;
                    }
                }
                i += 1;
            };
            d.total_coherent_weight = total_coherent_weight;

            // governance token minting
            let mint_amount = governance_tokens_for_score(final_score);
            if mint_amount > 0 {
                self._mint_governance_tokens(d.candidate, mint_amount);
                d.governance_tokens_minted = mint_amount;
            }

            // bond settlement
            let bond_amount = d.bond_amount;
            let requester = d.requester;
            let refund_bond = bond_amount > 0 && final_score >= 0;
            let slash_bond = bond_amount > 0 && final_score < 0;
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
                            dispute_id,
                            candidate: d.candidate,
                            amount: mint_amount,
                            final_score,
                        },
                    );
            }

            if refund_bond {
                self.erc20._transfer(get_contract_address(), requester, bond_amount);
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
            assert(
                !self.dispute_reward_claimed.entry((dispute_id, caller)).read(),
                'AlreadyClaimed',
            );
            assert(d.total_coherent_weight > 0, 'NoCoherentWeight');

            let weight = self.dispute_juror_draws.entry((dispute_id, caller)).read();
            let amount = d.slash_pool * weight.into() / d.total_coherent_weight.into();

            self.dispute_reward_claimed.entry((dispute_id, caller)).write(true);

            if amount > 0 {
                self.erc20._transfer(get_contract_address(), caller, amount);
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
                    // SCORE VOTING / PROPOSAL LIFECYCLE
        // ----------------------------------------------------------

        fn create_proposal(
            ref self: ContractState,
            funding_wallet: ContractAddress,
            evidence: ByteArray,
        ) -> u256 {
            self.reentrancyguard.start();
            let caller = get_caller_address();
            assert(funding_wallet.is_non_zero(), 'ZeroAddress');
            assert(evidence.len() > 0, 'EvidenceRequired');
            assert(evidence.len() <= MAX_EVIDENCE_LEN, 'EvidenceTooLong');

            // Anti-Sybil deposit: pull reputation_stake of own ERC20
            let deposit = self.reputation_stake.read();
            let ok = self.erc20.transfer_from(caller, get_contract_address(), deposit);
            assert(ok, 'TransferFailed');

            let proposal_id = self.proposal_count.read();
            self.proposal_count.write(proposal_id + 1);

            let p = FundingProposal {
                author: caller,
                funding_wallet,
                evidence,
                created_at: get_block_timestamp(),
                executed: false,
                power_total: 0,
                deposit_amount: deposit,
                final_score: 0,
                final_score_set: false,
            };
            self.proposals.entry(proposal_id).write(p);

            self.emit(ProposalCreated { proposal_id, author: caller, deposit_amount: deposit });
            self.reentrancyguard.end();
            proposal_id
        }

        fn create_conviction(ref self: ContractState, level: u8, amount: u256) -> u32 {
            self.reentrancyguard.start();
            assert(level >= 1 && level <= 10, 'InvalidLevel');
            assert(amount > 0, 'ZeroAmount');
            let caller = get_caller_address();

            // Lock governance tokens from available balance
            let total = self._decayed_total(caller);
            let locked = self.governance_locked_total.entry(caller).read();
            let available = if locked >= total {
                0
            } else {
                total - locked
            };
            assert(amount <= available, 'InsufficientGovBalance');

            self.governance_locked_total.entry(caller).write(locked + amount);

            let id = self.next_conviction_id.entry(caller).read();
            self.next_conviction_id.entry(caller).write(id + 1);

            // Lock window: level * conviction_base_lock (admin-tunable), capped
            // at MAX_LOCK_DURATION so admin can never brick the release path.
            let level_u64: u64 = level.into();
            let lock_duration: u64 = level_u64 * self.conviction_base_lock.read();
            assert(lock_duration <= MAX_LOCK_DURATION, 'LockTooLong');

            let c = Conviction {
                owner: caller,
                id,
                level,
                amount,
                created_at: get_block_timestamp(),
                lock_duration,
                votes_cast: 0,
                released: false,
            };
            self.convictions.entry((caller, id)).write(c);

            self.emit(ConvictionCreated { owner: caller, conviction_id: id, level, amount });
            self.reentrancyguard.end();
            id
        }

        fn vote_with_conviction(
            ref self: ContractState, proposal_id: u256, conviction_id: u32, score: i8,
        ) {
            self.reentrancyguard.start();
            assert(score >= -5 && score <= 5, 'InvalidScore');

            let count = self.proposal_count.read();
            assert(proposal_id < count, 'InvalidProposalId');

            let p = self.proposals.entry(proposal_id).read();
            assert(!p.executed, 'AlreadyExecuted');
            assert(!p.final_score_set, 'AlreadyFinalized');

            let caller = get_caller_address();
            let mut c = self.convictions.entry((caller, conviction_id)).read();
            assert(c.owner == caller, 'Unauthorized');
            assert(!c.released, 'ConvictionReleased');
            let already = self.conviction_voted_on.entry((caller, conviction_id, proposal_id)).read();
            assert(!already, 'AlreadyVotedOnProposal');
            // Mirror the Solidity gate: votes only inside the lock window.
            let lock_expiry = c.created_at + c.lock_duration;
            assert(get_block_timestamp() < lock_expiry, 'LockExpired');
            assert(c.votes_cast < self.max_votes_per_conviction.read(), 'MaxVotesReached');

            // Weight is STATIC (frozen at vote time): isqrt(level * amount)
            let weight = self._vote_weight(@c);

            // Bucket the score and bump the proposal's frozen power accumulator
            let bucket: u8 = (score + 5).try_into().unwrap();
            let cur = self.proposal_score_counts.entry((proposal_id, bucket)).read();
            self.proposal_score_counts.entry((proposal_id, bucket)).write(cur + weight);

            let mut pm = self.proposals.entry(proposal_id).read();
            pm.power_total += weight;
            self.proposals.entry(proposal_id).write(pm);

            c.votes_cast += 1;
            self.convictions.entry((caller, conviction_id)).write(c);
            self.conviction_voted_on.entry((caller, conviction_id, proposal_id)).write(true);

            self.emit(SupportAdded { proposal_id, owner: caller, conviction_id });
            self.reentrancyguard.end();
        }

        fn release_conviction(ref self: ContractState, conviction_id: u32) {
            self.reentrancyguard.start();
let caller = get_caller_address();
            let mut c = self.convictions.entry((caller, conviction_id)).read();
            assert(c.owner == caller, 'Unauthorized');
            assert(!c.released, 'AlreadyReleased');
            // Mirror the Solidity gate: stake stays frozen for the whole
            // level-based lock window; release only after it elapses.
            let lock_expiry = c.created_at + c.lock_duration;
            assert(get_block_timestamp() >= lock_expiry, 'LockNotExpired');

            // Votes are permanent: releasing frees the locked governance stake so
            // it can back a new conviction, but the already-cast votes (frozen
            // histogram weight + proposal `power_total`) stay intact.
            let amount = c.amount;
            let locked = self.governance_locked_total.entry(caller).read();
            assert(locked >= amount, 'LockAccountingError');
            self.governance_locked_total.entry(caller).write(locked - amount);

            c.released = true;
            self.convictions.entry((caller, conviction_id)).write(c);

            self.emit(ConvictionReleased { owner: caller, conviction_id, amount });
            self.reentrancyguard.end();
        }

        fn execute_proposal(ref self: ContractState, proposal_id: u256) {
            self.reentrancyguard.start();
            assert(proposal_id < self.proposal_count.read(), 'InvalidProposalId');
            let mut p = self.proposals.entry(proposal_id).read();
            assert(!p.executed, 'AlreadyExecuted');

            // O(1) threshold check against the frozen power accumulator.
            let total_power = p.power_total;
            assert(total_power >= self.conviction_threshold.read(), 'ThresholdNotMet');

            // Compute weighted final score from histogram
            let final_score = self._compute_weighted_score(proposal_id);
            p.final_score = final_score;
            p.final_score_set = true;
            p.executed = true;

            let funding_wallet = p.funding_wallet;
            let deposit_amount = p.deposit_amount;
            let author = p.author;
            self.proposals.entry(proposal_id).write(p);

            self.emit(ProposalExecuted { proposal_id, total_power, final_score });

            // Deposit settlement + score-based reward (score 0 is treated as
            // neutral: deposit refunded, no reward minted). The reward is
            // best-effort: if the month budget or supply cap has no room, the
            // proposal still executes and the deposit is refunded - only the
            // payout is skipped, never reverting the whole call.
            if final_score >= 0 {
                // Refund deposit
                if deposit_amount > 0 {
                    self.erc20._transfer(get_contract_address(), author, deposit_amount);
                    self
                        .emit(
                            ProposalDepositRefunded {
                                proposal_id, requester: author, amount: deposit_amount,
                            },
                        );
                }

                // Mint score-based reward to funding_wallet (best-effort)
                let score_u256 = score_to_u256(final_score);
                let rm = self.reward_multiplier.read();
                let mrm = self.mini_reward_multiplier.read();
                let reward: u256 = if score_u256 <= 3 {
                    score_u256 * mrm
                } else {
                    score_u256 * rm
                };
                if reward > 0 && self._mint_from_budget(funding_wallet, reward) {
                    self
                        .emit(
                            ScoreRewardReleased {
                                proposal_id, recipient: funding_wallet, amount: reward,
                            },
                        );
                }
            } else {
                // Slash deposit (tokens already in contract, just relabel)
                if deposit_amount > 0 {
                    self
                        .emit(
                            ProposalDepositSlashed {
                                proposal_id, requester: author, amount: deposit_amount,
                            },
                        );
                }
            }

            self.reentrancyguard.end();
        }

        fn get_conviction_power(
            self: @ContractState, owner: ContractAddress, conviction_id: u32,
        ) -> u256 {
            let c = self.convictions.entry((owner, conviction_id)).read();
            if c.votes_cast == 0 {
                0
            } else {
                self._vote_weight(@c)
            }
        }

        fn get_proposal_total_power(self: @ContractState, proposal_id: u256) -> u256 {
            let p = self.proposals.entry(proposal_id).read();
            p.power_total
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

        fn burn(ref self: ContractState, amount: u256) {
            self.reentrancyguard.start();
            assert(amount > 0, 'ZeroAmount');
            self.erc20.burn(get_caller_address(), amount);
            self._track_burn(amount);
            self.reentrancyguard.end();
        }

        // ----------------------------------------------------------
                // MONTHLY INFLATION / BURN-RECYCLING BUDGET
        // ----------------------------------------------------------

        fn get_current_month(self: @ContractState) -> u64 {
            self.month_index.read()
        }

        fn get_month_start(self: @ContractState) -> u64 {
            self.month_start.read()
        }

        fn get_month_budget(self: @ContractState, month: u64) -> u256 {
            self.month_budget.entry(month).read()
        }

        fn get_month_budget_minted(self: @ContractState, month: u64) -> u256 {
            self.month_minted.entry(month).read()
        }

        fn get_month_burned(self: @ContractState, month: u64) -> u256 {
            self.month_burned.entry(month).read()
        }

        fn get_remaining_month_budget(self: @ContractState) -> u256 {
            let month = self.month_index.read();
            let budget = self.month_budget.entry(month).read();
            let minted = self.month_minted.entry(month).read();
            if minted >= budget {
                0
            } else {
                budget - minted
            }
        }

        fn get_inflation_rate_bps(self: @ContractState) -> u16 {
            self.inflation_rate_bps.read()
        }

        // ----------------------------------------------------------
                        // DECAY (ERC20 balances)
        // ----------------------------------------------------------

        fn apply_decay(ref self: ContractState, user: ContractAddress) {
            self.reentrancyguard.start();
            assert(!self.is_protected.entry(user).read(), 'ProtectedAddress');
            self._apply_decay(user);
            self.reentrancyguard.end();
        }

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
              // JUROR STAKE LOCKING VIEWS
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
            self.evaluation_bond_amount.read()
        }

        fn get_active_dispute_for_candidate(
            self: @ContractState, candidate: ContractAddress,
        ) -> u256 {
            self.active_dispute_for_candidate.entry(candidate).read()
        }

        fn get_dispute_evidence(self: @ContractState, dispute_id: u256) -> ByteArray {
            self.dispute_evidence.entry(dispute_id).read()
        }

        // ----------------------------------------------------------
              // ADMIN - timelocked parameter changes
        // ----------------------------------------------------------

        fn propose_set_evaluation_bond_amount(ref self: ContractState, amount: u256) {
            assert(amount > 0, 'ZeroAmount');
            assert(amount <= MAX_SUPPLY, 'TooHigh');
            self._propose_change(PARAM_EVALUATION_BOND_AMOUNT, amount);
        }

        fn execute_set_evaluation_bond_amount(ref self: ContractState) {
            let value = self._execute_change(PARAM_EVALUATION_BOND_AMOUNT);
            self.evaluation_bond_amount.write(value);
        }

        fn propose_set_reputation_stake(ref self: ContractState, amount: u256) {
            assert(amount > 0, 'ZeroAmount');
            assert(amount <= MAX_SUPPLY, 'TooHigh');
            self._propose_change(PARAM_REPUTATION_STAKE, amount);
        }

        fn execute_set_reputation_stake(ref self: ContractState) {
            let value = self._execute_change(PARAM_REPUTATION_STAKE);
            self.reputation_stake.write(value);
        }

        fn propose_set_conviction_threshold(ref self: ContractState, threshold: u256) {
            assert(threshold > 0, 'ZeroAmount');
            assert(threshold <= MAX_SUPPLY, 'TooHigh');
            self._propose_change(PARAM_CONVICTION_THRESHOLD, threshold);
        }

        fn execute_set_conviction_threshold(ref self: ContractState) {
            let value = self._execute_change(PARAM_CONVICTION_THRESHOLD);
            self.conviction_threshold.write(value);
        }

        fn propose_set_reward_multiplier(ref self: ContractState, amount: u256) {
            assert(amount > 0, 'ZeroAmount');
            assert(amount <= MAX_SUPPLY, 'TooHigh');
            self._propose_change(PARAM_REWARD_MULTIPLIER, amount);
        }

        fn execute_set_reward_multiplier(ref self: ContractState) {
            let value = self._execute_change(PARAM_REWARD_MULTIPLIER);
            self.reward_multiplier.write(value);
        }

        fn propose_set_mini_reward_multiplier(ref self: ContractState, amount: u256) {
            assert(amount > 0, 'ZeroAmount');
            assert(amount <= MAX_SUPPLY, 'TooHigh');
            self._propose_change(PARAM_MINI_REWARD_MULTIPLIER, amount);
        }

        fn execute_set_mini_reward_multiplier(ref self: ContractState) {
            let value = self._execute_change(PARAM_MINI_REWARD_MULTIPLIER);
            self.mini_reward_multiplier.write(value);
        }

        fn propose_set_vrf_provider(
            ref self: ContractState, new_vrf_provider: ContractAddress,
        ) {
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
            assert(amount <= MAX_SUPPLY, 'TooHigh');
            self._propose_change(PARAM_MIN_DECAY_FOR_REWARD, amount);
        }

        fn execute_set_min_decay_for_reward(ref self: ContractState) {
            let value = self._execute_change(PARAM_MIN_DECAY_FOR_REWARD);
            self.min_decay_for_reward.write(value);
        }

        fn propose_set_caller_reward_amount(ref self: ContractState, amount: u256) {
            assert(amount <= MAX_SUPPLY, 'TooHigh');
            self._propose_change(PARAM_CALLER_REWARD_AMOUNT, amount);
        }

        fn execute_set_caller_reward_amount(ref self: ContractState) {
            let value = self._execute_change(PARAM_CALLER_REWARD_AMOUNT);
            self.caller_reward_amount.write(value);
        }

        fn propose_set_num_draws(ref self: ContractState, num_draws: u32) {
            assert(num_draws >= MIN_NUM_DRAWS, 'BelowMinNumDraws');
            assert(num_draws <= MAX_NUM_DRAWS, 'AboveMaxNumDraws');
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

        fn propose_set_conviction_base_lock(ref self: ContractState, lock_duration: u64) {
            assert(lock_duration > 0, 'InvalidDuration');
            assert(lock_duration <= MAX_LOCK_DURATION, 'TooHigh');
            self._propose_change(PARAM_CONVICTION_BASE_LOCK, lock_duration.into());
        }

        fn execute_set_conviction_base_lock(ref self: ContractState) {
            let value = self._execute_change(PARAM_CONVICTION_BASE_LOCK);
            let value_u64: u64 = value.try_into().unwrap();
            self.conviction_base_lock.write(value_u64);
        }

        fn get_conviction_base_lock(self: @ContractState) -> u64 {
            self.conviction_base_lock.read()
        }

        fn propose_set_max_votes_per_conviction(ref self: ContractState, max_votes: u64) {
            assert(max_votes > 0, 'InvalidVotesCount');
            assert(max_votes <= MAX_MAX_VOTES_PER_CONVICTION, 'TooHigh');
            self._propose_change(PARAM_MAX_VOTES_PER_CONVICTION, max_votes.into());
        }

        fn execute_set_max_votes_per_conviction(ref self: ContractState) {
            let value = self._execute_change(PARAM_MAX_VOTES_PER_CONVICTION);
            let value_u64: u64 = value.try_into().unwrap();
            self.max_votes_per_conviction.write(value_u64);
        }

        fn get_max_votes_per_conviction(self: @ContractState) -> u64 {
            self.max_votes_per_conviction.read()
        }

        fn propose_set_inflation_rate_bps(ref self: ContractState, bps: u16) {
            assert(bps <= MAX_INFLATION_BPS, 'TooHigh');
            self._propose_change(PARAM_INFLATION_RATE_BPS, bps.into());
        }

        fn execute_set_inflation_rate_bps(ref self: ContractState) {
            let value = self._execute_change(PARAM_INFLATION_RATE_BPS);
            let value_u64: u64 = value.try_into().unwrap();
            let value_u16: u16 = value_u64.try_into().unwrap();
            self.inflation_rate_bps.write(value_u16);
        }

        fn propose_set_protected_address(
            ref self: ContractState, target: ContractAddress, protected: bool,
        ) {
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

        fn get_pending_protected(
            self: @ContractState, target: ContractAddress,
        ) -> PendingProtectedChange {
            self.pending_protected.entry(target).read()
        }

        // ---- admin roster ----

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
            assert(
                self.accesscontrol.has_role(DEFAULT_ADMIN_ROLE, admin_to_remove), 'NotAnAdmin',
            );
            let effective_at = get_block_timestamp() + TIMELOCK_DURATION;
            self
                .pending_admin_changes
                .entry(admin_to_remove)
                .write(PendingAdminChange { is_add: false, effective_at, exists: true });
            self.emit(AdminRemoveProposed { admin_to_remove, effective_at });
        }

        fn execute_remove_admin(ref self: ContractState, admin_to_remove: ContractAddress) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let pc = self.pending_admin_changes.entry(admin_to_remove).read();
            assert(pc.exists, 'NoPendingChange');
            assert(!pc.is_add, 'NotARemoveProposal');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            assert(
                self.accesscontrol.has_role(DEFAULT_ADMIN_ROLE, admin_to_remove), 'NotAnAdmin',
            );
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

        fn get_pending_admin_change(
            self: @ContractState, target: ContractAddress,
        ) -> PendingAdminChange {
            self.pending_admin_changes.entry(target).read()
        }

        fn admin_count(self: @ContractState) -> u32 {
            self.admin_count.read()
        }

        // ----------------------------------------------------------
                          // UPGRADEABILITY
        // ----------------------------------------------------------

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

        fn propose_disable_upgrades(ref self: ContractState) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(!self.upgrades_disabled.read(), 'AlreadyDisabled');
            assert(!self.pending_upgrade_disable.read().exists, 'AlreadyPending');
            let effective_at = get_block_timestamp() + UPGRADE_TIMELOCK_DURATION;
            self
                .pending_upgrade_disable
                .write(PendingChange { new_value: 1, effective_at, exists: true });
            self.emit(UpgradeDisableProposed { effective_at });
        }

        fn execute_disable_upgrades(ref self: ContractState) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            assert(!self.upgrades_disabled.read(), 'AlreadyDisabled');
            let pc = self.pending_upgrade_disable.read();
            assert(pc.exists, 'NoPendingChange');
            assert(get_block_timestamp() >= pc.effective_at, 'TimelockNotElapsed');
            self
                .pending_upgrade_disable
                .write(PendingChange { new_value: 0, effective_at: 0, exists: false });
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

        fn get_pending_upgrade_disable(self: @ContractState) -> PendingChange {
            self.pending_upgrade_disable.read()
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

        fn get_conviction(
            self: @ContractState, owner: ContractAddress, id: u32,
        ) -> Conviction {
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


    /// Returns the hash of the most recent block old enough for Starknet
    /// to expose via syscall, or zero on a chain younger than
    /// `BLOCK_HASH_LOOKBACK` blocks. Mixed into the VRF seed so that the
    /// draw seed always includes a component the contract reads itself,
    /// rather than depending solely on values an external VRF provider
    /// supplies and could in principle withhold.
    fn _recent_block_hash(self: @ContractState) -> felt252 {
        let current = get_block_number();
        if current < BLOCK_HASH_LOOKBACK {
            return 0;
        }
        let target = current - BLOCK_HASH_LOOKBACK;
        match get_block_hash_syscall(target) {
            Result::Ok(hash) => hash,
            Result::Err(_) => 0,
        }
    }
        /// Mints ERC20 tokens after enforcing the global supply cap.
        /// This helper is used for the one-time constructor mint; budgeted
        /// rewards use `_mint_from_budget`, which performs its own checks and
        /// remains best-effort.
        fn _mint_capped(ref self: ContractState, to: ContractAddress, amount: u256) {
            assert(amount > 0, 'ZeroAmount');
            let current_supply = self.erc20.total_supply();
            assert(current_supply + amount <= MAX_SUPPLY, 'SupplyCapExceeded');
            self.erc20.mint(to, amount);
        }

        // ---- monthly inflation / burn-recycling budget ----

        /// Computes a month's inflation share plus burns recycled from the
        /// previous month. Inflation is capped by the remaining `MAX_SUPPLY`
        /// headroom; month zero has no recycled burn component.
        fn _compute_month_budget(self: @ContractState, month: u64) -> u256 {
            let recycle = if month == 0 {
                0
            } else {
                self.month_burned.entry(month - 1).read()
            };

            let supply = self.erc20.total_supply();
            if supply >= MAX_SUPPLY {
                return recycle;
            }

            let rate_bps: u256 = self.inflation_rate_bps.read().into();
            let inflation = supply * rate_bps / (DECAY_BPS_DENOM * MONTHS_PER_YEAR.into());
            let headroom = MAX_SUPPLY - supply;
            let inflation_part = if inflation > headroom { headroom } else { inflation };
            inflation_part + recycle
        }

        /// Advances stale monthly budget state up to `MAX_ROLLOVER_MONTHS`
        /// months in one call. Each closed month's unused budget is written
        /// off, then the next month's inflation and recycled-burn budget is
        /// initialized and emitted. A far-future timestamp is intentionally
        /// clamped rather than reverted, so repeated calls can catch up.
        fn _ensure_current_month(ref self: ContractState) {
            let now = get_block_timestamp();
            let mut start = self.month_start.read();
            if now < start + MONTH_SECONDS {
                return;
            }

            // Clamp the rollover so a long-inactive contract settles at most
            // MAX_ROLLOVER_MONTHS per call. This keeps the loop bounded and
            // gas-fixed; a caller who touches the contract far in the future is
            // served over successive calls instead of being hard-reverted.
            let elapsed = (now - start) / MONTH_SECONDS;
            let mut settle = elapsed;
            if settle > MAX_ROLLOVER_MONTHS {
                settle = MAX_ROLLOVER_MONTHS;
            }

            let mut idx = self.month_index.read();
            let mut i: u64 = 0;
            loop {
                if i >= settle {
                    break;
                }

                // Settle the just-closed month: burn any unutilized budget.
                let budget = self.month_budget.entry(idx).read();
                let minted = self.month_minted.entry(idx).read();
                if minted < budget {
                    let leftover = budget - minted;
                    self.emit(MonthlyBudgetBurned { month: idx, amount: leftover });
                }

                // Open the next month with a fresh budget.
                idx += 1;
                start += MONTH_SECONDS;
                let new_budget = self._compute_month_budget(idx);
                let recycle = self.month_burned.entry(idx - 1).read();
                let inflation_part = new_budget - recycle;
                self.month_budget.entry(idx).write(new_budget);
                self
                    .emit(
                        MonthlyBudgetSet {
                            month: idx, budget: new_budget, inflation_part, recycle_part: recycle,
                        },
                    );

                i += 1;
            };

            self.month_index.write(idx);
            self.month_start.write(start);
        }

        /// Attempts to mint a reward from the current month's budget.
        ///
        /// The result is `true` only when tokens are actually minted. A zero
        /// amount, exhausted monthly budget, or insufficient `MAX_SUPPLY`
        /// headroom returns `false` without reverting, allowing the enclosing
        /// slash, decay, or proposal operation to complete without its reward.
        fn _mint_from_budget(ref self: ContractState, to: ContractAddress, amount: u256) -> bool {
            if amount == 0 {
                return false;
            }
            self._ensure_current_month();

            let month = self.month_index.read();
            let budget = self.month_budget.entry(month).read();
            let minted = self.month_minted.entry(month).read();
            if minted + amount > budget {
                return false;
            }
            if self.erc20.total_supply() + amount > MAX_SUPPLY {
                return false;
            }

            self.erc20.mint(to, amount);
            self.month_minted.entry(month).write(minted + amount);
            self.emit(BudgetRewardMinted { month, recipient: to, amount });
            true
        }

        /// Records an ERC20 burn in the current month after lazily advancing
        /// month state. The recorded amount is available as recycled budget
        /// when the following month is initialized.
        fn _track_burn(ref self: ContractState, amount: u256) {
            assert(amount > 0, 'ZeroAmount');
            self._ensure_current_month();

            let month = self.month_index.read();
            let burned = self.month_burned.entry(month).read();
            self.month_burned.entry(month).write(burned + amount);
        }

        // ---- juror slot registry ----

        /// Returns a juror's existing Fenwick slot or allocates the next slot.
        /// Allocation is bounded by the configured tree capacity and updates
        /// both forward and reverse slot mappings.
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

        // ---- Fenwick tree ----

        /// Adds `amount` to a Fenwick slot and every aggregate cell covering it.
        /// The slot must be within the configured tree size; callers obtain valid
        /// slots through `_get_or_create_index`.
        fn _fenwick_add(ref self: ContractState, index: u32, amount: u256) {
            let size = self.tree_size.read();
            let mut i = index;
            loop {
                if i > size {
                    break;
                }
                let cur = self.fenwick_tree.entry(i).read();
                self.fenwick_tree.entry(i).write(cur + amount);
                i += lowbit(i);
            };
        }

        /// Subtracts `amount` from a Fenwick slot and its aggregate cells.
        /// Every affected cell must contain at least `amount`; otherwise the
        /// helper reverts with `FenwickUnderflow` rather than corrupting totals.
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
                i += lowbit(i);
            };
        }

        /// Computes the total weighted stake in slots one through `index`.
        /// The loop follows Fenwick low bits and returns zero for index zero.
        fn _fenwick_prefix_sum(self: @ContractState, index: u32) -> u256 {
            let mut sum: u256 = 0;
            let mut i = index;
            loop {
                if i == 0 {
                    break;
                }
                sum += self.fenwick_tree.entry(i).read();
                i -= lowbit(i);
            };
            sum
        }

        /// Returns the total weighted stake represented by the entire tree.
        fn _fenwick_total(self: @ContractState) -> u256 {
            self._fenwick_prefix_sum(self.tree_size.read())
        }

        /// Finds the first slot whose cumulative weight exceeds `target`.
        /// The binary Fenwick search is bounded by the tree height; callers
        /// must supply a target below the tree's total weight.
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

        // ---- non-transferable governance token accounting ----

        /// Adds a non-transferable governance grant using the first reusable
        /// fully decayed slot, then an unused slot, or finally the most-decayed
        /// slot when the per-holder cap is reached. The bounded slot count keeps
        /// governance balance reads finite.
        fn _mint_governance_tokens(
            ref self: ContractState, holder: ContractAddress, amount: u256,
        ) {
            let count = self.governance_next_grant.entry(holder).read();
            let slot = self._next_free_grant_slot(holder);
            if slot < count {
                // Reuse a slot whose previous grant has fully decayed to zero.
                self
                    .governance_grant
                    .entry((holder, slot))
                    .write(Grant { amount, minted_at: get_block_timestamp() });
            } else if count < MAX_GOV_GRANTS_PER_HOLDER {
                self.governance_next_grant.entry(holder).write(count + 1);
                self
                    .governance_grant
                    .entry((holder, count))
                    .write(Grant { amount, minted_at: get_block_timestamp() });
            } else {
                // At cap with no expired slot: overwrite the most-decayed grant.
                self._overwrite_most_decayed_grant(holder, amount);
            }
        }

        /// Returns the first grant slot whose amount has fully decayed to zero,
        /// or the current slot count when no reusable slot exists.
        fn _next_free_grant_slot(self: @ContractState, holder: ContractAddress) -> u32 {
            let count = self.governance_next_grant.entry(holder).read();
            let mut i: u32 = 0;
            loop {
                if i >= count {
                    break;
                }
                let g = self.governance_grant.entry((holder, i)).read();
                if self._decayed_grant_amount(@g) == 0 {
                    return i;
                }
                i += 1;
            };
            count
        }

        /// Replaces the grant with the smallest currently remaining decayed
        /// amount. This is the fallback when all `MAX_GOV_GRANTS_PER_HOLDER`
        /// slots are occupied by non-zero grants.
        fn _overwrite_most_decayed_grant(
            ref self: ContractState, holder: ContractAddress, amount: u256,
        ) {
            let count = self.governance_next_grant.entry(holder).read();
            let g0 = self.governance_grant.entry((holder, 0)).read();
            let mut target: u32 = 0;
            let mut min_remaining: u256 = self._decayed_grant_amount(@g0);
            let mut i: u32 = 1;
            loop {
                if i >= count {
                    break;
                }
                let g = self.governance_grant.entry((holder, i)).read();
                let remaining = self._decayed_grant_amount(@g);
                if remaining < min_remaining {
                    min_remaining = remaining;
                    target = i;
                }
                i += 1;
            };
            self
                .governance_grant
                .entry((holder, target))
                .write(Grant { amount, minted_at: get_block_timestamp() });
        }

        /// Computes one grant's remaining amount at the current timestamp.
        /// Decay is linear over 8,760 whole hours; a grant reaches zero at or
        /// after one year, and timestamps at or before mint time return the
        /// original amount.
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

        /// Sums the current decayed amounts across a holder's bounded grant
        /// array. No grant is physically swept; decay is recomputed on each read.
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

        // ---- score voting power ----

        /// Computes a conviction's static vote weight as
        /// `isqrt(level * locked_amount)`. The result is frozen when a vote is
        /// cast and is not recalculated from elapsed lock time.
        fn _vote_weight(self: @ContractState, c: @Conviction) -> u256 {
            let level_u256: u256 = (*c.level).into();
            let amount_u256: u256 = (*c.amount).into();
            isqrt(level_u256 * amount_u256)
        }

        /// Computes a proposal's final score from its eleven weighted score
        /// buckets. Positive and negative weighted contributions are compared,
        /// the magnitude is truncated toward zero, and the result is bounded to
        /// the protocol's -5 through 5 range.
        fn _compute_weighted_score(self: @ContractState, proposal_id: u256) -> i64 {
            let mut weighted_pos: u256 = 0;
            let mut weighted_neg: u256 = 0;
            let mut total: u256 = 0;
            let mut i: u8 = 0;
            loop {
                if i > 10 {
                    break;
                }
                let cnt = self.proposal_score_counts.entry((proposal_id, i)).read();
                if i >= 5 {
                    weighted_pos += cnt * (i - 5).into();
                } else {
                    weighted_neg += cnt * (5 - i).into();
                }
                total += cnt;
                i += 1;
            };

            let (is_neg, magnitude): (bool, u256) = if total == 0 {
                (false, 0)
            } else if weighted_pos >= weighted_neg {
                (false, (weighted_pos - weighted_neg) / total)
            } else {
                (true, (weighted_neg - weighted_pos) / total)
            };
            assert(magnitude <= 5, 'InvalidAvgScore');

            let unsigned_score: i64 = if magnitude == 0 {
                0
            } else if magnitude == 1 {
                1
            } else if magnitude == 2 {
                2
            } else if magnitude == 3 {
                3
            } else if magnitude == 4 {
                4
            } else {
                5
            };

            if is_neg {
                -unsigned_score
            } else {
                unsigned_score
            }
        }

        // ---- ERC20 balance decay ----

        /// Applies elapsed-time ERC20 balance decay and optional caller reward.
        /// Decay is charged in whole elapsed hours at the configured annual
        /// basis-point rate, never exceeds the user's balance, and rejects the
        /// contract's own escrow address. A reward is attempted only for a
        /// different caller after the minimum burn and cooldown checks.
        fn _apply_decay(ref self: ContractState, user: ContractAddress) {
            // The contract's own escrow (locked juror stakes, evaluation bonds,
            // proposal deposits) must never be burnable via the public decay
            // entrypoints - burning it would make these obligations insolvent.
            assert(user != get_contract_address(), 'ProtectedAddress');
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
                self._track_burn(burn_amount);
                self.emit(DecayApplied { user, amount: burn_amount, caller });
            }

            if caller != user && burn_amount >= self.min_decay_for_reward.read() {
                let last_reward = self.last_caller_reward_at.entry(caller).read();
                if now >= last_reward + CALLER_REWARD_COOLDOWN {
                    self.last_caller_reward_at.entry(caller).write(now);
                    let reward = self.caller_reward_amount.read();
                    if reward > 0 && self._mint_from_budget(caller, reward) {
                        self.emit(DecayCallerRewarded { caller, user, reward });
                    }
                }
            }
        }

        // ---- juror stake locking ----

        /// Releases a dispute-specific juror stake snapshot exactly once.
        /// A release marker prevents repeated reveal or slash calls from
        /// decrementing the aggregate lock and open-dispute count twice.
        fn _release_dispute_lock(
            ref self: ContractState, dispute_id: u256, juror: ContractAddress,
        ) {
            if self.dispute_juror_lock_released.entry((dispute_id, juror)).read() {
                return;
            }
            let snapshot = self.dispute_juror_locked_snapshot.entry((dispute_id, juror)).read();
            let total = self.juror_locked_total.entry(juror).read();
            self.juror_locked_total.entry(juror).write(total - snapshot);

            let open = self.juror_open_lock_count.entry(juror).read();
            if open > 0 {
                self.juror_open_lock_count.entry(juror).write(open - 1);
            }

            self.dispute_juror_lock_released.entry((dispute_id, juror)).write(true);
        }

        // ---- generic timelock engine ----

        /// Records an admin-authorized ordinary parameter change with a
        /// three-day execution time and emits `ChangeProposed`.
        fn _propose_change(ref self: ContractState, param_key: felt252, new_value: u256) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let effective_at = get_block_timestamp() + TIMELOCK_DURATION;
            self
                .pending_changes
                .entry(param_key)
                .write(PendingChange { new_value, effective_at, exists: true });
            self.emit(ChangeProposed { param_key, new_value, effective_at });
        }

        /// Consumes and returns a matured ordinary parameter change.
        /// Only the default admin may execute it, the record must exist, and
        /// the timelock must have elapsed; the pending record is cleared before
        /// the value is returned.
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

        /// Encodes an address as a felt value for generic timelock storage.
        fn _address_to_u256(self: @ContractState, addr: ContractAddress) -> u256 {
            let addr_felt: felt252 = addr.into();
            addr_felt.into()
        }

        /// Decodes a felt-encoded timelock value back to an address.
        /// The value is expected to have been produced by `_address_to_u256`.
        fn _u256_to_address(self: @ContractState, value: u256) -> ContractAddress {
            let value_felt: felt252 = value.try_into().unwrap();
            value_felt.try_into().unwrap()
        }
    }
}
