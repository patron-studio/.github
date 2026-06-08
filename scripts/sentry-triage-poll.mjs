// Org-level Sentry → auto-fix triage poll.
//
// Runs on a schedule from THIS repo (patron-studio/.github). For every Sentry
// project in the org it pulls unresolved production error issues, runs a strict
// gate + a cheap LLM classifier to keep ONLY genuine, scoped code defects, and
// files a Linear ticket assigned to sam for each survivor. Each product repo's
// existing claude-bot poll then turns sam/Todo tickets into a fix PR — so Linear
// is the only seam between this org-level brain and the per-repo bots.
//
// Why a poll and not a webhook: the team reviews candidates before dispatch
// (tickets land in a holding state; you approve by moving them to Todo), so the
// human is the latency floor and sub-10-min detection buys nothing. A poll also
// needs no always-on endpoint and lives naturally beside the org's other
// defaults here.
//
// The gate is the whole point. Most live production issues are missing-env /
// quota / infra-timeout / transient-network noise, NOT code defects; letting
// those through would flood the bot with unfixable work. So we reject hard and
// cheaply BEFORE spending a token, then let the LLM make the final call.
//
// Dedupe is by Linear search (a ticket whose title carries the Sentry short id),
// so the poll is idempotent with no database.
//
// Env:
//   SENTRY_AUTH_TOKEN   org-scoped Sentry token with event:read + project:read
//   SENTRY_ORG          org slug (default: patron-studio)
//   LINEAR_API_KEY      sam's Linear key (same as the bot poll)
//   OPENAI_API_KEY      for the triage classifier (gpt-4o-mini)
//   SLACK_WEBHOOK_URL   optional — incoming webhook for the digest
//   AUTO_DISPATCH       optional — 'true' sends high-confidence defects straight
//                       to Todo (auto-fix) instead of the holding state
//   DRY_RUN             optional — 'true' classifies + logs but creates nothing

const SENTRY_REGION = "https://us.sentry.io";
const SENTRY_ORG = process.env.SENTRY_ORG || "patron-studio";
const SENTRY_TOKEN = process.env.SENTRY_AUTH_TOKEN;
const LINEAR_KEY = process.env.LINEAR_API_KEY;
const OPENAI_KEY = process.env.OPENAI_API_KEY;
const SLACK_WEBHOOK = process.env.SLACK_WEBHOOK_URL || "";
const AUTO_DISPATCH = process.env.AUTO_DISPATCH === "true";
const DRY_RUN = process.env.DRY_RUN === "true";

const LINEAR_API = "https://api.linear.app/graphql";
const SAM = "01852073-c47d-4266-8a1d-72e64cf8ab5d";
const TEAM_KEY = "PAT";
const OMKAI_PROJECT = "0bfdbab1-ae47-4b68-ae73-1ce2bb55aa23";
const DEFAULT_REVIEWER = "oliver@patron.studio";

const TODO_STATE = "Todo"; // the state patron-sales-dashboard's poll dispatches from
const MAX_TICKETS_PER_RUN = 5; // bound the blast radius per run
const MIN_EVENTS = 5; // frequency floor (sweep sees accumulated counts)
const RECENCY_HOURS = 48;
const MIN_SEER_SCORE = 0.4;
const MIN_CONFIDENCE = 0.7; // LLM confidence required to file
const AUTO_DISPATCH_CONFIDENCE = 0.9; // higher bar to skip the human gate

// ── Project registry ──────────────────────────────────────────────────────
// The org webhook/poll sees EVERY project; this decides what happens to each.
// `fix` → triage + Linear ticket (repo must run claude-bot poll).
// `digest` → digest only (no ticket) for projects with no bot.
// `ignore` → drop. Unknown projects default to ignore — never file work no bot
// can pick up. Onboarding a project to the fix loop is a one-line change here.
const PROJECT_MODES = {
  "sales-dashboard": "fix",
  // 'slvrlake': 'digest',
  // 'patron-website': 'digest',
  // 'johns-and-co': 'digest',
};
const projectMode = (slug) => PROJECT_MODES[slug] || "ignore";

// ── The gate ────────────────────────────────────────────────────────────────
// Block issues that came from the fix pipeline itself (its own failures are
// captured into Sentry too — we've seen "Auto-fix bot run failed for #167").
const BOT_ORIGIN = [
  /auto-fix bot run failed/i,
  /\bclaude-fix\b/i,
  /claude-auto-fix/i,
  /sentry-triage/i,
  /\/api\/sentry-webhook/i,
];
// Unambiguously not-a-code-defect. Conservative on purpose: genuine bugs like
// "… is not a valid document ID" (a trailing-space defect) must fall through.
const NOISE = [
  /\benv var\b/i,
  /\bis not set\b/i,
  /not configured\b/i,
  /credentials not configured/i,
  /\b(auth source|credentials) configured\b/i,
  /\bquota\b/i,
  /plan_limit/i,
  /statement timeout/i,
  /canceling statement/i,
  /aborted due to timeout/i,
  /operation was aborted/i,
  /\bECONNRESET\b/i,
  /\bETIMEDOUT\b/i,
  /network error/i,
  /\bNetworkError\b/i,
  /client has been destroyed/i,
  /auth failure/i,
  /\bUnauthorized\b/i,
  /Tenant ".*?" not found/i,
  /Dashboard not found/i,
];
const matches = (patterns, ...texts) =>
  texts.some((t) => t && patterns.some((p) => p.test(t)));

// Returns { pass: true } or { pass: false, reason }. Cheap structural checks
// first so the reason is the most specific one (the digest reports the mix).
function gate(issue, nowMs) {
  if (issue.status !== "unresolved")
    return { pass: false, reason: "not-unresolved" };
  if (issue.assignedTo != null)
    return { pass: false, reason: "already-assigned" };
  const level = (issue.level || "").toLowerCase();
  if (level !== "error" && level !== "fatal")
    return { pass: false, reason: "not-error-level" };
  const category = (issue.issueCategory || "").toLowerCase();
  if (category && category !== "error")
    return { pass: false, reason: "not-error-category" };
  if (matches(BOT_ORIGIN, issue.title, issue.culprit))
    return { pass: false, reason: "bot-origin" };
  if (matches(NOISE, issue.title))
    return { pass: false, reason: "config-or-infra-noise" };

  const score = issue.seerFixabilityScore;
  if (typeof score === "number" && score < MIN_SEER_SCORE) {
    return { pass: false, reason: "low-seer-fixability" };
  }

  if (Number(issue.count || 0) < MIN_EVENTS)
    return { pass: false, reason: "below-frequency" };

  if (issue.lastSeen) {
    const ageH = (nowMs - Date.parse(issue.lastSeen)) / 3_600_000;
    if (Number.isFinite(ageH) && ageH > RECENCY_HOURS)
      return { pass: false, reason: "stale" };
  }
  return { pass: true };
}

// ── Sentry API ────────────────────────────────────────────────────────────
async function sentry(path, params) {
  const url = new URL(`${SENTRY_REGION}/api/0${path}`);
  for (const [k, v] of Object.entries(params || {})) url.searchParams.set(k, v);
  const res = await fetch(url, {
    headers: { Authorization: `Bearer ${SENTRY_TOKEN}` },
  });
  if (!res.ok)
    throw new Error(`Sentry ${path} -> ${res.status} ${await res.text()}`);
  return res.json();
}

async function fetchProductionIssues() {
  // project=-1 → every project the token can access; the query enforces prod +
  // error so each returned issue is production by construction.
  const issues = await sentry(`/organizations/${SENTRY_ORG}/issues/`, {
    query: "is:unresolved environment:production level:error",
    project: "-1",
    statsPeriod: "14d",
    limit: "100",
    sort: "freq",
  });
  return Array.isArray(issues) ? issues : [];
}

// Best-effort: pull the latest event's in-app stack frames for the classifier.
async function fetchStack(issueId) {
  try {
    const ev = await sentry(
      `/organizations/${SENTRY_ORG}/issues/${issueId}/events/latest/`,
      {},
    );
    const exc = (ev.entries || []).find((e) => e.type === "exception");
    const frames =
      exc?.data?.values?.flatMap((v) => v.stacktrace?.frames || []) || [];
    return frames
      .filter((f) => f.inApp)
      .slice(-6)
      .map(
        (f) =>
          `  at ${f.function || "?"} (${f.filename || "?"}:${f.lineNo ?? "?"})`,
      )
      .join("\n");
  } catch {
    return "";
  }
}

// ── LLM classifier ──────────────────────────────────────────────────────────
const CLASSIFY_SCHEMA = {
  name: "triage",
  strict: true,
  schema: {
    type: "object",
    additionalProperties: false,
    properties: {
      category: {
        type: "string",
        enum: [
          "code-defect",
          "config",
          "infra",
          "upstream",
          "transient",
          "unknown",
        ],
      },
      fixable: { type: "boolean" },
      scoped: { type: "boolean" },
      confidence: { type: "number" },
      rootCause: { type: "string" },
    },
    required: ["category", "fixable", "scoped", "confidence", "rootCause"],
  },
};

async function classify(issue, stack) {
  const system =
    "You triage production Sentry errors for an automated fix bot. Decide if an " +
    "issue is a genuine CODE DEFECT a bot could fix with a small, well-scoped diff. " +
    "category=code-defect ONLY for bugs in our own application code (null guards, " +
    "bad input handling, logic errors, unsanitised values). Use config (missing env " +
    "var / credentials / settings), infra (db/timeout/resource), upstream (third-party " +
    "API), or transient (network blip) otherwise. scoped=true only if the fix is " +
    "plausibly one or a few files. Be conservative: when unsure, lower confidence.";
  const user =
    `Title: ${issue.title}\n` +
    `Culprit: ${issue.culprit || "(none)"}\n` +
    `Level: ${issue.level}  Events: ${issue.count}  Users: ${issue.userCount}\n` +
    (stack ? `Top in-app stack:\n${stack}\n` : "");

  const res = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${OPENAI_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: "gpt-4o-mini",
      temperature: 0,
      messages: [
        { role: "system", content: system },
        { role: "user", content: user },
      ],
      response_format: { type: "json_schema", json_schema: CLASSIFY_SCHEMA },
    }),
  });
  if (!res.ok) throw new Error(`OpenAI -> ${res.status} ${await res.text()}`);
  const json = await res.json();
  return JSON.parse(json.choices[0].message.content);
}

const classifierAccepts = (v) =>
  v.category === "code-defect" &&
  v.scoped &&
  v.fixable &&
  v.confidence >= MIN_CONFIDENCE;

// ── Linear ────────────────────────────────────────────────────────────────
async function linear(query, variables) {
  const res = await fetch(LINEAR_API, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: LINEAR_KEY },
    body: JSON.stringify({ query, variables }),
  });
  const json = await res.json();
  if (json.errors) throw new Error("Linear: " + JSON.stringify(json.errors));
  return json.data;
}

async function resolvePatStates() {
  const data = await linear(
    `query ($key: String!) {
       teams(filter: { key: { eq: $key } }) {
         nodes { id states { nodes { id name type } } }
       }
     }`,
    { key: TEAM_KEY },
  );
  const team = data.teams.nodes[0];
  if (!team) throw new Error(`Linear team ${TEAM_KEY} not found`);
  const states = team.states.nodes;
  const todo = states.find((s) => s.name === TODO_STATE);
  // Holding state for the approve lane: a backlog-type state the dispatch poll
  // ignores. Approving = moving the ticket to Todo.
  const holding =
    states.find((s) => s.type === "backlog") ||
    states.find((s) => s.name.toLowerCase() === "backlog") ||
    todo;
  if (!todo)
    throw new Error(`Linear "${TODO_STATE}" state not found on ${TEAM_KEY}`);
  return {
    teamId: team.id,
    todoId: todo.id,
    holdingId: holding?.id || todo.id,
  };
}

async function alreadyFiled(shortId) {
  const data = await linear(
    `query ($q: String!) {
       issues(filter: { title: { contains: $q } }, first: 1) { nodes { id identifier } }
     }`,
    { q: `[${shortId}]` }, // bracketed so SALES-DASHBOARD-1 doesn't match -1H
  );
  return data.issues.nodes.length > 0;
}

async function createTicket({ issue, verdict, stateId }) {
  const title = `[${issue.shortId}] ${issue.title}`.slice(0, 250);
  const description = [
    `Auto-filed from Sentry by the org triage poll.`,
    "",
    `**Sentry:** ${issue.permalink}`,
    `**Short ID:** ${issue.shortId}  ·  **Events:** ${issue.count}  ·  **Users:** ${issue.userCount}`,
    `**Culprit:** \`${issue.culprit || "(none)"}\``,
    "",
    `**Likely root cause (LLM, confidence ${verdict.confidence.toFixed(2)}):** ${verdict.rootCause}`,
    "",
    `Follow CLAUDE.md. Keep changes minimal. Do not touch secrets or .env files.`,
    `Verify the fix against the Sentry stack trace before closing.`,
    `<!-- reviewer: ${DEFAULT_REVIEWER} -->`,
  ].join("\n");

  const data = await linear(
    `mutation ($input: IssueCreateInput!) {
       issueCreate(input: $input) { success issue { identifier url } }
     }`,
    {
      input: {
        teamId: STATE.teamId,
        projectId: OMKAI_PROJECT,
        assigneeId: SAM,
        stateId,
        title,
        description,
      },
    },
  );
  if (!data.issueCreate.success)
    throw new Error(`issueCreate failed for ${issue.shortId}`);
  return data.issueCreate.issue;
}

// ── Slack digest ────────────────────────────────────────────────────────────
async function postDigest({ scanned, rejects, filed }) {
  if (!SLACK_WEBHOOK) return;
  const rejectLines = Object.entries(rejects)
    .sort((a, b) => b[1] - a[1])
    .map(([reason, n]) => `• ${reason}: ${n}`)
    .join("\n");
  const filedLines = filed.length
    ? filed
        .map(
          (f) =>
            `• <${f.permalink}|${f.shortId}> → <${f.ticketUrl}|${f.ticketId}> _(conf ${f.confidence.toFixed(
              2,
            )}${f.dispatched ? ", auto-dispatched" : ", awaiting approval"})_`,
        )
        .join("\n")
    : "_none_";
  const text = filed.length
    ? `Sentry triage: ${filed.length} bot-fixable issue(s) ${
        AUTO_DISPATCH ? "queued" : "ready for approval"
      }`
    : "Sentry triage: no bot-fixable issues this run";

  await fetch(SLACK_WEBHOOK, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      text,
      blocks: [
        { type: "section", text: { type: "mrkdwn", text: `*${text}*` } },
        {
          type: "section",
          text: {
            type: "mrkdwn",
            text: `*Candidates*\n${filedLines}\n\n_Scanned ${scanned}; filtered:_\n${rejectLines || "• none"}`,
          },
        },
        ...(filed.length && !AUTO_DISPATCH
          ? [
              {
                type: "context",
                elements: [
                  {
                    type: "mrkdwn",
                    text: "Approve by moving the Linear ticket to *Todo* — the bot dispatches within ~10 min.",
                  },
                ],
              },
            ]
          : []),
      ],
    }),
  });
}

// ── Orchestration ───────────────────────────────────────────────────────────
let STATE = null;

async function main() {
  if (!SENTRY_TOKEN) return console.log("No SENTRY_AUTH_TOKEN — skipping.");
  if (!LINEAR_KEY) return console.log("No LINEAR_API_KEY — skipping.");
  if (!OPENAI_KEY) return console.log("No OPENAI_API_KEY — skipping.");

  const nowMs = Date.now();
  const issues = await fetchProductionIssues();
  console.log(`Fetched ${issues.length} unresolved production error issue(s).`);

  const rejects = {};
  const bump = (reason) => (rejects[reason] = (rejects[reason] || 0) + 1);
  const filed = [];

  STATE = DRY_RUN
    ? { teamId: "", todoId: "", holdingId: "" }
    : await resolvePatStates();

  for (const issue of issues) {
    if (filed.length >= MAX_TICKETS_PER_RUN) {
      console.log(
        `Hit MAX_TICKETS_PER_RUN (${MAX_TICKETS_PER_RUN}); remaining wait for next run.`,
      );
      break;
    }
    const slug = issue.project?.slug || "unknown";
    const mode = projectMode(slug);
    if (mode !== "fix") {
      bump(
        mode === "ignore" ? `ignored-project:${slug}` : `digest-only:${slug}`,
      );
      continue;
    }

    const g = gate(issue, nowMs);
    if (!g.pass) {
      bump(g.reason);
      continue;
    }

    const stack = await fetchStack(issue.id);
    let verdict;
    try {
      verdict = await classify(issue, stack);
    } catch (e) {
      console.log(`Classify failed for ${issue.shortId}: ${e.message}`);
      bump("classify-error");
      continue;
    }
    if (!classifierAccepts(verdict)) {
      bump(`llm-rejected:${verdict.category}`);
      continue;
    }

    if (await alreadyFiled(issue.shortId)) {
      bump("already-filed");
      continue;
    }

    const dispatched =
      AUTO_DISPATCH && verdict.confidence >= AUTO_DISPATCH_CONFIDENCE;
    const stateId = dispatched ? STATE.todoId : STATE.holdingId;

    if (DRY_RUN) {
      console.log(
        `[dry-run] would file ${issue.shortId} (conf ${verdict.confidence.toFixed(2)}, ${
          dispatched ? "Todo" : "holding"
        }): ${verdict.rootCause}`,
      );
      filed.push({
        ...issue,
        ticketId: "(dry-run)",
        ticketUrl: "",
        confidence: verdict.confidence,
        dispatched,
      });
      continue;
    }

    const ticket = await createTicket({ issue, verdict, stateId });
    console.log(
      `Filed ${issue.shortId} → ${ticket.identifier} (${dispatched ? "Todo" : "holding"})`,
    );
    filed.push({
      shortId: issue.shortId,
      permalink: issue.permalink,
      ticketId: ticket.identifier,
      ticketUrl: ticket.url,
      confidence: verdict.confidence,
      dispatched,
    });
  }

  await postDigest({ scanned: issues.length, rejects, filed });
  console.log(
    `Done: filed ${filed.length}. Rejects: ${JSON.stringify(rejects)}`,
  );
}

await main();
