# Security Model — why Cairn's predicates are the authorization layer

Cairn sits between Postgres (or Supabase) and every device. Two facts about
that position mean Postgres Row Level Security (RLS) does **not** protect
synced data the way it protects a normal client connection, and Cairn has to
supply the equivalent guarantee itself.

## Why RLS doesn't reach sync traffic

1. **Logical replication streams unfiltered rows.** `cairn-server`'s
   `PgReplicator` reads the WAL through a replication slot as a privileged
   Postgres role. RLS policies are evaluated per-session for normal SQL
   connections; the replication protocol has no session and no policy
   evaluation. Every row change on a published table reaches Cairn's server,
   regardless of which tenant it belongs to.
2. **Write-back is a privileged connection.** Direct write-back (ADR-0013)
   applies client-queued mutations to Postgres over a single, privileged
   `PgWriteBack` connection — not as the end user, and not subject to that
   user's RLS policies. A write that isn't scoped by the server can touch any
   row the allowlisted table exposes.

So the two places RLS would normally do the work — read filtering and write
scoping — are both bypassed by construction. Cairn cannot lean on Postgres's
authorization model for sync traffic; it has to be its own authorization
layer.

## What Cairn does instead

- **Reads:** server-enforced predicates (ADR-0011). The server never trusts a
  client-supplied tenant filter — when `CAIRN_SYNC_AUTH=supabase-jwt` and
  `CAIRN_TENANT_COLUMN` is set, `build_predicate` drops any client-attested
  filter on that column and ANDs in `<tenant_column> = <principal.tenant_id>`
  on every subscription, including subscriptions that carry a `where_sql`
  clause (ADR-0012) — a client expression can never widen scope past its own
  tenant.
- **Writes:** tenant enforcement on the write path is being extended to match
  (see the write-path tenant enforcement ADR, authored alongside this launch
  gate) — force-stamping the tenant column on INSERT and ANDing the tenant
  clause onto UPDATE/DELETE so a cross-tenant write is rejected before it
  reaches Postgres.
- **`CAIRN_SYNC_AUTH=none` is dev-only.** Anonymous mode injects no tenant
  filter — there is no principal to scope to — so it is single-tenant only.
  The server warns at startup when it starts in this mode; a multi-tenant
  deploy (including any Supabase project with more than one tenant's data in
  a synced table) **must** set `CAIRN_SYNC_AUTH=supabase-jwt`.

## Summary

| Layer | Postgres RLS | Cairn |
|---|---|---|
| Reads | Bypassed (replication has no session) | Server-injected tenant predicate, ADR-0011 |
| Writes | Bypassed (privileged write-back connection) | Write-path tenant enforcement (in progress) |
| Anonymous/dev mode | N/A | Single-tenant only, warned at startup |

If you are relying on Supabase RLS to isolate tenants and you point Cairn at
that project, RLS provides no protection for data flowing through Cairn's
`/sync` socket — Cairn's own authorization layer is what you are trusting.
Configure `CAIRN_SYNC_AUTH=supabase-jwt` and `CAIRN_TENANT_COLUMN` for any
deploy with more than one tenant's data.

See also: [`SECURITY.md`](../SECURITY.md) (vulnerability reporting),
[ADR-0010](adr/0010-sync-authentication-and-principal.md) (authentication),
[ADR-0011](adr/0011-server-enforced-predicates.md) (read-path enforcement).
