# Security Policy

## Reporting a vulnerability

If you believe you've found a security vulnerability in any Patron Studio
repository or deployed system, please **do not** open a public GitHub issue.

Instead, email **oliver@patron.studio** with:

- The repository / system affected
- A description of the issue
- Steps to reproduce (or a proof of concept)
- The potential impact as you understand it

We aim to acknowledge reports within 2 business days and to provide a remediation
timeline within 7 business days.

## Scope

This policy covers code in any repository in the `patron-studio` GitHub
organisation, and any deployed environment we operate.

It does not cover third-party services we depend on (Supabase, Vercel, Sanity,
Postmark, Airtable, Shopify, Meta, etc.) — please report those directly to the
relevant vendor.

## Out of scope

- Reports based purely on automated scanner output without a working PoC
- Missing security headers on non-production preview deployments
- Issues requiring a compromised user device or shared credentials
- Volumetric / DoS findings on infrastructure we don't operate (CDN, hosting)

## Per-repo overrides

Individual repositories may add their own `SECURITY.md` if they need a different
contact or scope (for example, a public-facing repo with a separate security
contact). The per-repo file takes precedence over this one.
