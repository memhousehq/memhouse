<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# MemHouse Beta Roadmap

Status: active. This is the only roadmap.
Application version at time of writing: `0.2.0`.
Repository state verified: 2026-07-28.

MemHouse is past its proof-of-concept stage. The memory engine, governance,
retrieval, documents, packaging, and release machinery are implemented and
under test. This document lists **only the work that is still outstanding**.
Anything already delivered has been removed from here; the record of what runs
today lives in `specs/implementation-status.md`.

This roadmap merges and replaces three earlier documents:

- `specs/roadmap/l3-automation-flow.md` (delivery workflow),
- `specs/roadmap/main-branch-ruleset.md` (branch protection checklist),
- `specs/roadmap/manual-automation-setup.md` (maintainer setup runbook),

and it absorbs the still-open phases of the former
`specs/roadmap/free-core-roadmap.md`, whose durable architecture content now
lives at `specs/architecture/free-core-architecture.md`.

## How to read this

- Capabilities are named literally. The old `F0`–`F11` phase labels are
  retired. Version identity strings that happen to start with an `f`
  (`f4-1`, `f5-1`, `f7-1`, `f9-1`, `f10-1`, `f11-1`) are **contract versions**,
  not phase labels, and must not be renamed.
- Checkboxes are evidence markers, not estimates. Tick an item only when its
  implementation, its regression evidence, and its closest durable
  documentation are committed together. Untick it if that evidence is removed
  or stops passing.
- Blueprint anchors (`FR-*`, `AD-*`, `AINV-*`, `NFR-*`, `EV-*`) keep their
  existing meanings. Cite them; do not redefine them.
- Every track below is executed the same way: one task, one issue, one branch,
  one PR. See [Delivery workflow](#delivery-workflow).

## Where we are

Delivered and covered by tests, documented in `specs/implementation-status.md`
and the notes under `specs/architecture/`:

- the frozen API baseline, the Ash domain backbone, transactional
  writes/audit/jobs, identity/tenancy/RBAC, Gate A/B governance, the model
  layer and structured extraction, documents/connectors/sync,
  retrieval/entity resolution/context, skill readiness and procedural memory,
  portability/packaging/operations, and evaluation/CI/release readiness;
- ten Ash Domains and a 38-Resource durable boundary;
- packaged-pg0 and external-Postgres parity lanes, a production container, and
  fail-closed release checks.

Outstanding, in priority order:

| Track | Theme | Blocking 1.0? |
| --- | --- | --- |
| 1 | Integration surfaces, gateway, and SDKs | Yes |
| 2 | Grounded answering | Yes |
| 3 | Evidence at upstream scale | Yes, for public claims |
| 4 | Repository automation and merge protection | Yes, for autonomous delivery |
| 5 | Retire proof-of-concept vestiges | No, but blocks a clean 1.0 surface |
| 6 | Operations and supply-chain hardening | No |

---

## Track 1 — Integration surfaces, gateway, and SDKs

The single remaining product capability. One Ash action set must reach every
transport without a second implementation. Anchors: `FR-API-11`,
`FR-API-14` to `FR-API-22`, `AD-API-*`, `AINV-1`.

Today only the hand-written Phoenix JSON controller, the `ash_ai` MCP tools,
and the transport-neutral readiness helpers under `sdk/` exist.
`specs/eval/surface-contract-inventory.json` records generated OpenAPI and the
complete SDKs as **unavailable**; keep it honest until each lands.

### 1.1 AshJsonApi and generated OpenAPI

- [ ] Expose ingest, `add_message`, and document ingest as AshJsonApi routes
  backed by the existing Ash actions, with no new write path.
- [ ] Expose `get_context`, `ask`, `search`, `query_knowledge`, and
  `check_readiness` as AshJsonApi read routes.
- [ ] Expose human governance actions (validation queue decisions, scope
  proposal confirmation, consent, peer self-view, contest/redact,
  history/diff) with the human-only policies unchanged.
- [ ] Expose admin policy actions and export/import behind account-admin
  authorization.
- [ ] Expose internal/eval probes only when explicitly enabled by runtime
  configuration; default them off.
- [ ] Generate and commit the OpenAPI document, and add a CI check that fails
  when the committed document drifts from the action definitions.
- [ ] Prove that machine credentials cannot reach any human governance action
  through the new routes.
- [ ] Flip `ash_json_api_openapi` in
  `specs/eval/surface-contract-inventory.json` from `unavailable` to `gated`
  with real evidence paths.

### 1.2 MCP tool completion

- [ ] Audit the shipped `ash_ai` MCP tool set against the public operation set
  in `specs/architecture/free-core-architecture.md` and close the gaps.
- [ ] Keep the machine-credential boundary intact: raw observation submission,
  governed reads, the calling peer's own frozen inline question, and
  clamp-only ask-limit changes. No curator, promotion, gate-administration, or
  bulk actions.
- [ ] Version MCP tool schemas alongside the API surface and record the rule
  in `specs/process/versioning.md`.

### 1.3 Gateway proxy

- [ ] Phoenix proxy for OpenAI-compatible endpoints: capture the exchange as
  raw observations and inject scope-anchored context.
- [ ] Phoenix proxy for Anthropic-compatible endpoints with the same
  semantics.
- [ ] Context injection must use the reasoning-free projection path; it must
  not introduce a second retrieval implementation.
- [ ] Capture writes raw observations only. Extraction stays behind the
  pipeline and Gate A/B.
- [ ] Content-safe telemetry: never log proxied prompts, completions, or
  upstream credentials.

### 1.4 Generated SDKs

- [ ] Generate a TypeScript client from the OpenAPI document, with primitives,
  context injection, auto-forwarding, and the existing readiness helper folded
  in.
- [ ] Generate a Python client with the same surface.
- [ ] Package and version both, tied to the API version rather than to the
  application version.
- [ ] Keep the server authoritative: SDK code must never override a server
  blocker or write knowledge directly.
- [ ] Flip `generated_typescript_sdk` and `generated_python_sdk` in the
  surface inventory to `gated` with evidence.

### 1.5 Surface versioning rules

- [ ] Write down and enforce the versioning rule for API paths, OpenAPI
  schemas, MCP tool schemas, retrieval profiles, prompt versions, and SDK
  packages in `specs/process/versioning.md`.
- [ ] Add a release check that refuses to ship when a surface changed without
  a corresponding version transition and changelog entry.

**Acceptance for Track 1**

- [ ] One action definition drives every transport.
- [ ] Agent credentials cannot call human governance actions through any
  route.
- [ ] No surface is advertised as shipped while the inventory still marks it
  unavailable.

---

## Track 2 — Grounded answering

`ask` currently returns a cited answer over retrieved candidates. The
dialectic loop specified by the blueprint is not implemented. Anchors:
`FR-API-1` to `FR-API-8`, `FR-API-23`, `FR-API-24`, `FR-API-26`.

- [ ] Implement the dialectic loop over the `:thorough` retrieval profile
  using the dialectic model role.
- [ ] Verify every citation against ids actually retrieved in-loop; reject an
  answer that cites anything else.
- [ ] Feed cross-strategy disagreement (already computed before fusion) into
  the loop as an explicit signal, `query_dependent_empty` included: a run no
  query-reading strategy answered is abstention evidence, not a thin answer.
- [ ] Handle stale and `needs_revalidation` knowledge explicitly rather than
  answering from it silently.
- [ ] Abstain when the relevant knowledge is absent, held, or stale, and say
  which.
- [ ] Keep `get_context` reasoning-free; the loop belongs to `ask` only.
- [ ] Add deterministic cassette tests for citation verification and for each
  abstention reason.

**Acceptance for Track 2**

- [ ] `ask` cannot cite knowledge that was not retrieved in-loop.
- [ ] `ask` cannot invent an answer when the relevant knowledge is absent or
  stale.

---

## Track 3 — Evidence at upstream scale

The evaluation framework, report contract, thresholds, and CI lanes are done.
The committed fixtures are deliberately smoke-scale. Anchors: `AD-EVAL-3`,
`EV-STRAT-1`, `NFR-1`, `NFR-11`.

- [ ] Run upstream-scale LoCoMo through `mix memhouse.eval.release` and
  retain the `f11-1` report as release evidence.
- [ ] Run upstream-scale LongMemEval and retain the report.
- [ ] Run upstream-scale ConvoMem and retain the report.
- [ ] Run the upstream-scale BEAM degradation curve and retain the report.
- [ ] Run an independent-family live-model judge (different provider and model
  family from the dialectic answer role) and retain the report.
- [ ] Tune fusion weights using the held-out split only, and cite the tuning
  report in the PR that changes them.
- [ ] Publish comparative claims only with application version, retrieval
  profile version, all four model-role versions, dataset id/SHA-256/split,
  deadline setting, date, judge identity, strategy override, and run limits.
- [ ] Extend deterministic coverage into applied dream-time deductions and
  projection builds.
- [ ] Extend provider-compatibility coverage beyond the current cassette set.

**Acceptance for Track 3**

- [ ] No public quality number lacks its full provenance tuple.
- [ ] The 2026-07-27 minimal reports stay labelled as the historical baseline
  and are never relabelled as current evidence.

---

## Track 4 — Repository automation and merge protection

This track replaces `l3-automation-flow.md`, `main-branch-ruleset.md`, and
`manual-automation-setup.md`. Every item here is a **GitHub-side setting** that
requires a maintainer with repository or organization permissions. An agent
must not assume any of it and must not describe a workflow file as proof that
`main` is protected.

### Already verified in place on 2026-07-28 — do not redo

The twelve execution and risk labels exist; `.github/CODEOWNERS`, the three
issue templates, and the PR template are committed; the `CI`, `Nightly
evaluation`, and `Release readiness` workflows are committed and `CI` has
reported green on `main`; repository Actions access is restricted to
GitHub-owned actions plus `erlef/setup-beam@*`; the default workflow token is
read-only and cannot approve pull requests; a ruleset named `main` is active
and already requires a pull request with one approving review, dismisses stale
approvals on push, requires Code Owner review, and blocks deletions and force
pushes.

### 4.1 Correct the existing branch ruleset

The active ruleset targets `~ALL` refs, not the default branch. That blocks
direct pushes to feature branches and blocks deleting merged branches, which
is not the intended workflow.

- [ ] Retarget the `main` ruleset from `~ALL` to the default branch only.
- [ ] Enable **require conversation resolution before merging**
  (`required_review_thread_resolution`), currently off.
- [ ] Enable **require branches to be up to date before merging** until a
  merge queue is justified by PR volume.
- [ ] Review the bypass actor. A team currently holds `always` bypass; narrow
  it to repository administrators, document it as emergency-only, or remove
  it.
- [ ] Re-verify with one low-risk PR that the intended rules fire and that
  ordinary feature-branch pushes are no longer blocked.

### 4.2 Require the CI checks that now report

All four job names have reported successfully on `main`, so GitHub can require
them. Names must match exactly.

- [ ] Require `Deterministic gate (external Postgres)`.
- [ ] Require `Dialyzer`.
- [ ] Require `Deterministic gate (packaged pg0)`.
- [ ] Require `Release and container builds`.
- [ ] Confirm the required set matches
  `specs/process/release-checklist.md`; update both together if a job is
  renamed.
- [ ] Never require a check that has not recently reported — it silently
  blocks all merges.

Reference:

```bash
gh api repos/memhousehq/memhouse/rulesets/<ruleset-id>
gh api repos/memhousehq/memhouse/actions/permissions
```

### 4.3 Secrets, variables, and environments

Nothing is configured today: zero secrets, zero variables, zero environments.
The nightly live-model evaluation lane therefore cannot run.

- [ ] Create a protected environment for release and publishing credentials.
- [ ] Add `OPENROUTER_API_KEY` as an environment secret, never exposed to
  pull requests from forks.
- [ ] Add the `MEMHOUSE_EVAL_JUDGE_MODEL` repository variable, set to a
  provider and model family different from `MEMHOUSE_MODEL_ASK`.
- [ ] Add `HEX_API_KEY` only when a package publish task exists, scoped to the
  release environment.
- [x] Publish tagged containers to GHCR with the built-in `GITHUB_TOKEN` and
  job-scoped `packages: write`; do not add a long-lived `GHCR_TOKEN`.
- [ ] Keep separate provider projects for development, evaluation, and
  release, with least-privilege keys and a rotation plan.
- [ ] Document every external service in `specs/security/` or `specs/eval/`
  before a workflow depends on it.

### 4.4 Repository security settings

Secret scanning, push protection, and Dependabot security updates are all
disabled on a public repository where they are free.

- [ ] Enable secret scanning.
- [ ] Enable secret scanning push protection.
- [ ] Enable Dependabot security updates.
- [ ] Decide whether `delete_branch_on_merge` should be on (currently off).

### 4.5 Codex and agent wiring

- [ ] Connect Codex Cloud to the `memhousehq` organization with the minimum
  repository access MemHouse needs.
- [ ] Start with manual `@codex review` on pull requests; enable automatic
  review only after several manual reviews produce low-noise feedback.
- [ ] Keep agent implementation limited to issues labelled `ai-ready`.
- [ ] Add GitHub-side prompt files under `.github/codex/prompts/` only once a
  task defines the prompt name, its trigger, the permissions it receives,
  whether it may write comments or commits, and how a human reviews its
  output. Local helper prompts stay in `.codex/prompts/`.

### 4.6 Label hygiene

- [ ] Fix the `backend-parity-required` label description. It still reads
  "SQLite and Postgres parity evidence required"; ADR-0003 makes every
  deployment mode Postgres, so it must read "packaged pg0 and external
  Postgres parity evidence required".

```bash
gh label edit backend-parity-required \
  --description "Packaged pg0 and external Postgres parity evidence required"
```

### 4.7 Process-channel automation

Do not build this until the GitHub issue and PR flow is stable.

- [ ] Choose the process channel and create its bot credential.
- [ ] Emit only: issue marked `ai-ready`, PR opened, CI failed, PR ready for
  human review, PR merged, manual setup blocked.
- [ ] Never send secrets, customer data, model keys, restricted knowledge, or
  personal data to the channel.

**Acceptance for Track 4**

- [ ] `main` cannot be updated without a reviewed pull request and the four
  required checks.
- [ ] Every required check name matches a job that has actually reported.
- [ ] Bypass ability is limited, documented, and emergency-only.
- [ ] Secrets exist only where a workflow needs them.

---

## Track 5 — Retire proof-of-concept vestiges

Naming left over from the proof-of-concept stage still appears in code,
configuration, and test fixtures. Each item is a deliberate contract decision,
not a cosmetic rename: changing a default or an identity string is a versioned
behaviour change that needs a changelog entry and updated contract evidence.

- [ ] Replace the `/poc` default scope path in `lib/memhouse/memory.ex` with
  a neutral default, update the baseline contract tests and eval fixtures, and
  version the change in `CHANGELOG.md`.
- [ ] Rename `test/memhouse/poc_contract_test.exs` and
  `test/fixtures/eval/poc-contract-baseline.json` to baseline-contract names,
  and decide explicitly whether the `contract_version` string stays `poc-0` as
  frozen history or advances to a beta identity.
- [ ] Rename the `poc-baseline` default of `MEMHOUSE_RETRIEVAL_VARIANT` in
  `config/runtime.exs`, noting that the label is an experiment-comparison key
  and that older recorded experiments keep the old value.
- [ ] Rename the `eval-poc` default account and the `memhouse-poc-smoke`
  benchmark label in `lib/mix/tasks/memhouse.eval.smoke.ex`.
- [ ] Retire `MemHouse.Memory` as a facade once every surface calls Ash
  actions directly, per
  `specs/architecture/free-core-architecture.md`.
- [ ] Leave historical artefacts alone and say so in the PR:
  `priv/repo/migrations/20260727101000_create_memory_poc.exs`, the
  `pipeline_version` default `poc-0` baked into old migrations and resource
  snapshots, the `legacy_poc` backfill value, and the `poc-0` profile version
  recorded in `specs/eval/results/`. These are immutable evidence.

**Acceptance for Track 5**

- [ ] No default value, public identifier, or user-visible string implies a
  proof of concept.
- [ ] Every historical `poc-0` reference that remains is documented as frozen
  evidence rather than current behaviour.

---

## Track 6 — Operations and supply-chain hardening

- [ ] Decide and document how ONNX and tokenizer artefacts reach an operator.
  They are operator-supplied today, which makes the default embedding role a
  manual setup step.
- [ ] Document and test the pg0 version-upgrade path, including a data
  directory that survives an application upgrade.
- [ ] Add an Account archive administration surface, or state explicitly that
  the Mix tasks are the supported interface for the beta.
- [ ] Add connector administration to the governance UI, or state explicitly
  that connectors are configuration-only for the beta.
- [ ] Confirm the redacted production-log metadata allowlist against the
  shipped surfaces, and add a test that fails when a new field escapes it.

---

## Delivery workflow

One task, one issue, one branch, one pull request. This replaces
`l3-automation-flow.md`.

- [ ] A human scopes exactly one implementation issue and labels it
  `ai-ready` only after its scope, acceptance criteria, blueprint anchors,
  risk class, and tests are clear.
- [ ] The agent reads `AGENTS.md`, the relevant blueprint anchors, and the
  closest architecture note before editing.
- [ ] The agent implements only that issue's acceptance criteria. No
  opportunistic cleanup, no roadmap creep.
- [ ] The agent opens one focused pull request with real check evidence and
  links the issue.
- [ ] A human reviews and remains the merge gate.
- [ ] The next task starts only after merge, from the updated `main`.

Every issue carries exactly one execution-control label — `ai-ready`,
`ai-assisted`, `ai-review-only`, or `human-only` — plus any applicable risk
label: `needs-adr`, `security-sensitive`, `tenancy-sensitive`,
`audit-sensitive`, `pipeline-sensitive`, `backend-parity-required`,
`eval-required`, `good-first-agent-task`.

Licensing boundaries, entitlement semantics, and moving a feature across the
free/enterprise line remain human-only decisions under ADR-0002.

## Definition of done for 1.0

The beta becomes 1.0 when all of the following hold, each with committed
evidence:

1. [ ] A fresh user installs and runs MemHouse single-node without Docker or
   a preinstalled Postgres on a supported platform.
2. [ ] All public writes persist raw observations only; every knowledge write
   comes from the pipeline through Gate A/B.
3. [ ] Account and scope isolation are enforced at the Phoenix edge, in Ash
   policies, and in PostgreSQL RLS.
4. [ ] `get_context`, `ask`, `search`, `query_knowledge`, and
   `check_readiness` work through HTTP, MCP where applicable, the generated
   SDKs, and the gateway.
5. [ ] `get_context` is reasoning-free and projection-backed.
6. [ ] `ask` is grounded, cited, and able to abstain.
7. [ ] The validation queue, peer self-view, revalidation, contest/redact,
   erasure, audit, and history/diff flows are usable.
8. [ ] Documents are dual-ingested into chunks/embeddings and governed
   knowledge.
9. [ ] Export/import round-trips an Account into a fresh instance and rebuilds
   derived caches.
10. [ ] The deterministic PR gate and the release/nightly evaluation lanes
    provide real, current evidence for correctness, quality, latency, token
    efficiency, and backend parity.
11. [ ] `main` is protected by required reviews and the four required checks.
12. [ ] No proof-of-concept naming survives in a public surface.

## Sequencing rules

- Keep each implementation issue tied to one track and one acceptance slice.
- Do not add enterprise-only code to complete a free-core feature.
- Do not merge a feature whose public surface bypasses Ash actions.
- Do not publish a quality number without its full provenance tuple.
- Do not turn a frontier-tracked measure into a release gate without an
  explicit, reviewed threshold change.
- Prefer inert, reviewable documentation over speculative automation until the
  matching repository settings exist.

## References

- Product and architecture anchors: `specs/memory-system-functional-requirements.md`,
  `specs/memory-system-architecture-and-nfr.md`,
  `specs/memory-system-product-blueprint.md`,
  `specs/memory-system-evaluation-framework.md`.
- Target architecture: `specs/architecture/free-core-architecture.md`.
- What runs today: `specs/implementation-status.md`.
- Operator procedures: `docs/operations/`.
- GitHub labels: https://docs.github.com/issues/using-labels-and-milestones-to-track-work/managing-labels
- Repository rulesets: https://docs.github.com/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets
- Codex code review in GitHub: https://developers.openai.com/codex/integrations/github
