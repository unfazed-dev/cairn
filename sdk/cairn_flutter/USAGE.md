# Using Cairn in a Flutter app

End-to-end: from the Cairn landing page, through Cairn Cloud auth, to a
Flutter app doing CRUD (and more) against the Cairn API.

> **API surface here is verified against `lib/` as of 2026-07-20.** Signatures,
> op names, and the config shape are read from the shipped code — not paraphrased
> from memory. The working app at `fixtures/flutter/todo` is the canonical
> consumer example (referenced below).

---

## 1. What Cairn gives you

Cairn is a Rust-native, local-first sync engine. In a Flutter app you get:

- **Offline-first SQLite** — every read hits a local SQLite file (Rust-owned,
  via `flutter_rust_bridge`). The UI never blocks on the network.
- **A WebSocket sync loop** — Postgres logical replication → `cairn-server` →
  your device. Changes stream in; you subscribe to tables and react.
- **A durable write outbox** — writes land locally first, then replay to the
  server on reconnect. No `uploadData` toll-booth (ADR-0013).
- **A typed reactive facade** — `Collection<T>` + `CairnDatabase` (ADR-0024):
  declare a schema, connect, and read/write typed records.

There is **no connector class** and **no client-side schema artifact** to
maintain by hand. `subscribe` sets the server-side predicate; `watch` gives you
a reactive `Stream` of rows; `write` is a durable local outbox.

---

## 2. From the landing page (not yet live)

<!-- CAIRN-IDENTITY-PENDING: no domain is registered — docs/IDENTITY.md. This
     section read "the marketing site at cairn.dev … is the front door", present
     tense, for a site that does not exist at an unregistered domain. -->

The marketing site (the `web/` SvelteKit app — "The Cairn Field" identity,
ADR-0008) is **planned as** the front door; **no domain is registered yet**, so
this section describes the intended flow, not something you can visit today.
From there you would choose one of two paths:

### Path A — Cairn Cloud (managed)

Sign up → create a project. Cairn Cloud (the `cairn-cloud` control plane:
axum + rusqlite, ADR-0006) provisions, per project:

- a **`cairn-server` `/sync` endpoint** (`wss://sync.<your-project>.cairn.app/sync`),
- a linked **Supabase project** (auth + Postgres), and
- an **API key + HMAC-signed license** (`<payload>.<sig>`) carrying your tier
  and device cap (`cairn-domain::Tier`: Hobby / Pro / Scale / Enterprise).

You will leave the landing page with: your sync URL, your Supabase project URL
+ anon/publishable key, and your license token. Those four values go into the
app's `cairn.json` (Section 5).

### Path B — Self-host (OSS, Apache-2.0)

Run `cairn-server` yourself. For local dev the zero-setup default is fine
(`CAIRN_REPLICATOR=fake`, `CAIRN_SYNC_AUTH=none`); for real data point it at
your own Postgres. You keep the landing page open only for docs. See
`docs/OPERATING.md` for the server env vars and failure modes.

Either path lands you at the same Flutter API below.

---

## 3. Auth: getting a token the SDK can present

Cairn's `/sync` WebSocket authenticates with a **bearer token** passed as
`?token=` on the WS handshake. What that token *is* depends on the server's
`CAIRN_SYNC_AUTH` mode (ADR-0010):

| `CAIRN_SYNC_AUTH` | Token | Tenant isolation | Use it when |
|---|---|---|---|
| `none` | ignored (anonymous) | **none — single-tenant only** | local dev / OSS single-user |
| `supabase-jwt` | a Supabase **access JWT** (HS256-verified with `CAIRN_SUPABASE_JWT_SECRET`) | **yes** — the JWT `sub` claim is the user/tenant id (ADR-0011) | managed Cloud, any multi-user app |

### The managed/Cloud path (recommended for real apps)

Your users authenticate with **Supabase** (email/password, magic link, OAuth —
whatever GoTrue gives you). The Supabase session's **access token** is then
handed to Cairn as the bearer token. Cairn verifies it with the same secret
Supabase signed it with, reads `sub` as the tenant, and isolates that user's
rows.

```dart
// 1. The user signs in via supabase_flutter (your login UI).
await Supabase.instance.client.auth
    .signInWithPassword(email: 'ada@example.com', password: '••••');

// 2. Grab the access token — this is what Cairn will present at /sync.
final session = Supabase.instance.client.auth.currentSession!;
final cairnToken = session.accessToken;
```

You usually do **not** pass that token by hand — `CairnDatabase.supabase(...)`
and `CairnDatabase.open(config: ...)` read the current Supabase session for you
(Section 6).

### The dev / self-host path

With `CAIRN_SYNC_AUTH=none`, pass any non-empty token (or none). To exercise
the `supabase-jwt` path locally without Supabase, mint an HS256 JWT signed
with your dev `CAIRN_SUPABASE_JWT_SECRET` and a `sub` claim of your choosing:

```
header: {"alg":"HS256","typ":"JWT"}
payload: {"sub":"user-a"}        # ← becomes the tenant id
```

Sign with the same secret the server verifies with. (Do **not** ship a real
signing secret in a client; this is for local testing only.)

> **v1 fast-follow (honest):** token auto-refresh on rotation is not yet
> transparent. Long-lived sessions whose Supabase token rotates mid-flight will
> eventually hit 401s. Until the fast-follow lands, subscribe to
> `onAuthStateChange` and re-`connect`/re-`subscribe` on `tokenRefreshed`.

---

## 4. Install

**Published (once W6 ships to pub.dev):**
```yaml
dependencies:
  cairn_flutter: ^0.1.0
```

**Pre-publish (path or git, today):**
```yaml
dependencies:
  cairn_flutter:
    path: ../../sdk/cairn_flutter        # adjust to your checkout
    # git:
    #   url: https://github.com/unfazed-dev/cairn
    #   path: sdk/cairn_flutter
```

The package ships its Rust core as a prebuilt native library via
`flutter_rust_bridge`'s native-assets hook (`hook/`) — no toolchain setup
required for consumers.

---

## 5. Configure: `cairn.json` + your schema

### `assets/cairn.json`

Bundled with the app and loaded by `CairnConfig.load()`. Keys (verified in
`CairnConfig.fromJson`):

```json
{
  "url": "wss://sync.<your-project>.cairn.app/sync",
  "supabase": {
    "url": "https://<project-ref>.supabase.co",
    "anon_key": "YOUR_SUPABASE_ANON_OR_PUBLISHABLE_KEY"
  },
  "sqlite_filename": "cairn.sqlite"
}
```

- `url` **(required)** — the `cairn-server` `/sync` WebSocket URL.
- `supabase` *(optional)* — object with `url` + `anon_key` (or its successor
  name `publishable_key`). Present this block and `CairnDatabase.open` will
  initialize Supabase and use the signed-in session's access token as the sync
  bearer token.
- `sqlite_filename` *(optional, default `cairn.sqlite`)* — joined onto the
  `sqliteDir` you pass at connect time.

Register it under `flutter/assets` in your `pubspec.yaml`:
```yaml
flutter:
  assets:
    - assets/cairn.json
```

### Declare your schema (PowerSync-style)

A declared `CairnSchema` **is** the migration story: every connect re-applies
it (read-views are dropped + recreated server-side, `SqliteStorage::apply_schema`).
Adding a column = adding a `CairnColumn`; no migration files, no version
counters. The row payloads under `cairn_data` are schema-less JSON, so only the
view shape changes (ADR-0019).

```dart
import 'package:cairn_flutter/cairn_flutter.dart';

const appSchema = CairnSchema(tables: [
  CairnTable(name: 'tasks', primaryKey: ['id'], columns: [
    CairnColumn.text('id'),
    CairnColumn.text('title'),
    CairnColumn.integer('completed'),   // 0 / 1
    CairnColumn.text('user_id'),
    CairnColumn.text('created_at'),
  ]),
]);
```

> `CairnTable` / `CairnColumn` are the package's collision-free aliases — `Table`
> and `Column` would shadow `material.dart` widgets, so they are intentionally
> not re-exported under those names.

If you omit `schema` at connect time, the SDK fetches it via
`GET {http-base}/schema` and parses it for you (`CairnSchema.fromSchemaDescriptor`).

---

## 6. Connect

Three factories, one underlying engine. Pick by ergonomics:

### Recommended — `CairnDatabase.open` (config-driven)

Loads `assets/cairn.json`, resolves the schema, applies it, and (if the config
has a `supabase` block) initializes Supabase + forwards the session token.

```dart
import 'package:path_provider/path_provider.dart';

final config = await CairnConfig.load();
final dir = await getApplicationSupportDirectory();

final db = await CairnDatabase.open(
  config: config,
  schema: appSchema,
  sqliteDir: dir.path,
);

await db.subscribe('tasks');          // start the sync session for a table
```

### Supabase one-liner — `CairnDatabase.supabase`

Throws `StateError` if no Supabase session is live — sign in first (Section 3).

```dart
final db = await CairnDatabase.supabase(
  cairnUrl: 'wss://sync.<your-project>.cairn.app/sync',
  supabaseUrl: 'https://<project-ref>.supabase.co',
  supabaseAnonKey: 'YOUR_KEY',
  schema: appSchema,
  sqlitePath: '${dir.path}/cairn.sqlite',
);
```

### Lowest-level — `CairnDatabase.connect`

You own the URL, the token, and the SQLite path. Useful for tests, non-Supabase
auth, or a pinned schema.

```dart
final db = await CairnDatabase.connect(
  url: 'wss://sync.<your-project>.cairn.app/sync',
  token: cairnToken,                  // bearer JWT (Section 3); omit for CAIRN_SYNC_AUTH=none
  schema: appSchema,                  // omit to fetch via GET /schema
  sqlitePath: '${dir.path}/cairn.sqlite',
);
await db.subscribe('tasks');
```

Multi-table? Subscribe to several at once:
```dart
await db.subscribeTables(['tasks', 'projects', 'comments']);
```

---

## 7. CRUD with `Collection<T>` (the typed facade)

Construct a `Collection<T>` per table, then read/write typed records. This is
the primary API (ADR-0024) and matches what `fixtures/flutter/todo` does.

```dart
class Task {
  Task(this.id, this.title, this.completed);
  final String id;
  final String title;
  final bool completed;

  factory Task.fromRow(Map<String, dynamic> r) => Task(
    r['id'] as String,
    r['title'] as String,
    (r['completed'] as int) == 1,
  );

  Map<String, dynamic> toRow() => {
    'id': id,
    'title': title,
    'completed': completed ? 1 : 0,
  };
}

final tasks = db.collection<Task>(
  table: 'tasks',
  fromRow: Task.fromRow,
  toRow: Task.toRow,
  pkColumn: 'id',           // default; shown for clarity
);
```

### Create / full-row update — `upsert` / `upsertRow`

```dart
// typed (uses toRow)
await tasks.upsert(Task('1', 'Ship Cairn', false));

// form / map-driven (no toRow needed on the call site)
await tasks.upsertRow({'id': '1', 'title': 'Ship Cairn', 'completed': 0});
```

### Partial update — `patch` (column-level, last-write-wins, ADR-0014)

```dart
await tasks.patch('1', {'completed': 1});        // flip done
await tasks.patch('1', {'title': 'Ship Cairn ✅'});  // rename
```

### Delete — `delete`

```dart
await tasks.delete('1');
```

> **All writes return `Future<int>` = the local outbox id, NOT a server ack.**
> The applied row round-trips back through `watch()` once the server replicates
> it (ADR-0013 outbox contract). This is what makes writes work offline.

### Raw write primitive — `db.write`

`Collection`'s write methods are thin wrappers over the universal primitive:

```dart
Future<int> write({
  required String table,
  required String op,        // "upsert" | "delete" | "patch"
  required Object pk,
  Map<String, dynamic>? payload,
});
```

Reach for it directly when you don't want a `Collection<T>` (dynamic tables,
generated code, etc.). `op` must be one of those three strings; `table` must
match an active subscription (v1).

---

## 8. Reactive reads

### Typed stream — `Collection<T>.watch`

```dart
final Stream<List<Task>> active = tasks.watch(
  where: 'completed = 0',
  orderBy: 'title',
);
```

- `where` is a literal SQL fragment (e.g. `'completed = 0'`, `"user_id = 'user-a'"`).
- `orderBy` is a literal `ORDER BY` fragment (e.g. `'created_at DESC'`).
- `throttle` coalesces a burst of change ticks into one re-query per window.

The stream re-emits whenever the table's synced data changes (full re-snapshot
per tick — self-healing on lag, not a fragile diff).

### Derived count — `Collection<T>.count`

```dart
final Stream<int> openCount = tasks.count(where: 'completed = 0');
```

Use this for count badges so they don't rebuild on unrelated column writes.

### Wire it into the widget tree

```dart
StreamBuilder<List<Task>>(
  stream: tasks.watch(where: 'completed = 0', orderBy: 'title'),
  builder: (context, snap) {
    final items = snap.data ?? const <Task>[];
    return ListView(children: items.map(TaskTile.new).toList());
  },
);
```

### Raw SQL escape hatch — `db.watch` / `db.getAll`

```dart
final Stream<List<Map<String, dynamic>>> s =
    db.watch('SELECT * FROM tasks ORDER BY created_at DESC');
final List<Map<String, dynamic>> rows =
    await db.getAll('SELECT * FROM tasks LIMIT 10');
```

> **v1 boundary (honest):** `db.watch(sql)` does **not** yet take a
> `parameters: [...]` list (it's P1). Until it lands, interpolate carefully or
> prefer the typed `Collection<T>.watch(where:)`. `execute(sql)` is SELECT-only
> in v1 — writes go through `write()` / the Collection methods so they enter the
> outbox rather than desyncing the local view.

---

## 9. Sync status

```dart
final ValueListenable<SyncStatus> status = db.status;
final SyncStatus now = db.currentStatus;
```

`SyncStatus` carries:

| Field | Type | Meaning |
|---|---|---|
| `conn` | `CairnConnectionState` | `connecting / connected / reconnecting / disconnected` |
| `connected` | `bool` | convenience for `conn == connected` |
| `lastSyncedAt` | `DateTime?` | best-effort: stamped on each `connected` transition |
| `hasSynced` | `bool` | has synced at least once — tells "nothing synced yet" from "no data" |
| `pendingWrites` | `int` | writes captured locally, not yet ack'd by the server |
| `hasPendingWrites` | `bool` | `pendingWrites > 0` |
| `uploading` | `bool` | connected with writes still draining |
| `deadLetteredWrites` | `int` | writes that **permanently failed** this session |
| `lastWriteError` | `String?` | the server's message for the last permanent failure |
| `hasWriteError` | `bool` | `lastWriteError != null` |

### Pending is not an error

`pendingWrites > 0` while offline is the offline-first promise working. Show it
as "N unsynced changes".

`lastWriteError` is different: it is set **only** when a write has permanently
failed and left the send queue. Ordinary server rejections are frequently
transient and retry on their own, so they deliberately do not set it — surfacing
those would train users to dismiss write errors. When `hasWriteError` is true, a
write is genuinely lost and a human should be told. The message is the server's
verbatim reason and is usually actionable (a write-allowlist rejection, for
example, names the exact env var to set).

Banner widget:
```dart
ListenableBuilder(
  listenable: db.status,
  builder: (context, _) {
    final s = db.currentStatus;
    if (s.hasWriteError) {
      return Text('Change not saved: ${s.lastWriteError}');
    }
    if (s.hasPendingWrites) {
      return Text('${s.pendingWrites} unsynced change'
          '${s.pendingWrites == 1 ? '' : 's'}');
    }
    return Text(s.connected
        ? 'Synced${s.lastSyncedAt == null ? '' : ' · ${s.lastSyncedAt}'}'
        : 'Offline — changes queued');
  },
);
```

This is what makes Flutter's own optimistic-state pattern expressible on Cairn:
`db.write` returns as soon as the write is durable *locally*, so there is no
`catch` to revert in — `hasWriteError` is the signal that a previously-accepted
write did not survive the server.

For raw streams (e.g. non-Flutter logic), use `db.connectionState` →
`Stream<CairnConnectionState>`, or `cairn.writeStatus` →
`Stream<({int pending, int deadLettered, String? lastError})>`.

---

## 10. More

### Multi-table

Subscribe to many tables, hold one `Collection<T>` per table:
```dart
await db.subscribeTables(['tasks', 'projects', 'comments']);
final tasks = db.collection<Task>(table: 'tasks', fromRow: ..., toRow: ...);
final projects = db.collection<Project>(table: 'projects', fromRow: ..., toRow: ...);
```

### Schema migrations

There are none to write. Edit `appSchema`, restart, done — the next connect
re-applies it (views are dropped + recreated). Adding a column surfaces it from
already-synced payloads on next launch; removing one drops it from the view.
See `CairnSchema`'s class doc.

### Offline + the outbox

- **Reads** always hit local SQLite — the UI is fully functional offline.
- **Writes** are captured in a durable local outbox first, then replayed to the
  server when the connection returns. The applied row arrives back through
  `watch()` like any other replicated change (ADR-0013).
- Reconnect/replay after a dropped session is handled by the engine (ADR-0025:
  resume-info epoch + snapshot reconcile).

### Per-field conflict tier

`patch` is last-write-wins by default (ADR-0014). For fields that need richer
merge semantics, the per-field conflict-tier seam is the extension point — see
ADR-0004 / ADR-0014.

### Server-side write allowlist

Writes are **server-gated** by `CAIRN_WRITE_TABLES` (empty default = all writes
no-op, ADR-0013). On your `cairn-server`, set it to your writable tables:
```
CAIRN_WRITE_TABLES=tasks,projects,comments
```
If your writes silently do nothing, this is why — see `docs/OPERATING.md`.

---

## 11. Production checklist

- [ ] **Server auth:** `CAIRN_SYNC_AUTH=supabase-jwt` +
      `CAIRN_SUPABASE_JWT_SECRET` (your Supabase project's GoTrue signing key).
      `none` is single-tenant only.
- [ ] **Tenant isolation:** the JWT `sub` becomes the tenant id (ADR-0011). Confirm
      your Postgres publication + server predicate filter on it.
- [ ] **Write allowlist:** `CAIRN_WRITE_TABLES=<your writable tables>` — without
      it, every write silently no-ops.
- [ ] **License (Cloud only):** `CAIRN_LICENSE=<payload>.<sig>` from Cairn Cloud
      sets tier + device cap. Empty (default) = OSS self-host, unlimited
      (ADR-0006).
- [ ] **Token refresh:** wire `Supabase.instance.client.auth.onAuthStateChange`
      → reconnect on `tokenRefreshed` (v1 fast-follow until transparent refresh
      lands).
- [ ] **SQLite path:** pass the same `sqlitePath` / `sqliteDir` across launches
      so the durable store + its read-views persist.

---

## 12. API quick reference (verified signatures)

```dart
// Connect (pick one)
static Future<CairnDatabase> open({required CairnConfig config, CairnSchema? schema, required String sqliteDir});
static Future<CairnDatabase> connect({required String url, String? token, CairnSchema? schema, required String sqlitePath});
static Future<CairnDatabase> supabase({/* cairnUrl, supabaseUrl, supabaseAnonKey, schema, sqlitePath */});

// Session
Future<void> subscribe(String table, {String? where});
Future<void> subscribeTables(List<String> tables);
ValueListenable<SyncStatus> get status;
SyncStatus get currentStatus;
Stream<CairnConnectionState> get connectionState;
Future<void> close();

// SyncStatus
CairnConnectionState get conn;   bool get connected;
DateTime? get lastSyncedAt;      bool get hasSynced;
int get pendingWrites;           bool get hasPendingWrites;   bool get uploading;
int get deadLetteredWrites;      String? get lastWriteError;  bool get hasWriteError;

// Reads
Stream<List<Map<String, dynamic>>> watch(String sql, {Duration? throttle});
Future<List<Map<String, dynamic>>> getAll(String sql);
Future<List<Map<String, dynamic>>> execute(String sql);   // SELECT-only in v1
Stream<List<T>> watchMapped<T>(String sql, T Function(Map<String, dynamic>) fromRow);
Future<List<T>> getAllMapped<T>(String sql, T Function(Map<String, dynamic>) fromRow);

// Writes (op ∈ {"upsert","delete","patch"})
Future<int> write({required String table, required String op, required Object pk, Map<String, dynamic>? payload});

// Typed facade
Collection<T> collection<T>({required String table, required T Function(Map<String, dynamic>) fromRow, Map<String, dynamic>? Function(T)? toRow, String pkColumn = 'id'});

// Collection<T>
Stream<List<T>> watch({String? where, Duration? throttle, String? orderBy});
Stream<int> count({String? where});
Future<int> upsert(T value);                              // needs toRow
Future<int> upsertRow(Map<String, dynamic> row);
Future<int> patch(Object pk, Map<String, dynamic> columns);   // LWW, ADR-0014
Future<int> delete(Object pk);
```

### Exports (`package:cairn_flutter/cairn_flutter.dart`)
`Cairn`, `CairnSupabase`, `CairnConnectionState`, `CairnTableSub`, `CairnConfig`,
`CairnSchema`, `CairnTable`, `CairnColumn`, `CairnDatabase`, `Collection`,
`SyncStatus`.

---

## 13. Where to go next

- **Working consumer app:** `fixtures/flutter/todo` — a real Flutter app using
  `Collection<T>` with add / edit / toggle / swipe-to-delete + a sync-status
  banner, against a live `cairn-server`. Read its
  `lib/infra/cairn_todo_repository.dart` for the exact CRUD pattern in production.
- **Server ops:** `docs/OPERATING.md` — every env var, startup-failure modes,
  slot lifecycle, "connected but lists empty" triage.
- **Architecture & decisions:** `docs/ARCHITECTURE.md`, then ADRs — 0004
  (conflict tiers), 0010/0011 (auth + tenant isolation), 0013 (write outbox +
  allowlist), 0014 (patch LWW), 0019 (schema), 0024 (`Collection<T>`), 0025
  (resume/replay), 0026 (shutdown durability).
- **Packaging path proof:** `integration_test/cairn_server_test.dart` in this
  package — the W4 acceptance test that spins up a real `cairn-server` and
  drives the full connect/subscribe/watch loop inside a genuine app bundle.
