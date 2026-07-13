# Cairn Reference Demo App — Offline-First Tasks (all SDKs)

**Started:** 2026-07-13. **Owner:** Claude (tech lead). **Bar (operator-approved):**
engineer + design ONE application that demonstrates **all** cairn features, with
the **same** app implemented across every SDK — starting with **Flutter** (iOS +
Android), then the other iOS/Android-capable SDKs (React Native, Kotlin, Swift,
Capacitor, .NET). The operator must **visually see** the app running with action
controls (pause / resume-restart / stop / airplane-mode), and cairn must operate
as a **local offline-first** engine (PowerSync-equivalent): reads + writes against
the local store while offline, durable queued writes, automatic sync on reconnect.

Per the standing scope rule, every SDK app **lives as a cairn test fixture** under
`sdk/<sdk>/example` (or the SDK's app dir) — not a separate product repo. This
plan is the shared spec; Flutter is the reference implementation; the other SDKs
port it.

## What "all cairn features" means here

| cairn capability | how the demo shows it |
|---|---|
| Live replication (server → client) | task list updates as rows arrive over `/sync` |
| Reactive watch | `watch(table)` / equivalent drives the list `Stream` |
| Reactive SQL watch (PowerSync parity) | `watchQuery` / equivalent for a filtered view (e.g. open vs done) |
| Durable offline writes (outbox) | add a task while "offline" → it survives in the local store, flushes on reconnect (ADR-0013) |
| Auto-reconnect | connection-state badge cycles Disconnected → Reconnecting → Connected |
| Client → server echo | the writer's own write re-emits via the server's WriteBack and lands locally |
| Checkpoint / Lsn | a small "synced through Lsn N" line in the status panel |
| Connection control | operator buttons: Pause / Resume / Stop / Airplane |

## Architecture (same for every SDK)

```
Supabase cloud PG (db.<ref>.supabase.co:5432, table `tasks`, publication `cairn_pub`)
        ▲
        │ logical replication (PgReplicator, `--features pg`)
        │
   cairn-server (runs on the dev host / a box with line-of-sight to cloud + device)
        ▲
        │ WebSocket  /sync  (JSON wire frames; ADR-0009)
        │
   SDK app (Flutter / RN / Kotlin / …) on device/sim
        │
   local SQLite (cairn-owned) — the offline-first source of truth
```

The app **never** talks to Postgres directly. It talks to one `cairn-server`
over `/sync`. Offline = the `/sync` WebSocket is down (airplane) or the app has
`close()`d its session (pause/stop); the local SQLite remains the read + write
surface, and the durable outbox holds writes until reconnect.

## The cloud source (Supabase)

- **Direct connection only** (`db.<ref>.supabase.co:5432`) — the pooler cannot
  carry logical replication (documented in `docs/plans/flutter-supabase-plug-and-play-launch.md`).
- **Schema + publication:** apply `docker/pg-init/01-sources.sql` as the `postgres`
  role — creates the `tasks` table + `cairn_pub` publication. (The
  `fixtures/flutter/todo/supabase/schema.sql` is `auth.users`-bound + RLS — NOT a
  replication source; do not use it for this.)
- **cairn-server launch:** `cargo run --features pg -p cairn-server --
  --replicator pg --pg-url 'postgresql://postgres:<pw>@db.<ref>.supabase.co:5432/postgres'
  --pg-publication cairn_pub --pg-slot cairn_slot --sync-auth none`.
- **Secret handling:** the password lives in the gitignored root `.env`
  (`SUPABASE_PASSWORD` + `CAIRN_PG_URL_CLOUD`); `.env.example` carries placeholders
  only. Never commit the password.

### IPv6-only reachability — RESOLVED via a WARP relay (2026-07-13)

`db.ltamqsxxumtusyxswezi.supabase.co` resolves **IPv6-only** (`2406:da1c:…`), and
this dev host's VPN stack (ProtonVPN + Tailscale) tunnels IPv4 but **drops IPv6**
egress — so cairn-server's `PgReplicator` cannot reach the direct host. The launch
plan's three documented fixes: host IPv6 / Supabase IPv4 add-on / **a relay**.

**The relay (in use, verified end-to-end):** a `wireproxy` userspace WireGuard
client tunnels to **Cloudflare WARP** (which has full IPv6) and exposes a local
**TCPClientTunnel `127.0.0.1:15433` → `[Supabase-IPv6]:5432`**. cairn-server
connects to plain IPv4 `127.0.0.1:15433`; wireproxy relays each byte over WARP to
Supabase. Supabase accepts **non-SSL** on the direct port + authenticates with
**SCRAM-SHA-256** — both compatible with cairn's `NoTls` connector (no TLS change
needed). Verified: a correct PG StartupMessage through the tunnel returns
`AuthenticationRequest code=10 (SCRAM-SHA-256)`; cairn-server then connects,
creates `cairn_slot`, and streams the `cairn_pub` publication.

**cairn-server launch (cloud-backed, via the relay):**
```
CAIRN_BIND=127.0.0.1:8800 \
CAIRN_REPLICATOR=pg \
CAIRN_PG_URL='postgresql://postgres:<pw>@127.0.0.1:15433/postgres?sslmode=disable' \
CAIRN_PG_SLOT=cairn_slot CAIRN_PG_PUBLICATION=cairn_pub CAIRN_SYNC_AUTH=none \
RUST_LOG=info ./target/debug/cairn-server
```
(the binary must be built with `--features pg`; `target/debug/cairn-server` is.)

**Reproducing the relay** (the WARP private key is a regenerable Cloudflare free-tier
secret — keep it out of git; the live conf lives at `/private/tmp/.../scratchpad/cairn-warp.conf`):
register a WARP device at `engage.cloudflareclient.com`, then run
`wireproxy -c cairn-warp.conf` with a `[TCPClientTunnel] BindAddress=127.0.0.1:15433`
`Target=[<supabase-ipv6>]:5432`. For a production deploy, prefer native host IPv6 or
the Supabase IPv4 add-on over a WARP relay; the relay is a dev-box workaround for the
VPN-broken-IPv6 case (it mirrors how PowerSync "just works" — PowerSync's *client* is
IPv4/443 to a sync service; the Postgres link is server-side, where cairn-server now
also sits, just tunneled through WARP).

**Verified demo (2026-07-13):** schema applied (`docker/pg-init/01-sources.sql` →
`tasks` + `cairn_pub`); cairn-server connected to Supabase via the relay; a Flutter
app on macOS connected to cairn-server, and a row INSERTed into the **Supabase cloud
`tasks`** table appeared in the app in real time (server→client logical replication).

**Known cairn-server gap surfaced by this demo (separate from IPv6):** a *fresh*
subscriber does **not** receive the table's pre-existing rows — only events that
arrive *after* subscribe. Rows INSERTed before the app connects are missed; rows
INSERTed while connected stream live. PowerSync sends the existing snapshot on first
sync ("open the app, see your data"); cairn-server's fan-out currently forwards from
subscribe-time only. This is a real PowerSync-parity gap to address in the
`FanOutService`/session path — not blocking the IPv6 fix, but blocking the "fresh
install sees existing data" UX.

## Operator controls (the same five on every SDK)

The app surfaces a control panel + a connection-state badge. Mapping to the
cairn client surface (Flutter as reference; others mirror):

| control | cairn action | what the operator sees |
|---|---|---|
| **Pause** | `close()` the active subscription (keep the `Cairn` handle) | badge → Disconnected; writes queue locally |
| **Resume / Restart** | `subscribe(table)` again on the same handle | badge → Connecting → Connected; queued writes flush |
| **Stop** | `close()` + release the handle | session fully torn down |
| **Airplane mode** | toggle real device network (platform channel) where supported; else = Pause | the hero offline proof — cairn rides a true network drop |
| (badge) | `connectionState` stream | Connecting / Connected / Reconnecting / Disconnected |

**Why this is a *real* offline-first demo, not theater:** cairn's durable outbox
is the on-device SQLite store (ADR-0013). `close()` aborts the sync loop but the
SQLite file — including pending writes — persists. Re-subscribe opens the same
file; pending writes flush to the server on reconnect. So Pause → add tasks →
Resume visibly shows queued writes syncing. That is the PowerSync-equivalent
contract.

## Per-SDK status (fills as each ships)

| SDK | platform(s) | status |
|---|---|---|
| Flutter | iOS / Android / macOS | 🟡 reference — in progress 2026-07-13 |
| React Native | iOS / Android | ⏳ port (after Flutter reference locks) |
| Kotlin | Android | ⏳ port |
| Swift | iOS / macOS | ⏳ port |
| Capacitor | iOS / Android (webview) | ⏳ port |
| .NET | iOS / Android | ⏳ port |
| Node / Tauri / Rust / Web | desktop / server / browser | ⏳ later (not "iOS/Android first") |

Ports are fanned out via the Swarm **after** the Flutter reference is locked +
visually verified — each port is independently compiled + run on a device before
it's marked green (this session's process lesson: agents' green self-reports are
unverified until reproduced).

## Sequencing

1. **Flutter reference** (this effort): redesign `sdk/cairn_flutter/example/lib/main.dart`
   into the Tasks UI + controls; run against the cloud-backed `cairn-server` on
   iOS sim (fallback macOS); screenshot the offline-first flow.
2. **Cloud wiring + per-SDK runner tables** (infra, parallel).
3. **Swarm fan-out:** RN → Kotlin → Swift → Capacitor → .NET, each porting the
   Flutter spec, each verified on a device.
