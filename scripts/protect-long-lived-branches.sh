#!/usr/bin/env bash
# Create a repository ruleset that protects long-lived branches from deletion
# and force-push.
#
# Covers the permanent branches by exact name (main/master/dev/staging) and
# future long-lived branches by naming convention (release/*, hotfix/*,
# epic/*). "Restrict deletions" also overrides auto-delete-on-merge, so
# anything matching these patterns is safe from BOTH manual and automatic
# deletion. To protect a new long-lived branch in future, just name it with
# one of the blessed prefixes — no config change needed.
#
# Usage:
#   scripts/protect-long-lived-branches.sh <owner/repo> [<owner/repo> ...]
#
# Example:
#   scripts/protect-long-lived-branches.sh patron-studio/slvrlake
#
# Requires: `gh` CLI authenticated with `repo` / `admin:repo` scope.
#
# Repository rulesets work on private repos on the Team plan (unlike ORG-level
# rulesets on private repos, which are Enterprise-only — see org-settings.md).
# Re-running skips a repo that already has a same-named ruleset. To change the
# rule, edit the include list below, delete the old ruleset, then re-run.

set -euo pipefail

RULESET_NAME="protect-long-lived-branches"

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <owner/repo> [<owner/repo> ...]" >&2
  exit 1
fi

read -r -d '' RULESET_JSON <<JSON || true
{
  "name": "$RULESET_NAME",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": {
      "include": [
        "refs/heads/main",
        "refs/heads/master",
        "refs/heads/dev",
        "refs/heads/staging",
        "refs/heads/release/**/*",
        "refs/heads/hotfix/**/*",
        "refs/heads/epic/**/*"
      ],
      "exclude": []
    }
  },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" }
  ]
}
JSON

for repo in "$@"; do
  echo "→ $repo"
  if gh api "repos/$repo/rulesets" --jq '.[].name' 2>/dev/null \
       | grep -qx "$RULESET_NAME"; then
    echo "  • '$RULESET_NAME' already present, skipping"
    continue
  fi
  if printf '%s' "$RULESET_JSON" | gh api \
       --method POST --input - \
       "repos/$repo/rulesets" >/dev/null 2>/tmp/rs-err-$$; then
    echo "  ✓ ruleset created"
  else
    echo "  ✗ failed:"
    sed 's/^/      /' /tmp/rs-err-$$ | head -3
  fi
  rm -f /tmp/rs-err-$$
done
