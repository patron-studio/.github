# Repo standard

One set of branch and merge rules for every `patron-studio` repo, modelled on
`omkai`. Apply it with
[`scripts/apply-repo-standard.sh`](../scripts/apply-repo-standard.sh). A change
to the standard is a PR here, followed by re-running the script on every repo.
Never hand-edit a repo's rulesets.

What CI runs, and how cheaply, is in [ci-standard.md](ci-standard.md).

## The rules

| Branch                | Rule                                                                                                        |
| --------------------- | ----------------------------------------------------------------------------------------------------------- |
| `main`                | PR required, 0 approvals, merge commit only, `CI` + `Gitleaks` must pass. No deletion, no force push.       |
| `dev`, `staging`      | Everyone on the team pushes directly. No deletion, no force push. A PR into them auto-merges.               |
| `release/*` etc.      | No deletion, no force push (`protect-long-lived-branches`, see [branch-hygiene.md](branch-hygiene.md)).     |

- **Merge commits everywhere, never squash or rebase.** Squashing a branch that
  is later promoted rewrites its commits under new SHAs, so the next promotion
  conflicts on every file both sides touched (omkai, 14 Sep 2026: eight
  conflicts). A single rule is also one less thing to get wrong.
- **Only `main` is gated.** `dev` and `staging` take direct pushes from anyone
  on the team (Oliver, 19 Oct 2026). Local hooks are their quality gate, and
  Gitleaks still scans every push. Any PR rule or required check on them would
  block those pushes.
- **No classic branch protection.** Rulesets only, so `gh api .../rulesets`
  shows every rule. Classic protection layered underneath once held a release
  on a hidden conversation-resolution rule (airo #500).

## Bypass: a deliberate click, never automatic

The `maintainers` team (Oliver) can bypass `main` in **`pull_request` mode**. On
a PR in GitHub, tick "Merge without waiting for requirements to be met". Nobody
can push straight to `main`. GitHub also accepts `gh pr merge --admin` from the
bypass holder, so the bypass is a check on the person, not a technical lock.

Claude never bypasses. `~/.claude/hooks/pr-merge-guard.sh` denies `--admin` and
squash merges, and auto mode blocks Claude from editing rulesets.

## Getting CI on `main` fast: `pnpm ci:local`

Instead of bypassing, run `pnpm ci:local` on a clean, pushed `dev` before opening
the release PR. It runs the `CI` job's steps locally against that exact commit
and records a `local-ci` commit status on it. The repo's `ci.yml` has a
`local-ci` job that skips `CI` when the PR head has that status from
`OliverBurns` and merging into `main` leaves the tested tree unchanged. A
skipped job satisfies the required check. Every other PR runs CI in full.
Templates: [`templates/local-ci/`](../templates/local-ci/).

## Which repos

| Tier         | Repos                                                                                                                          | What they get                                                     |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------- |
| **Full**     | omkai, airo-storefront, slvrlake, turbo-next-sanity-boilerplate, companion, at-rare, colours-agency, johns-and-co, jelly, think-artfully, chm-website | All of the above                                                  |
| **Baseline** | snyder, at-trayler, at-collective, foster-son-store, foster-dev, johns-and-co_AWS, maintenance-orchestrator                    | `protect-long-lived-branches` only; no CI gate                    |

Full is every repo that had commits in the 30 days to 19 Oct 2026 and has lint
or typecheck scripts to run. The boilerplate is included because every new site
starts from it. A baseline repo moves to Full when work on it restarts.

## Rolling out to a repo

Order matters: requiring a check that nothing reports blocks every merge.

1. PR into the repo's working branch, adding the workflows if missing:
   - `ci.yml` with a job named `CI` on PRs into `main`, plus the `local-ci` job
   - `secret-scan.yml` (job `Gitleaks`, every push and PRs into `main`)
   - `semgrep.yml` on PRs into `main`
   - [`auto-merge.yml`](../workflow-templates/auto-merge.yml)
   - `scripts/ci-local.sh` with a `ci:local` package script

   `scripts/audit-ci.sh patron-studio/<repo>` checks them against
   [ci-standard.md](ci-standard.md).
2. Once those workflows are on the working branch and `main`, run the script as
   a dry run, check the diff, then run it with `--apply`:
   ```bash
   scripts/apply-repo-standard.sh patron-studio/<repo>
   scripts/apply-repo-standard.sh --apply patron-studio/<repo>
   ```
   The script refuses a repo until step 1 is done: `CI` and `Gitleaks`
   reported, the `local-ci` job, the auto-merge workflow, and no squash merges
   anywhere.

### Exceptions

- **slvrlake** works main-first. Its `/sync` command used to push `main`
  directly; under this standard it opens a PR into `main` (auto-merged once
  green), then runs `/propagate` to push `staging` and `dev` directly.
