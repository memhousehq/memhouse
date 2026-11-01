<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# ADR 0001 — Licences of the product repository

| Field | Value |
|---|---|
| Status | **Accepted for development; final confirmation by counsel before publication (roadmap G09)** |
| Date | 1 November 2026 |
| Goal | G02 |

## Decision

| Path | Licence | SPDX identifier |
|---|---|---|
| everything except `docs/` | Apache License 2.0 | `Apache-2.0` |
| `docs/` | Creative Commons Attribution 4.0 International | `CC-BY-4.0` |

Every source and documentation file carries its identifier; `cargo xtask spdx` enforces the
path rule. Third-party dependencies must be permissively licensed (`deny.toml`); copyleft needs a
recorded exception.

## Why

- **Apache-2.0 for the code**: the widest adoption among companies that embed or self-host
  infrastructure, an explicit patent grant, and compatibility with the permissive ecosystem the
  code depends on. It is what `Cargo.toml` has declared since the first commit.
- **CC BY 4.0 for documentation**: lets others reuse and translate the docs with attribution.

## Alternative still open

AGPLv3 for the core. It would deter hosted forks but also some
enterprise adopters. The founder confirms the choice with counsel before the first public push;
if it changes, `LICENSE`, the SPDX identifiers (`cargo xtask spdx --fix` after changing the rule in
`xtask/src/spdx.rs`) and `deny.toml` change together, while the history is still private.
