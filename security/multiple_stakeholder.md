> **Correction note (2026-09-24):** this design note predates the conviction-voting redesign. The "Governance Token Spam" point (§ above) and the "Fix the $O(N)$ Proposal Power Loop" item described `get_proposal_total_power`/`_proposal_total_power` looping over a per-proposal supporter list and capping/DoSing `execute_proposal`. Those structures are **gone** (see `StakeholderConviction_Security_Analysis_v3.md` §11): `FundingProposal.power_total` is a frozen O(1) accumulator bumped at vote time, supporter voting is unbounded, and `execute_proposal` no longer iterates supporters. The operational conclusion still stands.

## Opt-In Evaluation with a Bond
Instead of the system automatically creating a dispute for every stakeholder, stakeholders must request to be evaluated if they want governance power (Stage 2 tokens).

Mechanism: A stakeholder calls a new function request_evaluation(candidate_address) and must lock a bond (e.g., 50 of the contract's ERC20 tokens).

Incentive: This filters out the hundreds of thousands of passive users. Only those who actually want to participate in Conviction Voting (Stage 3) will pay the bond and initiate the dispute.

Outcome: If they score > 0, they get their bond back + the governance tokens. If they score < 0 (or fail to provide evidence), the bond is slashed and sent to the juror slash pool.


## Stake once and participate as many dispute per month
Your idea to have jurors stake once for a month and participate in many disputes is excellent for maintaining a deep, stable liquidity pool for the Fenwick-tree sortition. However, the current contract draft has a critical vulnerability regarding unstaking.
The Slashing Evasion Bug:
As noted in the contract's own CAVEATS section:

    "LOCKED STAKE (jurors): ...this draft does not stop a juror from unstaking immediately after being drawn, before commit/reveal."

How it breaks:

    A juror stakes 10,000 tokens and is drawn for 50 disputes in a month.
    The juror immediately calls unstake(10000) and withdraws their tokens.
    The juror simply ignores the commit/reveal phases for those 50 disputes.
    When slash_non_revealer is called, the contract checks self.juror_stake.entry(juror).read(). Because the juror already unstaked, their stake is 0.
    The slash_amount calculates to 0, and the malicious juror escapes punishment entirely, having disrupted 50 disputes for free.

The Fix (Required for your strategy):
You must modify the contract to track "Locked Stake per Dispute". When a juror is drawn, their stake should be logically locked until that specific dispute is finalized. The unstake function must assert:
assert(current_stake - amount >= total_locked_in_pending_disputes, 'InsufficientUnlockedStake');


### Why "Kleros for Every Stakeholder" Fails at Scale 

Will above method fix it. 
If you have 100,000+ stakeholders and create a create_selection_dispute for each one, you will encounter three fatal bottlenecks:

    Juror Fatigue & Schelling Game Collapse: The Kleros Schelling game relies on jurors having some basis to find the "truth" (or consensus). If jurors are presented with 100,000 random addresses to score from [-5 to +5], they will not research them. They will suffer from severe "voter fatigue," leading them to guess randomly, copy-paste previous scores, or simply abstain. If jurors guess randomly, the statistical trimming (stdev outlier removal) in finalize_selection becomes meaningless, and the resulting "empowerment" scores will be essentially random noise.
    Transaction & VRF Overhead: For 100,000 stakeholders, you are looking at a minimum of 2.1 million transactions (100k creations + 100k commits + 100k reveals + 100k finalizations, assuming only 1 juror drawn per dispute, though your contract enforces a minimum of 10 draws). Even on Starknet, coordinating millions of VRF requests (Cartridge VRF) and juror actions is operationally impossible and expensive.
    Governance Token Spam: If every stakeholder receives a positive score, your contract will mint millions of Stage 2 non-transferable governance tokens. While Stage 2 is uncapped and decays over a year, flooding the system with 10M+ active governance tokens dilutes the "conviction voting" power of serious participants and makes the get_proposal_total_power iteration (which loops over all supporters) increasingly gas-expensive.



Ah, that is a **massive** and game-changing clarification. 

If you mean a **throughput of 1 lakh (100,000) disputes per year**, the answer changes completely:

**Yes, the contract will technically scale to handle this throughput.** 

At 100,000 disputes per year, you are looking at roughly **274 disputes per day**, or about **11 disputes per hour**. This is well within the compute, gas, and storage limits of Starknet. 

However, while the *code* won't break, the **human and economic mechanics** will face severe friction at this volume. Here is the exact breakdown of what will happen at this scale and the minor tweaks needed to ensure it runs smoothly.

---

### ✅ Why the Code Will Handle It (The Math)

1. **Compute & Gas Limits**: 
   - 274 disputes/day × 10 draws (`num_draws`) = 2,740 Fenwick tree lookups per day. 
   - A single Starknet block can handle thousands of simple transactions. This throughput is trivial for the Cairo VM.
2. **Juror Lock Concurrency**: 
   - A dispute lifecycle is 2 days (1 day commit + 1 day reveal).
   - At 274 disputes/day, there will be roughly **550 active disputes** at any given moment.
   - 550 disputes × 10 draws = **5,500 active juror locks** system-wide.
   - If you have a healthy pool of, say, 1,000 active staked jurors, the *average* juror will hold ~5.5 concurrent locks. This is safely below your `MAX_CONCURRENT_JUROR_LOCKS` limit of 15. The redraw mechanism will only trigger if stake is extremely concentrated, and even then, it will likely find an uncapped juror within the 20 attempts.
3. **State Bloat**: 
   - 100,000 disputes/year means ~1 million new map entries (draws, commits, reveals) annually. On Starknet, this is a manageable amount of state growth, especially if you eventually leverage state-rent or pruning mechanisms as the ecosystem evolves.

---

### ⚠️ The Real Risks at This Throughput (Human & Economic Friction)

While the VM won't crash, the *system* might stall due to these three factors:

#### 1. Juror Fatigue and "Spam" Scoring
274 disputes a day is a lot of noise. If jurors are asked to evaluate random addresses without context, they will experience severe decision fatigue. 
* **The Result**: Jurors will either stop revealing entirely, or they will blindly commit/reveal a default score (like `0` or `+1`) just to collect rewards or avoid slashes. This turns your sophisticated trimmed-mean stdev calculation into a random number generator, minting governance tokens to undeserving candidates.

#### 2. The Keeper Bottleneck (Lock Buildup)
If even 10% of jurors fail to reveal due to fatigue, that’s **~27 non-reveals per day** that need to be slashed to free up their locks.
* **The Problem**: Your `SLASH_KEEPER_REWARD` is a flat `0.0005` tokens. For a keeper bot to scan the chain, identify non-reveals, and execute the transaction 27 times a day, this reward is likely too low to cover gas/compute costs. 
* **The Result**: Non-reveals won't get slashed promptly. Juror `open_lock_count` will slowly creep up toward the 15-lock cap, eventually triggering the `'NoEligibleJurors'` revert for the most heavily staked whales.

#### 3. The VRF Multicall UX Hurdle
As noted in your caveats, `create_selection_dispute` requires the caller to prefix the multicall with `VRF.request_random`. 
* At 274 times a day, no human is doing this manually. This *must* be automated by a backend bot or a highly abstracted frontend wallet. If the UX for this is clunky, dispute creation will bottleneck.

---

### 🛠️ Actionable Tweaks to Guarantee Smooth Scaling

To make this 100,000/year throughput robust, implement these four adjustments:

#### 1. Increase the Keeper Reward (Critical)
Change `SLASH_KEEPER_REWARD` from a flat, tiny amount to a **percentage of the slashed amount** (e.g., 10% of `slash_amount`). 
* **Why**: This dynamically scales the incentive. If a whale with a large stake fails to reveal, the slash is large, and the keeper reward is large, guaranteeing a bot will clean it up immediately and free the lock.

#### 2. Implement an "Opt-In Bond" for Candidates (Highly Recommended)
Instead of letting anyone trigger a dispute for anyone, require the `candidate` to initiate and fund their own evaluation.
* Add a `request_evaluation(bond_amount: u256)` function that locks the candidate's tokens before calling `create_selection_dispute`.
* **Why**: Out of 1 lakh users, perhaps only 5,000 actually *want* governance power. This naturally filters out the noise, reducing the load from 100,000 disputes/year to a much more manageable 5,000, saving gas and preserving juror attention for high-quality candidates.

#### 3. Add a Simple `set_juror_active(bool)` Toggle
Give jurors a way to temporarily pause themselves from being drawn if they are going on vacation or are overwhelmed.
* Add `is_active: bool` to the juror state. If `false`, the draw loop simply `continue`s to the next redraw. This is much more predictable than relying solely on the `MAX_REDRAW_ATTEMPTS` fallback.

#### 4. (Optional but Safe) Fix the $O(N)$ Proposal Power Loop
While 100k *disputes* per year is fine, if a single *funding proposal* gets 5,000 supporters, `execute_proposal` will still hit the Starknet step limit due to the loop in `_proposal_total_power`. 
* **Fix**: Add `current_total_power: u256` to the `FundingProposal` struct. Increment it in `add_support` and decrement it in `remove_support`. This makes execution $O(1)$ and future-proofs the contract against viral proposals.

### Summary
Your revised scope (1 lakh per year) is **perfectly viable** for this contract architecture. The code is well-designed, and the juror locking mechanism successfully closes the evasion loophole. By slightly tuning the keeper economics and strongly considering an opt-in bond for candidates, this system will run smoothly and securely at that scale.
