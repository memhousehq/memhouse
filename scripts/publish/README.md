<!-- SPDX-License-Identifier: Apache-2.0 -->
# Publication scripts (roadmap G09)

Used once, to publish this repository as `memhousehq/memhouse` (the Elixir 0.x implementation is
archived as `memhousehq/archive-memhouse`) and to split out `memory-format`. They read
their settings from `publish.env` (copy `publish.env.example`; the file is not committed).

| Step | Command | Changes |
|---|---|---|
| 1. Build the public copies | `scripts/publish/prepare.sh` | creates `../memhouse-publish/memhouse` and `../memhouse-publish/memory-format`; this repository is untouched |
| 2. Check the copy | `git clone ../memhouse-publish/memhouse /tmp/m && cd /tmp/m && cargo xtask ci` | nothing |
| 3. Rehearse hosted CI | `STEP=rehearse DRY_RUN=0 scripts/publish/forge-setup.sh` | a temporary private repository, deleted afterwards |
| 4. Create and push, private | `STEP=publish DRY_RUN=0 scripts/publish/forge-setup.sh` | creates both repositories as private, pushes `main`, applies settings and labels; CI runs |
| 5. Go public | `STEP=public DRY_RUN=0 scripts/publish/forge-setup.sh` | makes both repositories public, then turns on the security features and rulesets (on the free plan they need a public repository) |

`prepare.sh` removes every path in `private-paths.txt` from every commit. Paths in
`republish-paths.txt` are removed too, then added back as they are now in one last commit, because
their earlier versions were drafts with private planning material. It maps every identity to
`PUBLIC_NAME <PUBLIC_EMAIL>`, and replaces the private addresses and the terms listed in the
`PRIVATE_TERMS` file (kept outside this repository) in file contents and commit messages. With
`HISTORY=fresh` it builds one commit with the current tree instead. It then fails unless no
private path, address or term remains and the full-history secret scan is clean.

`forge-setup.sh` targets GitHub through the `gh` CLI and prints what it would do unless
`DRY_RUN=0`. Read the dry run first.
