# Operations guide

This guide covers running MemHouse on a laptop, on a server and in the cloud: deployment, sizing,
backups, upgrades, enrichment workers, monitoring and troubleshooting.

## Contents

- [Deployment shapes](#deployment-shapes)
- [Laptop](#laptop)
- [Server (systemd)](#server-systemd)
- [Container image](#container-image)
- [Cloud with managed Postgres](#cloud-with-managed-postgres)
- [Reverse proxy and TLS](#reverse-proxy-and-tls)
- [Sizing](#sizing)
- [Enrichment workers](#enrichment-workers)
- [Backup and restore](#backup-and-restore)
- [Upgrades](#upgrades)
- [Monitoring](#monitoring)
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
   # MemHouse shuts down gracefully on Ctrl-C (SIGINT): it finishes requests and stops workers.
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

There is no published image yet. This Dockerfile builds one:

```dockerfile
FROM rust:1.85-bookworm AS build
WORKDIR /src
COPY . .
RUN cargo build --release -p memhouse-cli

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/target/release/memhouse /usr/local/bin/memhouse
ENV MEMHOUSE_HOME=/data MEMHOUSE_BIND=0.0.0.0:7077
VOLUME /data
EXPOSE 7077
STOPSIGNAL SIGINT
ENTRYPOINT ["memhouse"]
CMD ["serve"]
```

Mount `/data` (or set `[embedding] cache_dir`) so the model download survives restarts. Pass the
database URL and API key as environment variables, as in
[configuration.md](configuration.md#environment-variables).

A `docker compose` file for a self-contained server:

```yaml
services:
  db:
    image: pgvector/pgvector:pg17
    environment: { POSTGRES_USER: memhouse, POSTGRES_PASSWORD: change-me, POSTGRES_DB: memhouse }
    volumes: [pgdata:/var/lib/postgresql/data]
  memhouse:
    build: .
    depends_on: [db]
    ports: ["127.0.0.1:7077:7077"]
    environment:
      MEMHOUSE_DATABASE_URL: postgres://memhouse:change-me@db:5432/memhouse
      MEMHOUSE_API_KEY: ${MEMHOUSE_API_KEY:?set it}
    volumes: [mhdata:/data]
volumes: { pgdata: {}, mhdata: {} }
```

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
- Use TLS to the database (`?sslmode=require` in the URL).
- Keep `max_connections` × number of instances below the database's connection limit, or put
  PgBouncer in transaction mode in front of it.
- **Data residency:** with the default local embedding model, conversation text never leaves your
  network. Only enrichment (if you turn it on) sends text to the LLM endpoint you configure. Point
  it at a regional or self-hosted endpoint to keep data in region.

## Reverse proxy and TLS

`memhouse serve` speaks plain HTTP and allows all CORS origins. Keep it bound to `127.0.0.1` (the
default) and put TLS in front of it.

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
        proxy_set_header Host $host;
        proxy_read_timeout 60s;
    }
}
```

To restrict browser origins, add the `Access-Control-Allow-Origin` header at the proxy and drop
the upstream's.

## Sizing

Measured on a laptop CPU (Apple M-series, `bge-small-en-v1.5`, 384 dimensions):

| Operation | Typical cost |
|---|---|
| Recall (embed query + one SQL statement per probe) | p50 26–35 ms, p95 ~40 ms with ~500 rounds per subject |
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

## Backup and restore

Back up Postgres as you would any database: `pg_dump` for small installs, base backups with WAL
archiving (pgBackRest, WAL-G, or the provider's point-in-time recovery) for production.

```bash
pg_dump -Fc -d "$DATABASE_URL" -f memhouse-$(date +%F).dump
```

```bash
pg_restore -d "$NEW_DATABASE_URL" --no-owner memhouse-2026-11-01.dump
```

There is also a portable, model-independent export:

```bash
memhouse export -o memhouse.jsonl                       # every memory, including superseded and quarantined
memhouse export --subject customer:acme -o acme.jsonl
memhouse import memhouse.jsonl                           # ids, timestamps, provenance kept; re-embeds
```

The first line is a header (`{"format":"memhouse.memory","version":1,"exported_at":…,"embedder":…}`)
and each further line is one Memory object. Import skips ids that already exist, so it is safe
to run twice. Use it to move between embedding models or into another deployment.

### Re-applying deletions after a restore

A backup taken before an erasure request still holds the erased data. The deletion ledger records
every deletion so you can apply them again after restoring. Keep a copy of the ledger from the
live database before you restore over it.

```mermaid
flowchart LR
    B[backup<br/>Mon 02:00] --> R[restore]
    L["mh_deletion_ledger<br/>from the live DB<br/>(deletions since Mon 02:00)"] --> X[re-apply deletions]
    R --> X --> OK[restored DB without<br/>the erased data]
```

```bash
# 1. Before restoring: save the live ledger
psql "$LIVE_URL" -c "\copy (SELECT tenant, subject, memory_id, scope, at FROM mh_deletion_ledger) TO 'ledger.csv' CSV"
```

```sql
-- 2. After restoring: load it and re-apply
CREATE TEMP TABLE ledger (tenant text, subject text, memory_id uuid, scope text, at timestamptz);
\copy ledger FROM 'ledger.csv' CSV

-- Single-memory deletions and retention purges, and the facts derived from them
DELETE FROM mh_memory m USING ledger l
 WHERE l.scope IN ('memory', 'retention') AND m.tenant = l.tenant
   AND (m.id = l.memory_id OR m.metadata->'source_ids' ? l.memory_id::text);

-- Subject erasures
DELETE FROM mh_memory m USING ledger l
 WHERE l.scope = 'subject' AND m.tenant = l.tenant AND m.subject = l.subject;
DELETE FROM mh_enrich_job j USING ledger l
 WHERE l.scope = 'subject' AND j.tenant = l.tenant AND j.subject = l.subject;

-- Carry the ledger forward so the next restore re-applies these too
INSERT INTO mh_deletion_ledger (at, tenant, subject, memory_id, scope, actor)
SELECT at, tenant, subject, memory_id, scope, 'restore' FROM ledger
EXCEPT SELECT at, tenant, subject, memory_id, scope, 'restore' FROM mh_deletion_ledger;
```

Embedding-cache rows for the deleted text can't be matched once the text is gone. If an erasure
fell inside the restored window, also clear `mh_embed_cache` and `mh_llm_cache`. Both are caches
and rebuild on demand, at the cost of re-embedding. A built-in `memhouse restore --reapply-deletions`
is planned (TR-WF-03).

## Upgrades

1. Read the release notes.
2. Back up (`pg_dump`, or a snapshot).
3. Replace the binary and restart. The schema migrates on start-up with additive
   `CREATE/ALTER … IF NOT EXISTS` statements. `mh_meta.schema_version` records the version.
4. `memhouse doctor`.

Rolling restarts work: old and new processes can share the database while the changes are additive.
Changing the embedding model is **not** an in-place upgrade. Use a new database and
`export` / `import`.

## Monitoring

| Signal | How |
|---|---|
| Liveness | `GET /health` → `{"status":"ok"}` |
| Full self-check | `memhouse doctor`: config, container, database, model, audit chain, MCP round-trip |
| Volumes | `GET /v1/stats`: memories, quarantined, superseded, subjects, audit events |
| Enrichment backlog | `GET /v1/enrich/status`: alert if `pending` keeps growing or `failed` > 0 |
| Audit integrity | `memhouse audit --verify`, daily (cron) |
| Recall latency | `took_ms`, `embed_ms` and `search_ms` in every recall response; log them client-side |
| Logs | stderr; set `RUST_LOG=info` (or `debug`) |

A cron job that checks integrity and alerts on failure:

```bash
# /etc/cron.d/memhouse
15 3 * * * memhouse MEMHOUSE_HOME=/var/lib/memhouse /usr/local/bin/memhouse audit --verify || logger -p user.err "memhouse audit chain broken"
```

## Routine maintenance

| Task | How often | Command |
|---|---|---|
| Retention purge | hourly, done by `serve` automatically | `memhouse retention` to run it now |
| Audit chain check | daily | `memhouse audit --verify` |
| Backups | daily, plus WAL | `pg_dump` / PITR |
| Vacuum | autovacuum is enough; after bulk erasures run `VACUUM (ANALYZE) mh_memory;` | |
| Rotate API keys | when staff or clients change | add the new key to `api_keys`, restart, move clients, remove the old key, restart |
| Trim old enrichment jobs | monthly | `DELETE FROM mh_enrich_job WHERE status = 'done' AND finished_at < now() - interval '90 days';` |

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `cannot connect to Postgres at …` | Check the URL, the network and `pg_hba.conf`. With `memhouse up`, `docker ps` should list `memhouse-pg`; run `memhouse up` again to start it. |
| `this database stores 384-dimensional embeddings but the configured model produces 768` | The model changed. Revert `[embedding]`, or use a new database with export/import. |
| `extension "vector" is not available` | Install pgvector on the database server (`postgresql-17-pgvector`), or use the `pgvector/pgvector` image. |
| `401 missing or invalid API key` | Run `memhouse key` and send `Authorization: Bearer <key>`. If the message says no keys are configured, run `memhouse init`. |
| `cannot listen on 127.0.0.1:7077` | The port is in use. Set `--bind` or `MEMHOUSE_BIND`. |
| The model download hangs or fails | It needs `huggingface.co` once. Pre-seed `cache_dir` from a machine that has access for air-gapped installs. |
| Enrichment `pending` grows and `done` doesn't | No workers (`workers = 0` everywhere) or `enabled = false` in the worker process. |
| Enrichment jobs `failed` | Look at `error` in `mh_enrich_job` (query above). Common causes are a missing API key variable, 401s from the LLM endpoint, model names the provider doesn't serve, and `reached max_cost_usd`. |
| Recall misses something you know is stored | Check the subject (`GET /v1/subjects`), the status (`?all=true` shows superseded and quarantined records), `valid_to`, and `as_of`. Try `"mode":"keyword"` for exact identifiers. |
| A legitimate memory was quarantined | It matched an injection pattern (the `note` says which). Rephrase it as a fact about the user ("Alice asked us to…") rather than an instruction. See [governance.md](governance.md#prompt-injection-quarantine). |
| Slow recall | Look at `embed_ms` versus `search_ms`. A high embed time means CPU is short or the remote embedder is slow; a high search time means a very large subject or a cold cache. |
