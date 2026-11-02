<!-- SPDX-License-Identifier: Apache-2.0 -->
# Publication scripts (roadmap G09)

Used once, to publish this repository and split out `memory-format`. They read their settings
from `publish.env` (copy `publish.env.example`; the file is not committed).

| Step | Command | Changes |
|---|---|---|
| 1. Build the public copies | `scripts/publish/prepare.sh` | creates `../memhouse-publish/memhouse` and `../memhouse-publish/memory-format`; this repository is untouched |
| 2. Check the copy | `git clone ../memhouse-publish/memhouse /tmp/m && cd /tmp/m && cargo xtask ci` | nothing |
| 3. Create, configure, push (private) | `DRY_RUN=0 scripts/publish/forge-setup.sh` | the forge: repositories, team, security settings, rulesets, environment, labels; pushes `main` |
| 4. Go public | `DRY_RUN=0 PUBLIC=1 scripts/publish/forge-setup.sh` | flips both repositories to public |

`prepare.sh` removes every path in `private-paths.txt` from every commit, maps every identity
to `PUBLIC_NAME <PUBLIC_EMAIL>`, and replaces the private addresses in file contents and commit
messages. With `HISTORY=fresh` it builds one commit with the current tree instead. It then fails
unless no private path or address remains and the full-history secret scan is clean. It also
splits `memory-format/` and `docs/memory-format.md` into a repository of their own, history
included.

`forge-setup.sh` targets GitHub through the `gh` CLI and prints what it would do unless
`DRY_RUN=0`. It hasn't been run against the live API yet, so read the dry run first.
