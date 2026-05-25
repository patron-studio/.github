#!/usr/bin/env bash
# Apply the Patron Studio standard branch protection to one or more repos.
#
# Usage:
#   scripts/apply-branch-protection.sh <repo> [<repo> ...]
#
# Example:
#   scripts/apply-branch-protection.sh \
#     patron-studio/patron-sales-dashboard \
#     patron-studio/patron-ui \
#     patron-studio/patron-emailer
#
# Requires: `gh` CLI authenticated with `repo` scope.
#
# What gets applied to `main` on each repo:
#   - Require a PR (no direct push)
#   - Require 1 approving review, dismiss stale reviews on new commit
#   - Require Code Owners review (uses each repo's .github/CODEOWNERS,
#     falling back to the org-defaults CODEOWNERS in patron-studio/.github)
#   - Require conversation resolution before merge
#   - Block force pushes and deletions
#
# Status-check requirements are intentionally NOT applied here because
# different repos have different workflow names. Add them per-repo in the
# GitHub UI once you've adopted the right templates.
#
# To also protect `dev` on a repo, re-run with `BRANCH=dev`:
#   BRANCH=dev scripts/apply-branch-protection.sh patron-studio/foo

set -euo pipefail

BRANCH="${BRANCH:-main}"

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <owner/repo> [<owner/repo> ...]" >&2
  exit 1
fi

# `gh api -F field=` can't set fields to JSON null. The branch-protection
# endpoint requires required_status_checks + restrictions to be null when
# unused. Use JSON-on-stdin via `--input -` instead.
read -r -d '' PROTECTION_JSON <<'JSON' || true
{
  "required_status_checks": null,
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": true,
    "require_last_push_approval": false
  },
  "restrictions": null,
  "required_linear_history": false,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": true,
  "lock_branch": false,
  "allow_fork_syncing": false
}
JSON

for repo in "$@"; do
  echo "→ $repo ($BRANCH)"
  if printf '%s' "$PROTECTION_JSON" | gh api \
       --method PUT \
       --input - \
       "repos/$repo/branches/$BRANCH/protection" \
       >/dev/null 2>/tmp/protect-err-$$; then
    echo "  ✓ protected"
  else
    echo "  ✗ failed:"
    sed 's/^/      /' /tmp/protect-err-$$ | head -3
  fi
  rm -f /tmp/protect-err-$$
done
