<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# The Lite profile

Lite is MemHouse without a database server: the same binary and the same engine, with
everything stored in **one SQLite file**. There is nothing to install and no Docker. It is meant
for one machine and one process: a developer's laptop, a single agent host, a small service.

The other profile, Standard, is the same engine on Postgres. Both expose the same REST API, MCP
tools and command line, with the same behaviour: one scenario is run through all three ways in
on each profile, and the governance suite runs on both ([conformance.md](conformance.md)).

```bash
memhouse up --lite                 # writes the config, creates the file, downloads the embedding model
memhouse connect claude-code       # as on Standard
memhouse serve                     # REST, MCP over HTTP, the Memory Browser
```

`memhouse up --lite` only sets up a new installation. It writes `config.toml` and the database
file `memhouse.db` under `MEMHOUSE_HOME` (`~/.memhouse` by default), generates the bootstrap
API key, and sets `[embedding] sessions = 1`.

## When to choose Lite, and when not

| | Lite | Standard |
|---|---|---|
| Store | one SQLite file | Postgres 16+ with pgvector |
| To install | nothing | Postgres, or Docker for `memhouse up` |
| Writers | one process at a time (a command-line tool beside the server waits its turn) | many |
| Size it is measured at | 100,000 memories, 10,000 per subject | see [benchmarks.md](benchmarks.md) |
| Keyword search | one English-stemming index for every record | a text-search configuration per language |
| Backup | `memhouse backup` | `pg_dump` ([operations.md](operations.md#backup-and-restore)) |

Choose Standard when several processes or hosts write, when subjects grow well past 10,000
memories, or when you need keyword stemming in languages other than English. `memhouse migrate` moves a
Lite installation to Standard, or back, with everything in it
([operations.md](operations.md#moving-between-profiles)).

## How it works

The design is recorded in [ADR 0002](adr/0002-lite-embedded-store.md) and
[ADR 0003](adr/0003-vector-storage-format.md).

- **One file, the same logical schema.** The tables and columns are those of
  [schema.md](schema.md); only physical types differ (timestamps are integer microseconds, ids
  and JSON are text).
- **Keyword search** is SQLite's FTS5 with BM25. The subject is a token inside every query, so
  a search never returns or ranks another subject's rows. The BM25 statistics (how common a
  word is, the average length) are those of the whole table, as FTS5 keeps them.
- **Vector search is exact.** Vectors are stored at half precision (2 bytes per dimension) and
  every vector of the subject is scored in process on each recall. There is no approximate
  index. The half-precision scan returns the same top 10 as full precision; two neighbours
  whose similarities differ by less than half precision can tell apart (about 0.001) may come
  back in either order. A test in the store and a governance check compare against brute force.
- **Jobs are tables in the same file.** A write is acknowledged once its proposal is in the
  intake queue and flushed to the device. The pipeline's work after that (the gate, the insert,
  extraction bookkeeping) commits without waiting for the device: if power fails, it is run again
  from the queue, exactly once. Deletions, policies and keys are always flushed before they
  are acknowledged.
- **The security baseline is the engine's**, so it is the same as on Standard: authentication,
  the access check on every call, redaction, the write gate and injection screen, the audit
  chain, deletion across derived data.

## Embedded: Python and Node

Lite also runs inside your own process, with no server and no socket: `memhouse_lite` for
Python and `@memhouse/lite` for Node.js ([bindings/python](../bindings/python/README.md),
[bindings/node](../bindings/node/README.md)).

The library is not a second API. It embeds the router that `memhouse serve` runs and passes
each request to it in process, so what you call is the REST API of [api.md](api.md), and what
runs on the way is what runs on the server: the authentication middleware, the access check, the
write gate and injection screen, redaction, the audit trail. It also starts what a served
deployment runs beside the router: the write pipeline's workers, enrichment when it is
configured, and the hourly retention pass. The SDKs use it as a transport in place of HTTP
([sdk.md](sdk.md)).

```python
from memhouse_lite import Lite

with Lite("/home/ada/.memhouse/memhouse.db") as lite:
    status, body = lite.request("POST", "/v1/recall", '{"subject": "user:ada", "query": "tea or coffee?"}')
```

```js
const { Lite } = require('@memhouse/lite')

async function main() {
  const lite = await Lite.open({ path: '/home/ada/.memhouse/memhouse.db' })
  const { status, body } = await lite.request('POST', '/v1/recall', '{"subject": "user:ada", "query": "tea or coffee?"}')
  await lite.close()
}

main()
```

- **What to open.** A file path opens (or creates) that SQLite file with the defaults
  `memhouse up --lite` writes. A `config.toml` (`config=`) is read as every command reads it.
  With neither, the installation's configuration under `MEMHOUSE_HOME` is used.
- **Authentication is not skipped.** Every request is verified by the same middleware. The
  embedding process holds the configuration and so the bootstrap key: a request that carries
  no credential is sent with that key, as a local client reading the same file would send it,
  and runs as `admin:bootstrap`. For a bare file path there is no configuration file, so a
  random key is made for the process and kept in memory only. A request that names a
  credential is verified as it stands, and a wrong one is refused with 401 and audited
  (`auth.failed`). Code that acts for an agent or a user passes that principal's key or token
  and is held to its permissions. A header is given once: two names that differ only in
  letter case (`Authorization` and `authorization`) are an error, and nothing is sent.
- **One writer.** The embedding process is the one process that writes the file; do not run
  `memhouse serve` on the same file at the same time and expect both to keep up.
- **Close it.** `close()` stops the workers (it can take about a second) and releases the
  file; in Python it also ends the native threads the deployment ran on. It can be called more
  than once, also at the same time: every call returns when the workers have stopped.

**Building.** Nothing is published yet: wheels and npm packages for each platform are release
work, planned with the packaging goal. Until then the libraries are built from a checkout, and
have been built and tested on macOS (Apple silicon) only:

```bash
(cd bindings/python && ./test.sh && uvx maturin build)         # a wheel in target/wheels/ (CPython 3.9+, stable ABI)
(cd bindings/node && pnpm install && pnpm build && pnpm test)  # memhouse-lite.<platform>.node beside index.js
```

Both need a Rust toolchain; Python needs [uv](https://docs.astral.sh/uv/), Node needs pnpm and,
to build, Node.js 20.17+, 22.13+ or 24+ (the built addon runs on Node.js 18 and later).

## The database file

- The file is created readable and writable by its owner only (mode 0600).
- **Its directory must be yours alone.** On Linux and macOS the store refuses to open a database in a directory
  that another user owns or that others can write to, and says how to fix it (`chmod 700`).
  SQLite trusts the journal files it finds beside a database, so nobody else may be able to
  put one there. Keep it under directories that only you can write to as well: the check looks
  at the database's own directory, not at its parents. For the same reason, do not open a
  database directory you were given by someone you do not trust, and on Windows (where there
  is no such check) set the directory's access yourself: the bundled SQLite has a known flaw in reading a crafted journal
  file (RUSTSEC-2026-0459; the fixed version cannot be used yet, see `deny.toml`).
- A second process on the same file waits up to 10 seconds for the writer.
- Erased content can remain in the file's free pages until SQLite reuses them. Old backups
  and pre-upgrade copies keep what was erased after they were made (see below).

## Upgrades

On start, a database written by an older version is upgraded in place. Before it changes
anything, the store writes a copy of the file as it was, next to it:
`memhouse.db.before-v<new schema version>-<timestamp>`. Delete the copy once you are satisfied
with the upgrade; it holds everything the database held, including anything you erase later.
A database written by a newer version than the binary is refused and left untouched.

## Backup and restore

```bash
memhouse backup /path/to/backup-2026-11-21        # while the server runs
memhouse restore /path/to/backup-2026-11-21       # into an installation without a database: see the ledger below
memhouse restore /path/to/backup-2026-11-21 --force   # over the current database
```

A backup directory (created for its owner only) holds:

| File | What |
|---|---|
| `memhouse.db` | a consistent snapshot of the database, taken while it may be in use |
| `export-<tenant>.jsonl` | the canonical export of each tenant ([memory-format.md](memory-format.md)), read from that same snapshot |
| `deletion-ledger.jsonl` | every deletion and erasure up to the backup |
| `manifest.json` | when, schema version, embedder, counts, and the SHA-256 of each file |

**A restore given the current deletion ledger never brings back what was deleted after the
backup.** Restoring over the current database (`--force`) first reads the current deletion
ledger and re-applies every deletion and erasure made since the snapshot: the record (also
where the snapshot holds it still queued), its derived facts, a whole subject, a whole tenant.
Where there is no current database (another machine, a lost file), the restore has no ledger
of its own: export the ledger from the live installation with
`memhouse backup <dir> --ledger-only` and pass it with `--ledger <file>`. Without it, the
restore warns that what was deleted after the backup is back. A re-applied erasure of a subject
or tenant removes everything the snapshot holds of it: the erasure was made after the backup, so
all of that was written before it, whatever time a record carries. That holds for a backup of
the same installation. A backup of a copy that went on being written elsewhere loses what the
copy wrote about an erased subject, too: the restore cannot tell it from the erased data, and
removes it. Each re-applied
deletion is audited (`deletion.reapply`), with `backup.create` and `backup.restore` for the two
commands.

Things to know:

- Stop `memhouse serve` before a restore; the command cannot detect a running server.
- The restore checks the snapshot against the manifest's SHA-256 and refuses a changed one.
- Audit events written between the backup and the restore go with the replaced database; the
  re-applied deletions are recorded with their original time and actor.
- **Backups keep erased data.** A backup made before an erasure still contains the erased
  records. Delete backups older than your retention allows; nothing prunes them for you.

## Footprint and performance

Measured through the engine (gate, intake queue, audit, fusion) on a laptop, with
`memhouse bench footprint` ([benchmarks.md](benchmarks.md#lite-profile)). The requirement
figures are for the store and the binary; a local embedding model has its own budget.

| Requirement | Target | Measured at 100,000 memories |
|---|---|---|
| Binary, without models | ≤ 100 MB | 60.5 MB |
| Resident memory | ≤ 256 MB | 52 MB |
| Recall p95 on a 10,000-memory subject | ≤ 50 ms | 35.5 ms |
| Write acknowledgement p95 | ≤ 20 ms | 3.8 ms, one write at a time |
| A gated memory is recallable | ≤ 2 s | 97 ms p95 |

- **Bursts of writes** are acknowledged more slowly (123 ms at p95 for 200 back-to-back writes
  on a large subject): Lite has one writer.
- **Local model** (the default): a command that loads it peaked at about 850 MB of resident
  memory on a macOS laptop (21 November 2026, one session, which is why Lite sets
  `[embedding] sessions = 1`; with the automatic four sessions it was 1.6 GB). The technology
  spike had measured 394 MB with one session; the difference is not explained yet.
- **Remote embedding** (`[embedding] provider = "openai"`, any OpenAI-compatible endpoint): no
  model is loaded, and the process stays within the store's footprint.

## Model files

The built-in local models are pinned to an exact revision on the model hub, and every file's
SHA-256 is checked when it is downloaded and again when a process first loads it. A file that
does not match is refused by name and never enters the cache. `memhouse doctor` shows the pin.
Another model works with a warning that it is not pinned; `[embedding] revision` and
`[embedding] sha256` pin it ([configuration.md](configuration.md#embedding)).
