#!/usr/bin/env bash
# Sync the Patron Studio standard Dependabot config into one or more repos.
#
# Dependabot config is NOT inherited from the org `.github` repo — every repo
# needs its own `.github/dependabot.yml`. This script copies the canonical
# template (templates/dependabot.yml) into each target repo via a PR.
#
# Usage:
#   scripts/sync-dependabot.sh <owner/repo> [<owner/repo> ...]
#
# Example:
#   scripts/sync-dependabot.sh \
#     patron-studio/patron-sales-dashboard \
#     patron-studio/patron-ui
#
# Requires: `gh` CLI authenticated with `repo` scope.
#
# What it does, per repo:
#   - Skips the repo if its `.github/dependabot.yml` already matches the template
#   - Creates a branch `chore/adopt-dependabot` off the default branch
#   - Adds/updates `.github/dependabot.yml` from templates/dependabot.yml
#   - Opens a PR titled "chore: adopt standard Dependabot config"
#
# The template assumes a single root lockfile (`directory: '/'`) and the npm
# ecosystem (covers npm/pnpm/yarn). Repos with a non-standard layout — multiple
# lockfiles, non-JS ecosystems — need their `directory` / `package-ecosystem`
# entries adjusted in the PR before merging.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/../templates/dependabot.yml"
BRANCH="${BRANCH:-chore/adopt-dependabot}"
TARGET_PATH=".github/dependabot.yml"
TITLE="chore: adopt standard Dependabot config"

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <owner/repo> [<owner/repo> ...]" >&2
  exit 1
fi

if [ ! -f "$TEMPLATE" ]; then
  echo "Template not found: $TEMPLATE" >&2
  exit 1
fi

CONTENT_B64="$(base64 < "$TEMPLATE" | tr -d '\n')"

PR_BODY="Adds the Patron Studio standard \`.github/dependabot.yml\` (synced from \`patron-studio/.github/templates/dependabot.yml\` via \`scripts/sync-dependabot.sh\`).

- Weekly grouped version updates: \`dev-dependencies\` (minor+patch) and \`prod-patches\` (patch).
- GitHub Actions version updates.
- Major bumps are ignored for manual review.

If this repo has a non-standard layout (multiple lockfiles, a non-JS ecosystem), adjust the \`directory\` / \`package-ecosystem\` entries before merging."

for repo in "$@"; do
  echo "→ $repo"

  default_branch="$(gh api "repos/$repo" --jq .default_branch)"

  # Skip if the deployed file already matches the template byte-for-byte.
  if existing="$(gh api "repos/$repo/contents/$TARGET_PATH?ref=$default_branch" --jq .content 2>/dev/null | base64 -d 2>/dev/null)"; then
    if [ "$existing" = "$(cat "$TEMPLATE")" ]; then
      echo "  ✓ already up to date — skipping"
      continue
    fi
  fi

  head_sha="$(gh api "repos/$repo/git/refs/heads/$default_branch" --jq .object.sha)"

  # Create the working branch (reset it to head if it already exists).
  if gh api "repos/$repo/git/refs/heads/$BRANCH" >/dev/null 2>&1; then
    gh api --method PATCH "repos/$repo/git/refs/heads/$BRANCH" \
      -f sha="$head_sha" -F force=true >/dev/null
  else
    gh api --method POST "repos/$repo/git/refs" \
      -f ref="refs/heads/$BRANCH" -f sha="$head_sha" >/dev/null
  fi

  # Commit the file (include the existing blob sha when updating in place).
  file_sha="$(gh api "repos/$repo/contents/$TARGET_PATH?ref=$BRANCH" --jq .sha 2>/dev/null || true)"
  if [ -n "$file_sha" ]; then
    gh api --method PUT "repos/$repo/contents/$TARGET_PATH" \
      -f message="$TITLE" -f content="$CONTENT_B64" \
      -f branch="$BRANCH" -f sha="$file_sha" >/dev/null
  else
    gh api --method PUT "repos/$repo/contents/$TARGET_PATH" \
      -f message="$TITLE" -f content="$CONTENT_B64" \
      -f branch="$BRANCH" >/dev/null
  fi

  # Open a PR (skip if one is already open for this branch).
  if [ -n "$(gh pr list --repo "$repo" --head "$BRANCH" --json number --jq '.[0].number' 2>/dev/null)" ]; then
    echo "  ✓ PR already open"
  else
    gh pr create --repo "$repo" --base "$default_branch" --head "$BRANCH" \
      --title "$TITLE" --body "$PR_BODY" >/dev/null
    echo "  ✓ PR opened"
  fi
done
