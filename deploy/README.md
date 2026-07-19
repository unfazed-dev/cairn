# Deploying cairn

Two binaries, two deploy targets:

| Binary | Role | Port | Deploys as |
|---|---|---|---|
| `cairn-server` | the sync engine (Postgres logical-replication → clients) | 8800 | one Fly app **per managed project** (template: [`../fly.toml`](../fly.toml)) |
| `cairn-cloud` | the control plane (accounts, projects, API keys, billing, admin) | 9090 | one Fly app for the whole cloud |

Both build from the repo-root [`Dockerfile`](../Dockerfile) (multi-stage,
`cairn-server --features pg` + `cairn-cloud`, slim runtime).

---

## Managed-cloud architecture (the groundwork slice)

```
   customer                 cairn-cloud (1 app)              one Fly app per project
   ┌────────┐  POST /v1/    ┌──────────────────────┐   provision   ┌─────────────────────┐
   │ admin  │──projects/──► │ control plane        │ ────────────► │ cairn-server (sync)  │
   │ SPA    │   provision   │ • store (acct/proj/  │   (Fly API)   │  • CAIRN_PG_URL=...  │
   └────────┘               │   api_keys/subs)     │               │  • its own slot      │
        │                   │ • Stripe billing     │               │  • isolated from     │
        │ Stripe            │ • Provisioner trait  │               │    every other proj  │
        ▼                   │   (Manual / Fly)     │               └──────────┬──────────┘
   ┌────────┐               └──────────┬───────────┘                          │ ws://<app>.fly.dev
   │ Stripe │  webhook HMAC            │ stores sync_url                      │ /sync
   └────────┘                          ▼                                      ▼
                                   ┌──────────────┐   each project's   ┌──────────────┐
                                   │  sqlite      │   Postgres source  │  Postgres    │
                                   │  (control)   │ ◄───────────────── │  (customer)  │
                                   └──────────────┘                     └──────────────┘
```

**Multi-tenant isolation = one cairn-server Fly app per project.** Each app
binds exactly one project's `CAIRN_PG_URL` (a Fly secret, never logged), owns
its own `cairn_slot`/`cairn_pub`, and shares no state with other projects.
Isolation is at the process boundary, not a multi-tenant in-process split — the
simplest correct model (no cross-tenant leakage path through shared memory,
connection pools, or a shared SQLite file).

### The Provisioner seam (next slice — not yet wired)

The control plane stores `Project.sync_url` but does **not** yet provision the
sync-server instance. The next managed-cloud slice adds a `Provisioner` trait
(`crates/cairn-cloud/src/provision.rs`):

```rust
#[async_trait]
pub trait Provisioner: Send + Sync {
    /// Deploy an isolated cairn-server for `project` bound to `pg_source_url`.
    /// Returns the public sync_url the control plane records on the project.
    async fn provision(&self, project: &Project, pg_source_url: &str)
        -> Result<ProvisionedSync>;
}

pub struct ProvisionedSync {
    pub sync_url: String,    // wss://cairn-sync-<project>.fly.dev/sync
    pub region: String,
    pub instance_id: String, // the Fly app name
}
```

Two impls:
- **`ManualProvisioner`** — ops deploys the app by hand (the steps below) and
  registers the sync_url via `POST /v1/projects/{id}/sync-url`. For MVP / local
  / pre-Fly-account.
- **`FlyProvisioner`** — calls the Fly API (machines / apps) to deploy
  [`fly.toml`](../fly.toml) as `cairn-sync-<project-id>`, injects
  `CAIRN_PG_URL` + `CAIRN_WRITE_TABLES` as Fly secrets, returns the sync_url.
  Requires `FLY_API_TOKEN`; returns a clear `not-configured` error (never a
  silent stub) when absent.

A `POST /v1/projects/{id}/provision` route (admin-authed) calls the provisioner
and stores the resulting `sync_url`.

---

## Deploy a sync server by hand (ManualProvisioner path)

Prereqs: [`flyctl`](https://fly.io/docs/hands-on/install-flyctl/) + `fly auth login`.

```sh
APP=cairn-sync-$PROJECT_ID          # one app per project
fly launch --no-deploy --name "$APP" --image-label "$APP" --dockerfile Dockerfile
# Secrets (never commit) — the customer's Postgres source + the write allowlist:
fly secrets set --app "$APP" \
  CAIRN_PG_URL="postgresql://...@<customer-pg>:5432/...?sslmode=require" \
  CAIRN_WRITE_TABLES="tasks,providers,..." \
  CAIRN_JWT_AUD="<your-aud>" \
  CAIRN_JWKS_URL="<your-jwks>"   # or CAIRN_JWT_SECRET for HS256
fly deploy --app "$APP"
# Register the sync_url with the control plane:
curl -X POST https://cloud.<your-domain>/v1/projects/$PROJECT_ID/sync-url \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -d "{\"sync_url\":\"wss://$APP.fly.dev/sync\"}"
```

Point the customer's client at `wss://$APP.fly.dev/sync`. Done.

### Deploy the control plane (cairn-cloud)

One app for the whole cloud (separate from the per-project sync apps):

```sh
fly launch --no-deploy --name cairn-cloud --dockerfile Dockerfile
fly secrets set --app cairn-cloud \
  STRIPE_SECRET_KEY=... STRIPE_WEBHOOK_SECRET=... CAIRN_CLOUD_ADMIN_KEY=...
# Override the entrypoint to the cloud binary (the image defaults to cairn-server):
fly deploy --app cairn-cloud --strategy rolling
```

(The cloud app sets `[processes]`/CMD to `cairn-cloud`; the per-project sync
apps use the default `cairn-server` entrypoint.)

---

## Observability on Fly

- **Logs**: `CAIRN_LOG_FORMAT=json` is set in [`fly.toml`](../fly.toml) →
  `fly logs` shows structured JSON; pipe to an OTel collector / Logtail /
  Datadog via Fly's [log shippers](https://fly.io/docs/reference/logs).
- **Metrics**: `GET /metrics` (Prometheus text) on the sync app — scrape with
  [`fly metrics`](https://fly.io/docs/reference/metrics/) or a Prometheus
  instance. Watch `cairn_slot_wal_status` (the P0-1 slot-health gauge) and
  `cairn_replication_lag_bytes` — alert if `wal_status` leaves `Healthy`.

---

## Why a sync server must not auto-stop

`fly.toml` sets `auto_stop_machines = false` + `min_machines_running = 1`.
A "sleeping" cairn-server stops consuming its Postgres replication slot; once
`max_slot_wal_keep_size` fires, `wal_status` flips to `lost` and offline changes
are silently skipped (the P0-1 data-loss class). **A stopped sync server is a
data-loss server.** Keep it running. (See
`docs/plans/cairn-soundness-audit-2026-07-19.md` §P0-1.)
