<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# Acting on your own data

`/api/v1/self/*` lets a person act on knowledge about **themselves**. It
requires a human password identity; agent API keys receive 403.

The credential fixes the subject. No parameter can select another person.

## See what the system holds about you

```bash
curl -fsS http://127.0.0.1:4000/api/v1/self/knowledge \
  -H "authorization: Bearer $TOKEN"
```

Newest first, skipping already-deleted items. This view includes items that are
still `provisional` or `held` and therefore invisible to ordinary retrieval —
**seeing an item here does not mean anyone else can see it.**

## Contest

```bash
curl -fsS -X POST http://127.0.0.1:4000/api/v1/self/knowledge/<id>/contest \
  -H "authorization: Bearer $TOKEN"
```

The item becomes `contested`, writes an immutable audit entry, and queues human
review with a 24-hour deadline.

Contesting states an objection. It does not delete or rewrite the claim, and
only a human curator can resolve it.

## Redact

```bash
curl -fsS -X POST http://127.0.0.1:4000/api/v1/self/knowledge/<id>/redact \
  -H "authorization: Bearer $TOKEN"
```

The item moves to a redacted state. Unlike contesting, this queues no review:
the subject's decision stands on its own.

**Redaction is not erasure.** The row survives in a redacted state so history
and audit stay intact.

## Erase

```bash
curl -fsS -X POST http://127.0.0.1:4000/api/v1/self/erasure \
  -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d '{"mode":"proportionate"}'
```

| Mode | What it removes |
| --- | --- |
| `proportionate` (default) | Your observations, the knowledge you are the subject of, and your traces scrubbed out of provenance other knowledge still depends on. |
| `strict` | The same, plus knowledge that was only ever sourced through you. |

```mermaid
flowchart TD
    E[Erasure request] --> S1[Remove subject content]
    S1 --> S2[Scrub shared provenance]
    S2 --> Q{Does a statement have<br/>surviving independent provenance?}
    Q -->|yes| KEEP[It stays. Not yours to delete.]
    Q -->|no| GONE[Removed]
    S2 --> P[Recompute or dirty affected<br/>projections and entity caches]
    S2 --> A[Content-safe audit evidence retained]
```

Neither mode retracts independently supported knowledge.

The response carries only the request's id, mode, and state. Reporting *what*
was removed would re-disclose the very content you asked to have destroyed.

Content-safe ids, hashes, actions, and counts survive to prove erasure without
retaining erased content.

## Not found means not yours

An unknown id and an id belonging to someone else's knowledge produce the same
not-found response. The two cases are deliberately indistinguishable, so these
routes cannot be used to probe for the existence of other people's records.

## Related

- [Governance gates](../concepts/governance.md)
- [Isolation and access control](../concepts/security-model.md)
