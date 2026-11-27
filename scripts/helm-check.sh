#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Checks of the Helm chart (roadmap G21; DEP-05). Needs helm on PATH
# (scripts/release/tools.sh <dir> helm installs the pinned version). No cluster is contacted.
#
#   scripts/helm-check.sh
#
# Lints the chart, renders it with the minimal values and with every optional part on, and
# holds the rendered manifests to what the chart promises: non-root, read-only root
# filesystem, no capabilities, no service-account token, the database URL only from a Secret,
# no password anywhere; and the values the schema must refuse are refused.
set -euo pipefail
cd "$(dirname "$0")/.."

CHART=deploy/helm/memhouse
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail() {
  printf 'helm-check: FAILED: %s\n' "$*" >&2
  exit 1
}
has() { grep -F -- "$2" "$1" >/dev/null || fail "$1 lacks: $2"; }
lacks() { if grep -iE -- "$2" "$1" >/dev/null; then fail "$1 holds: $2"; fi; }

helm version --short
helm lint "$CHART" --strict --set database.existingSecret=memhouse-db
helm lint "$CHART" --strict -f "$CHART/ci/test-values.yaml"

helm template mh "$CHART" --namespace memhouse --set database.existingSecret=memhouse-db >"$WORK/minimal.yaml"
helm template mh "$CHART" --namespace memhouse -f "$CHART/ci/test-values.yaml" >"$WORK/full.yaml"

# The hardening, on each workload by itself: the test Pod repeats the Deployment's settings,
# so a search of the whole render would still pass if the Deployment lost them.
for values in "--set database.existingSecret=memhouse-db" "-f $CHART/ci/test-values.yaml"; do
  for workload in deployment tests/health; do
    # shellcheck disable=SC2086  # the values arguments, split on purpose
    helm template mh "$CHART" --namespace memhouse $values --show-only "templates/$workload.yaml" >"$WORK/workload.yaml"
    has "$WORK/workload.yaml" "runAsNonRoot: true"
    has "$WORK/workload.yaml" "runAsUser: 65532"
    has "$WORK/workload.yaml" "readOnlyRootFilesystem: true"
    has "$WORK/workload.yaml" "allowPrivilegeEscalation: false"
    has "$WORK/workload.yaml" "- ALL"
    has "$WORK/workload.yaml" "type: RuntimeDefault"
    has "$WORK/workload.yaml" "automountServiceAccountToken: false"
  done
done

for f in "$WORK/minimal.yaml" "$WORK/full.yaml"; do
  has "$f" "kind: Deployment"
  has "$f" "kind: ServiceAccount"
  has "$f" "name: MEMHOUSE_DATABASE_URL"
  has "$f" 'name: "memhouse-db"'
  has "$f" 'key: "database-url"'
  has "$f" "path: /health"
  has "$f" 'bind = "0.0.0.0:7077"'
  has "$f" "kind: PodDisruptionBudget"
  # No secret value can come out of the chart: it has none to render.
  lacks "$f" 'postgres(ql)?://'
  lacks "$f" 'password'
done
has "$WORK/minimal.yaml" "replicas: 2"
lacks "$WORK/minimal.yaml" 'kind: Ingress'
lacks "$WORK/minimal.yaml" 'MEMHOUSE_API_KEY'
VERSION=$(sed -n 's/^appVersion: "\(.*\)"$/\1/p' "$CHART/Chart.yaml")
has "$WORK/minimal.yaml" "image: \"ghcr.io/memhousehq/memhouse:$VERSION\""
has "$WORK/full.yaml" "kind: Ingress"
has "$WORK/full.yaml" 'public_url = "https://memhouse.example.com"'
has "$WORK/full.yaml" 'template = "support"'
has "$WORK/full.yaml" "name: MEMHOUSE_API_KEY"
has "$WORK/full.yaml" 'name: "memhouse-admin"'
has "$WORK/full.yaml" "secretName: memhouse-tls"

# Numbers in a values file reach the configuration as what they are: Helm reads every number
# of a values file as a float, and `max_connections = 32.0` would stop the server at start-up.
cat >"$WORK/numbers.yaml" <<'VALUES'
database:
  existingSecret: memhouse-db
config:
  database:
    max_connections: 32
  memory:
    relevance_weight: 0.5
  intake:
    workers: 4
  language:
    enabled: [en, de]
VALUES
helm template mh "$CHART" -f "$WORK/numbers.yaml" --show-only templates/configmap.yaml >"$WORK/numbers.out"
has "$WORK/numbers.out" "max_connections = 32"
has "$WORK/numbers.out" "workers = 4"
has "$WORK/numbers.out" "relevance_weight = 0.5"
has "$WORK/numbers.out" 'enabled = ["en", "de"]'
lacks "$WORK/numbers.out" '= [0-9]+\.0$'

# A digest pins the image over the tag.
DIGEST=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
helm template mh "$CHART" --set database.existingSecret=memhouse-db --set image.digest=$DIGEST | grep -F "image: \"ghcr.io/memhousehq/memhouse@$DIGEST\"" >/dev/null || fail "image.digest is not used"

# What the schema refuses.
refused() { # <what> <helm args...>
  local what=$1
  shift
  if helm template mh "$CHART" "$@" >/dev/null 2>"$WORK/err"; then fail "$what was accepted"; fi
}
refused "no database Secret"
refused "a database URL as a value" --set database.existingSecret=memhouse-db --set database.url=postgres://example
refused "a database URL in config" --set database.existingSecret=memhouse-db --set config.database.url=postgres://example
refused "API keys in config" --set database.existingSecret=memhouse-db --set 'config.server.api_keys={mh_x}'
refused "an unknown value" --set database.existingSecret=memhouse-db --set replicas=3
refused "a malformed digest" --set database.existingSecret=memhouse-db --set image.digest=latest

helm package "$CHART" --destination "$WORK" >/dev/null
[ -f "$WORK/memhouse-$VERSION.tgz" ] || fail "helm package did not write memhouse-$VERSION.tgz"
echo "helm-check: all checks passed (chart and app version $VERSION)"
