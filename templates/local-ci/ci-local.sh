#!/usr/bin/env bash
# Runs ci.yml's required "CI" job on this machine against the exact pushed
# commit, then records a `local-ci` commit status on it. On a PR into main,
# ci.yml's `local-ci` job finds that status and skips the GitHub CI run; any
# commit without it runs CI in full.
#
# Usage: `pnpm ci:local` on a clean, pushed dev, before opening the release
# PR. Keep the steps below in step with the `ci` job in ci.yml.
#
# Template from patron-studio/.github templates/local-ci/. Copy to
# scripts/ci-local.sh, add "ci:local": "bash scripts/ci-local.sh" to the root
# package.json, and fill in the two marked sections from the repo's ci.yml.
set -euo pipefail

fail() {
  echo "ci:local: $*" >&2
  exit 1
}

cd "$(git rev-parse --show-toplevel)"

[ -z "$(git status --porcelain)" ] ||
  fail 'the working tree has changes; commit or stash them so the run tests exactly the pushed commit.'

git fetch --quiet origin
sha=$(git rev-parse HEAD)
upstream=$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null) ||
  fail 'this branch has no upstream; push it first.'
[ "$sha" = "$(git rev-parse '@{upstream}')" ] ||
  fail "HEAD is not what $upstream points at; push or pull first."

# The PR's CI tests this commit merged into main. If main has changes this
# commit lacks, that merge is not what runs here, and ci.yml would ignore the
# status anyway.
merged=$(git merge-tree --write-tree origin/main HEAD) ||
  fail 'this commit conflicts with origin/main; merge main in first.'
[ "$merged" = "$(git rev-parse 'HEAD^{tree}')" ] ||
  fail 'origin/main has changes this commit lacks; merge main in first.'

# --- The CI job's env (copy its `env:` block as exports) ---
# export SKIP_ENV_VALIDATION=1

# --- The CI job's steps, in order ---
pnpm install --frozen-lockfile
# pnpm lint
# pnpm typecheck
# pnpm test

# A step that rewrote tracked files would mean the commit as pushed isn't
# what passed.
[ -z "$(git status --porcelain)" ] ||
  fail 'the run left changes in the working tree, so it did not test the commit as pushed.'
[ "$(git rev-parse HEAD)" = "$sha" ] || fail 'HEAD moved during the run.'

gh api --silent "repos/{owner}/{repo}/statuses/$sha" \
  -f state=success -f context=local-ci \
  -f description="pnpm ci:local passed on $(hostname -s)"
echo "ci:local: passed; recorded local-ci on ${sha:0:8}."

# A PR opened before this run started CI in full; a re-run takes the fast path.
run=$(gh run list --workflow ci.yml --commit "$sha" --event pull_request --limit 1 --json databaseId --jq '.[0].databaseId // empty')
if [ -n "$run" ]; then
  echo "ci:local: CI run $run already exists for this commit. Re-run it to skip: gh run cancel $run; gh run rerun $run"
fi
