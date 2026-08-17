# cairn-push — cairn-pushd, the standalone push daemon

Token-addressed APNs / FCM HTTP v1 / Web Push sends with debounce coalescing,
behind one REST API and one env-var credential contract. ADR-0038.

## What it is

- A self-hosted push server you run next to any stack: register device
  tokens, POST sends, poll delivery receipts. No cairn sync engine required.
- Three rails, configured by env vars — unset = rail off:
  | rail | env |
  |---|---|
  | FCM HTTP v1 | `CAIRN_FCM_CREDENTIALS_JSON` (service-account JSON, inline) |
  | APNs | `CAIRN_APNS_KEY_P8` (p8 PEM or path), `CAIRN_APNS_KEY_ID`, `CAIRN_APNS_TEAM_ID`, `CAIRN_APNS_BUNDLE_ID`, optional `CAIRN_APNS_SANDBOX=1` |
  | Web Push | `CAIRN_WEBPUSH_VAPID_PRIVATE_KEY`, `CAIRN_WEBPUSH_VAPID_SUBJECT` (mailto:) |
- Tenant-scoped API keys (`CAIRN_PUSHD_API_KEYS="tenant:secret[:rail],…"` —
  the optional `:rail` suffix grants the Rail role required for rail-mode
  sends; a secret may not itself end with `:rail`, the reserved suffix),
  a SQLite token registry with prune-on-410/UNREGISTERED, and a per-target
  debounce coalescer using rail-native supersede keys.
- Abuse ceilings on the send path (config per the 2026-08-17 audit):
  per-tenant rate limit + burst (`CAIRN_PUSHD_SEND_RATE_PER_SEC`=10 /
  `CAIRN_PUSHD_SEND_BURST`=50 -> 429), request field caps (-> 400), and
  coalescer ceilings (10k pending keys, 64 losers per key).
- The API contract is versioned and pinned: `docs/api/cairn-pushd.yaml`.

## What it is NOT

- **Not a marketing platform.** No topics, scheduling, segments, A/B tests,
  or campaign analytics — that boundary is ratified in ADR-0037 and stands.
- **Not a delivery guarantee.** APNs/FCM/Web Push last-mile is best-effort;
  outcomes are reported via the receipt log, never promised. Push is a
  nudge — reconcile state another way (in cairn, that way is sync).
- **Not presence-aware.** "Don't doorbell an online device" needs a session
  store, which only the sync engine has. Standalone coalescing is
  time-window debounce only.

## Quickstart

```sh
# 1. Credentials — validates and writes gitignored .env (never cairn.toml):
cairn push init --fcm --fcm-credentials-json ./service-account.json
cairn push init --webpush --vapid-subject mailto:ops@example.com

# 2. Sanity — credential shape/reachability, never end-to-end delivery:
cairn push check

# 3. Run (append ":rail" to a key that cairn-server delegates with):
CAIRN_PUSHD_API_KEYS="acme:s3cr3t,hq:delegator-key:rail" cairn-pushd

# 4. Register + send (see docs/api/cairn-pushd.yaml):
#    POST /v1/tokens  {"token": "…", "platform": "fcm"}
#    POST /v1/send    {"token": "…", "payload": {"visible": {"title": "Hi", "body": "…"}}}
#    GET  /v1/receipts?since=0
```

Docker: the `cairn-pushd` service in `docker/docker-compose.stack.yml`
(ADR-0038; builds from the root Dockerfile).

## Postgres registry (v1.1)

SQLite is the default and needs nothing. For a shared / containerized
registry, build with the `pg` feature and point the daemon at Postgres:

```sh
cargo build --release -p cairn-push --features pg
CAIRN_PUSHD_DATABASE_URL="postgres://user:pass@host:5432/db" cairn-pushd
```

- Set + `pg` build → the PgStore: same trait, same semantics (tenant
  isolation, cross-tenant 409s, monotonic receipt seq, age sweep), DDL
  created idempotently at boot. Cross-tenant re-registration is refused by
  a single atomic `INSERT … ON CONFLICT … DO UPDATE … WHERE owner matches`,
  so it stays race-safe even with several daemon replicas on one database.
- Set on a build without the feature → the daemon refuses to start, naming
  the rebuild — it never silently downgrades you to SQLite.
- Unset → the SQLite registry (`CAIRN_PUSHD_DB`), byte-for-byte the v1.0
  behavior.

When to use it: more than one pushd replica, a registry that must outlive
a container filesystem, or ops that already back Postgres. The pool is a
single connection per daemon (the `PgTokenStore` pattern) — right-sized
for the daemon's low-write shape.

Real-Postgres store tests: `CAIRN_E2E_PG=1 CAIRN_PG_URL=… cargo test -p
cairn-push --features pg` (self-skip without the flag — a skipped run is
not a verified pass).

## The upgrade path (why this daemon exists)

cairn-pushd is the only push server with a sync-aware upgrade path. Adopt
cairn sync later, point `CAIRN_PUSH_REMOTE_URL`/`CAIRN_PUSH_REMOTE_KEY` at
this daemon, and your pushes become predicate-routed doorbells derived from
the same fan-out pass as sync — with presence-aware coalescing and
push-LSN → client-ack delivery proof no push vendor can offer
(ADR-0037 §5, ADR-0038 §3).

Full recipes: `docs/push.md`. Contract: `docs/api/cairn-pushd.yaml`.
Decision record: `docs/adr/0038-standalone-push-daemon.md`.
