<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# ADR 0015: Windowed message extraction

Status: Accepted.

## Decision

Message extraction uses a trailing, same-session-and-scope window of six messages. The
pipeline target remains the anchor message. The extractor receives the anchor,
the window text, and the id of every message in that window.

A model candidate may cite only ids from the supplied window. The schema
rejects an id outside the window. The pipeline writes every cited id to the
knowledge item's `source_message_ids` and creates one provenance row for each
id. Duplicate statements merge their cited ids.

The prompt tells the extractor to return no candidate for greetings,
acknowledgements, compliments, questions, and invitations that state no fact.
The deterministic local adapter applies the same narrow filter.

## Consequences

The window gives extraction the local context needed for a fact that spans
several turns. It does not change the raw-message system of record, governance,
or Account isolation. The window is bounded to control prompt size and keeps
provenance exact enough for erasure and source filtering.

The target message remains the job replay key and completion marker. Existing
jobs stay compatible. Overlapping windows can produce the same statement; the
existing statement hash and merge path converge the durable knowledge and its
source ids.

This decision does not publish a new quality, cost, or latency claim. A future
evaluation report must include the full `f11-1` provenance tuple before it
compares this extractor with the historical baseline.

## Anchors

- `FR-KN-1`, `FR-KN-5`, `FR-KN-6`, `FR-KN-7`, `FR-KN-8`
- `FR-FORM-13`, `FR-FORM-14`, `FR-FORM-16`
- `AINV-2`, `AINV-5`, `AINV-6`, `AINV-11`
- `AD-PIPE-2`, `AD-PIPE-3`, `AD-PIPE-4`, `AD-DATA-1`
