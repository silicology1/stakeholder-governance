Apply 5% decay of erc20 tokens per year decaying every hour, variable can be set by admin, min decay reward is set by admin

  function applyDecay(address user) external nonReentrant {
        if (isProtectedAddress[user]) revert ProtectedAddress();
        _applyDecay(user);
    }

    /// @notice Batch apply decay (max 50 users — gas griefing protection).
    function batchApplyDecay(address[] calldata users) external nonReentrant {
        if (users.length > 50) revert TooManyUsers();
        for (uint256 i; i < users.length; i++) {
            if (isProtectedAddress[users[i]]) continue;
            _applyDecay(users[i]);
        }
    }

    Also reward for those who call decay.

          // Reward caller if decay is significant, prevent self-farming
            if (msg.sender != user && burnAmount >= MIN_DECAY_FOR_REWARD) {
                if (block.timestamp >= lastCallerRewardAt[msg.sender] + 1 days) {
                    lastCallerRewardAt[msg.sender] = block.timestamp;
                    TOKEN.mint(msg.sender, CALLER_REWARD);
                }
            }
