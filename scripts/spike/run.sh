#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Technology spike (roadmap G03): intake queue and authorization store on Postgres, with pgbench.
# Runs inside the local `memhouse up` container against a scratch database `memhouse_spike`.
set -euo pipefail
C=${CONTAINER:-memhouse-pg}
cd "$(dirname "$0")"
psql() { docker exec -i "$C" psql -U memhouse -v ON_ERROR_STOP=1 -q "$@"; }
docker exec "$C" psql -U memhouse -d postgres -qtc "SELECT 1 FROM pg_database WHERE datname = 'memhouse_spike'" | grep -q 1 \
  || docker exec "$C" psql -U memhouse -d postgres -qc "CREATE DATABASE memhouse_spike"
for f in *.sql; do docker cp "$f" "$C:/tmp/$f"; done
bench() { docker exec "$C" sh -c "cd /tmp && pgbench -U memhouse -n $* memhouse_spike" 2>&1 | grep -E 'number of transactions actually processed|latency average|latency stddev|tps ='; }
p95() { docker exec "$C" sh -c "cat /tmp/$1.* | awk '{print \$3}' | sort -n | awk '{a[NR]=\$1} END {printf \"p50 %.2f ms, p95 %.2f ms, p99 %.2f ms (n=%d)\n\", a[int(NR*0.5)]/1000, a[int(NR*0.95)]/1000, a[int(NR*0.99)]/1000, NR}'; rm -f /tmp/$1.*"; }

echo "## Intake queue (Postgres table, FOR UPDATE SKIP LOCKED, synchronous commit on)"
psql -d memhouse_spike < queue_schema.sql
echo "### enqueue, 16 clients, 20 s"; bench "-c 16 -j 4 -T 20 -f queue_enqueue.sql"
echo "### claim + finish, 16 workers, 20 s"; bench "-c 16 -j 4 -T 20 -f queue_claim.sql"
echo "### claim + finish, 64 workers, 20 s"; bench "-c 64 -j 8 -T 20 -f queue_claim.sql"

echo; echo "## Authorization check (relationship tuples in Postgres, uncached)"
psql -d memhouse_spike < authz_schema.sql
docker exec "$C" psql -U memhouse -d memhouse_spike -Atc "SELECT count(*) || ' tuples' FROM spike_tuple"
echo "### 1 client, 20 s"; bench "-c 1 -T 20 -f authz_check.sql --log --log-prefix=/tmp/az1"; p95 az1
echo "### 16 clients, 20 s"; bench "-c 16 -j 4 -T 20 -f authz_check.sql --log --log-prefix=/tmp/az16"; p95 az16
docker exec "$C" psql -U memhouse -d memhouse_spike -Atc "SELECT round(100.0 * count(*) FILTER (WHERE r <> 'deny') / count(*), 1) || '% of random pairs granted' FROM (SELECT (SELECT coalesce((SELECT 'treating' FROM spike_tuple WHERE object = 'patient:' || p AND relation = 'treating' AND subject = 'clinician:' || c AND (valid_to IS NULL OR valid_to > now()) LIMIT 1), 'deny')) r FROM (SELECT (random() * 99999 + 1)::int p, (random() * 4999 + 1)::int c FROM generate_series(1, 2000)) x) y"
