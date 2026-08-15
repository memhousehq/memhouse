<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# ADR 0020: Score-aware retrieval fusion

Status: Accepted

This decision supersedes the fusion algorithm in ADR 0004. The candidate,
deadline, disagreement, and rerank seams from ADR 0004 remain in force.

## Context

Weighted reciprocal-rank fusion discarded the size of every local score gap.
With `k = 60`, an exact lexical hit and a weak first-place result contributed
the same value. Relevant evidence could therefore lose to candidates returned
by more strategies, even when those strategies had weak matches.

Raw strategy scores cannot be combined directly. Semantic similarity, full-text
rank, time relevance, salience, and mention confidence use different scales.

## Decision

Normalize scores separately inside each returned strategy list. The best score
maps to 1 and the worst maps to 0. A singleton or tied list maps to 1 because
that list contains no observed score separation.

For each strategy, combine 95% normalized score with a 5% reciprocal-rank
tie-break. Apply the profile weight, sum contributions for matching candidate
ids, then divide by the total configured weight. Missing strategies contribute
zero. The result is a `fusion_score` from 0 to 1.

Store `rrf_k` in each profile and default it to 15. Keep `rrf_score` as a
deprecated response alias for one contract version. Historical `poc-0` reports
stay unchanged and continue to identify the former `k = 60` RRF behavior.

## Rejected alternatives

Pure RRF remains insensitive to match strength. Lowering `k` widens rank gaps
but does not restore the discarded score signal.

Combining raw scores makes one strategy dominate when its model, analyzer, or
corpus changes scale. Global calibration has the same maintenance problem and
requires new calibration data after those changes.

Z-score normalization is sensitive to small lists and outliers. Min-max
normalization has bounded output and a deterministic singleton rule.

## Consequences

Fusion order can change when a strategy's returned tail changes because that
tail defines its observed score range. Strategy cutoffs and caps therefore
remain part of the versioned profile.

`MemHouse.Retrieval.Fusion`, `MemHouse.Retrieval.Profile`, and the F7 retrieval
contract tests enforce this decision. Held-out evaluation must tune the 95/5
mix, profile weights, or `rrf_k`; reported evaluation data must not be used for
tuning.
