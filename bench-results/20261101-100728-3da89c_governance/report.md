# MemHouse benchmark: governance

Run `20261101-100728-3da89c` · 2026-11-01 10:07 UTC · 4 s wall time

| Setting | Value |
|---|---|
| MemHouse | 0.1.0 |
| Embedder | `local:Xenova/bge-small-en-v1.5` |
| Reranker | off |
| Retrieval | hybrid (RRF k=60, keyword w=1, vector w=1, 100 candidates per retriever) |
| Query analysis | window w=0.15, top 3 +1, sub-query w=0 |
| Selection | limit=all stride=1 offset=0 types=all |
| Host | macos aarch64 · 8 CPU threads · embeddings on CPU |

## Governance and safety gates

**12 of 12 checks passed** (3541 ms). Deterministic checks, never decided by a model.

| | Check | Requirement | Result | Target | Detail |
|---|---|---|---|---|---|
| ✅ pass | Injected instructions are never committed or recalled | QUAL-02 / strategy 7.2 | 0 committed, 0 recalled of 15 attempts x 2 paths | 0 | all quarantined |
| ✅ pass | Benign look-alike statements are not quarantined | QUAL-02 | 0.0% (0/15) | <= 7% |  |
| ✅ pass | Cards, SSNs and API keys are redacted before storage (records and audit log) | GOV-05 / TR-IN-04 | 0 of 5 canaries found in storage | 0 | 3 records checked |
| ✅ pass | Recall never returns another subject's memory | GOV-02 / TR-RQ-01 | 0 cross-subject hits in 36 recalls | 0 | own memory found in 36/36 recalls |
| ✅ pass | Same subject id in another tenant sees nothing | GOV-02 | 0 hits from tenant B | 0 | tenant A sees 1 hit(s) |
| ✅ pass | Forget removes the record, its cached embedding and every recall path, and is audited | GOV-07 / TR-WF-01 | recall after delete: 0, records: 0, cached vectors: 0 | 0 / 0 / 0 | found before delete: 1, audit event: true |
| ✅ pass | Erasing a subject removes all of its records | GOV-07 | 0 remaining after erasing 20 | 0 |  |
| ✅ pass | Superseded facts are not recalled; the update is | CORE-03 / strategy 7.2 | stale-fact rate 0.0% (0/8) | <= 1% | updated fact recalled 8/8; 8 prior versions kept for audit |
| ✅ pass | Expired memories are excluded from current recall | CORE-05 | 1 current hit(s) | only valid memories | as-of 2 days ago returns 0 hit(s) (created now, so none were known then) |
| ✅ pass | Repeated writes do not create duplicate memories | CORE-06 | 2 record(s) after 3 writes | 1-2 | exact repeat deduplicated: true, near repeat deduplicated: false |
| ✅ pass | Every write and deletion is in a tamper-evident (hash-chained) audit log | GOV-12 | 389 events verified | intact |  |
| ✅ pass | Same input gives the same embedding | Strategy 7.1 | max |Δ| = 0.00e0 | < 1e-5 | local:Xenova/bge-small-en-v1.5 |

