# CI standard

What GitHub Actions runs in every `patron-studio` repo, when, and how cheaply.
The [repo standard](repo-standard.md) says which branches are gated; this says
what the gate costs. Check a repo against it with
[`scripts/audit-ci.sh`](../scripts/audit-ci.sh). A change to the standard is a
PR here, then a PR in each repo.

## Why it matters

Actions bills per job, rounded up to the whole minute, once the org's 3,000
included minutes run out. The org budget stops **all** Actions when it is hit.
That blocks every release, because `main` requires `CI` and `Gitleaks`. In
October 2026, 7,157 minutes ran, 70% of them in airo-storefront. Most were spent
on CI for every dev push and on a runner started for every Vercel deploy.

## What runs when

| Event                          | What runs                                                                                 |
| ------------------------------ | ----------------------------------------------------------------------------------------- |
| Push to any branch             | `Gitleaks` only, about a minute                                                           |
| PR into `dev` or `staging`     | `Auto-merge` arms the merge. No checks: these branches take direct pushes                 |
| PR into `main`                 | `CI` + `Gitleaks` (required), `Semgrep` (advisory), and build/E2E jobs where a repo has them |
| Deploy (`deployment_status`)   | Production monitors only, filtered in the job's `if:`                                     |
| Schedule                       | Monitors and product jobs, each with a comment saying why it runs that often              |

Never:

- CI on push: no "early warning" runs on `dev`, and no runs on push to `main`
  (the PR already ran it)
- `pull_request` without `branches: [main]`, which runs the gate on every PR
  into `dev`
- CodeQL or GitHub Code Security on private repos. They cost $30 per active
  committer per month, and Semgrep already covers static analysis

## The dev gate is local

`dev` and `staging` have no CI, so the local hooks are their gate. Each repo's
pre-push hook (Lefthook or Husky) runs the same commands as its `CI` job,
including coverage thresholds. That way a CI failure shows up locally first,
not on the release PR. Turbo's cache makes a repeat run nearly instant.

Before opening a release PR, run `pnpm ci:local` on a clean, pushed `dev`. It
runs the `CI` job's steps against that exact commit and records a `local-ci`
status. The release PR's `CI` job then skips its steps (see
[repo-standard.md](repo-standard.md#getting-ci-on-main-fast-pnpm-cilocal)).

Every release PR costs one full run of the gate: for airo-storefront that is
about 15 minutes with CI, or 7 with `ci:local`. Open one when there is
something to ship, not after every dev merge.

## Making each run cheap

- **Filter in the job's `if:`, not in a step.** A skipped job starts no runner
  and bills nothing. A job that starts only to decide there is nothing to do
  bills a full minute. This matters most for `deployment_status`, which fires
  for every preview, dev and Studio deploy.
- **`concurrency` with `cancel-in-progress`** on every workflow that a newer
  push or PR update supersedes.
- **`timeout-minutes` on every job**, at about 1.5x its slowest normal run.
  Without one, a hung job can bill up to six hours.
- **One job per gate, sharing one install.** Each parallel job pays its own
  setup, install and rounding. Heavy jobs (build, E2E) use `needs: ci`, so they
  never start when CI has already failed.
- **Cache everything that's keyed on a lockfile or version:**
  - the pnpm store, with `actions/setup-node` and `cache: pnpm`
  - Turbo's `.turbo/cache`, with `actions/cache` keyed on the commit SHA and
    restoring the newest entry, so packages a release didn't touch replay
    instead of re-running
  - Playwright's browsers, keyed on the Playwright version
- **Docs-only changes skip the advisory workflows** (`paths-ignore`). Required
  checks can't use path filters, because a check that never reports blocks the
  merge.
- **Slack hears only about failures.**

## Workflow templates

Repos copy these, and keep them in step when this standard changes:

- [`workflow-templates/gitleaks.yml`](../workflow-templates/gitleaks.yml):
  `secret-scan.yml`. Runs on every push and on PRs into `main`. A release PR
  whose head `auto-merge.yml` merged into `dev` has no push run, so its
  required check would never report without the PR trigger.
- [`workflow-templates/semgrep.yml`](../workflow-templates/semgrep.yml):
  `semgrep.yml`. Repo-specific `--exclude-rule` lines stay in the repo.
- [`workflow-templates/auto-merge.yml`](../workflow-templates/auto-merge.yml)
- [`templates/local-ci/`](../templates/local-ci/): the `local-ci` job and
  `ci-local.sh`

`ci.yml` is per repo, because each one runs that repo's own scripts. Its shape
is fixed: it runs on `pull_request` into `main` only, with a `local-ci` job and
a job named `CI`.

## Checking repos

```bash
scripts/audit-ci.sh patron-studio/omkai patron-studio/airo-storefront
scripts/audit-ci.sh --ref oliver/repo-standard patron-studio/jelly
```

The script is read-only. It reads each repo's workflows on `dev` (or the
default branch) and lists anything that breaks the rules above. Run it in the
monthly maintenance sweep and before adding a workflow.
