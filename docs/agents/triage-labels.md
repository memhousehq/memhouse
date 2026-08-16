# Triage labels

The triage skill uses these labels. Each label has one meaning.

| Label | Meaning |
| --- | --- |
| `needs-triage` | The request has not been classified. |
| `needs-info` | Work cannot be scoped because required information is missing. |
| `ready-for-agent` | Scope and acceptance criteria are ready for agent implementation. |
| `ready-for-human` | Agent work is complete or needs a human decision or review. |
| `wontfix` | The repository will not take this request. |

These labels supplement the existing execution-control and risk labels. Keep
those labels unchanged:

- Execution control: `ai-ready`, `ai-assisted`, `ai-review-only`, `human-only`.
- Risk and task signals: `needs-adr`, `security-sensitive`,
  `tenancy-sensitive`, `audit-sensitive`, `pipeline-sensitive`,
  `backend-parity-required`, `eval-required`, `good-first-agent-task`.

Use exactly one execution-control label. Add risk labels only when they apply.
Do not create equivalent labels with different names.
