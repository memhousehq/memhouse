#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Configure GitHub and push the repositories built by prepare.sh (roadmap G09).
#
# Prints every command and changes nothing unless DRY_RUN=0. Needs the GitHub CLI logged in as an
# owner of the organisation (`gh auth login`). Two steps:
#
#   STEP=rehearse DRY_RUN=0 scripts/publish/forge-setup.sh
#       creates a PRIVATE repository $ORG/$REPO-rehearsal and pushes main to it, so hosted CI runs
#       on a clean runner before anything is public. Delete it afterwards (the script says how).
#
#   STEP=publish DRY_RUN=0 scripts/publish/forge-setup.sh
#       $ORG/$REPO is already public (the Elixir 0.x implementation): its main is kept as branch
#       $LEGACY_BRANCH (its tags stay where they are), then main is replaced by the new history;
#       settings, security features, labels and rulesets are applied; $ORG/$FORMAT_REPO is
#       created and pushed. Everything pushed here is public at once.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/../.." && pwd)"
# shellcheck disable=SC1090
source "${PUBLISH_ENV:-$here/publish.env}"
: "${ORG:?}" "${REPO:?}" "${FORMAT_REPO:?}" "${WORKDIR:?}" "${LEGACY_BRANCH:?}" "${GITHUB_LOGIN:?}"
case "$WORKDIR" in /*) work="$WORKDIR" ;; *) work="$src/$WORKDIR" ;; esac
DRY_RUN="${DRY_RUN:-1}"
STEP="${STEP:?set STEP=rehearse or STEP=publish}"

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
  api -X PUT "repos/$ORG/$r/vulnerability-alerts"
  api -X PUT "repos/$ORG/$r/automated-security-fixes"
  api -X PUT "repos/$ORG/$r/private-vulnerability-reporting"
  api -X PATCH "repos/$ORG/$r" --input - <<'JSON'
{"security_and_analysis": {"secret_scanning": {"status": "enabled"}, "secret_scanning_push_protection": {"status": "enabled"}}}
JSON
  api -X PUT "repos/$ORG/$r/actions/permissions/workflow" -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
  api -X PUT "repos/$ORG/$r/actions/permissions" -F enabled=true -f allowed_actions=selected
  api -X PUT "repos/$ORG/$r/actions/permissions/selected-actions" --input - <<'JSON'
{"github_owned_allowed": true, "verified_allowed": false, "patterns_allowed": ["dtolnay/rust-toolchain@*", "taiki-e/install-action@*"]}
JSON
  api -X PUT "repos/$ORG/$r/actions/permissions/fork-pr-contributor-approval" -f approval_policy=first_time_contributors
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

[ "$STEP" = publish ] || { echo "unknown STEP=$STEP"; exit 1; }

echo "== $ORG/$REPO: keep the current main as $LEGACY_BRANCH"
old=$( [ "$DRY_RUN" = 0 ] && gh api "repos/$ORG/$REPO/git/ref/heads/main" -q .object.sha || echo OLD_MAIN_SHA )
echo "   current main: $old"
if [ "$DRY_RUN" = 0 ] && gh api "repos/$ORG/$REPO/git/ref/heads/$LEGACY_BRANCH" >/dev/null 2>&1; then
  echo "   $LEGACY_BRANCH already exists; left as it is"
else
  api -X POST "repos/$ORG/$REPO/git/refs" -f ref="refs/heads/$LEGACY_BRANCH" -f sha="$old"
fi
echo "   rulesets and branch protection that could refuse the force push:"
if [ "$DRY_RUN" = 0 ]; then
  gh api "repos/$ORG/$REPO/rulesets" -q '.[] | "     ruleset \(.id) \(.name) (\(.enforcement))"' || true
  gh api "repos/$ORG/$REPO/branches/main/protection" >/dev/null 2>&1 && echo "     classic branch protection on main: remove it in Settings > Branches first" || true
fi

echo "== $ORG/$REPO: replace main"
run git -C "$work/$REPO" push --force-with-lease="main:$old" "$(remote "$ORG/$REPO")" main
api -X PATCH "repos/$ORG/$REPO" -f description="Governed long-term memory for AI agents: Rust + Postgres, REST and MCP" \
  -F has_discussions=true
settings "$REPO"
echo "== labels ($REPO)"
python3 - "$src/.github/labels.yml" <<'PY' | while IFS=$'\t' read -r name color desc; do run gh label create "$name" --repo "$ORG/$REPO" --color "$color" --description "$desc" --force; done
import re, sys
for line in open(sys.argv[1]):
    m = re.match(r"- \{name: (.+?), color: (\w+), description: (.+)\}$", line.strip())
    if m:
        print("\t".join(m.groups()))
PY
rulesets "$REPO" '[{"context": "checks"}, {"context": "end-to-end and governance suite"}]'

echo "== $ORG/$FORMAT_REPO"
run gh repo create "$ORG/$FORMAT_REPO" --public --description "The MemHouse Memory Format: specification and conformance vectors"
run git -C "$work/memory-format" push "$(remote "$ORG/$FORMAT_REPO")" main
settings "$FORMAT_REPO"
rulesets "$FORMAT_REPO" '[]'

echo
echo "Published. Left to you:"
echo "  - check a fresh public clone: git clone https://github.com/$ORG/$REPO && cd $REPO && cargo xtask ci"
echo "  - the open issues and the GitHub Pages site belong to the Elixir version: close or label them,"
echo "    and unpublish the site in Settings > Pages if it should go"
echo "  - the 0.x releases and tags stay; $LEGACY_BRANCH holds their history"
