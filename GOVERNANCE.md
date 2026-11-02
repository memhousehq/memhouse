<!-- SPDX-License-Identifier: Apache-2.0 -->
# Governance

How decisions about MemHouse are made, and by whom.

## Roles

| Role | Who | Can |
|---|---|---|
| Contributor | anyone who opens an issue or a pull request | propose changes; every commit is signed off under the [DCO](CONTRIBUTING.md#developer-certificate-of-origin-dco) |
| Maintainer | listed in [`CODEOWNERS`](CODEOWNERS) and the `maintainers` team | review and merge, triage, run the paid benchmark workflow, cut releases |
| Lead maintainer | the founder of the MemHouse project | final say when maintainers disagree; appoints and removes maintainers; owns the roadmap and the trademarks |

The project starts with a single lead maintainer. Maintainers are added from contributors who
have made sustained, high-quality contributions and reviews; the lead maintainer proposes them and
the existing maintainers agree.

## How decisions are made

- **Day to day:** a pull request merges when a maintainer approves it, the required checks pass
  (the T1 guard among them), and it follows [CONTRIBUTING.md](CONTRIBUTING.md). Owners in
  `CODEOWNERS` must approve changes to safety-critical paths (the write gate, the store, the
  governance suite, the benchmark baselines, the dependency policy).
- **Design:** changes to the public API, the Memory Format, the policy model or the security
  baseline start as an issue with a short design note. Lasting decisions are written down as
  [decision records](docs/adr/README.md).
- **Roadmap:** the [roadmap](docs/roadmap.md) is public. It is organised as numbered goals, and the
  maintainers keep it current. Proposals for new goals are welcome as issues.
- **Compatibility:** the [API stability policy](docs/api-stability.md) binds every decision: no
  breaking change within a major version, 12 months of deprecation.
- **Disagreement:** discussed in the issue or pull request first. If maintainers can't agree, the
  lead maintainer decides and records why.

## Quality gates that no decision overrides

- The governance suite stays at 100% (redaction, quarantine, isolation, deletion, audit, access).
- The benchmark guard must not regress against `bench/baselines.json`; baselines are only raised
  after a deliberate, reviewed improvement.
- The security baseline ([docs/security/baseline.md](docs/security/baseline.md)) can't be made
  configurable off.

## Licences

Code is Apache-2.0 and documentation is CC BY 4.0. See ADR 0001.

## Security, conduct and trademarks

- Vulnerabilities: [SECURITY.md](SECURITY.md) (privately, never in public issues).
- Conduct: [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md); maintainers enforce it.
- Name and logo: [TRADEMARKS.md](TRADEMARKS.md).

## Changing this document

By pull request, approved by the lead maintainer.
