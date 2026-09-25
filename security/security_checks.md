# Starknet / Cairo Security Skill File for OpenCode

**Goal:** Identify security vulnerabilities and enforce best practices specific to Starknet and Cairo smart contracts.

### Check Function Visibility and Decorators
- Ensure functions are correctly marked with `#[external(v0)]`, `#[view]`, or kept as internal/private helper functions.
- Verify trait implementations and `pub` vs `pub(crate)` visibility for library code to prevent unintended external access.

### Test Coverage
- Ensure high test coverage using Cairo Test (`scarb test`) or, preferably, **Starknet Foundry** (`snforge`) for advanced testing capabilities.

### Invariant Tests
- Implement invariant and fuzzing tests (e.g., using Starknet Foundry's fuzzing) to ensure system invariants (e.g., "total supply equals sum of all balances") hold under all randomized conditions.

### Check for Weird ERC20 / SNIP-2 Compliance
- Ensure compatibility with the **SNIP-2** token standard (Starknet's equivalent of ERC20).
- Verify correct handling of tokens that might have non-standard behavior. Always use the official OpenZeppelin Cairo `ERC20Dispatcher` for external token interactions to handle return values safely.
- Check for **SNIP-12** (Permit) compatibility if the contract relies on signature-based approvals.

### Event Emission and Indexing
- Ensure critical state changes emit events using the `#[event]` attribute and `emit!` macro.
- Verify events contain the necessary data for off-chain indexing and monitoring.

### Check Every Warning of Static Analysis Tools
- Run and resolve all warnings from Starknet-specific static analysis tools like **Caracal** (by Nethermind) and `cairo-lint`.

### Write Docs for Functions (NatSpec / Cairo Docs)
- Document all public and external functions using Cairo doc comments (`///`) following NatSpec-like standards for clarity, auditability, and automatic documentation generation.

### Check Every Warning of Compiler Static Analysis
- Ensure `scarb build` and `scarb check` complete with zero warnings. Pay special attention to unused variable, unreachable code, or type inference warnings.

### Functions and Variables Never Used
- Remove dead code. While Cairo's compiler is strict, double-check for logically dead code, unused storage variables, or unused `const` definitions.

### Functions and Events Passing Variables in the Right Sequence
- Verify that event parameters and function arguments match the intended logical order to prevent off-chain indexing errors and misinterpretation.

### Integer Overflow or Underflow
- Cairo's `felt252` does not overflow in the traditional sense, but it wraps around the prime field. **Ensure explicit bounds checking** if `felt252` is used for financial math.
- For `u8`, `u16`, `u32`, `u64`, `u128`, and `u256`, Cairo panics on overflow by default. Verify this is the intended behavior and use `try_into` or safe math wrappers where graceful degradation is preferred over panics.

### External Call Before Updating State (Check-Effects-Interactions)
- **Be highly nervous** if an external dispatcher call (e.g., `IERC20Dispatcher { contract_address: addr }.transfer(...)`) is made *before* updating the contract's internal state. Always follow the CEI pattern.

### Min and Max Deposit Limits or Revert
- Ensure functions handling deposits, minting, or swaps have explicit minimum and maximum bounds to prevent dust attacks, economic exploits, or division-by-zero panics.

### Slippage Protection
- Ensure swap or trade functions include `min_amount_out` (or similar) and `deadline` parameters to protect users from unfavorable execution prices.

### No Magic Numbers, Use Constants
- Avoid hardcoded magic numbers. Use `const` definitions at the top of the file or in a dedicated `constants` module.

### Do You Need `const` or Storage Variables?
- Evaluate if a value should be a compile-time `const` or a mutable storage variable. *(Note: Cairo does not have `immutable` in the EVM sense; constructor-set storage variables are used instead).*

### Lacking Zero Address Checks
- Verify explicit checks against zero addresses for `ContractAddress` (e.g., `address == 0.into()`) and `EthAddress` before assigning roles, updating state, or transferring funds.

### Exploits: Failure to Initialize
- Uninitialized proxy contracts can be claimed by attackers. Ensure upgradeable contracts have robust initialization guards (e.g., OpenZeppelin Cairo `initializer` pattern) and that the implementation contract itself cannot be initialized directly.

### Exploits: Storage Collision
- **Critical in Starknet**: When using upgradeable proxies, ensure the storage layout of the new implementation does not collide with the existing storage. Use OpenZeppelin Cairo's storage utilities or unique storage keys/namespaces to prevent overwriting critical state.

### Exploits: Centralization
- Assess the level of trust in the contract owner or admin roles.
- **Silent Upgrades**: Ensure contract upgrades emit a clear event and, if possible, are subject to a timelock to prevent malicious or unexpected changes.

### Exploits: Signature Replay
- Verify that signature-based actions (e.g., SNIP-12 permits, off-chain approvals) include a `nonce` and a `domain_separator` (including `chain_id`) to prevent replay attacks across different transactions, users, or networks.

### Exploits: Unlimited Minting
- Ensure minting functions have strict caps, role-based access control (e.g., `OnlyMinter`), and logical limits to prevent hyperinflation of the token supply.

### Exploits: MEV (Sequencer Extractable Value)
- Ask yourself: *If the Starknet sequencer or a future decentralized block builder sees this transaction in the mempool, how can they abuse that knowledge?*
- **How to stop slippage attacks due to MEV**: Enforce strict slippage limits and deadline parameters.
- **Toxic MEV**:
  - **Frontrunning**: Attacker executes a transaction before the victim's to gain an advantage.
  - **Sandwich Attacks**: Attacker places transactions before and after the victim's to manipulate the price.
- **Non-toxic MEV**:
  - **Backrunning**: Attacker executes a transaction immediately after the victim's (e.g., arbitraging a DEX after a large trade). *(Note: Starknet's current sequencer model limits some MEV, but decentralized sequencing will make this highly relevant).*

### Specific Cairo / Scarb Versioning
- Pin specific versions of `cairo-lang`, `scarb`, and dependencies (like `openzeppelin`) in `Scarb.toml` to prevent unexpected breaking changes or supply chain attacks.

### Reentrancy
- While Cairo's execution model differs from the EVM, reentrancy is still possible via external contract calls (dispatchers) that call back into the vulnerable contract before state is finalized. Use OpenZeppelin Cairo's `ReentrancyGuard` for sensitive functions.

### Weak Randomness
- Weak randomness (e.g., using `get_block_info().block_number` or `block_timestamp`) allows the sequencer or users to influence or predict the outcome. Use a trusted VRF (Verifiable Random Function) or a commit-reveal scheme.

### Mishandling of STRK / ETH
- Ensure the correct, canonical addresses are used for native tokens:
  - **ETH**: `0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7`
  - **STRK**: `0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d`
- Verify proper handling of `approve` and `transfer_from` flows, ensuring the contract has sufficient allowance and handles the return boolean correctly.

### DoS Attack Analysis
- Avoid unbounded loops over dynamic storage arrays or mappings, as they can exceed the block step limit (gas limit) and cause the transaction to revert, potentially freezing the contract or making a function permanently unusable.

### Pull Over Push Pattern
- The *pull-over-push pattern* is the gold standard for distributing funds. Instead of pushing funds to multiple users in a loop (which can DoS if one user's contract reverts or is a malicious contract), record the amount they are owed in storage and let them *pull* (withdraw) it themselves. This prevents fund loss, DoS attacks, and reentrancy issues.

### Check–Effects–Interactions (CEI) Pattern
- Strictly adhere to CEI:
  1. **Check**: Validate all conditions, requirements, and authorizations.
  2. **Effects**: Update all internal state variables.
  3. **Interactions**: Make external calls (e.g., token transfers, dispatcher calls) at the very end of the function.

---

### 💡 Tips for using this in OpenCode
You can save this as a custom rule file (e.g., `.cursorrules`, `.github/copilot-instructions.md`, or a custom system prompt). When reviewing Cairo code, explicitly instruct the AI to: 

> *"Review this Cairo contract against the Starknet Security Skill File, paying special attention to SNIP-2 compliance, storage collision risks, and CEI pattern violations."*
