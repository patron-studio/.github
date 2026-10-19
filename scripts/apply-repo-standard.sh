#!/usr/bin/env bash
# Apply the Patron Studio repo standard (docs/repo-standard.md) to one or more
# repos. A dry run by default: prints the diff between each repo's current
# rules and the standard. Pass --apply to change them.
#
# Usage:
#   scripts/apply-repo-standard.sh [--apply] <owner/repo> [<owner/repo> ...]
#
# Per repo:
#   - "Protect main" ruleset: PR, 0 approvals, merge commit only, required
#     CI + Gitleaks check runs from GitHub Actions, no deletion or force push.
#     Bypass: the maintainers team in pull_request mode (a deliberate tick on
#     a PR in GitHub; no direct pushes).
#   - "Protect dev and staging" ruleset: PR, merge commit only, required
#     Gitleaks, no deletion or force push. Repo admins bypass always, so they
#     can push directly (slvrlake's /propagate). Replaces a "Protect dev" one.
#   - Classic branch protection on main removed; the rulesets replace it.
#   - Repo settings: auto-merge on, merge commits on, squash and rebase off.
#
# Refuses a repo until dev or main carries the standard workflows: CI and
# Gitleaks reported (a required check nothing reports blocks every merge), the
# local-ci fast path, the auto-merge workflow, and no squash merges.
#
# Requires: gh authenticated as an org admin. Claude's auto mode blocks it
# from running --apply, so run that yourself.

set -euo pipefail

APPLY=0
if [ "${1:-}" = "--apply" ]; then
  APPLY=1
  shift
fi
if [ "$#" -lt 1 ]; then
  echo "Usage: $0 [--apply] <owner/repo> [<owner/repo> ...]" >&2
  exit 1
fi

ACTIONS_APP_ID=15368         # GitHub Actions: only its check runs count
MAINTAINERS_TEAM_ID=16507662 # patron-studio/maintainers (Oliver)
ADMIN_ROLE_ID=5              # the Repository admin role

MAIN_RULESET=$(jq -n --argjson app "$ACTIONS_APP_ID" --argjson team "$MAINTAINERS_TEAM_ID" '{
  name: "Protect main",
  target: "branch",
  enforcement: "active",
  conditions: { ref_name: { include: ["refs/heads/main"], exclude: [] } },
  bypass_actors: [{ actor_id: $team, actor_type: "Team", bypass_mode: "pull_request" }],
  rules: [
    { type: "deletion" },
    { type: "non_fast_forward" },
    { type: "pull_request", parameters: {
        required_approving_review_count: 0,
        dismiss_stale_reviews_on_push: false,
        require_code_owner_review: false,
        require_last_push_approval: false,
        required_review_thread_resolution: false,
        allowed_merge_methods: ["merge"] } },
    { type: "required_status_checks", parameters: {
        strict_required_status_checks_policy: false,
        do_not_enforce_on_create: false,
        required_status_checks: [
          { context: "CI", integration_id: $app },
          { context: "Gitleaks", integration_id: $app } ] } }
  ]
}')

WORKING_RULESET=$(jq -n --argjson app "$ACTIONS_APP_ID" --argjson role "$ADMIN_ROLE_ID" '{
  name: "Protect dev and staging",
  target: "branch",
  enforcement: "active",
  conditions: { ref_name: { include: ["refs/heads/dev", "refs/heads/staging"], exclude: [] } },
  bypass_actors: [{ actor_id: $role, actor_type: "RepositoryRole", bypass_mode: "always" }],
  rules: [
    { type: "deletion" },
    { type: "non_fast_forward" },
    { type: "pull_request", parameters: {
        required_approving_review_count: 0,
        dismiss_stale_reviews_on_push: false,
        require_code_owner_review: false,
        require_last_push_approval: false,
        required_review_thread_resolution: false,
        allowed_merge_methods: ["merge"] } },
    { type: "required_status_checks", parameters: {
        strict_required_status_checks_policy: false,
        do_not_enforce_on_create: false,
        required_status_checks: [{ context: "Gitleaks", integration_id: $app }] } }
  ]
}')

SETTINGS='{"allow_auto_merge":true,"allow_merge_commit":true,"allow_squash_merge":false,"allow_rebase_merge":false}'

# Only the fields the standard sets, sorted, so a diff shows real changes and
# not the defaults GitHub fills in.
normalise() {
  jq -S '{name, enforcement, conditions,
    bypass_actors: [.bypass_actors[]? | {actor_id, actor_type, bypass_mode}],
    rules: [.rules[]? | if .type == "pull_request" then .parameters |= {
      allowed_merge_methods, dismiss_stale_reviews_on_push, require_code_owner_review,
      require_last_push_approval, required_approving_review_count,
      required_review_thread_resolution } else . end]}'
}

# Every workflow file on one branch, concatenated.
workflows() {
  local repo=$1 ref=$2 path paths
  paths=$(gh api "repos/$repo/contents/.github/workflows?ref=$ref" --jq '.[].path' 2>/dev/null) || return 0
  for path in $paths; do
    gh api -H 'Accept: application/vnd.github.raw' "repos/$repo/contents/$path?ref=$ref"
    echo
  done
}

# Prints what a branch's workflows lack for the standard, joined by "; ".
# PRs run the workflows from their own branch, so the branch work starts
# from (dev for omkai and airo, main for slvrlake) is the one that counts.
missing_on() {
  local wf
  wf=$(workflows "$1" "$2")
  local missing=()
  # `name: CI`, or a computed name that resolves to 'CI'.
  grep -qE "^ *name: *CI *$|'CI'" <<<"$wf" || missing+=("a job named CI")
  grep -qE "name: *Gitleaks" <<<"$wf" || missing+=("a job named Gitleaks")
  grep -qE "^ *local-ci:" <<<"$wf" || missing+=("the local-ci fast-path job")
  grep -q -- "--auto --merge" <<<"$wf" || missing+=("the auto-merge workflow")
  grep -q -- "--squash" <<<"$wf" && missing+=("no --squash merges (found one)")
  # The +-guard: macOS bash 3.2 treats an empty array as unset under set -u.
  (IFS=';'; echo "${missing[*]+${missing[*]}}")
}

# Creates or updates the ruleset matching one of `names` (a jq IN() list).
upsert() {
  local repo=$1 desired=$2 names=$3 id current
  id=$(gh api "repos/$repo/rulesets" --jq "[.[] | select(.name | IN($names))][0].id // empty")
  if [ -n "$id" ]; then
    current=$(gh api "repos/$repo/rulesets/$id" | normalise)
  else
    current='{}'
  fi
  local name
  name=$(jq -r .name <<<"$desired")
  if diff -q <(jq -S . <<<"$current") <(normalise <<<"$desired") >/dev/null; then
    echo "  = $name: already standard"
    return
  fi
  if [ -n "$id" ]; then
    echo "  ~ $name: update ruleset $id"
  else
    echo "  ~ $name: create"
  fi
  diff -u <(jq -S . <<<"$current") <(normalise <<<"$desired") | sed -n '3,$p' | sed 's/^/      /' || true
  [ "$APPLY" = 1 ] || return 0
  if [ -n "$id" ]; then
    gh api -X PUT "repos/$repo/rulesets/$id" --input - <<<"$desired" >/dev/null
  else
    gh api -X POST "repos/$repo/rulesets" --input - <<<"$desired" >/dev/null
  fi
  echo "    applied"
}

failed=0
for repo in "$@"; do
  echo "→ $repo"

  ready=""
  report=()
  for ref in dev main; do
    gh api "repos/$repo/branches/$ref" >/dev/null 2>&1 || continue
    gaps=$(missing_on "$repo" "$ref")
    if [ -z "$gaps" ]; then
      ready=$ref
      break
    fi
    report+=("$ref needs $gaps")
  done
  if [ -z "$ready" ]; then
    printf '  ✗ skipped: %s. Roll out the workflows first (docs/repo-standard.md).\n' "$(IFS=';'; echo "${report[*]-no dev or main branch}")"
    failed=1
    continue
  fi
  echo "  = workflows: standard on $ready"

  upsert "$repo" "$MAIN_RULESET" '"Protect main"'
  upsert "$repo" "$WORKING_RULESET" '"Protect dev and staging", "Protect dev"'

  if gh api "repos/$repo/branches/main/protection" >/dev/null 2>&1; then
    echo "  ~ classic protection on main: remove"
    if [ "$APPLY" = 1 ]; then
      gh api -X DELETE "repos/$repo/branches/main/protection" >/dev/null
      echo "    applied"
    fi
  else
    echo "  = classic protection on main: none"
  fi

  current=$(gh api "repos/$repo" --jq '{allow_auto_merge, allow_merge_commit, allow_squash_merge, allow_rebase_merge}')
  if [ "$(jq -S . <<<"$current")" = "$(jq -S . <<<"$SETTINGS")" ]; then
    echo "  = merge settings: already standard"
  else
    echo "  ~ merge settings: $(jq -c . <<<"$current") → $SETTINGS"
    if [ "$APPLY" = 1 ]; then
      gh api -X PATCH "repos/$repo" --input - <<<"$SETTINGS" >/dev/null
      echo "    applied"
    fi
  fi
done

[ "$APPLY" = 1 ] || echo "Dry run. Re-run with --apply to make these changes."
exit "$failed"
