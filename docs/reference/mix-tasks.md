<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# Mix tasks

These commands require a source checkout. Packaged-release equivalents are
listed where available.

| Task | Purpose |
| --- | --- |
| `memhouse.identity.bootstrap` | Create the Account and first administrator |
| `memhouse.portability.export` | Write a whole-Account logical archive |
| `memhouse.portability.import` | Load or verify an archive |
| `memhouse.reembed` | Enqueue or inspect an embedding transition |
| `memhouse.eval.smoke` | Developer sanity pass over the real write/read path |
| `memhouse.eval.benchmark` | Run one benchmark fixture and score it |
| `memhouse.eval.release` | Run the deterministic release matrix |
| `memhouse.eval.verify` | Validate a report's provenance |
| `memhouse.release.check` | Fail unless the tree is releasable |

Packaged standalone releases additionally provide `bin/update --check` and
`bin/update --version MAJOR.MINOR.PATCH`; these are not Mix tasks.

---

## `memhouse.identity.bootstrap`

Provisions the community Account, first password identity, root administrator
grant with downward propagation, and a 12-hour bearer token.

```bash
MEMHOUSE_BOOTSTRAP_PASSWORD='a long password' \
  mix memhouse.identity.bootstrap \
    --email admin@example.test \
    --name 'Local Admin'
```

| Switch | Notes |
| --- | --- |
| `--email`, `-e` | Required. Becomes the sign-in identity and, normalised, the peer key |
| `--name`, `-n` | Display name. Defaults to the email |
| `--password` | Prefer the environment variable — an argument is visible in shell history and the process list |

There is no fallback password. Re-running for an existing email raises. The
whole bootstrap is one transaction, so a failure never leaves a half-created
administrator.

**In a release:** call `MemHouse.Identity.bootstrap_human/1` through
`bin/memhouse rpc` — see the
[Quickstart](../getting-started/quickstart.md#1-bootstrap-an-administrator).

---

## `memhouse.portability.export`

```bash
mix memhouse.portability.export --output /secure/path/memhouse-account.tar.gz
```

Default output is `memhouse-export-YYYY-MM-DD.tar.gz` in the working
directory. Read inside one Account-scoped transaction, so the snapshot is
internally consistent.

**In a release:**
`bin/memhouse rpc 'MemHouse.Release.export!("/secure/path/account.tar.gz")'`

See [Export and import](../operations/portability.md) for what is included.

---

## `memhouse.portability.import`

```bash
mix memhouse.portability.import --input /secure/path/account.tar.gz
mix memhouse.portability.import --input /secure/path/account.tar.gz --validate-only
```

Before writing, import verifies the manifest, every resource and blob hash, and
the complete audit hash chain.

Import requires a **fresh target**: migrated, with no Account holding the
archived id or occupying the community slot. It refuses rather than blending
two histories.

**In a release:** `MemHouse.Release.import!/1` and
`MemHouse.Release.validate_archive!/1` through `bin/memhouse rpc`.

---

## `memhouse.reembed`

```bash
mix memhouse.reembed
mix memhouse.reembed --status PIPELINE_RUN_ID
```

The first command enqueues the configured Account-wide embedding identity. The
task prints the run id and durable progress as JSON. The status form reports
the phase, cursor, processed counts, attempt count, and last error class.

**In a release:**

```bash
bin/memhouse rpc 'MemHouse.Release.reembed!()'
bin/memhouse rpc 'MemHouse.Release.reembed_status!("PIPELINE_RUN_ID")'
```

Knowledge, active document chunks, and entity projections run in resumable
batches. Old-identity rows are absent from semantic retrieval until their
batch commits. Lexical retrieval remains available during the transition.

---

## `memhouse.eval.smoke`

```bash
mix memhouse.eval.smoke --profile balanced --account eval-poc
```

A developer sanity check, not a graded evaluation: it ingests a few messages,
asks a few questions, and prints what came back. No scores, no thresholds.

!!! danger "It writes real rows"
    There is no dry-run mode and no cleanup. Point it at a scratch database,
    and never reuse an Account key that holds real user data.

---

## `memhouse.eval.benchmark`

```bash
mix memhouse.eval.benchmark --benchmark locomo --dataset data/locomo10.json
```

Runs one fixture end to end through the ordinary write and answer paths and
scores it. Recognised shapes: LoCoMo, LongMemEval, ConvoMem, BEAM, and
MemHouse's own `{"messages": [...], "questions": [...]}`.

| Switch | Notes |
| --- | --- |
| `--dataset`, `-d` | Required. Hashed, so the report names the exact data |
| `--benchmark`, `-b` | Inferred from shape when omitted |
| `--profile`, `-p` | Default `balanced` |
| `--account` | Default `eval-benchmark` |
| `--run-id` | Seeds the scope root; give concurrent runs distinct ids |
| `--limit-cases` / `--limit-messages` / `--limit-questions` | Truncate for a fast loop — recorded in the report, because a truncated run is not comparable |
| `--no-model` | Deterministic local extractor and answerer |

Also writes real rows. Same warning applies.

---

## `memhouse.eval.release`

```bash
mix memhouse.eval.release \
  --no-model \
  --assert-thresholds \
  --output /private/tmp/memhouse-release-eval.json
```

Runs `specs/eval/release-suite.json` against floors in
`specs/eval/deterministic-thresholds.json`. Only release guardrails block;
ablations inform.

---

## `memhouse.eval.verify`

```bash
mix memhouse.eval.verify /tmp/memhouse-eval.json
```

Checks that a report carries enough provenance to be quotable: application
version, timestamp, benchmark, retrieval profile and version, deadline,
strategy override, run limits, dataset id with SHA-256 and split, all four
model-role identities, judge, and metrics.

Provenance only — it re-runs nothing and compares nothing to a floor.

---

## `memhouse.release.check`

```bash
mix memhouse.release.check --eval-report /private/tmp/memhouse-release-eval.json
mix memhouse.release.check --tag v0.4.0 --eval-report /private/tmp/...
```

Fails unless `mix.exs`, changelog, documentation, git tag, and evaluation
evidence describe one release. There is no warning-only outcome.

`--allow-missing-eval` exists for metadata-only lanes; a real release must
supply the report.
