# Security Policy

## Reporting a vulnerability

Report security vulnerabilities privately through **[GitHub private vulnerability
reporting](https://github.com/unfazed-dev/cairn/security/advisories/new)**
(repo → Security → Report a vulnerability). Do not open a public GitHub issue for
a suspected vulnerability — public issues are fine for everything else, but a
vulnerability report should stay private until a fix ships.

<!-- CAIRN-IDENTITY-PENDING: no contact mailbox exists yet — docs/IDENTITY.md.
     This previously read "report privately to founders@cairn.dev", a mailbox on
     an UNREGISTERED domain: such a report reaches nobody, and the reporter has
     no way to know it vanished. Add a real address here when one exists; until
     then GitHub's private reporting is the channel that actually works. -->

Include what you can: affected version/commit, reproduction steps, and
impact. We'll acknowledge your report and follow up as we investigate; credit
is given in the fix's release notes unless you ask us not to.

## Supported versions

| Version | Supported |
|---|---|
| `v0.1.x` | :white_check_mark: |
| pre-release / `main` | best-effort, alpha software |

Cairn is pre-1.0; there is no long-term-support branch yet. Security fixes
land on `main` and are backported to the current `v0.1.x` line.

## Trust model

Cairn's server sits between Postgres (or Supabase) and every synced device
with a privileged connection — logical replication and write-back both
bypass Postgres Row Level Security by construction. Cairn's own
server-enforced predicates and write-path tenant enforcement are what stand
in for RLS on sync traffic; see
[`docs/SECURITY-MODEL.md`](docs/SECURITY-MODEL.md) for the full explanation
of what is and isn't protected, and what a multi-tenant deploy must
configure (`CAIRN_SYNC_AUTH=supabase-jwt`, `CAIRN_TENANT_COLUMN`).
