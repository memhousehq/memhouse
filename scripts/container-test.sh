#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Checks of the container image (roadmap G21; PK-02, DEP-08). Needs Docker, curl and python3.
#
#   scripts/container-test.sh [image]        # default memhouse:dev (docker build -t memhouse:dev .)
#
# 1. The image: runs as the unprivileged user 65532, has no shell, carries its OCI labels.
# 2. Lite in the container: `up --lite` and `serve` with a read-only root filesystem, every
#    capability dropped and no new privileges; /health answers (also through the image's own
#    health check); a memory is written and recalled; SIGTERM stops the server cleanly.
# 3. Stateless service (DEP-08): two replicas on one Postgres. A memory written through one
#    is recalled through the other; then every replica and the model cache are destroyed and
#    new ones started: nothing is lost and recall answers exactly as before. While one replica
#    is gone the other keeps answering.
#
# Every container, network and volume it makes is named memhouse-ct-* and removed at the end
# (KEEP=1 leaves them). Passwords and keys are generated for the run and never printed.
set -euo pipefail

IMAGE=${1:-memhouse:dev}
PGVECTOR_IMAGE=${PGVECTOR_IMAGE:-pgvector/pgvector:pg17@sha256:b513c48566e4777cd3370451400000c78eda6a08131d68f4c31d4a76f27bd8fd}
P=memhouse-ct
PORT_LITE=${PORT_LITE:-17077}
PORT_A=${PORT_A:-17078}
PORT_B=${PORT_B:-17079}
# The hardening the Helm chart applies (deploy/helm/memhouse/values.yaml), as docker flags.
HARDEN=(--read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges)

step() { printf '\n== %s\n' "$*"; }
fail() {
  printf 'container-test: %s\n' "$*" >&2
  exit 1
}
cleanup() {
  if [ "${KEEP:-0}" != 1 ]; then
    docker rm -f "$P-lite" "$P-a" "$P-b" "$P-pg" >/dev/null 2>&1 || true
    docker volume rm "$P-lite-data" "$P-models" "$P-pgdata" >/dev/null 2>&1 || true
    docker network rm "$P-net" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
cleanup

# Every request has its own time limit: a server that accepts the connection and then says
# nothing fails the check instead of holding the script.
wait_health() { # <port> <container>
  local deadline=$(($(date +%s) + 300))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    curl -sf --max-time 5 "http://127.0.0.1:$1/health" >/dev/null 2>&1 && return 0
    [ "$(docker inspect -f '{{.State.Running}}' "$2" 2>/dev/null)" = true ] || {
      docker logs "$2" 2>&1 | tail -20 >&2
      fail "$2 stopped before it answered /health"
    }
    sleep 1
  done
  fail "$2 did not answer /health within 300 s"
}
api() { # <port> <key> <path> <json>
  curl -sf --max-time 60 "http://127.0.0.1:$1$3" -H "authorization: Bearer $2" -H "content-type: application/json" -d "$4"
}
# The (id, content) pairs of a recall, one per line, in rank order.
hits() { python3 -c 'import json,sys; [print(h["memory"]["id"], h["memory"]["content"]) for h in json.load(sys.stdin)["hits"]]'; }
recall_until() { # <port> <key> <subject> <query> <text expected>
  for _ in $(seq 1 40); do
    api "$1" "$2" /v1/recall "{\"subject\":\"$3\",\"query\":\"$4\"}" | grep -F "$5" >/dev/null && return 0
    sleep 0.5
  done
  fail "recall on port $1 never returned '$5'"
}

step "image: unprivileged user, no shell, labels"
[ "$(docker image inspect -f '{{.Config.User}}' "$IMAGE")" = "65532:65532" ] || fail "the image's user is not 65532:65532"
if docker run --rm --entrypoint /bin/sh "$IMAGE" -c true >/dev/null 2>&1; then fail "the image has a shell"; fi
docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.licenses"}}' "$IMAGE" | grep -x 'Apache-2.0' >/dev/null || fail "the licence label is missing"
docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.source"}}' "$IMAGE" | grep -F 'github.com/memhousehq/memhouse' >/dev/null || fail "the source label is missing"
VERSION=$(docker run --rm "${HARDEN[@]}" "$IMAGE" --version)
echo "  $VERSION, $(($(docker image inspect -f '{{.Size}}' "$IMAGE") / 1000000)) MB, user $(docker image inspect -f '{{.Config.User}}' "$IMAGE")"

step "Lite: up, serve, health, remember, recall (read-only root, no capabilities)"
docker volume create "$P-lite-data" >/dev/null
T0=$(date +%s)
docker run --rm "${HARDEN[@]}" -v "$P-lite-data:/data" "$IMAGE" up --lite >/dev/null 2>&1 || fail "up --lite failed in the container"
docker run -d --name "$P-lite" "${HARDEN[@]}" -v "$P-lite-data:/data" -p "127.0.0.1:$PORT_LITE:7077" "$IMAGE" >/dev/null
wait_health "$PORT_LITE" "$P-lite"
echo "  first start (model download, schema, serve): $(($(date +%s) - T0)) s"
# The process inside is not root, whatever the image says.
docker top "$P-lite" -o uid,pid,comm 2>/dev/null | awk 'NR > 1 && $1 != "65532" { bad = 1 } END { exit bad }' || fail "a process in the container does not run as uid 65532"
docker exec "$P-lite" memhouse health | grep '"status":"ok"' >/dev/null || fail "memhouse health failed inside the container"
KEY=$(docker run --rm "${HARDEN[@]}" -v "$P-lite-data:/data" "$IMAGE" key)
api "$PORT_LITE" "$KEY" /v1/remember '{"subject":"customer:acme","content":"Acme renews on 2027-03-01 and prefers email","kind":"semantic","wait":true}' >/dev/null
recall_until "$PORT_LITE" "$KEY" customer:acme "when does Acme renew" "2027-03-01"
[ "$(curl -s --max-time 30 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT_LITE/v1/stats")" = 401 ] || fail "an unauthenticated call was not refused"
# The root filesystem is read-only: a write outside /data and /tmp must fail.
if docker exec -e MEMHOUSE_HOME=/home/nonroot/elsewhere "$P-lite" memhouse up --lite >/dev/null 2>&1; then fail "the root filesystem is writable"; fi
T0=$(date +%s)
docker stop -t 25 "$P-lite" >/dev/null
[ "$(docker inspect -f '{{.State.ExitCode}}' "$P-lite")" = 0 ] || fail "the server did not exit cleanly on SIGTERM (exit $(docker inspect -f '{{.State.ExitCode}}' "$P-lite"))"
[ $(($(date +%s) - T0)) -lt 20 ] || fail "the server needed the kill timeout to stop"
echo "  SIGTERM: clean exit in $(($(date +%s) - T0)) s"
# What was written is there for the next container (the volume is the state in Lite).
docker rm "$P-lite" >/dev/null
docker run -d --name "$P-lite" "${HARDEN[@]}" -v "$P-lite-data:/data" -p "127.0.0.1:$PORT_LITE:7077" "$IMAGE" >/dev/null
wait_health "$PORT_LITE" "$P-lite"
recall_until "$PORT_LITE" "$KEY" customer:acme "when does Acme renew" "2027-03-01"
docker rm -f "$P-lite" >/dev/null

step "Standard: two replicas on one Postgres (DEP-08)"
PGPASS=$(openssl rand -hex 16)
APIKEY="mh_$(openssl rand -hex 24)"
docker network create "$P-net" >/dev/null
docker volume create "$P-models" >/dev/null
docker run -d --name "$P-pg" --network "$P-net" -e POSTGRES_USER=memhouse -e POSTGRES_PASSWORD="$PGPASS" -e POSTGRES_DB=memhouse -v "$P-pgdata:/var/lib/postgresql/data" "$PGVECTOR_IMAGE" >/dev/null
for _ in $(seq 1 60); do docker exec "$P-pg" pg_isready -U memhouse -d memhouse >/dev/null 2>&1 && break; sleep 1; done
replica() { # <name> <port>
  docker run -d --name "$1" --network "$P-net" "${HARDEN[@]}" -v "$P-models:/data" -p "127.0.0.1:$2:7077" \
    -e MEMHOUSE_DATABASE_URL="postgres://memhouse:$PGPASS@$P-pg:5432/memhouse" -e MEMHOUSE_API_KEY="$APIKEY" "$IMAGE" >/dev/null
}
# Both at once, on an empty database: the schema migration is taken by one and waited for by the other.
replica "$P-a" "$PORT_A"
replica "$P-b" "$PORT_B"
wait_health "$PORT_A" "$P-a"
wait_health "$PORT_B" "$P-b"
api "$PORT_A" "$APIKEY" /v1/remember '{"subject":"customer:globex","content":"Globex signed the three-year contract on 2026-10-12","kind":"semantic","wait":true}' >/dev/null
api "$PORT_A" "$APIKEY" /v1/remember '{"subject":"customer:globex","content":"Globex wants invoices sent to the finance team, not to the buyer","kind":"preference","wait":true}' >/dev/null
recall_until "$PORT_B" "$APIKEY" customer:globex "when did Globex sign" "2026-10-12"
recall_until "$PORT_B" "$APIKEY" customer:globex "where do invoices go" "finance team"
QUERY='{"subject":"customer:globex","query":"what do we know about the Globex contract and invoices"}'
BEFORE=$(api "$PORT_B" "$APIKEY" /v1/recall "$QUERY" | hits)
[ "$(printf '%s\n' "$BEFORE" | wc -l | tr -d ' ')" -ge 2 ] || fail "the recall before the restart has fewer than two hits"
echo "  written through replica a, recalled through replica b: $(printf '%s\n' "$BEFORE" | wc -l | tr -d ' ') hits"

# One replica destroyed: the other answers, with the same result.
docker rm -f "$P-a" >/dev/null
[ "$(api "$PORT_B" "$APIKEY" /v1/recall "$QUERY" | hits)" = "$BEFORE" ] || fail "recall changed while a replica was gone"
# Every replica destroyed, and the model cache with them: all that is left is Postgres.
docker rm -f "$P-b" >/dev/null
docker volume rm "$P-models" >/dev/null
docker volume create "$P-models" >/dev/null
replica "$P-a" "$PORT_A"
replica "$P-b" "$PORT_B"
wait_health "$PORT_A" "$P-a"
wait_health "$PORT_B" "$P-b"
for port in "$PORT_A" "$PORT_B"; do
  AFTER=$(api "$port" "$APIKEY" /v1/recall "$QUERY" | hits)
  [ "$AFTER" = "$BEFORE" ] || {
    printf 'before:\n%s\nafter (port %s):\n%s\n' "$BEFORE" "$port" "$AFTER" >&2
    fail "recall is not what it was before every replica was destroyed"
  }
done
echo "  all replicas and the model cache destroyed and recreated: recall unchanged on both"

printf '\ncontainer-test: all checks passed (%s)\n' "$IMAGE"
