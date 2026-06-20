#!/usr/bin/env bash
# Delete remote branches whose PR has already been merged, EXCEPT protected
# ones. Dry run by default — set APPLY=1 to actually delete.
#
# Uses merged PRs rather than `git branch --merged` so squash/rebase merges
# are caught: a squash-merged branch's tip is not an ancestor of main, so an
# ancestry check would miss it.
#
# Usage:
#   scripts/prune-merged-branches.sh <owner/repo>          # dry run (preview)
#   APPLY=1 scripts/prune-merged-branches.sh <owner/repo>  # actually delete
#
# Requires: `gh` CLI authenticated with `repo` scope.

set -euo pipefail

REPO="${1:?Usage: $0 <owner/repo>   (APPLY=1 to delete)}"

# Never delete: permanent branches (exact match) + long-lived prefixes.
KEEP_REGEX='^(main|master|dev|develop|staging)$|^(release|hotfix|epic)/'

gh pr list --repo "$REPO" --state merged --limit 1000 \
  --json headRefName --jq '.[].headRefName' \
| sort -u \
| while read -r branch; do
    [ -z "$branch" ] && continue
    if [[ "$branch" =~ $KEEP_REGEX ]]; then
      echo "keep          $branch"
      continue
    fi
    # Only act on branches that still exist on the remote.
    if ! gh api "repos/$REPO/branches/$branch" >/dev/null 2>&1; then
      continue
    fi
    if [ "${APPLY:-0}" = "1" ]; then
      if gh api --method DELETE \
           "repos/$REPO/git/refs/heads/$branch" >/dev/null 2>&1; then
        echo "deleted       $branch"
      else
        echo "FAILED delete $branch"
      fi
    else
      echo "would delete  $branch"
    fi
  done

if [ "${APPLY:-0}" != "1" ]; then
  echo
  echo "(dry run — re-run with APPLY=1 to delete the branches listed above)"
fi
