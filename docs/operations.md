<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# Operations guide

This guide covers running MemHouse on a laptop, on a server and in the cloud: deployment, sizing,
backups, upgrades, enrichment workers, monitoring and troubleshooting.

## Contents

- [Deployment shapes](#deployment-shapes)
- [Laptop](#laptop)
- [Server (systemd)](#server-systemd)
- [Container image](#container-image)
- [Cloud with managed Postgres](#cloud-with-managed-postgres)
- [TLS to the database](#tls-to-the-database)
- [Reverse proxy and TLS](#reverse-proxy-and-tls)
- [Sizing](#sizing)
- [Enrichment workers](#enrichment-workers)
- [Write pipeline](#write-pipeline)
- [Backup and restore](#backup-and-restore)
- [Row-level security](#row-level-security)
- [Monthly partitions for episodic memory](#monthly-partitions-for-episodic-memory)
- [SIEM export](#siem-export)
- [Moving between profiles](#moving-between-profiles)
- [Upgrades](#upgrades)
- [Changing the embedding model](#changing-the-embedding-model)
- [Languages](#languages)
- [Monitoring](#monitoring)
- [Traces, metrics and recall explanations](#traces-metrics-and-recall-explanations)
- [Routine maintenance](#routine-maintenance)
- [Troubleshooting](#troubleshooting)

## Deployment shapes

MemHouse is one binary. The only state it keeps is in Postgres; the model files on disk are a
cache that is downloaded again if lost. Every MemHouse process is stateless, so you can run as many
as you like against one database.

```mermaid
flowchart TB
    subgraph L["Laptop: memhouse up"]
        A1[agent] -- stdio MCP --> B1[memhouse mcp]
        B1 --> P1[(Docker: pgvector/pgvector:pg17<br/>127.0.0.1:54329)]
    end
    subgraph S["Server: systemd"]
        C2[clients] -- HTTPS --> N2[nginx / Caddy] --> B2[memhouse serve<br/>127.0.0.1:7077]
        B2 --> P2[(Postgres 16+ with pgvector)]
    end
    subgraph C["Cloud"]
        C3[clients] -- HTTPS --> LB[load balancer] --> B3a[memhouse serve] & B3b[memhouse serve]
        B3a & B3b --> P3[(RDS / Cloud SQL / Azure DB<br/>with pgvector)]
        W3[memhouse serve<br/>enrichment workers] --> P3
        W3 -- HTTPS --> LLM[(LLM endpoint)]
    end
```

| Shape | Use it when | Postgres |
|---|---|---|
| Laptop | one person, local agents | `memhouse up` (Docker) |
| Server | a team, or an on-prem regulated deployment | your own Postgres 16+ with pgvector |
| Cloud | several services and high availability | a managed Postgres with pgvector |

## Laptop

```bash
memhouse up --template coding    # Postgres + pgvector in Docker, config, model download (~15 s)
memhouse connect claude-code
memhouse doctor
```

- The data lives in the Docker volume `memhouse-pgdata` (`<name>-data` if you used `--name`).
- `memhouse down` stops the container and keeps the volume. `memhouse up` starts it again.
- Removing everything, which **deletes all memories**, takes two commands:

  ```bash
  docker rm -f memhouse-pg
  ```

  ```bash
  docker volume rm memhouse-pgdata
  ```

## Server (systemd)

1. **Postgres.** Install Postgres 16 or newer and the pgvector package (`postgresql-17-pgvector` on
   Debian/Ubuntu), then create a database and user.

   ```sql
   CREATE USER memhouse WITH PASSWORD 'change-me';
   CREATE DATABASE memhouse OWNER memhouse;
   \c memhouse
   CREATE EXTENSION IF NOT EXISTS vector;   -- as a superuser, so the app user needn't be one
   ```

2. **Binary and config.**

   ```bash
   cargo build --release -p memhouse-cli
   sudo install -m 755 target/release/memhouse /usr/local/bin/
   sudo useradd --system --home /var/lib/memhouse --create-home memhouse
   sudo -u memhouse MEMHOUSE_HOME=/var/lib/memhouse \
     memhouse init --database-url postgres://memhouse:change-me@127.0.0.1:5432/memhouse --template support
   ```

   `init` writes `/var/lib/memhouse/config.toml` (mode 0600) with a generated API key, migrates
   the schema and downloads the embedding model into `/var/lib/memhouse/models`.

3. **Service.** Save this as `/etc/systemd/system/memhouse.service`:

   ```ini
   [Unit]
   Description=MemHouse memory server
   After=network-online.target postgresql.service
   Wants=network-online.target

   [Service]
   User=memhouse
   Environment=MEMHOUSE_HOME=/var/lib/memhouse
   Environment=RUST_LOG=info
   # Only needed with [enrich] enabled = true:
   EnvironmentFile=-/etc/memhouse/secrets.env
   ExecStart=/usr/local/bin/memhouse serve
   # MemHouse shuts down gracefully on SIGINT and SIGTERM: it finishes requests and stops workers.
   KillSignal=SIGINT
   TimeoutStopSec=30
   Restart=on-failure
   NoNewPrivileges=true
   ProtectSystem=strict
   ReadWritePaths=/var/lib/memhouse
   PrivateTmp=true

   [Install]
   WantedBy=multi-user.target
   ```

   ```bash
   sudo systemctl daemon-reload && sudo systemctl enable --now memhouse
   ```

   ```bash
   curl -s localhost:7077/health
   ```

## Container image

`ghcr.io/memhousehq/memhouse` (from release 2.0.0), for `linux/amd64` and `linux/arm64`, or
`docker build -t memhouse .` from a checkout. It runs as the unprivileged user 65532, has no
shell, writes only to `/data` and `/tmp`, answers `GET /health`, carries its own health check
(`memhouse health`) and stops cleanly on SIGTERM. The [install guide](install.md#container-image)
has the commands for the Lite profile and for your own Postgres, the image's tags, and how to
start it without access to the model hub; [supply chain](security/supply-chain.md#the-container-image)
says how to verify it.

MemHouse's HTTPS clients (model downloads, LLM and OTLP endpoints) verify certificates against
the certificate store of the image's base, not a list bundled in the binary: to trust a private
CA for them, build an image on top that adds it. The connection to Postgres is different: it is
verified only when the database URL asks for it ([TLS to the database](#tls-to-the-database)). Mount a volume at `/data` (or set `[embedding] cache_dir`)
so the model download survives restarts. Pass the database URL and API key as environment
variables, as in [configuration.md](configuration.md#environment-variables).

A `docker compose` file for a self-contained server:

```yaml
services:
  db:
    image: pgvector/pgvector:pg17
    environment: { POSTGRES_USER: memhouse, POSTGRES_PASSWORD: change-me, POSTGRES_DB: memhouse }
    volumes: [pgdata:/var/lib/postgresql/data]
  memhouse:
    image: ghcr.io/memhousehq/memhouse:2.0.0     # or `build: .` from a checkout
    depends_on: [db]
    ports: ["127.0.0.1:7077:7077"]
    read_only: true
    tmpfs: [/tmp]
    cap_drop: [ALL]
    security_opt: [no-new-privileges]
    environment:
      MEMHOUSE_DATABASE_URL: postgres://memhouse:change-me@db:5432/memhouse
      MEMHOUSE_API_KEY: ${MEMHOUSE_API_KEY:?set it}
    volumes: [mhdata:/data]
volumes: { pgdata: {}, mhdata: {} }
```

In this example the database is a container on the Compose project's own network and the
connection to it is not encrypted. For a database on another host, use a URL with
`sslmode=verify-full` ([TLS to the database](#tls-to-the-database)).

On Kubernetes, use the [Helm chart](install.md#kubernetes-helm).

## Cloud with managed Postgres

All the big providers ship pgvector:

| Provider | Enable pgvector |
|---|---|
| AWS RDS / Aurora PostgreSQL | `CREATE EXTENSION vector;` (16+) |
| Google Cloud SQL / AlloyDB | `CREATE EXTENSION vector;` |
| Azure Database for PostgreSQL Flexible | allow-list `VECTOR` in `azure.extensions`, then `CREATE EXTENSION vector;` |
| Supabase, Neon, Crunchy Bridge | preinstalled; `CREATE EXTENSION vector;` |

Then:

- Run `memhouse serve` on any container platform (ECS/Fargate, Cloud Run, AKS, Fly.io) behind the
  platform's HTTPS load balancer. Health check: `GET /health`.
- Use verified TLS to the database: `?sslmode=verify-full` in the URL
  ([TLS to the database](#tls-to-the-database)).
- Keep `max_connections` × number of instances below the database's connection limit, or put
  PgBouncer in transaction mode in front of it.
- **Data residency:** with the default local embedding model, conversation text never leaves your
  network. Only enrichment (if you turn it on) sends text to the LLM endpoint you configure. Point
  it at a regional or self-hosted endpoint to keep data in region.

## TLS to the database

The database URL decides how the connection to Postgres is protected, with the `sslmode`
parameter (or the `PGSSLMODE` environment variable), as for any Postgres client:

| `sslmode` | Encrypted | Server certificate checked | |
|---|---|---|---|
| not set, or `prefer` | if the server offers it | no | **the default**: falls back to plaintext, and accepts any certificate |
| `require` | yes | no | protects against eavesdropping, not against a server that is not yours |
| `verify-ca` | yes | issued by a trusted CA | |
| `verify-full` | yes | issued by a trusted CA, for this host name | use this for any database reached over a network |

With `verify-ca` and `verify-full` the certificate is checked against the operating system's
certificate store, or against the file the URL names with `sslrootcert=/path/to/ca.pem` (or
`PGSSLROOTCERT`): that is how to trust a provider's or a private CA, in the container too (mount
the file; nothing has to be added to the image).

```
postgres://memhouse:<password>@db.internal:5432/memhouse?sslmode=verify-full&sslrootcert=/etc/memhouse/ca.pem
```

## Reverse proxy and TLS

`memhouse serve` speaks plain HTTP. Keep it bound to `127.0.0.1` (the default) and put TLS in
front of it. The [admin console](console.md) needs it: on any host but a loopback one its
session cookie is `Secure`, and a browser sends that only over TLS.

Caddy (gets certificates automatically):

```
memory.example.com {
    reverse_proxy 127.0.0.1:7077
}
```

nginx:

```nginx
server {
    listen 443 ssl;
    server_name memory.example.com;
    ssl_certificate     /etc/letsencrypt/live/memory.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/memory.example.com/privkey.pem;
    client_max_body_size 5m;          # large ingest batches
    location / {
        proxy_pass http://127.0.0.1:7077;
        proxy_set_header Host $http_host;   # the public host with its port, as the browser sent it
        proxy_read_timeout 60s;
    }
}
```

**Tell the server its origin.** The server refuses a browser request whose `Origin` is not
its own. It takes its own from the `Host` header: `proxy_set_header Host $http_host;` above
passes it on with its port (`$host` drops the port, which breaks a console on a port other
than 443), and Caddy does by default. If your proxy sends another `Host` upstream, set
`[server] public_url = "https://memory.example.com"` instead
([configuration.md](configuration.md#server)). `X-Forwarded-Host` is not read. With neither,
the console's own requests are refused with `403`.

**Other origins.** Pages of another origin cannot call the API from a browser unless the
origin is in `[server] cors_origins` ([configuration.md](configuration.md#server)); there is
nothing to add at the proxy. Clients that are not browsers (curl, SDKs, agents) send no
`Origin` and are not affected.

**More than one replica.** Console sessions are rows in the database, so a session opened on
one `memhouse serve` is valid on every other and survives a restart.

## Sizing

Measured on a laptop CPU (Apple M-series, `bge-small-en-v1.5`, 384 dimensions):

| Operation | Typical cost |
|---|---|
| Recall (embed query + one SQL statement for all probes) | p50 26–35 ms, p95 ~40 ms with ~500 rounds per subject |
| Recall with the cross-encoder rerank | +~0.9 s |
| Ingest | dominated by embedding: about 2 vectors per round, batched |
| Embedding cache | ~2.2 KB per cached vector |
| One episodic round in `mh_memory` | roughly 5–10 KB (two vectors, text, `tsvector`, indexes) |

Rules of thumb:

- **CPU** goes on embedding. Give the process two or more cores and set `[embedding] sessions` /
  `threads` for heavy ingest. With a remote embedding provider the process needs very little CPU.
- **Memory:** the local model plus runtime is about 300–500 MB. The rerank model adds about as much.
- **Postgres:** recall scans one subject exactly (there is no approximate index by design), so
  latency grows with the size of the *subject*, not of the database. Subjects up to tens of
  thousands of memories stay fast. Keep `shared_buffers` large enough to hold the hot subjects'
  vectors.
- **Storage:** 1 million rounds is on the order of 10 GB, plus the embedding cache.

Measure your own database:

```sql
SELECT count(*) AS memories,
       pg_size_pretty(pg_total_relation_size('mh_memory')) AS memory_table,
       pg_size_pretty(pg_total_relation_size('mh_embed_cache')) AS embed_cache,
       pg_size_pretty(pg_database_size(current_database())) AS database
FROM mh_memory;

-- The biggest subjects (recall latency follows these)
SELECT subject, count(*) FROM mh_memory WHERE status = 'committed'
GROUP BY 1 ORDER BY 2 DESC LIMIT 10;
```

To check latency on your own hardware, run `memhouse bench run --dataset longmemeval-s --stride 10`.
It reports p50 and p95 recall latency (see [benchmarks.md](benchmarks.md)).

## Enrichment workers

With `[enrich] enabled = true`, every ingest queues one job per session. Workers in any
`memhouse serve` process with `workers > 0` drain the queue.

```mermaid
sequenceDiagram
    participant C as Client
    participant API as memhouse serve (API)
    participant DB as Postgres
    participant W as worker (any process)
    participant L as LLM endpoint
    C->>API: POST /v1/ingest
    API->>DB: insert rounds + mh_enrich_job (pending)
    API-->>C: 200 {stored: n}  (does not wait)
    loop every worker
        W->>DB: claim job FOR UPDATE SKIP LOCKED, lease 5 min
        W->>DB: mh_llm_cache hit?
        alt cache miss
            W->>L: extract facts (small model)
            L-->>W: JSON facts + usage/cost
            W->>DB: cache answer
        end
        W->>DB: facts through the write gate → insert, job done (outcome, lag)
    end
    C->>API: POST /v1/recall (rounds now, rounds + facts once done)
```

**Job states:**

```mermaid
stateDiagram-v2
    [*] --> pending: ingest
    pending --> running: claimed (lease 5 min)
    running --> done: facts stored / cached / skipped
    running --> pending: error, retry after 2^attempts s
    running --> pending: lease expired (worker crashed)
    pending --> failed: attempts ≥ max_attempts
    done --> [*]
```

**Topologies:**

- *Simple:* every `serve` instance runs workers (the default, `workers = 8`).
- *Split:* API instances set `workers = 0`, and a separate worker instance (another
  `memhouse serve` bound to `127.0.0.1`, with `workers = 16`) does the LLM calls. Use this to keep
  outbound LLM traffic in one place, or to scale the two halves separately.

**Cost control:**

- Facts are about $0.00007 per session with `qwen/qwen3.7-flash`. LongMemEval_S cost $1.54 for
  21,000 sessions; LoCoMo cost $0.03.
- `max_cost_usd` stops LLM calls in that process once its spend reaches the limit. Jobs claimed
  after that fail with `reached max_cost_usd`, are retried with backoff and end up `failed`. Raise
  the limit or restart, then re-queue them with the `UPDATE` below.
- Repeated sessions are free: answers are cached under the hash of the prompt version, model,
  endpoint and prompt.
- Sessions with less than `min_user_chars` of user text are skipped without a call.
- Zero cost: point `[enrich.llm]` at a local Ollama (see [configuration.md](configuration.md#enrich)).

**Watching the queue:**

```bash
curl -s localhost:7077/v1/enrich/status -H "authorization: Bearer $KEY"
# {"pending":12,"running":8,"done":20341,"failed":0}
```

```sql
-- Spend, lag and throughput over the last day
SELECT count(*) AS jobs,
       round(sum((outcome->'usage'->>'cost_usd')::numeric), 4) AS usd,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY (outcome->>'lag_ms')::float) / 1000 AS lag_p50_s,
       sum((outcome->>'facts')::int) AS facts,
       count(*) FILTER (WHERE (outcome->>'cached')::bool) AS cached
FROM mh_enrich_job WHERE status = 'done' AND finished_at > now() - interval '1 day';

-- Why did jobs fail?
SELECT id, subject, attempts, left(error, 120) FROM mh_enrich_job WHERE status = 'failed' ORDER BY id DESC LIMIT 20;

-- Retry failed jobs (for example after fixing an API key)
UPDATE mh_enrich_job SET status = 'pending', attempts = 0, run_after = now(), error = NULL WHERE status = 'failed';
```

## Write pipeline

Writes are queued in the database (`mh_intake`) and answered `candidate` at once; the rest of
the pipeline runs in the request's own task right after the answer, so a write is normally
stored within tens of milliseconds ([architecture](architecture.md#write-path)). Pipeline workers
(`[intake] workers`, 2 in `memhouse serve`, 1 in `memhouse mcp`) pick up what a crash or a
failure left: a claimed proposal is held for `lease_secs` (60) and then claimed again. Several
processes can share one database; each subject's writes still take effect in order.

- **Lag.** `memhouse_intake_lag_seconds` is the age of the oldest unfinished proposal. It should
  stay near zero; if it grows, the pipeline is failing (look for `intake of … failed` errors in
  the log: a model endpoint or the database) or no process is running workers.
- **Poison proposals.** A proposal that fails `max_attempts` (5) times is set aside with status
  `dead` and its records stored as `quarantined` with `metadata.quarantine_reasons =
  ["intake_failed"]` and the error, so it never blocks its subject. Find them with `memhouse
  list --all` (the error is also in `mh_intake.error`). They can't be admitted: `POST
  /v1/review` only rejects them. To store one after fixing the cause (a model endpoint, a
  policy), forget the quarantined record and write its content again, with `remember` or
  `ingest`; until it is forgotten, the same content is answered as a duplicate of it.
- **Retryable refusals.** If the database can't take the write, the API answers `503
  unavailable` with `Retry-After`, and nothing is stored. Clients should retry with the same
  idempotency key.
- **Retrieval failures** answer an empty result flagged `degraded` within
  `[memory] recall_timeout_ms` (450 ms) instead of an error; watch `memhouse_recall_degraded_total`.
- **Restarts** lose nothing that was acknowledged: proposals stay in the table until stored.
  Finished ones keep only their ids and outcome and are pruned after `keep_done_secs` (1 h).

## Backup and restore

Back up Postgres as you would any database: `pg_dump` for small installs, base backups with WAL
archiving (pgBackRest, WAL-G, or the provider's point-in-time recovery) for production.

```bash
pg_dump -Fc -d "$DATABASE_URL" -f memhouse-$(date +%F).dump
```

```bash
pg_restore -d "$NEW_DATABASE_URL" --no-owner memhouse-2026-11-01.dump
```

There is also a portable, model-independent export in [Memory Format v2](memory-format.md):

```bash
memhouse export -o memhouse.jsonl                       # the tenant: every record in every state, links, policies
memhouse export --subject customer:acme -o acme.jsonl
memhouse import memhouse.jsonl                           # v1 or v2; ids, states, timestamps, provenance kept; re-embeds
```

The first line is a header; then one `policy`, `record` or `link` object per line. Vectors are
not in the file: an import embeds with its own model. Import skips ids that already exist, so it
is safe to run twice, and export → import → export reproduces every line. It does not include the
audit chain or the deletion ledger: back those up with the database.

On the [Lite profile](lite.md#backup-and-restore), `memhouse backup <dir>` writes a consistent
snapshot of the SQLite file together with the export and the deletion ledger. The ledger in
the backup ends where the backup was taken, so a restore needs the later one:
`memhouse restore <dir> --force` over the current database carries that database's ledger over
and re-applies it; on a machine without the current database, export the ledger first with
`memhouse backup <dir> --ledger-only` and pass it with `memhouse restore <dir> --ledger <file>`.
A plain `memhouse restore <dir>` there brings back what was deleted after the backup, and says
so. On Postgres the database itself is backed up and restored with Postgres' tools, and the two
commands handle the deletion ledger: see
[Re-applying deletions after a restore](#re-applying-deletions-after-a-restore).

### Console sessions after a restore

A dump holds the rows of the [console](console.md)'s sessions that were open when it was
taken: hashes, not the cookies' secrets. One of them may have been logged out since, and a
restore within the session lifetime (`[server] session_ttl_secs`, 8 hours) would make it
valid again. After restoring a Postgres dump, end them all:

```sql
DELETE FROM mh_session;
```

`memhouse restore` on Lite does this itself.

### Re-applying deletions after a restore

A backup taken before an erasure request still holds the erased data. The deletion ledger
records every deletion, so that a restore can make them again before the restored database
serves anyone (TR-WF-03). The ledger that matters is the one kept *outside* the backup: the
backup's own ledger ends where the backup was taken.

```mermaid
flowchart LR
    B[backup<br/>Mon 02:00] --> R[pg_restore]
    L["memhouse backup --ledger-only<br/>(every deletion up to now)"] --> X["memhouse restore --ledger"]
    R --> X --> OK[restored database without<br/>the erased data] --> S[memhouse serve]
```

```bash
# Routinely, beside your backups (the file is small: identifiers, never content):
memhouse backup /var/backups/memhouse-ledger --ledger-only     # a new or empty directory each time

# After a restore, before the service starts:
pg_restore -d "$DATABASE_URL" --no-owner memhouse-2026-11-01.dump
memhouse restore --ledger /var/backups/memhouse-ledger/deletion-ledger.jsonl
# ✓ deletion ledger: 214 entries, 187 already in the database, 27 re-applied, removing 41 records
#   audit chain intact (9120 events)
#   `memhouse serve` now starts on this database
```

`memhouse restore` applies each row the database's ledger does not have yet, with the cascade
of the deletion it records (a record with what was derived and promoted from it; a subject; a
tenant; for a retention purge the record and its derived facts), adds the row to the ledger as
it was made, so the next backup carries it, ends every [console session](#console-sessions-after-a-restore),
and writes `deletion.reapply` and `backup.restore` audit events. The whole replay is one transaction: a ledger row that cannot be applied leaves nothing applied,
and running it twice changes nothing the second time. If the restored database's audit chain
does not verify, the command says so and does **not** record the database as fit to serve. If
nothing was deleted since the backup, say so with `memhouse restore --no-ledger` (audited).

**What the exported ledger cannot hold.** The ledger lives in the database; the file is a copy
of it at the time of the export. A deletion made after the last export, on a database that is
then lost, is in neither the backup nor the file: the restore brings its data back and nothing
re-applies it. To keep that window small and known:

- export the ledger more often than you back up, and right after every erasure request
  (`memhouse backup <dir> --ledger-only` takes seconds; the file holds identifiers only), to
  storage that does not fail with the database;
- keep the audit events elsewhere as they are written ([SIEM export](#siem-export)): every
  deletion is an event (`memory.forget`, `subject.erase`, `retention.purge`,
  `deletion.certificate` and the others) with its subject or record identifiers;
- after a restore from a ledger older than the lost database, **reconcile before serving**:
  compare the deletion events your SIEM or your request records hold after the ledger's last
  entry with the restored database, and repeat those deletions (`memhouse forget`, the
  deletion API) before `memhouse serve` takes traffic. The restore guard cannot see this
  gap: it compares the database with what this host last served, not with what was deleted.

A ledger row says how it is re-applied: `memory` (a record with what was derived and promoted
from it), `retention` (a record with its derived facts), `subject`, `tenant`, and `record`: one
record exactly, nothing it led to. `record` rows are what a deletion writes when a legal hold
cut its cascade short (part of a subject erased, a derived fact kept), so that a replay takes
what went then and not what the hold kept; `record-reset` is the same for a reset that leaves
the caches.

Legal holds do not stop a replay: the ledger says what was deleted, and a hold that the backup
brought back is no reason to bring the data back with it. A hold *placed* after the backup is
not in the restored database: place it again.

**The restore guard.** `memhouse serve` remembers, under `MEMHOUSE_HOME/state/`, the newest
audit event of the database it serves (written at start, every minute, and at shutdown). When
it starts on a database whose audit log ends before that event, the database was restored
from a backup, and the service refuses to start until `memhouse restore` has run:

```text
this database is older than the one this installation last served: its audit log ends at event
9093, and event 9120 was seen on 2026-11-27 14:02:11 UTC. It was restored from a backup, so
records deleted since may be back. Run `memhouse restore --ledger <file>` …
```

The guard is a safety net, not the procedure: run `memhouse restore` after every
`pg_restore`. It notices a database older than the state it last recorded. The state is
written every minute and at once after every deletion the serving process carries out
(replaced atomically, so an interrupted write leaves the last good one); deletions made by
another process (the CLI, a second replica) are covered by the minute, and a restore to a
point inside it is not noticed. A state file that is there but cannot be read stops the start,
with the command to run: it is not taken for "nothing recorded". It works where `MEMHOUSE_HOME` outlives the restore: a server, or a container with a
volume for it. Where the home is rebuilt with every start (a pod without a volume), nothing is
remembered and the guard cannot notice: there the runbook must run `memhouse restore` after
every `pg_restore`. A failover to a replica that lost the last events also trips the guard,
which is the point: those events may include deletions. `[governance] restore_guard = false`
turns it off.

Embedding-cache rows of text deleted after the backup are removed with their records. Cached
vectors and extractions whose record is not in the restored database at all (written and
deleted after the backup) do not exist there either.

## Row-level security

`[database] row_level_security = true` adds a second line behind the service's own tenant and
subject filters (TR-DB-03). At the next start the service enables and forces a policy on every
table that holds memory content or what is derived from it (`mh_memory` and its partitions,
`mh_structured`, `mh_code_ref`, `mh_link`, `mh_recall`, `mh_intake`, `mh_request_key`,
`mh_enrich_job`; the two content-addressed caches are readable by the service alone):

- a row is visible to a session whose settings name its tenant (`memhouse.tenant`) and, if the
  session names one, its subject (`memhouse.subject`);
- the service sets those settings itself. Recall, the reads of a record and of a list run on a
  connection narrowed to the request's tenant and subject, and writes and deletions in a
  transaction narrowed to the tenant, so a statement that lost its own filter still reads and
  writes nothing else. The service's maintenance work (queues, retention across subjects,
  migrations) runs in a *service scope* that only the role owning the tables can take;
- a connection that did not come through the service has neither: it reads nothing.

```sql
-- psql as the service's role: nothing until the session says what it is for
SELECT count(*) FROM mh_memory;                                   -- 0
SELECT set_config('memhouse.tenant', 'default', false);
SELECT count(*) FROM mh_memory;                                   -- the tenant's records
SELECT set_config('memhouse.scope', 'service', false);            -- the owner's role only
```

What to know before turning it on:

- **A superuser, and a role with `BYPASSRLS`, are not bound by any policy.** The container
  `memhouse up` starts uses the image's superuser, so there the policies bind other roles only.
  For the second line to bind the service too, run it as an ordinary role that owns the tables
  (`CREATE ROLE memhouse LOGIN PASSWORD …; CREATE DATABASE memhouse OWNER memhouse;`).
  `memhouse evidence export` reports which it is (`isolation.json`).
- **Your own SQL sessions change.** The queries in this guide and in
  [governance.md](governance.md) return nothing until the session sets `memhouse.scope` (the
  owner) or `memhouse.tenant`.
- **It is a second line, not a boundary between roles.** A role that can connect can set the
  tenant it asks for. To hold a reporting role to one tenant, give it a policy of its own.
- Each narrowed statement costs one more round trip to set the session, and one when the
  connection is released.
- Turning the option off again leaves the policies in place; remove them with
  `ALTER TABLE … DISABLE ROW LEVEL SECURITY` on the tables above.

The governance check `rls_bypass` connects directly, as a role that does not own the tables,
and finds no row without the settings, only the tenant's and the subject's with them, a
refused write of another tenant's row, and no way into the service scope.

## Monthly partitions for episodic memory

`[database] episodic_partitions = true` converts the memory table, at the next start, into one
partitioned by month for episodic memory (TR-DB-04). Retention then drops a month's partition
instead of deleting its rows one by one: no dead rows, no vacuum of the largest part of the
table.

- **The conversion moves nothing.** The table as it is becomes the partition of rows without a
  month (`mh_memory_rest`): every record written so far, and every record that is not episodic.
  It takes an exclusive lock for one scan of the table; do it in a maintenance window on a
  large database, with the service's other replicas stopped. It is not converted back.
- Episodic records written from then on go to `mh_memory_e<YYYYMM>`, created when the first
  record of a month arrives. Rounds from before the conversion stay in `mh_memory_rest` and are
  purged row by row, as before.
- **A partition is dropped whole** when every row in it is the tenant's, past the tenant's
  retention, outside its scope rules and under no legal hold; the cascade of its rows (cached
  vectors, derived facts, extraction jobs, structured forms, ledger rows) and the drop are one
  transaction. A partition that holds anything else loses its due rows one by one.
- **What changes.** A partitioned table has no single unique index on `id` and cannot be
  referenced by a foreign key: uniqueness is per partition (ids are random UUIDs), and a
  trigger removes a record's structured form, code references and links with it, as the
  foreign keys did. `memhouse import` from a MemHouse older than this release cannot write to a
  partitioned table (its `ON CONFLICT (id)` has no index to name): import with this release.
- A recall reads every partition of the subject. While a month's partition holds only a few
  hundred rows the planner may read it whole instead of by index; the statement's own filters
  (and row-level security, if on) still apply.

## SIEM export

With `[siem]` set, `memhouse serve` sends every audit event to your SIEM, in order, within
seconds of its being written (GOV-15: 99.9% within 60 seconds).

```toml
[siem]
syslog = "tcp://siem.internal:6514"            # CEF in RFC 5424 syslog, one message per line
otlp_endpoint = "http://otel-collector:4318"    # OTLP logs, posted to /v1/logs as JSON
otlp_headers_env = { authorization = "SIEM_TOKEN" }
```

```text
<110>1 2026-11-27T14:02:11.482913Z mh-1 memhouse 71 subject.erase - CEF:0|MemHouse|memhouse|2.0.0|subject.erase|subject.erase|5|rt=1795788131482 externalId=9120 suser=admin:dpo cs1Label=tenant cs1=default cs5Label=hash cs5=2ce28a… cs6Label=prevHash cs6=91f0c4… cs2Label=subject cs2=customer:acme cs4Label=detail cs4={"records":214}
```

- An event carries what the audit log holds: the action, the actor, the tenant, the subject and
  record identifiers, the detail and the two hashes of the chain. Never memory content.
- The exporter keeps a cursor per receiver in the database and moves it only once the receiver
  has taken a batch. Over `tcp://` syslog and OTLP an event is delivered at least once, and a
  receiver that is down delays its events without losing them (they are sent when it is back;
  the service logs the outage once). **`udp://` syslog is best effort:** a datagram that left
  the host counts as sent, so events sent while a UDP receiver is down or the network drops
  them are lost and not sent again. Use `tcp://` or OTLP where the SIEM must hold every event.
- An OTLP collector that refuses a batch as such (HTTP 400, 413 or 422) gets it again in
  halves; an event it refuses even alone is skipped, so that it does not hold back every later
  one, and is named by its audit id in the service log and in the export's status (`skipped`,
  `errors`). Any other failure (the receiver down, a refused credential, a redirect, which is
  not followed) is retried and loses nothing.
- A receiver's address is a scheme, a host, a port and, for OTLP, a path: a user, a password,
  a query or a fragment in it is refused at start. Credentials go in `otlp_headers_env`.
- The export starts with the events written after it is first turned on.
- With several replicas one holds a lease and exports; another takes over within a minute if
  it stops.
- Syslog over TCP and UDP is sent in the clear: send to a forwarder on the host or inside the
  network (rsyslog, a collector) and let it speak TLS to the SIEM. The OTLP endpoint may be
  `https://`.
- The `audit.anchor` events ([audit anchors](governance.md#audit-log)) travel the same way, so
  the SIEM holds the head hashes a later verification must reproduce.

`memhouse evidence export` reports the cursors and the last pass (`siem-export.json`).

## Moving between profiles

`memhouse migrate` moves a whole installation from one database to another: Lite to Standard,
Standard to Lite, or to another database of the same kind (TR-MIG-01, PROF-02, PROF-03).

```bash
memhouse migrate --to postgres://memhouse@db.internal:5432/memhouse --dry-run   # look first
memhouse migrate --to postgres://memhouse@db.internal:5432/memhouse            # asks, then migrates
memhouse migrate --from postgres://… --to lite:///home/ada/.memhouse/memhouse.db --yes
```

- **The source** is the configured database unless `--from` names one. A URL is
  `postgres://…`, or `sqlite:<path>` (also spelled `lite://<path>`) for a Lite file.
- **Passwords:** give a URL in `MEMHOUSE_MIGRATE_FROM` or `MEMHOUSE_MIGRATE_TO` instead of on
  the command line. Whatever the command prints or audits shows URLs without credentials.
- **Stop `memhouse serve` and the agents first, and keep them stopped until the command has
  finished.** The migration is the downtime. What the command does about a source that is
  still written to is under [Writes to the source](#writes-to-the-source-during-a-migration).
- **The source is only read.** It is left as it was, whether the migration succeeds or not.

**What a dry run reports** (`--dry-run`, and the first thing every run prints): records by type
and state, the other tables' row counts, the size of the source, whether its audit chain is
intact, an estimate of the duration, the state of the target, and the records that need
attention. Anything that blocks the migration makes the command fail, in a dry run too: a
target that is not empty and is not a resumed migration of this source, a source written by an
older schema version (upgrade it first), another embedding model on the target, or text with
NUL characters on the way to Postgres, which cannot store them.

**What moves:**

| Moves | How |
|---|---|
| Records in every state, with their versions, provenance, labels, scope, language, structured rows and code references | as the canonical export ([memory-format.md](memory-format.md)) |
| Vectors | copied as stored; nothing is embedded again |
| Policies with their activations and approvals; principals, API key hashes and token signing keys; links, grants; evaluation suites and runs | row by row |
| The deletion ledger and the audit log | row by row, ids and hashes kept: the chain verifies on the target |
| The intake queue and extraction jobs | row by row, in order: queued work continues on the target |

Left behind, because they are rebuilt on use or expire: the embedding and extraction caches,
recall explanations, idempotency keys (a request repeated across the migration is carried
out again), and the [admin console](console.md)'s sessions (log in again on the target).

**Verification, then the switch.** After the copy every record is read back from the target
and its hash compared with the source's; every other table is compared row for row; a sample
of vectors is compared; the audit chain is verified. Only then is `[database] url` in the
configuration file changed to the target, with the file as it was kept beside it as
`config.toml.before-migrate-<timestamp>`. If the verification fails, the command names the
records, exits with an error, and changes neither the configuration nor the source. The file is
switched only when it names the source; otherwise it is left alone and the command says so.
Agents keep their keys and tokens. The target's audit log gains one event,
`migration.complete`.

**An interrupted migration** is run again with the same command: it continues where it stopped
and verifies everything. Running the command again after it completed copies nothing; it
switches the configuration file if that was still to do, and only if the source is still what
the target was verified against (the target records that). If the source was written to in
between, the command fails and switches nothing: migrate again into a new, empty target.

### Writes to the source during a migration

A write made to the source after its copy began is not in the target. The command does not
carry such writes over; it refuses to finish when it sees one.

| Source | What is guaranteed |
|---|---|
| Lite (a SQLite file) | The command refuses to start while another process has the file open, and holds the file's write lock from the start until after the configuration file is switched: no other process can write to it in that time. |
| Standard (Postgres) | The command cannot lock out a server. It notes other sessions on the database, refuses to start while a worker holds a live claim on queued work, and compares the source with what it held at the start three times: after the copy, after the verification, and immediately before the configuration file is switched. A difference fails the migration and nothing is switched. |

What is compared, each time:

- the number of records by tenant, type and state, the number of vectors, and the newest
  change time of any record;
- the last audit event (its id and hash) and the row count of every table that moves;
- a digest of every row of every table that moves row by row, except the audit log: policies
  and policy specs with their activations, principals, API keys, signing keys, links, grants,
  evaluation suites and runs, the deletion ledger, the intake queue and the extraction jobs.
  These rows are read again each time, so a row changed in place (a queued job that failed,
  a key that was revoked) is seen even when no row was added and no audit event written.

Records are not read a second time for this: a record that is added, changed or deleted moves
a count, the newest change time, or the sum of all records' change times (which moves also
when the changed record is not the newest, as after an import that kept later times). One
change is not seen: extending the session of a working record that was imported with a change
time in the future leaves that time where it was. The audit log is not digested again either:
it only grows, and its last event stands for every event before it. The same comparison decides whether a
migration that completed earlier is still complete when the command is run again.

What remains, for a Postgres source: a write that lands after the last comparison, in the
moment before the file is rewritten, is not seen. And whatever the source is, a server that is
still running after the switch keeps writing to the source, because it read its configuration
when it started; those writes are not in the target either. So the rule above is the
guarantee: the server and the agents stay stopped until the command has finished. If you
find the source was written to after a migration, the target is missing those writes: migrate
again into a new, empty target.

After the migration the command says what to do next, and that depends on what the server
would use, which is `MEMHOUSE_DATABASE_URL` or `DATABASE_URL` when one is set and the
configuration file's `[database] url` otherwise. When that names the target, it says to start
the server (and, when only the environment names it, to set the file as well). Otherwise it
says that MemHouse is not pointed at the target yet and what to change, and does not call the
source unused.

**The managed container** (`[database] container`, set by `memhouse up`) is kept in the
configuration only when the target is another database on the same Postgres host and port;
for a file or another server it is removed, so `memhouse down` never stops a container that
does not serve the configured database.

Where a migrated database is not bit-identical to its source:

- **Vectors on the way to Lite** are rounded once to half precision, Lite's storage format
  (largest change of a component about 0.0001); the report says so. Records and their hashes
  are unaffected. Lite to Standard, and every later move, copies vectors exactly.
- **A number in a record's JSON attributes** that Postgres writes differently (`1e16` becomes
  `10000000000000000`) changes that record's hash. The report counts such records as equal in
  value and lists them; any other difference fails the migration.

**Duration** (PROF-03: at most 5 minutes of downtime per million records): 1,000,000 records
with 384-dimension vectors and 1,000,000 audit events moved from Lite to Postgres in 120 s on a
laptop, verification included ([benchmarks.md](benchmarks.md#migration-at-size)).

## Upgrades

1. Read the release notes.
2. Back up (`pg_dump`, or a snapshot).
3. Replace the binary and restart. The schema migrates on start-up with additive
   `CREATE/ALTER … IF NOT EXISTS` statements, then backfills new fields in batches.
   `mh_meta.schema_version` records the version; a database newer than the binary is refused.
   Version 1 → 2 adds provenance, scopes, the full lifecycle, working memory, structured records,
   code references, links, policies and request keys; no memory is re-embedded or re-extracted
   ([schema](schema.md#upgrading-from-v1)).
4. `memhouse doctor`.

   Version 9 adds three nullable columns to `mh_memory` (`language`, `ts_config`, `tsv_lang`), a
   trigger and a partial index. No row is rewritten: existing records keep their `english`
   keyword index and have no `language` until they are written again.
   A database upgraded to version 9 is refused by an older binary.

Rolling restarts work: old and new processes can share the database while the changes are additive.
Changing the embedding model is different: see [Changing the embedding model](#changing-the-embedding-model).

## Changing the embedding model

Vectors from different models (or the same model with a different passage prefix) can't be
compared, so a database holds one embedder at a time. `memhouse reembed` moves every stored
memory to the model now in `[embedding]`, in place, while the server keeps answering:

```bash
# 1. Edit [embedding] in the config (model, dim, provider, passage_prefix …). Nothing else changes yet:
#    the running server keeps its old model; a new process refuses to start and points here.
memhouse reembed --dry-run    # from / to, records, characters ≈ tokens (for a paid API)
memhouse reembed              # asks first; --yes to skip the question
# 2. Restart `memhouse serve`, workers and MCP clients so they load the new model.
```

How it works:

1. New vectors are written into staging columns next to the current ones, in batches
   (`--batch`, default 256). Recall and writes keep using the old model meanwhile.
2. Records written during the run by processes still on the old model are picked up by another
   pass.
3. One transaction blocks writes (not reads), checks nothing is pending, swaps the columns,
   records the new embedder, dimension and prefix, deletes the old model's cached vectors and
   writes an `embedding.reembed` audit event. A dimension change is fine (384 → 1536, say).
4. From then on the database refuses writes from a process on the old model, and such a process's
   recall fails within 5 seconds with "restart with the new [embedding] configuration".

Rounds that also have a vector of the user's words alone get it rebuilt too; the text is recovered
from the round and checked against its stored hash. A round where that fails keeps only its main
vector, and the report counts them.

**Interrupted?** Run `memhouse reembed` again with the same config: it resumes. **Changed your
mind before the switch?** `memhouse reembed --abort` drops the staging columns; the current
vectors were never touched. After the switch there is no undo, apart from re-embedding back
(or restoring a backup), so take one first.

Plan for it:

| | |
|---|---|
| Time | about as long as embedding the same records took at ingest (`--dry-run` shows the count; the run prints records per second). A remote API is limited by its rate limits. For a remote API set `batch_size` to 64 or more in `[embedding]`, so each request carries many texts. |
| Cost | a paid API charges for the characters `--dry-run` shows (≈ 4 per token), once per record and once per second vector. |
| Disk | the staging columns double the vector storage until the switch; dropped columns are reclaimed as autovacuum reuses the space, or at once by `VACUUM FULL mh_memory` in a maintenance window. |
| Writers | writes go on during the run; they wait only for the switch itself (well under a second plus the last few records). If records keep arriving from old-model writers through 10 passes, the run stops and asks you to stop them; progress is kept. |

## Languages

Full reference: [languages.md](languages.md).

- **Enable a language:** add its code to `[language] enabled` and restart. `memhouse lang list`
  shows the packs; `memhouse doctor` names the enabled ones and warns about an English-only
  embedding model.
- **Text search:** each pack names a Postgres text-search configuration. The server checks at
  start that the database has every one an enabled pack names, and stops with the name of a
  missing one. Records written before a language was enabled keep the `english` index; they are
  indexed in their own language when they are written again (`revise`, or export and import).
- **Embedding model:** with another language than English, move to a multilingual model with
  `memhouse reembed` (above); vector search with an English-only model is poor in other
  languages.
- **Your own packs:** put `<code>.toml` files in `[language] packs_dir`. Check each with
  `memhouse lang check <file> --tests <test set>` before a restart: a file that does not
  validate stops the start, with its file and line, whether or not its language is enabled.
- **A tenant with fewer languages:** `[language] enabled` in the tenant's policy spec.
- **Detection:** `memhouse lang detect "<text>"` shows what a text is detected as. A record's
  `language` field shows what it was stored as.

## Monitoring

| Signal | How |
|---|---|
| Liveness | `GET /health` → `{"status":"ok"}` |
| Full self-check | `memhouse doctor`: config, container, database, model, audit chain, MCP round-trip |
| Liveness of a running server | `memhouse health` (or `--url http://host:7077`): asks `/health`, exits non-zero when there is no answer; the container image's health check |
| Volumes | `GET /v1/stats`: memories, quarantined, superseded, subjects, audit events |
| Write pipeline backlog | `memhouse_intake_proposals{state}` and `memhouse_intake_lag_seconds` on `/metrics`: alert if the lag stays above a few seconds or `dead` > 0 (see [Write pipeline](#write-pipeline)) |
| Enrichment backlog | `GET /v1/enrich/status`: alert if `pending` keeps growing or `failed` > 0 |
| Audit integrity | `memhouse audit --verify`, daily (cron) |
| Recall latency | `memhouse_recall_stage_duration_seconds` (embed, search, rerank, total) on `/metrics`; also `took_ms`, `embed_ms`, `search_ms` in every response |
| Everything else | `GET /metrics` (Prometheus) and OTLP traces: see [below](#traces-metrics-and-recall-explanations) |
| Logs | stderr; set `RUST_LOG=info` (or `debug`) |

A cron job that checks integrity and alerts on failure:

```bash
# /etc/cron.d/memhouse
15 3 * * * memhouse MEMHOUSE_HOME=/var/lib/memhouse /usr/local/bin/memhouse audit --verify || logger -p user.err "memhouse audit chain broken"
```

## Traces, metrics and recall explanations

**Traces (QUAL-07).** Every operation is a span: `memhouse.remember`, `.revise`, `.ingest`,
`.forget`, `.recall` and `.enrich`, with the principal, subject, policy version, record ids and
outcome. Below them are stage spans (`recall.embed`, `recall.search`, `recall.rerank`), one span
per database statement (`db.search`, `db.insert`, … with `db.system = postgresql`), the
authorization decision (`memhouse.authorize`: operation, rule, allowed), the HTTP request
(`http.request`, named by route template) and, for enrichment, the LLM call (`gen_ai.chat` with
`gen_ai.request.model`, token counts and cost, the GenAI conventions that LLM-observability tools
read). Spans hold identifiers, counts and timings, never memory content or queries (PR-3).

Export is off until you name an OTLP/HTTP endpoint:

```toml
[telemetry]
otlp_endpoint = "http://localhost:4318"   # an OpenTelemetry collector, Jaeger, Tempo, Honeycomb…
sample_ratio = 1.0
```

```bash
# Or with the standard variables:
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
# Langfuse (TR-OPS-06): its OTLP endpoint, with the project's keys as Basic auth
export OTEL_EXPORTER_OTLP_ENDPOINT=https://cloud.langfuse.com/api/public/otel
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic%20$(printf '%s' "$LANGFUSE_PUBLIC_KEY:$LANGFUSE_SECRET_KEY" | base64)"
```

A quick look without any infrastructure: `docker run -p 16686:16686 -p 4318:4318
jaegertracing/all-in-one`, set the endpoint to `http://localhost:4318`, open `localhost:16686`.
`MEMHOUSE_OTLP_FILTER` (an `RUST_LOG`-style directive) exports more than MemHouse's own spans,
e.g. `info,sqlx=warn`.

With export off the spans still exist in-process, and instrumentation costs a few microseconds
per recall. The governance check `telemetry_overhead` measures it on every guard run (about
0.002 ms of a 2.6 ms recall, 0.07%).

**Metrics.** `GET /metrics` serves the Prometheus text format to a key with `ops:read`:

| Metric | Labels | |
|---|---|---|
| `memhouse_http_requests_total`, `memhouse_http_request_duration_seconds` | method, route, status | route templates, never concrete subjects |
| `memhouse_operations_total`, `memhouse_operation_duration_seconds` | op, outcome | outcome is `ok` or the error code |
| `memhouse_recall_stage_duration_seconds` | stage: embed, search, rerank, total | |
| `memhouse_recall_statements` | | database round trips per recall; 1 on Postgres (PERF-02) |
| `memhouse_writes_total` | status: committed, candidate, quarantined, rejected, deduplicated | records the pipeline stored, by state |
| `memhouse_intake_proposals`, `memhouse_intake_lag_seconds` | state: pending, running, done, dead | the intake queue and the age of its oldest unfinished proposal (TR-IN-06) |
| `memhouse_intake_ack_seconds`, `memhouse_intake_duration_seconds`, `memhouse_intake_freshness_seconds` | | time to the durable acknowledgement (PERF-03), to run the pipeline, and from acknowledgement to stored (PERF-04) |
| `memhouse_intake_total`, `memhouse_intake_refused_total` | outcome: ok, retry, dead | pipeline runs; writes refused because they could not be queued |
| `memhouse_gate_statements_total`, `memhouse_gate_corrections_total` | statement | what the gate read writes as; corrections that superseded a record |
| `memhouse_code_refs_total` | change: flagged, cleared, moved, revalidated | code references that became stale, stopped being stale, followed a rename, or were revalidated ([coding.md](coding.md)) |
| `memhouse_gate_tier_total` | tier: rules, small, large | the tiered classifier: which tier decided each statement (ECON-04) |
| `memhouse_gate_tier_capped_total` | | large-model reads refused by the tenant's cap |
| `memhouse_recall_degraded_total` | | recalls answered empty and flagged after a failure or timeout (PERF-07) |
| `memhouse_refused_total` | kind: auth, access; reason | 401s by reason, 403s by rule |
| `memhouse_enrich_jobs`, `memhouse_enrich_queue_lag_seconds` | state | queue depth and the age of the oldest pending job |
| `memhouse_enrich_cost_usd_total`, `memhouse_enrich_tokens_total` | type | LLM spend |
| `memhouse_enrich_tier_total` | tier: rules, small, large | sessions by the tier that produced their facts |
| `memhouse_enrich_tier_capped_total` | | escalations held back by the tenant's share |
| `memhouse_build_info` | version, api_version | |

```yaml
# prometheus.yml
scrape_configs:
  - job_name: memhouse
    metrics_path: /metrics
    authorization: {credentials: "<a key with ops:read, e.g. memhouse key create admin:prometheus --scopes ops:read>"}
    static_configs: [{targets: ["memhouse:7077"]}]
```

Alerts worth having: `memhouse_intake_lag_seconds > 30`; `memhouse_intake_proposals{state="dead"} > 0`;
any `memhouse_recall_degraded_total`; `memhouse_enrich_queue_lag_seconds > 600`; a rising
`memhouse_refused_total{kind="auth"}` (a client with a revoked key, or someone guessing);
`histogram_quantile(0.95, rate(memhouse_recall_stage_duration_seconds_bucket{stage="total"}[5m])) > 0.2`.

**Recall explanations (GOV-04).** Every recall response has a `recall_id`, and
`GET /v1/recalls/{id}/explanation` says why it returned what it did. You get the results with
their ranking signals, and every other record that matched the query with the reason it was left
out: status, access, label, validity, filter, duplicate, budget or rank. See the
[API reference](api.md#get-v1recallsidexplanation-why-a-recall-returned-what-it-did). The records
are kept in `mh_recall` for `[telemetry] explanation_retention_days` (30 by default; the hourly
retention pass purges older ones). They are erased with their subject, their tenant and, for
`forget` by user, the user's own recalls. The record holds the query text, so treat the table
like the memories themselves.

## Routine maintenance

| Task | How often | Command |
|---|---|---|
| Retention purge, and deletions whose legal hold was released | hourly, done by `serve` automatically | `memhouse retention` to run it now |
| Audit chain check | daily | `memhouse audit --verify`; against anchors kept elsewhere: `memhouse audit anchor --verify <file>` |
| Anchor the audit head | hourly, by `serve`, with `[governance] audit_anchor_path` | `memhouse audit anchor --out <file>` |
| Backups | daily, plus WAL | `pg_dump` / PITR |
| Deletion ledger, beside the backups | daily, and before any restore | `memhouse backup <dir> --ledger-only` |
| Evidence for an audit | when asked | `memhouse evidence export <dir> --suite-report <summary.json>` |
| Vacuum | autovacuum is enough; after bulk erasures run `VACUUM (ANALYZE) mh_memory;` | |
| Rotate API keys | when staff or clients change, and on a schedule | `memhouse key rotate <id> --grace 24h` prints the replacement; move the client; the old key stops at the end of the grace period. `memhouse key revoke <id>` ends a key at once (and its tokens within 5 s) |
| Review principals | monthly | `memhouse principal list`, `memhouse key list`; `memhouse principal disable <id>` for leavers |
| Remove bootstrap keys | after set-up | delete `[server] api_keys` once every client has its own principal's key |
| Trim old enrichment jobs | monthly | `DELETE FROM mh_enrich_job WHERE status = 'done' AND finished_at < now() - interval '90 days';` |

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `cannot connect to Postgres at …` | Check the URL, the network and `pg_hba.conf`. With `memhouse up`, `docker ps` should list `memhouse-pg`; run `memhouse up` again to start it. |
| `this database's memories are embedded with …, but the configuration says …` | `[embedding]` changed. Revert it, or run `memhouse reembed` ([Changing the embedding model](#changing-the-embedding-model)). |
| `this database has schema version N, newer than this build` | A newer MemHouse already upgraded the database. Run that version (or newer). |
| `pgvector … is too old` | `ALTER EXTENSION vector UPDATE;` (0.5 at least, 0.8 recommended); on a managed service, upgrade the extension from its console. |
| `extension "vector" is not available` | Install pgvector on the database server (`postgresql-17-pgvector`), or use the `pgvector/pgvector` image. |
| `401 … (send Authorization: Bearer <key or token>)` | The message names the reason: `no credential`, `unknown key`, `revoked key`, `expired key`, `expired token`, `disabled principal`. Use the client's own key (`memhouse key create <principal>`), or the bootstrap key from `memhouse key`. Every refusal is in the audit log as `auth.failed`. |
| `403 forbidden` | The credential is valid but may not do this: the message says which rule (permission, tenant, subject, label, user, scope). `GET /v1/whoami` shows what the key may do. |
| An agent says "MEMHOUSE_MCP_KEY was refused" or "needs the agent's key" | Run `memhouse connect <agent>` again: it creates the agent's principal and a fresh key and writes it into the agent's MCP config. |
| An agent's memories stay `candidate` | `[access] admission = "review"`: commit them with `POST /v1/review`, or grant the agent direct commits with `memhouse principal add agent:<name> --commit`. |
| An agent's procedures or the organisation's terms stay `candidate` | By design ([memory types](memory-types.md#the-types)): `procedural` memory proposed by an agent waits for `POST /v1/review`, `taxonomic` memory for an admin's review. |
| An agent can't see another agent's notes | Working memory is private to the agent that wrote it, and so is any record with `scope.agent`. Share it with `memhouse grant add <grantor> <grantee>`. |
| A recall no longer returns working memory written with `scope.session` | From API 1.5 working memory in a session is session-local: a recall returns it only when the request names that session (`"scope": {"session": "…"}`), and the list operations, which take no session, don't return it to non-admin callers. Other types are unaffected. |
| `cannot listen on 127.0.0.1:7077` | The port is in use. Set `--bind` or `MEMHOUSE_BIND`. |
| The model download hangs or fails | It needs `huggingface.co` once (or a mirror in `HF_ENDPOINT`). Pre-seed `cache_dir` from a machine that has access for air-gapped installs. |
| `invalid peer certificate: UnknownIssuer` | The operating system has no CA certificates (install `ca-certificates`), or a proxy re-signs TLS: add its CA to the system store. |
| Enrichment `pending` grows and `done` doesn't | No workers (`workers = 0` everywhere) or `enabled = false` in the worker process. |
| Enrichment jobs `failed` | Look at `error` in `mh_enrich_job` (query above). Common causes are a missing API key variable, 401s from the LLM endpoint, model names the provider doesn't serve, and `reached max_cost_usd`. |
| Recall misses something you know is stored | Check the subject (`GET /v1/subjects`), the status (`?all=true` shows superseded and quarantined records), `valid_to`, and `as_of`. Try `"mode":"keyword"` for exact identifiers. |
| A legitimate memory was quarantined | It matched an injection pattern (the `note` says which). Rephrase it as a fact about the user ("Alice asked us to…") rather than an instruction. See [governance.md](governance.md#prompt-injection-quarantine). |
| Slow recall | Look at `embed_ms` versus `search_ms`. A high embed time means CPU is short or the remote embedder is slow; a high search time means a very large subject or a cold cache. |
