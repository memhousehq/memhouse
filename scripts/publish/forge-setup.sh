#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Configure GitHub and push the repositories built by prepare.sh (roadmap G09).
#
# Prints every command and changes nothing unless DRY_RUN=0. Needs the GitHub CLI logged in as an
# owner of the organisation (`gh auth login`). Three steps:
#
#   STEP=rehearse   a temporary PRIVATE repository $ORG/$REPO-rehearsal with main pushed, so CI
#                   runs on a clean runner first. Delete it afterwards (the script says how).
#   STEP=publish    creates $ORG/$REPO and $ORG/$FORMAT_REPO as PRIVATE repositories (refuses if
#                   they exist), pushes main, applies settings and labels. CI runs on main.
#   STEP=public     makes both public, then turns on secret scanning, push protection, Dependabot
#                   security updates, private vulnerability reporting and the rulesets (on the free
#                   plan these need a public repository). This is the publication.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/../.." && pwd)"
# shellcheck disable=SC1090
source "${PUBLISH_ENV:-$here/publish.env}"
: "${ORG:?}" "${REPO:?}" "${FORMAT_REPO:?}" "${WORKDIR:?}" "${GITHUB_LOGIN:?}"
case "$WORKDIR" in /*) work="$WORKDIR" ;; *) work="$src/$WORKDIR" ;; esac
DRY_RUN="${DRY_RUN:-1}"
STEP="${STEP:?set STEP=rehearse, publish or public}"

run() {
  printf '+ %s\n' "$*"
  if [ "$DRY_RUN" = 0 ]; then "$@"; fi
}
api() { run gh api -H "Accept: application/vnd.github+json" "$@"; }

# Push over the protocol gh is configured for. SSH needs no extra token scope for workflow files;
# GitHub's host keys come from its API (over HTTPS) when known_hosts doesn't have them yet.
remote() { printf '%s' "$remote_base$1.git"; }
remote_base="https://github.com/"
if [ "$(gh config get git_protocol -h github.com 2>/dev/null || true)" = ssh ]; then
  remote_base="git@github.com:"
  if ! ssh-keygen -F github.com >/dev/null 2>&1; then
    kh="$(mktemp)"
    gh api meta -q '.ssh_keys[]' | sed 's/^/github.com /' > "$kh"
    export GIT_SSH_COMMAND="ssh -o UserKnownHostsFile=$kh -o StrictHostKeyChecking=yes"
  fi
fi

[ -d "$work/$REPO/.git" ] || { echo "$work/$REPO not found: run prepare.sh first"; exit 1; }
if [ "$DRY_RUN" = 0 ]; then
  command -v gh >/dev/null || { echo "the GitHub CLI (gh) is not installed: brew install gh"; exit 1; }
  me=$(gh api user -q .login)
  [ "$me" = "$GITHUB_LOGIN" ] || { echo "gh is logged in as $me, expected $GITHUB_LOGIN"; exit 1; }
fi

# Repository settings shared by both repositories: merges, sign-off on web commits, security
# features (free on public repositories), and Actions limited to a read-only token and to GitHub's
# own and the pinned third-party actions.
settings() {
  local r="$1"
  api -X PATCH "repos/$ORG/$r" -F has_wiki=false -F has_projects=false -F delete_branch_on_merge=true \
    -F allow_merge_commit=false -F allow_rebase_merge=true -F allow_squash_merge=true \
    -F web_commit_signoff_required=true
  api -X PUT "repos/$ORG/$r/actions/permissions/workflow" -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
  api -X PUT "repos/$ORG/$r/actions/permissions" -F enabled=true -f allowed_actions=selected
  api -X PUT "repos/$ORG/$r/actions/permissions/selected-actions" --input - <<'JSON'
{"github_owned_allowed": true, "verified_allowed": false, "patterns_allowed": ["dtolnay/rust-toolchain@*", "taiki-e/install-action@*"]}
JSON
  api -X PUT "repos/$ORG/$r/actions/permissions/fork-pr-contributor-approval" -f approval_policy=first_time_contributors
}

security() {
  local r="$1"
  api -X PUT "repos/$ORG/$r/vulnerability-alerts"
  api -X PUT "repos/$ORG/$r/automated-security-fixes"
  api -X PUT "repos/$ORG/$r/private-vulnerability-reporting"
  api -X PATCH "repos/$ORG/$r" --input - <<'JSON'
{"security_and_analysis": {"secret_scanning": {"status": "enabled"}, "secret_scanning_push_protection": {"status": "enabled"}}}
JSON
}

# main: pull requests only (no approval required while there is one maintainer), the required
# checks, linear history, no force pushes or deletion; organisation admins may bypass through a
# pull request. Release tags can't be moved or deleted.
rulesets() {
  local r="$1" checks="$2"
  local status_rule=""
  [ "$checks" = "[]" ] || status_rule=', {"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": true, "required_status_checks": '"$checks"'}}'
  api -X POST "repos/$ORG/$r/rulesets" --input - <<JSON
{"name": "main", "target": "branch", "enforcement": "active",
 "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
 "bypass_actors": [{"actor_id": 1, "actor_type": "OrganizationAdmin", "bypass_mode": "pull_request"}],
 "rules": [
  {"type": "deletion"}, {"type": "non_fast_forward"}, {"type": "required_linear_history"},
  {"type": "pull_request", "parameters": {"required_approving_review_count": 0, "dismiss_stale_reviews_on_push": true,
    "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": true}}$status_rule
 ]}
JSON
  api -X POST "repos/$ORG/$r/rulesets" --input - <<'JSON'
{"name": "release tags", "target": "tag", "enforcement": "active",
 "conditions": {"ref_name": {"include": ["refs/tags/v*"], "exclude": []}},
 "rules": [{"type": "update"}, {"type": "deletion"}]}
JSON
}

if [ "$STEP" = rehearse ]; then
  r="$REPO-rehearsal"
  echo "== private rehearsal repository $ORG/$r"
  run gh repo create "$ORG/$r" --private --description "Temporary: CI rehearsal before publication"
  api -X PUT "repos/$ORG/$r/actions/permissions/workflow" -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
  run git -C "$work/$REPO" push "$(remote "$ORG/$r")" main
  echo
  echo "Watch the run:   gh run watch --repo $ORG/$r"
  echo "When it passes:  gh repo delete $ORG/$r   (needs: gh auth refresh -s delete_repo)"
  echo "Then:            STEP=publish DRY_RUN=0 scripts/publish/forge-setup.sh"
  exit 0
fi

checks='[{"context": "checks"}, {"context": "end-to-end and governance suite"}]'

if [ "$STEP" = publish ]; then
  for r in "$REPO" "$FORMAT_REPO"; do
    if [ "$DRY_RUN" = 0 ] && gh api "repos/$ORG/$r" -q .full_name 2>/dev/null | grep -qx "$ORG/$r"; then
      echo "$ORG/$r already exists; this step only creates new repositories"; exit 1
    fi
  done
  echo "== $ORG/$REPO (private)"
  run gh repo create "$ORG/$REPO" --private --description "Governed long-term memory for AI agents: Rust + Postgres, REST and MCP"
  settings "$REPO"
  api -X PATCH "repos/$ORG/$REPO" -F has_discussions=true
  run git -C "$work/$REPO" push "$(remote "$ORG/$REPO")" main
  echo "== labels ($REPO)"
  python3 - "$src/.github/labels.yml" <<'PY' | while IFS=$'\t' read -r name color desc; do run gh label create "$name" --repo "$ORG/$REPO" --color "$color" --description "$desc" --force; done
import re, sys
for line in open(sys.argv[1]):
    m = re.match(r"- \{name: (.+?), color: (\w+), description: (.+)\}$", line.strip())
    if m:
        print("\t".join(m.groups()))
PY
  echo "== $ORG/$FORMAT_REPO (private)"
  run gh repo create "$ORG/$FORMAT_REPO" --private --description "The MemHouse Memory Format: specification and conformance vectors"
  settings "$FORMAT_REPO"
  run git -C "$work/memory-format" push "$(remote "$ORG/$FORMAT_REPO")" main
  echo
  echo "Both are private. Watch CI: gh run watch --repo $ORG/$REPO"
  echo "Then publish:             STEP=public DRY_RUN=0 scripts/publish/forge-setup.sh"
  exit 0
fi

[ "$STEP" = public ] || { echo "unknown STEP=$STEP"; exit 1; }
for r in "$REPO" "$FORMAT_REPO"; do
  echo "== $ORG/$r: public"
  run gh repo edit "$ORG/$r" --visibility public --accept-visibility-change-consequences
  security "$r"
done
rulesets "$REPO" "$checks"
rulesets "$FORMAT_REPO" '[]'
echo
echo "Published. Check a fresh public clone: git clone https://github.com/$ORG/$REPO && cd $REPO && cargo xtask ci"
