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
# Requires: `gh` CLI authenticated with `admin:org` + `repo` scopes.
# (If gh complains about scope, run: `gh auth refresh -h github.com -s admin:org,repo`)
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

for repo in "$@"; do
  echo "→ $repo ($BRANCH)"
  gh api \
    --method PUT \
    "repos/$repo/branches/$BRANCH/protection" \
    -F required_status_checks= \
    -F enforce_admins=false \
    -F 'required_pull_request_reviews[required_approving_review_count]=1' \
    -F 'required_pull_request_reviews[dismiss_stale_reviews]=true' \
    -F 'required_pull_request_reviews[require_code_owner_reviews]=true' \
    -F 'required_pull_request_reviews[require_last_push_approval]=false' \
    -F restrictions= \
    -F required_linear_history=false \
    -F allow_force_pushes=false \
    -F allow_deletions=false \
    -F required_conversation_resolution=true \
    -F lock_branch=false \
    -F allow_fork_syncing=false \
    >/dev/null 2>&1 && echo "  ✓ protected" || echo "  ✗ failed (default branch missing? insufficient scope?)"
done
