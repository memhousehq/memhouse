#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Create and configure the public repositories on GitHub, then push (roadmap G09). Run it only
# after the founder has signed off the checklist (private-repo/publication-signoff.md).
#
# Prints every command and changes nothing unless DRY_RUN=0. Needs the GitHub CLI logged in as
# an organisation owner (`gh auth login`, with 2FA on the account). Order matters: the
# repositories are created private, configured and pushed, CI runs, and only then are they made
# public (PUBLIC=1, a separate, deliberate run).
#
#   DRY_RUN=0 scripts/publish/forge-setup.sh [publish.env]          # create, configure, push
#   DRY_RUN=0 PUBLIC=1 scripts/publish/forge-setup.sh [publish.env] # make both repositories public
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/../.." && pwd)"
# shellcheck disable=SC1090
source "${1:-$here/publish.env}"
: "${ORG:?}" "${REPO:?}" "${FORMAT_REPO:?}" "${WORKDIR:?}"
case "$WORKDIR" in /*) work="$WORKDIR" ;; *) work="$src/$WORKDIR" ;; esac
DRY_RUN="${DRY_RUN:-1}"

run() {
  printf '+ %s\n' "$*"
  if [ "$DRY_RUN" = 0 ]; then "$@"; fi
}

api() { run gh api -H "Accept: application/vnd.github+json" "$@"; }

if [ "${PUBLIC:-0}" = 1 ]; then
  for r in "$REPO" "$FORMAT_REPO"; do
    run gh repo edit "$ORG/$r" --visibility public --accept-visibility-change-consequences
  done
  echo "Both repositories are public. Check a fresh public clone: git clone https://github.com/$ORG/$REPO && cd $REPO && cargo xtask ci"
  exit 0
fi

if [ "$DRY_RUN" = 0 ]; then
  command -v gh >/dev/null || { echo "the GitHub CLI (gh) is not installed"; exit 1; }
  gh auth status
fi

echo "== team"
api -X POST "orgs/$ORG/teams" -f name=maintainers -f privacy=closed -f description="MemHouse maintainers" || true
me=$( [ "$DRY_RUN" = 0 ] && gh api user -q .login || echo YOUR_LOGIN )
api -X PUT "orgs/$ORG/teams/maintainers/memberships/$me" -f role=maintainer

configure() {
  local r="$1" desc="$2" checks="$3"
  echo "== $ORG/$r"
  run gh repo create "$ORG/$r" --private --description "$desc" --disable-wiki
  api -X PATCH "repos/$ORG/$r" -F has_discussions=true -F has_projects=false -F delete_branch_on_merge=true \
    -F allow_merge_commit=false -F allow_rebase_merge=true -F allow_squash_merge=true \
    -F web_commit_signoff_required=true
  api -X PUT "orgs/$ORG/teams/maintainers/repos/$ORG/$r" -f permission=maintain
  # Security: alerts, Dependabot security updates, private vulnerability reporting, secret scanning
  # with push protection (free on public repositories; on private ones they need Advanced Security
  # until the repository is made public, when they are switched on again below).
  api -X PUT "repos/$ORG/$r/vulnerability-alerts"
  api -X PUT "repos/$ORG/$r/automated-security-fixes"
  api -X PUT "repos/$ORG/$r/private-vulnerability-reporting"
  api -X PATCH "repos/$ORG/$r" --input - <<JSON
{"security_and_analysis": {"secret_scanning": {"status": "enabled"}, "secret_scanning_push_protection": {"status": "enabled"}}}
JSON
  # Actions: read-only token by default; fork pull requests from first-time contributors need a
  # maintainer's approval to run; only GitHub's own and the pinned third-party actions are allowed.
  api -X PUT "repos/$ORG/$r/actions/permissions/workflow" -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
  api -X PUT "repos/$ORG/$r/actions/permissions" -F enabled=true -f allowed_actions=selected
  api -X PUT "repos/$ORG/$r/actions/permissions/selected-actions" --input - <<'JSON'
{"github_owned_allowed": true, "verified_allowed": false, "patterns_allowed": ["dtolnay/rust-toolchain@*", "taiki-e/install-action@*"]}
JSON
  api -X PUT "repos/$ORG/$r/actions/permissions/fork-pr-contributor-approval" -f approval_policy=first_time_contributors
  # main: pull requests only, one approval, code owners, the required checks, linear history, no
  # force pushes or deletion. Organisation admins can bypass in an emergency (logged).
  api -X POST "repos/$ORG/$r/rulesets" --input - <<JSON
{"name": "main", "target": "branch", "enforcement": "active",
 "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
 "bypass_actors": [{"actor_id": 1, "actor_type": "OrganizationAdmin", "bypass_mode": "pull_request"}],
 "rules": [
  {"type": "deletion"}, {"type": "non_fast_forward"}, {"type": "required_linear_history"},
  {"type": "pull_request", "parameters": {"required_approving_review_count": 1, "dismiss_stale_reviews_on_push": true,
    "require_code_owner_review": true, "require_last_push_approval": true, "required_review_thread_resolution": true}},
  {"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": true,
    "required_status_checks": $checks}}
 ]}
JSON
  # Release tags: only maintainers create them, and they must be signed.
  api -X POST "repos/$ORG/$r/rulesets" --input - <<'JSON'
{"name": "release tags", "target": "tag", "enforcement": "active",
 "conditions": {"ref_name": {"include": ["refs/tags/v*"], "exclude": []}},
 "bypass_actors": [{"actor_id": 1, "actor_type": "OrganizationAdmin", "bypass_mode": "always"}],
 "rules": [{"type": "creation"}, {"type": "update"}, {"type": "deletion"}, {"type": "required_signatures"}]}
JSON
}

configure "$REPO" "Governed long-term memory for AI agents: Rust + Postgres, REST and MCP" \
  '[{"context": "checks"}, {"context": "e2e and benchmark guard (T1)"}]'
configure "$FORMAT_REPO" "The MemHouse Memory Format: specification and conformance vectors" '[]'

echo "== labels ($REPO)"
python3 - "$src/.github/labels.yml" <<'PY' | while IFS=$'\t' read -r name color desc; do run gh label create "$name" --repo "$ORG/$REPO" --color "$color" --description "$desc" --force; done
import re, sys
for line in open(sys.argv[1]):
    m = re.match(r"- \{name: (.+?), color: (\w+), description: (.+)\}$", line.strip())
    if m:
        print("\t".join(m.groups()))
PY

echo "== the reviewer-gated environment for paid benchmarks ($REPO)"
team_id=$( [ "$DRY_RUN" = 0 ] && gh api "orgs/$ORG/teams/maintainers" -q .id || echo 0 )
api -X PUT "repos/$ORG/$REPO/environments/benchmarks" --input - <<JSON
{"wait_timer": 0, "prevent_self_review": false,
 "reviewers": [{"type": "Team", "id": $team_id}],
 "deployment_branch_policy": {"protected_branches": true, "custom_branch_policies": false}}
JSON
echo "   Then, by hand (the value is typed, never stored in a file):"
echo "   gh secret set OPENAI_API_KEY --repo $ORG/$REPO --env benchmarks"
echo "   gh variable set LLM_BASE_URL --repo $ORG/$REPO --env benchmarks --body https://openrouter.ai/api/v1"

echo "== push"
run git -C "$work/memhouse" push "https://github.com/$ORG/$REPO.git" main
run git -C "$work/memory-format" push "https://github.com/$ORG/$FORMAT_REPO.git" main

echo
echo "Next: wait for the ci workflow to pass on main, then make both repositories public:"
echo "  DRY_RUN=0 PUBLIC=1 scripts/publish/forge-setup.sh"
