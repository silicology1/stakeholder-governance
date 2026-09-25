Yes — it's a real design benefit, and the mechanics are worth being precise about since "deducts" is almost, but not quite, the right word.

**How it actually works in the math**

```
avgScore = Σ(score_i × weight_i) / Σ(weight_i)
```

- The **denominator** (`Σweight_i`) is always positive — every conviction's weight (`level × stake`) is added regardless of whether the vote was +5 or -5.
- The **numerator** is where sign matters. A -5 vote contributes `-5 × weight` to the sum, so it directly cancels out positive contributions before the division happens.

So negative votes don't reduce *turnout* or *quorum weight* — they reduce the *weighted sum* that gets averaged. Practically: if one voter puts in 1000 tokens at conviction level 10 rating +5, and another puts in the same weight rating -5, the numerator nets to zero and the average comes out 0, even though quorum (`totalVotes`/`totalConviction`, tracked separately in `proposalStats`) was clearly met by both.

**Why that's a genuine benefit over a 0–10 scale**

1. **Disapproval vs. mild approval are distinguishable.** On a 0–10 scale, "I hate this" and "I'm mildly okay with this" both have to land somewhere in the low-positive range — there's no way to signal active rejection separately from lukewarm support. On -5..+5, 0 means "neutral/no net opinion" and negative means "this actively should not be funded."

2. **Polarized proposals get correctly penalized.** Imagine a proposal that half the voters love (+5) and half hate (say, they'd want to rate it -5). On a forced 0–10 scale, that might average out to something like a middling 5 — which reads as "okay, somewhat good" and could still hit `MIN_SCORE_FOR_REWARD`. On the -5..+5 scale it averages to 0, which is below `MIN_SCORE_FOR_REWARD = 1` and correctly blocks the reward. Genuine consensus is required to clear the bar, not just an absence of universal hatred.

3. **The reward gate becomes a real signal, not an artifact of scale choice.** Because `releaseReward` reverts unless `finalScore >= 1`, the negative range means "the community actively pushed back" and "the community had no strong opinion" both fail to fund the proposal — which is the intended behavior — while a 0–10 scale would conflate "no one had an opinion" (which might default near the middle) with "everyone hated it."

One thing to flag if you don't already have it: because negative votes don't reduce the quorum-counted `totalConviction`, a low-effort or hostile flood of small-weight negative votes can still help a proposal reach quorum while working to sink its average — which is probably intended (spam alone still needs weight to matter), but worth confirming is the behavior you want, since quorum and "net approval" are tracked completely independently in this design.
