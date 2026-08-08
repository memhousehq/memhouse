<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# Versioning And Changelog Policy

MemHouse uses Semantic Versioning: `MAJOR.MINOR.PATCH`, optionally followed by
a prerelease suffix. The application version in `mix.exs` is authoritative.
Release tags use the exact form `vMAJOR.MINOR.PATCH`.

Before 1.0:

- increment PATCH for compatible fixes that do not version a public contract;
- increment MINOR for new behavior or an intentional pre-1.0 contract
  transition;
- reserve MAJOR for a deliberate stability milestone or an explicitly reviewed
  incompatible release policy.

Protocol identities such as `f4-1`, `f5-1`, `f7-1`, `f9-1`, `f10-1`, and
`f11-1` do not replace the application version. They identify a particular
behavior/report schema; their `f`-prefixes are historical version tags and no
longer name a roadmap phase. Change one only when its contract changes, and
record the transition in `CHANGELOG.md`, the closest architecture note, tests,
and fixtures.

`CHANGELOG.md` follows a Keep-a-Changelog layout with `Unreleased` at the top.
Each release moves its entries under a dated version heading and cites the
blueprint/architecture anchors that make the change reviewable. Do not publish
a tag whose version, changelog, evaluation report, and built artifact disagree.
