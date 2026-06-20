#!/usr/bin/env bash
# Enable "Automatically delete head branches" on one or more repos.
#
# After a PR merges, its source (head) branch is deleted automatically. This
# only ever deletes a MERGED PR's head branch — it never touches main/master/
# dev/staging, because those are merge targets, not merged heads.
#
# Usage:
#   scripts/set-auto-delete.sh <owner/repo> [<owner/repo> ...]
#
# Example:
#   scripts/set-auto-delete.sh patron-studio/slvrlake patron-studio/canons
#
# Requires: `gh` CLI authenticated with `repo` scope.
#
# This is a per-repo setting (`delete_branch_on_merge`). There is no org-wide
# toggle on the Team plan, so run it once per repo.

set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <owner/repo> [<owner/repo> ...]" >&2
  exit 1
fi

for repo in "$@"; do
  echo "→ $repo"
  if gh api --method PATCH "repos/$repo" \
       -F delete_branch_on_merge=true >/dev/null 2>/tmp/ad-err-$$; then
    echo "  ✓ auto-delete enabled"
  else
    echo "  ✗ failed:"
    sed 's/^/      /' /tmp/ad-err-$$ | head -3
  fi
  rm -f /tmp/ad-err-$$
done
