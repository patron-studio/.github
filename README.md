# patron-studio/.github

Org-wide defaults for every repository in [`patron-studio`](https://github.com/patron-studio).

## What lives here

| Path                        | Purpose                                                                                           |
| --------------------------- | ------------------------------------------------------------------------------------------------- |
| `profile/README.md`         | Public-facing org page README (visible at github.com/patron-studio)                               |
| `SECURITY.md`               | Default vulnerability reporting policy. Picked up by any repo without its own `SECURITY.md`.      |
| `PULL_REQUEST_TEMPLATE.md`  | Default PR template. Picked up by any repo without its own.                                       |
| `CODEOWNERS`                | Default code owners fallback. Per-repo `CODEOWNERS` overrides.                                    |
| `workflow-templates/`       | "Use this template" entries that appear under _Actions → New workflow → By patron-studio_.        |
| `.github/workflows/`        | Reusable workflows (`on: workflow_call`) that repos invoke via `uses:` — update once, all callers get it. |
| `templates/`                | Copy-paste-able per-repo files that GitHub doesn't inherit (e.g. `dependabot.yml`).               |

## How GitHub picks these up

GitHub treats a repo literally named `.github` in an org as a fallback location
for **community health files**. Any of `SECURITY.md`, `CONTRIBUTING.md`,
`SUPPORT.md`, `PULL_REQUEST_TEMPLATE.md`, `ISSUE_TEMPLATE/*` placed here will
apply to every repo in the org that doesn't define its own.

`CODEOWNERS` in this repo also acts as a fallback. Per-repo
`.github/CODEOWNERS` (like the one in `patron-sales-dashboard`) overrides this.

Workflow templates are different — they're a starting point only. They appear
in the Actions UI when a user clicks "New workflow", but they're never
automatically applied. Each repo opts in by adding the workflow file itself.

## Reusable workflows

Unlike `workflow-templates/` (copied once, then diverge), reusable workflows in
`.github/workflows/` are referenced live — update them here and every caller
picks up the change on its next run.

| Workflow | Purpose |
| --- | --- |
| `claude-pr-review.yml` | Read-only Claude PR-review bot. Reads the calling repo's `CLAUDE.md` + `.claude/agents/*.md` and posts inline comments. Informational — never make it a required check. |

Call it from a repo with a thin caller workflow (note the doubled `.github` in
the path):

```yaml
# .github/workflows/claude-pr-review.yml in the calling repo
name: Claude PR Review
on:
  pull_request:
    types: [opened, ready_for_review]
    branches: [main]
permissions:
  contents: read
  pull-requests: write
  id-token: write
jobs:
  review:
    uses: patron-studio/.github/.github/workflows/claude-pr-review.yml@v1
    secrets: inherit
```

**Pin to a tag, not `@main`.** Reusable workflows are versioned with git tags on
this repo — callers pin `@v1`. Cut a `v1` tag (and move it forward on breaking
changes) so callers get a stable contract.

**Secrets.** `claude-pr-review.yml` needs `CLAUDE_CODE_OAUTH_TOKEN` (and
optionally `SLACK_WEBHOOK_URL`). Set these as **org-level secrets** with
`--visibility all` so every repo inherits them via `secrets: inherit`.

## What this _doesn't_ cover

- **Dependabot** — config is per-repo. The `templates/dependabot.yml` file is a
  copy-paste starter, not an inherited default.
- **Branch protection** — set per-repo or via org-level
  [Repository Rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets).
- **Required workflows** — also via Rulesets, separately from the templates here.
