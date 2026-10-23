#!/usr/bin/env bash
# Check repos' GitHub Actions workflows against the CI standard
# (docs/ci-standard.md). Read-only: it reports drift and changes nothing.
#
# Usage:
#   scripts/audit-ci.sh [--ref <branch>] <owner/repo> [<owner/repo> ...]
#
# Reads .github/workflows on --ref, else on dev if the repo has one, else on
# the default branch. Exits 1 if any repo has a violation.
#
# Checks:
#   - ci.yml runs only on pull_request into main (no push, no other bases)
#   - secret-scan.yml has a Gitleaks job, runs on every push and on PRs into
#     main, and can read PRs
#   - semgrep.yml runs only on pull_request into main (plus an optional
#     weekly schedule)
#   - every job sets timeout-minutes
#   - every workflow a newer push or PR update can supersede sets a
#     concurrency group
#   - a repo with a turbo.json uses Vercel Remote Cache in ci.yml
#   - no CodeQL (it needs a paid Code Security licence on private repos)
#   - every deployment_status job without `needs` filters on the deployment
#     in its `if:`, so no runner starts for deploys it ignores
#
# Requires: gh, jq, ruby (macOS ships one; used only to parse YAML).

set -euo pipefail

REF=""
if [ "${1:-}" = "--ref" ]; then
  REF="$2"
  shift 2
fi
if [ "$#" -lt 1 ]; then
  echo "Usage: $0 [--ref <branch>] <owner/repo> [<owner/repo> ...]" >&2
  exit 1
fi

# Reads workflow files given as arguments; prints one line per violation.
read -r -d '' CHECK <<'RUBY' || true
require "yaml"

def triggers(doc)
  # YAML 1.1 parses a bare `on:` key as true.
  on = doc.key?("on") ? doc["on"] : doc[true]
  case on
  when String then { on => nil }
  when Array then on.map { |t| [t, nil] }.to_h
  when Hash then on
  else {}
  end
end

def only_prs_into_main(on, allowed = [])
  pr = on["pull_request"]
  (on.keys - allowed) == ["pull_request"] && pr.is_a?(Hash) && pr["branches"] == ["main"]
end

# A run that a newer push or PR update can supersede.
def supersedable(on)
  pr = on["pull_request"]
  pr_types = pr.is_a?(Hash) ? pr["types"] : nil
  on.key?("push") || (on.key?("pull_request") && (pr_types.nil? || pr_types.include?("synchronize")))
end

ARGV.each do |path|
  name = File.basename(path)
  doc = YAML.safe_load(File.read(path), aliases: true) || {}
  on = triggers(doc)
  jobs = doc["jobs"] || {}

  case name
  when "ci.yml"
    puts "#{name}: must run only on pull_request into main (has: #{on.keys.join(", ")})" unless only_prs_into_main(on)
    if ENV["TURBO_REPO"] == "1" && !File.read(path).include?("vercel/setup-turborepo-remote-cache-action")
      puts "#{name}: Turbo repo without Vercel Remote Cache (docs/ci-standard.md#turbo-remote-cache)"
    end
  when "semgrep.yml"
    # A weekly full scan is allowed; it catches new rules on unchanged code.
    puts "#{name}: must run only on pull_request into main (has: #{on.keys.join(", ")})" unless only_prs_into_main(on, %w[schedule])
  when "secret-scan.yml"
    push = on["push"].is_a?(Hash) ? on["push"]["branches"] : nil
    pr = on["pull_request"].is_a?(Hash) ? on["pull_request"]["branches"] : nil
    puts "#{name}: must run on push to every branch ('**')" unless push == ["**"]
    puts "#{name}: must also run on pull_request into main (a bot-merged release head has no push run)" unless pr == ["main"]
    puts "#{name}: needs a job named Gitleaks (the required check)" unless jobs.values.any? { |j| j["name"] == "Gitleaks" }
    perms = doc["permissions"]
    if perms.is_a?(Hash) && !%w[read write].include?(perms["pull-requests"])
      puts "#{name}: needs pull-requests: read (gitleaks-action lists a PR's commits; without it the PR run fails with a 403)"
    end
  end

  if File.read(path).include?("github/codeql-action")
    puts "#{name}: uses CodeQL, which needs a paid Code Security licence; Semgrep covers static analysis"
  end

  if supersedable(on) && !doc["concurrency"]
    puts "#{name}: runs on every push or PR update without a concurrency group"
  end

  jobs.each do |id, job|
    next unless job.is_a?(Hash)
    next if job["uses"] # reusable workflow: the callee sets its own timeouts
    puts "#{name}: job #{id} has no timeout-minutes" unless job["timeout-minutes"]
    if on.key?("deployment_status") && !job["needs"] && !job["if"].to_s.include?("github.event.deployment.environment")
      puts "#{name}: job #{id} starts a runner for every deploy; filter on github.event.deployment.environment in its if:"
    end
  end
end
RUBY

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAILED=0

for REPO in "$@"; do
  ref="$REF"
  if [ -z "$ref" ]; then
    if gh api "repos/$REPO/branches/dev" >/dev/null 2>&1; then
      ref=dev
    else
      ref=$(gh api "repos/$REPO" --jq .default_branch)
    fi
  fi

  dir="$TMP/${REPO//\//_}"
  mkdir -p "$dir"
  files=$(gh api "repos/$REPO/contents/.github/workflows?ref=$ref" --jq '.[] | select(.name | test("\\.ya?ml$")) | .name' 2>/dev/null || true)
  if [ -z "$files" ]; then
    echo "✗ $REPO@$ref: no workflows"
    FAILED=1
    continue
  fi
  while IFS= read -r f; do
    gh api "repos/$REPO/contents/.github/workflows/$f?ref=$ref" --jq .content | base64 --decode >"$dir/$f"
  done <<<"$files"

  for required in ci.yml secret-scan.yml semgrep.yml auto-merge.yml; do
    [ -f "$dir/$required" ] || echo "missing $required" >>"$dir/.violations"
  done
  turbo=0
  gh api "repos/$REPO/contents/turbo.json?ref=$ref" >/dev/null 2>&1 && turbo=1
  TURBO_REPO=$turbo ruby -e "$CHECK" "$dir"/*.y*ml >>"$dir/.violations"

  if [ -s "$dir/.violations" ]; then
    echo "✗ $REPO@$ref"
    sed 's/^/    /' "$dir/.violations"
    FAILED=1
  else
    echo "✓ $REPO@$ref"
  fi
done

exit "$FAILED"
