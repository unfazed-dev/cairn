# Quickstart: Flutter + Cairn in ≤5 minutes

Cairn is Postgres logical replication → a Rust fan-out server → on-device
SQLite: local-first, offline-capable sync for Flutter, Apache-2.0 end to end.
One control plane (your Postgres/Supabase project + one CLI), no connector
class, no server-deployed sync-rules DSL, no duplicated client-side schema —
your Dart predicates (`where_sql`) ARE the sync rules.

Two tracks below:

- **Local dev** (this page's own dry-run — see the timing note at the
  bottom) — any Postgres, works today, no external account needed.
- **Supabase project** — the target launch flow. Every
  Supabase-project-specific step is marked **⏳ pending live verification**:
  W0 (`docs/plans/flutter-supabase-plug-and-play-launch.md`) needs an
  operator-provided Supabase project to empirically verify these against a
  real one (JWKS default, direct-connection reachability, slot limits — see
  that plan's "Research ground truth"). Everything NOT marked ⏳ is proven —
  either directly, or via the local track exercising the identical code path
  (auth → tenant-scoped reads → tenant-enforced write-back) against a
  same-shape HS256 JWT instead of Supabase's real RS256/JWKS token.

`cairn` ships as a prebuilt binary (GitHub Releases + `brew tap` + curl
installer) once W6 (release engineering) lands. **Until then**, every `cairn
...` command below is `cargo run -p cairn-cli -- ...` from a checkout of this
repo — the CLI itself is fully built and working (W3), only its distribution
is pending.

## Local dev (works today)

Prerequisites: a Rust toolchain (`rustup show` in this repo), Flutter ≥3.44
with native assets enabled (`flutter config --enable-native-assets`, one-time
per machine), and a Postgres with `wal_level = logical` (the repo's `docker
compose -f docker/docker-compose.yml up -d postgres` gives you one
pre-configured — see `fixtures/flutter/todo/tool/cairn_live_up.sh` for the
scripted version of everything below).

| Step | Command | Time budget |
|---|---|---|
| 1. Start Postgres | `docker compose -f docker/docker-compose.yml up -d postgres` (or point at your own `wal_level=logical` Postgres) | 0:00–0:15 |
| 2. Create your table | `CREATE TABLE todos (id text primary key, user_id text not null, title text not null, done boolean not null default false, created_at timestamptz not null default now());` — `cairn init` creates the **publication**, not your tables | 0:15–0:45 |
| 3. `cairn init` | `cargo run -p cairn-cli -- init --db-url postgresql://cairn:cairn@localhost:5433/cairn --tables todos --write-tables todos --tenant-column user_id` | 0:45–1:15 |
| 4. `cairn dev` | `cargo run -p cairn-cli -- dev` — prints the `ws://` URL + a copy-paste Dart snippet | 1:15–1:45 (plus first-run Rust compile — see the timing note) |
| 5. Add the SDK | `flutter pub add cairn_flutter` (pub.dev, once W6 publishes it — today: a `path:` dependency on `sdk/cairn_flutter`, see `fixtures/flutter/todo/pubspec.yaml`) | 1:45–2:15 |
| 6. ~10 lines of Dart | see below | 2:15–3:00 |

```dart
import 'package:cairn_flutter/cairn_flutter.dart';

final cairn = await Cairn.connect(url: 'ws://127.0.0.1:8800/sync', token: jwt);
await cairn.subscribe('todos'); // no where clause needed — the server scopes
                                 // reads to YOUR rows once auth is configured
                                 // (CAIRN_SYNC_AUTH=supabase-jwt, ADR-0011)

cairn.watch('todos').listen((rows) {
  // rows: the full current row set for `todos` — durable-offline snapshot
  // first, then re-emitted after every applied change.
});

await cairn.write('todos', op: 'upsert', pk: id, payload: {'title': 'buy milk'});
// returns as soon as the write is durable on disk — NOT once the server
// acks it. The UI never blocks on connectivity (ADR-0013's outbox).
```

`token` is a bearer JWT `cairn-server` verifies per `CAIRN_SYNC_AUTH`. With
no auth configured (`cairn init`'s default — no `--tenant-column`'s auth
wiring active until a JWT secret exists), `token` is ignored and every
client sees every row — fine for solo local dev, wrong for anything shared.
To exercise real per-user tenant isolation locally (what the Supabase track
gets for free from RLS-adjacent enforcement — see
`docs/SECURITY-MODEL.md`), mint an HS256 JWT against the dev secret `cairn
dev` picked up from `.env`'s `CAIRN_SUPABASE_JWT_SECRET` — see
`fixtures/flutter/todo/tool/mint_jwt.sh` for a working example (`sub` becomes
both account id and tenant id).

**Wire types** (ADR-0019): `watch()` rows carry native JSON types — a
Postgres `boolean` is a Dart `bool`, `int2`/`int4` are `int`, and so on. Two
precision-preserving exceptions arrive as `String`: `int8`/`numeric`/`money`
(can exceed the 2^53 range a `double`/JS `number` holds exactly — parse with
`int.parse`/a `Decimal` type, never `num.parse`), and `bytea` (base64 —
decode with `base64Decode`). Timestamps arrive as RFC 3339 UTC strings
(`...Z`) — parse with `DateTime.parse`.

### The full working example

`fixtures/flutter/todo` is a real Flutter app with three interchangeable
backends selected purely by env — mock (default, no setup), Supabase-direct
(`SUPABASE_URL`/`SUPABASE_ANON_KEY`), and Cairn "local live"
(`CAIRN_WS_URL`/`CAIRN_TOKEN`, see `lib/env.dart`). The Cairn-backed
repository is `lib/infra/cairn_todo_repository.dart` — read it as the
canonical ~80-line example of wiring `cairn_flutter` into a real app
(subscribe once, map rows to a domain model, write without a `user_id` in
the payload — the server force-stamps it, ADR-0018).

Run the whole thing yourself:

```sh
fixtures/flutter/todo/tool/cairn_live_up.sh    # docker PG + cairn init + cairn dev, idempotent
cd fixtures/flutter/todo
flutter test integration_test/cairn_live_test.dart -d macos   # the W5 proof — see below
fixtures/flutter/todo/tool/cairn_live_down.sh
```

### What the proof actually showed (2026-07-12) — a launch-blocking finding

`integration_test/cairn_live_test.dart` set out to drive two real `Cairn`
instances (user-a / user-b, distinct HS256 JWTs) through
`CairnTodoRepository` against a real `cairn-server` + real docker Postgres.
While building it, **this uncovered a real, previously-untested bug in
`cairn_flutter`/`cairn-client`** — not a fixture bug, and not something this
page can fix (out of scope: `crates/`, `sdk/`). Full detail, source
citations, and reproduction are in that test file's header comment; summary:

- **The bug:** `cairn_flutter`'s `watch()` can permanently fail to reflect a
  write to a real-Postgres-backed table if nothing else happens on that
  connection afterward — the single most common shape for a todo app (one
  user, one action, then quiet). Root cause:
  `crates/cairn-core/src/apply.rs`'s `ApplyEngine::feed` buffers frames
  sharing a transaction id and only flushes (which is what feeds `watch()`)
  when a SUBSEQUENT frame with a different/absent txn id arrives — there's
  no idle/time-based fallback in `feed()` itself. The one safety net that
  exists, `SyncClientConfig::idle_timeout`, is explicitly set to `None` in
  `sdk/cairn_flutter/rust/src/api/cairn.rs:145`. A second, sharper symptom
  reproduced twice: an isolated FIRST connection's write may never even
  reach Postgres at all (not just fail to reflect via `watch()`) — consistent
  with the outbox-flush trigger also being gated on incoming traffic on that
  same connection.
- **Why it was invisible until now:** `cairn_flutter`'s own passing example
  test uses a continuous synthetic `FakeReplicator` stream (always more
  frames coming, so batches close instantly) with no auth. `cairn-client`'s
  own test suite never exercises the real `PgReplicator` at all. The
  `cairn-infra` e2e suite that DOES prove the real-PG write→replicate→deliver
  round trip (`CAIRN_E2E_PG=1 cargo test -p cairn-infra --features pg --test
  e2e_pg_writeback`, 8/8 passing) drives a raw WebSocket client, never
  `SyncClient`. This exact combination — `SyncClient` + real `PgReplicator`
  + a realistic single-user usage pattern — had never been exercised
  anywhere in this repo before this fixture.
- **What's still proven, independent of the bug** (verified with a raw
  `dart:io` WebSocket client and direct Postgres queries, both channels this
  bug doesn't touch):
  - The server, real Postgres replication, and HS256 auth are all healthy —
    a raw client receives a replicated frame within ~3s of a direct SQL
    insert.
  - **Read isolation (ADR-0011):** subscribing to `todos` with no `where`
    clause, a raw client authenticated as user-a never receives user-b's row
    and vice versa.
  - **Write isolation (ADR-0018):** user-a's attempted upsert onto user-b's
    existing `todos` row id does not change the row in Postgres — verified
    by direct `SELECT`, which is also the ONLY way to observe this: the SDK
    has no client-visible signal for a server-rejected write at all
    (`WriteResult{ok:false}` just retries forever, silently — a second,
    separate SDK gap, see below).
  - `cairn.write()` returns in low double-digit milliseconds regardless (the
    local-outbox durability contract holds) — it's whether the write ever
    reaches the server, and whether the client ever reflects a synced row
    back, that's broken.

Run `flutter test integration_test/cairn_live_test.dart -d macos` yourself
for current pass/fail — this page is not a substitute for running the suite,
and the scenarios that depend on the broken path are marked `skip:` with the
reason inline rather than silently omitted.

### Timing dry-run (author's machine, NOT the stranger test)

This is the plan's own author re-running the "Local dev" steps above,
stopwatched, alone, on a machine that already has this repo checked out —
**not** the operator-mandated stranger test (fresh machine, fresh person, no
author present), which stays a launch-blocking TODO.

| Cache state | Steps 1–5 wall-clock | Note |
|---|---|---|
| Warm (`cargo`/pub caches already populated from earlier work in this repo) | ~10s docker + init + ~3s dev startup + pub get already resolved | Comfortably inside 5:00 |
| Cold (fresh `~/.cargo/registry`, no prior build of `cairn-cli`/`cairn-server`/`cairn_flutter`'s Rust crate) | **not separately measured in this pass** — cargo compiling `cairn-cli`, `cairn-server` (with the `pg` feature), and `cairn_flutter`'s native-assets fallback from scratch is realistically several minutes each, likely blowing the 5:00 budget on a cold machine | This is exactly what W6's prebuilt-binary distribution (GitHub Releases, `hook/prebuilt.json`) exists to fix — until it ships, "≤5 minutes" is a warm-cache claim, not a cold-clone one. Flagged, not fudged. |

## Supabase project

1. Create a Supabase project (or use an existing one).
2. Database → get the **direct connection string** (not the pooler — logical
   replication needs it).
   > **⚠️ IPv6 warning (verified 2026-07-12):** free-tier direct connections
   > are **IPv6-only** (AAAA records only), and a network that *assigns* your
   > machine an IPv6 address does not necessarily *route* it — we reproduced
   > exactly this on a real dev network: global IPv6 address present, all v6
   > TCP failing "no route to host". `cairn doctor` detects this case and
   > names it. Poolers do NOT carry logical replication, so you must reach the
   > direct host. Fixes, easiest first:
   > 1. **Userspace Cloudflare WARP** (free, no sudo, no macOS system
   >    extension, does not disturb an existing full-tunnel VPN) —
   >    `SUPABASE_REF=<ref> scripts/warp-ipv6-egress.sh up` runs WARP via
   >    `wireproxy` in userspace and exposes `127.0.0.1:15433` → your Supabase
   >    host. Point cairn at
   >    `postgresql://postgres:<pw>@127.0.0.1:15433/postgres?sslmode=disable`
   >    (cairn connects with NoTls today; Supabase's direct host permits
   >    plaintext, so `sslmode=disable` — *not* `require`). Verified
   >    end-to-end against a real project: the full replication e2e is green
   >    through this tunnel. `…sh down` stops it.
   > 2. A network with working IPv6 egress.
   > 3. The Supabase IPv4 add-on (paid, Pro+) for the direct connection.
3. `cairn init --db-url <direct connection string> --tables <your tables>
   --write-tables <writable subset> --tenant-column <your tenant column>
   --supabase-url https://<project-ref>.supabase.co` — creates the
   publication, derives the JWKS URL, writes `cairn.toml` + `.env`.
   ✅ verified 2026-07-12 against project `ltamqsxxumtusyxswezi`: the
   `postgres` role can create/drop a logical slot + publication (pgoutput),
   5 slots / 0 used, and cairn's `PgReplicator` runs the full snapshot +
   live + LSN-resume e2e green (`e2e_pg_replication` 3/3, `e2e_pg_snapshot`
   2/2).
4. `cairn dev` — prints the `ws://` URL.
5. `flutter pub add cairn_flutter supabase_flutter`.
6. ```dart
   final session = Supabase.instance.client.auth.currentSession!;
   final cairn = await CairnSupabase.connect(
     cairnUrl: 'ws://<your cairn dev host>:8800/sync',
     supabaseUrl: 'https://<project-ref>.supabase.co',
     accessToken: session.accessToken,
   );
   ```
   ⏳ pending live verification against a real Supabase JWT: `cairn-server`'s
   JWKS verifier (RS256/ES256, the default for projects created since
   2025-10-01) is implemented and unit-tested (W2) but not yet exercised
   against a genuine Supabase-issued token end-to-end.
7. RLS does **not** apply to Cairn's replication or write-back traffic —
   Cairn's server-side tenant predicates ARE the authorization layer for sync
   traffic. Read `docs/SECURITY-MODEL.md` before treating your existing RLS
   policies as sufficient.

## Known gaps (read before you build on this)

- **LAUNCH-BLOCKING: `watch()` can permanently miss a real-Postgres write
  with no follow-up activity, and an isolated first connection's write may
  never even reach the server.** See "What the proof actually showed" above
  for the full root cause and citations. This is not an edge case — it's the
  normal shape of using this product (one user, one action). Fixing it is a
  prerequisite for shipping the Flutter+Postgres story at all, not a
  polish item.
- **`Cairn` has no `close()`/`dispose()`.** Every `Cairn.connect()` appears to
  leave its background connection running indefinitely; a real app that
  reconnects (e.g. on auth state change, per the README's `CairnSupabase`
  note) has no way to release the old one. Noticed while diagnosing the bug
  above — worth its own investigation.
- **No client-visible write-rejection signal.** A write the server rejects
  (wrong tenant, disallowed table) has no Dart-facing error — it just stays
  queued in the local outbox and retries forever
  (`crates/cairn-client/src/client.rs`, the `ok:false` branch). A design
  partner hitting a legitimate permanent rejection (e.g. a stale/misissued
  token) would see their write silently never land, with no exception to
  catch. Needs a dead-letter policy or a surfaced `Stream<WriteResult>`
  before this is safe for anything beyond a showcase.
- **`cairn_flutter` forces a Rust build even for pure-Dart/mock-mode
  tests.** Once it's a `pubspec.yaml` dependency, `flutter test` resolves
  native assets for the whole package graph regardless of whether the test
  actually imports it — a contributor running only mock-mode tests still
  pays a Rust compile (cargo-fallback path, since no prebuilt binary exists
  yet) the first time. Not a correctness bug, but a CI-cost and
  onboarding-friction one.
- **`cairn init` has no `--bind`/port flag.** `cairn.toml`'s `server.bind`
  always defaults to `0.0.0.0:8800`; running two local instances (or
  avoiding a collision with another `cargo run -p cairn-server` on the
  default port) means hand-editing `cairn.toml` after `init` — see
  `fixtures/flutter/todo/tool/cairn_live_up.sh`'s `sed` step for a working
  example.
- **`cairn dev`'s printed Flutter snippet uses the wrong parameter names.**
  `crates/cairn-cli/src/commands/dev.rs`'s banner prints
  `Cairn.connect(wsUrl: ..., sessionToken: ...)`; the actual SDK API
  (`sdk/cairn_flutter/lib/src/cairn.dart`) is `Cairn.connect(url: ...,
  token: ...)`. Cosmetic (copy-pasting it fails loudly, an SDK IDE
  autocomplete catches it in seconds) but worth a one-line CLI fix before
  launch — it's the first thing a stranger would paste.
