# Org-wide security settings

Two settings live at the GitHub organisation level — they protect every repo
in the org with zero per-repo work. Both should be on. Neither is enabled as
of the last audit.

## 1. Require 2FA for all members

**Settings → Authentication security → Require two-factor authentication**

Forces every member to have 2FA enabled on their GitHub account. Members
without 2FA are **removed from the org** the moment this is flipped on.

Before flipping:

```bash
# List members without 2FA so you can give them notice first
gh api orgs/patron-studio/members --paginate \
  -F filter=2fa_disabled --jq '.[].login'
```

Once the list is empty (or you've confirmed everyone has 2FA), enable it:
Settings → Authentication security → tick **Require two-factor authentication**.

## 2. Secret scanning + push protection

**Settings → Code security → Code security and analysis**

GitHub-native scanning of every push for known secret patterns (AWS keys,
Stripe tokens, GitHub tokens, etc). Two switches:

- **Secret scanning** — detects secrets that have already been committed.
  Free on all plans. Turn on for the whole org.
- **Push protection** — blocks pushes containing detected secrets before
  they land. Available on Team plan as part of GitHub Advanced Security.
  Turn on if your plan includes it; otherwise it's a paid add-on.

Both can be enabled with a "Enable for all eligible repositories" toggle.
There's a separate "Enable for new repositories" toggle that should also
be on so new repos inherit the setting.

## 3. (Already covered) Branch protection

For per-repo branch protection on `main`, use the script in
`scripts/apply-branch-protection.sh`. Org-level Repository Rulesets that
apply to private repos are an Enterprise-only feature, so per-repo
protection is the practical path on the Team plan.

## What's not enabled at the org level

The following would be valuable but require either Enterprise tier or
manual per-repo opt-in:

- **Required workflows** (force every repo to run a specific workflow on
  every PR — would let us _enforce_ Semgrep / Gitleaks org-wide rather
  than just offer them as templates). Enterprise-only for private repos.
- **Required signed commits**. Possible per-repo as part of branch
  protection — not applied by the default script because the team doesn't
  uniformly sign commits today.
