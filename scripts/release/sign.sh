#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Keyless Sigstore signatures (RL-02, SC-01) for the files a person downloads by hand:
# SHA256SUMS, which covers every artefact, and each binary archive. For <file> it writes
# <file>.sigstore.json, a bundle holding the signature, the short-lived certificate and the
# transparency-log proof; `cosign verify-blob --bundle` needs nothing else.
#
#   scripts/release/sign.sh <dir>
#
# Runs in the release workflow, where cosign takes the job's OIDC identity (`id-token: write`):
# no key exists before or after. Run by hand it would open a browser and put the signer's
# e-mail address in the public log, so it refuses to run outside a workflow.
set -eu

[ $# -eq 1 ] || { echo "usage: scripts/release/sign.sh <dir>" >&2; exit 2; }
[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || { echo "sign.sh: no workflow OIDC identity here (ACTIONS_ID_TOKEN_REQUEST_URL is unset): release artefacts are signed only by the release workflow" >&2; exit 1; }
command -v cosign >/dev/null 2>&1 || { echo "sign.sh: cosign is not on PATH (scripts/release/tools.sh <dir> cosign)" >&2; exit 1; }
cd "$1"
[ -f SHA256SUMS ] || { echo "sign.sh: $1/SHA256SUMS is missing (scripts/release/checksums.sh)" >&2; exit 1; }
for f in SHA256SUMS memhouse-*-*-*.tar.gz; do
  [ -f "$f" ] || continue
  cosign sign-blob "$f" --bundle "$f.sigstore.json" --yes
  echo "signed $f"
done
