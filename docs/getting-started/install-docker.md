<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# Run with Docker

Docker runs the standard release against a PostgreSQL container. The image
does not include pg0.

## Start the stack

```bash
docker compose up --build
```

The application is then at `http://127.0.0.1:4000`:

```bash
curl -fsS http://127.0.0.1:4000/api/ready
```

The image runs as a non-root user.

## With local tracing and metrics

```bash
MEMHOUSE_OTEL_ENABLED=true docker compose --profile observability up --build
```

This adds the local collector stack. See
[Observability](../operations/observability.md) for what it exports and what it
is forbidden from recording.

!!! danger "Replace the development credentials before exposing this"
    The Compose file ships a signing secret and a database password suitable
    only for a developer machine. Replace both before this stack is reachable
    by anything other than your own workstation.

## Configuration

Compose passes environment variables through. See
[Configuration](../reference/configuration.md), especially:

- `MEMHOUSE_AUTH_SIGNING_SECRET` — at least 64 random bytes, independent of
  `SECRET_KEY_BASE`;
- `DATABASE_URL` — the container path always uses external-database mode;
- `MEMHOUSE_BLOB_ROOT` — must be a durable volume if you ingest documents,
  because the database stores content hashes and blob references rather than
  the bytes themselves.

## Next

- [Quickstart tutorial](quickstart.md)
- [Operations overview](../operations/index.md)
