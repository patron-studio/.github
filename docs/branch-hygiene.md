# Branch hygiene

Keeping `origin` tidy when lots of short-lived branches land — parallel-agent
workflows, Conductor workspaces, etc. — without ever losing the branches that
matter.

There are three pieces. **None of them are inherited automatically by other
repos.** The scripts live here as the source of truth, but each must be _run
against a repo_ to take effect — same model as
[`scripts/apply-branch-protection.sh`](../scripts/apply-branch-protection.sh).

## 1. Auto-delete merged branches — `scripts/set-auto-delete.sh`

Enables GitHub's "Automatically delete head branches". After a PR merges, its
source branch is deleted. This only ever deletes a **merged PR's head branch**
— `main`, `master`, `dev`, `staging` are merge targets, never merged heads, so
they are structurally safe.

```bash
scripts/set-auto-delete.sh patron-studio/<repo>
```

It's a per-repo setting (`delete_branch_on_merge`); there is no org-wide toggle
on the Team plan, so run it once per repo.

## 2. Protect long-lived branches — `scripts/protect-long-lived-branches.sh`

Creates a repository ruleset that restricts deletion + force-push on the
permanent branches (by name) and future long-lived branches (by convention:
`release/*`, `hotfix/*`, `epic/*`). "Restrict deletions" overrides auto-delete
too, so a protected branch is safe from both manual and automatic deletion.

```bash
scripts/protect-long-lived-branches.sh patron-studio/<repo>
```

To protect a new long-lived branch in future, name it with one of the blessed
prefixes — no config change needed. To bless a new prefix, edit the `include`
list in the script and re-run (delete the old ruleset first; re-running
otherwise skips a repo that already has the same-named ruleset).

Repository rulesets work on private repos on the Team plan; only **org-level**
rulesets on private repos are Enterprise-only (see
[`org-settings.md`](org-settings.md)).

## 3. Prune the existing backlog — `scripts/prune-merged-branches.sh`

Auto-delete (step 1) only applies going forward. To clear branches that already
piled up, this deletes remote branches whose PR is already merged, skipping the
protected names/prefixes. **Dry run by default.**

```bash
scripts/prune-merged-branches.sh patron-studio/<repo>          # preview
APPLY=1 scripts/prune-merged-branches.sh patron-studio/<repo>  # delete
```

## Applying to a repo

For any repo you want covered, from a checkout of this repo (with `gh`
authenticated):

```bash
scripts/set-auto-delete.sh             patron-studio/<repo>
scripts/protect-long-lived-branches.sh patron-studio/<repo>
scripts/prune-merged-branches.sh       patron-studio/<repo>   # dry run first
```

Fold the first two into whatever bootstraps a new repo / Conductor project so
new repos are covered from day one.

### Recurring prune (optional)

For a hands-off recurring sweep across all repos, the right home is a scheduled
GitHub Action in [`patron-studio/automation`](https://github.com/patron-studio/automation)
(cron, iterating org repos with a token) rather than running step 3 by hand.
Not included here.
