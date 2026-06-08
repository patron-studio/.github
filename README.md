# patron-studio/.github

Org-wide defaults for every repository in [`patron-studio`](https://github.com/patron-studio).

## What lives here

| Path                       | Purpose                                                                                                                                             |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `profile/README.md`        | Public-facing org page README (visible at github.com/patron-studio)                                                                                 |
| `SECURITY.md`              | Default vulnerability reporting policy. Picked up by any repo without its own `SECURITY.md`.                                                        |
| `PULL_REQUEST_TEMPLATE.md` | Default PR template. Picked up by any repo without its own.                                                                                         |
| `CODEOWNERS`               | Default code owners fallback. Per-repo `CODEOWNERS` overrides.                                                                                      |
| `workflow-templates/`      | "Use this template" entries that appear under _Actions → New workflow → By patron-studio_.                                                          |
| `templates/`               | Copy-paste-able per-repo files that GitHub doesn't inherit (e.g. `dependabot.yml`).                                                                 |
| `.github/workflows/`       | Org-level automation that **runs in this repo** on a schedule (e.g. the Sentry triage poll). Unlike `workflow-templates/`, these actually run here. |
| `scripts/`                 | Helpers for the above + admin tasks (`apply-branch-protection.sh`, `sentry-triage-poll.mjs`).                                                       |

## Automation that runs here

Most of this repo is passive (defaults GitHub inherits, templates other repos
opt into). The exception is `.github/workflows/` — workflows that run **in this
repo itself**, for genuinely org-level jobs that don't belong to any one product:

- **[Sentry triage poll](docs/sentry-triage.md)** — scans every Sentry project
  for production code defects and files Linear tickets for the auto-fix bot.
  See the doc for the gate, provisioning (org secrets), and how to approve.

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

## What this _doesn't_ cover

- **Dependabot** — config is per-repo. The `templates/dependabot.yml` file is a
  copy-paste starter, not an inherited default.
- **Branch protection** — set per-repo or via org-level
  [Repository Rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets).
- **Required workflows** — also via Rulesets, separately from the templates here.
