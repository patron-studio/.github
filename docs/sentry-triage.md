# Sentry triage poll

Org-level automation that turns production Sentry errors into auto-fix work,
running in this repo on a schedule (`.github/workflows/sentry-triage-poll.yml`
→ `scripts/sentry-triage-poll.mjs`).

## What it does

Every 15 minutes it pulls **unresolved production error** issues across **all**
Sentry projects in `patron-studio`, runs a strict gate plus a cheap LLM
classifier to keep only genuine, scoped **code defects**, and files a Linear
ticket (assigned to sam) for each survivor. Each product repo's existing
`claude-bot` poll then turns sam/Todo tickets into a fix PR.

```
Sentry (all projects)
   │  poll: is:unresolved environment:production level:error
   ▼
deterministic gate  ──reject──▶  (dropped, counted in the digest)
   │  passes
   ▼
LLM classifier (gpt-4o-mini)  ──not a scoped code defect──▶  (dropped)
   │  code-defect && scoped && confidence ≥ 0.7
   ▼
dedupe (Linear search by Sentry short id)  ──exists──▶  (skipped)
   │  new
   ▼
Linear ticket → sam, holding state  ──(you approve: move to Todo)──▶  claude-bot poll → fix PR
```

Linear is the **only** seam between this org-level brain and the per-repo bots —
this workflow never writes to any repo, so it needs only `contents: read`.

## The gate (why it's strict)

Most live production issues are **not** code defects — they're missing-env,
quota, infra-timeout, or transient-network noise. Filing those would flood the
bot with unfixable work. The deterministic gate (`gate()` in the script) rejects,
cheaply and before any LLM call:

- non-production, non-error/fatal level, already-assigned, or resolved issues
- **bot-origin** issues (the bot's own failures are captured into Sentry too —
  this prevents a fix loop)
- a **config/infra denylist** (missing env var, quota, statement timeout,
  network error, auth failure, "Tenant not found", …) — deliberately
  conservative so real bugs like `"… is not a valid document ID"` fall through
- low Seer fixability score, low frequency (`< 5` events), or stale (`> 48h`)

Survivors go to the LLM, which makes the final `code-defect / scoped /
confidence` call. Tuning knobs are constants at the top of the script.

## Project registry

`PROJECT_MODES` in the script decides what happens per Sentry project:

| mode     | behaviour                                                    |
| -------- | ------------------------------------------------------------ |
| `fix`    | triage + file a Linear ticket (repo must run the claude-bot) |
| `digest` | include in the Slack digest only — for projects with no bot  |
| `ignore` | drop (the default for unlisted projects)                     |

Today only `sales-dashboard` is `fix`. Onboarding another project to the fix
loop is a one-line change here — **not** any Sentry-side work.

> **v1 constraint:** `patron-sales-dashboard`'s poll dispatches _every_ sam/Todo
> PAT ticket into its own repo. That's correct while `sales-dashboard` is the
> only `fix` project. Before adding a second `fix` repo, make the ticket carry a
> target-repo label and have each repo's poll filter on it.

## Approving / autonomy

Tickets land in a **holding (backlog) state** by default. **Approve by moving
the ticket to `Todo`** — the product repo's poll dispatches it within ~10 min.
The Slack digest lists each candidate with its Sentry and Linear links.

Set the repo variable `SENTRY_TRIAGE_AUTO_DISPATCH=true` to send
**high-confidence** defects (≥ 0.9) straight to `Todo` with no human gate;
everything else still waits for approval.

## Provisioning (one-time, org-level)

Add these as **org secrets** (or secrets on this repo). Nothing per project.

| secret / var                  | what                                                                 |
| ----------------------------- | -------------------------------------------------------------------- |
| `SENTRY_AUTH_TOKEN`           | Sentry org/internal-integration token, `event:read` + `project:read` |
| `SAM_LINEAR_API_KEY`          | sam's Linear key (same one the bot poll uses)                        |
| `OPENAI_API_KEY`              | for the classifier (gpt-4o-mini)                                     |
| `SLACK_WEBHOOK_URL`           | optional — incoming webhook for the digest                           |
| `SENTRY_TRIAGE_AUTO_DISPATCH` | optional repo **variable**, `true` to enable the auto lane           |

The schedule runs only from `main`. To test from a branch, use **Actions → Sentry
Triage Poll → Run workflow** with **dry_run** ticked (classifies and logs, creates
nothing).
