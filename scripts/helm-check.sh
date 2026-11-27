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

for f in "$WORK/minimal.yaml" "$WORK/full.yaml"; do
  has "$f" "runAsNonRoot: true"
  has "$f" "runAsUser: 65532"
  has "$f" "readOnlyRootFilesystem: true"
  has "$f" "allowPrivilegeEscalation: false"
  has "$f" "- ALL"
  has "$f" "type: RuntimeDefault"
  has "$f" "automountServiceAccountToken: false"
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
