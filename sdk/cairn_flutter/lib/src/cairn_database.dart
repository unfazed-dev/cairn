import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'cairn.dart';
import 'cairn_config.dart';
import 'schema.dart';

/// PowerSync-style entry point: open a [Cairn] sync connection AND resolve
/// the server schema in one call, so `SELECT * FROM <table>` works
/// immediately against the WS2 read-views (see `SqliteStorage::apply_schema`
/// — the views persist in the SQLite file once [applySchema] runs).
///
/// The high-level DX:
/// ```dart
/// final db = await CairnDatabase.connect(
///   url: 'ws://localhost:8800/sync',
///   sqlitePath: './cairn.sqlite',
/// );
/// await db.subscribe('todos');
/// db.watch('SELECT * FROM todos').listen((rows) => print(rows));
/// await db.write(table: 'todos', op: 'upsert', pk: '1', payload: {'title': 'ship'});
/// ```
///
/// This class adds no sync logic of its own — it wires [Cairn] (the thin
/// reactive wrapper over the Rust engine) to a resolved [CairnSchema]. A
/// Supabase-flavored factory is provided (see [CairnDatabase.supabase]).
class CairnDatabase {
  CairnDatabase._(this._cairn, this.schema);

  /// Test-only: wrap an injected [Cairn] (itself injectable via
  /// `Cairn.withEngine`) to exercise the typed mappers ([watchMapped] /
  /// [getAllMapped]) without the native library. See
  /// `test/cairn_ws6_test.dart`.
  @visibleForTesting
  CairnDatabase.forTest(this._cairn, this.schema);

  final Cairn _cairn;

  /// The resolved server schema used to materialize the read-views.
  /// Exposed for inspection / codegen; not meant to be mutated.
  final CairnSchema schema;

  /// Open a [Cairn] connection and resolve the schema.
  ///
  /// [url] is the `cairn-server` `/sync` WebSocket URL (the one `cairn dev`
  /// prints). [sqlitePath] is the on-disk SQLite file location (no default
  /// here — callers choose it; pass the same path across runs to keep the
  /// durable store and its WS2 views).
  ///
  /// If [schema] is `null`, the HTTP base is derived from [url]
  /// (`wss`→`https`, `ws`→`http`, trailing path stripped) and `GET
  /// {base}/schema` is fetched + parsed via [CairnSchema.fromSchemaDescriptor].
  /// Then `Cairn.applySchema` runs once to create the read-views. Returns a
  /// ready [CairnDatabase]; call [subscribe] next to start syncing.
  ///
  /// Pass an explicit [schema] to skip the HTTP round-trip (e.g. a pinned
  /// schema bundled with the app, or a test fixture).
  static Future<CairnDatabase> connect({
    required String url,
    String? token,
    CairnSchema? schema,
    required String sqlitePath,
  }) =>
      _open(url: url, token: token, schema: schema, sqlitePath: sqlitePath);

  /// Config-driven open: connect using a [CairnConfig] (normally loaded
  /// from the app's bundled `assets/cairn.json` via [CairnConfig.load])
  /// plus the app's declared [schema].
  ///
  /// This is the recommended app entry point:
  ///
  /// ```dart
  /// final config = await CairnConfig.load();
  /// final dir = await getApplicationSupportDirectory();
  /// final db = await CairnDatabase.open(
  ///   config: config,
  ///   schema: appSchema,
  ///   sqliteDir: dir.path,
  /// );
  /// ```
  ///
  /// Behavior:
  /// - SQLite lands at `{sqliteDir}/{config.sqliteFilename}`.
  /// - If [schema] is `null`, it is fetched from the server
  ///   (`GET {base}/schema`) as in [connect]. Passing your declared schema
  ///   is preferred — re-applying it at every connect IS the migration
  ///   mechanism (views are dropped + recreated; see [CairnSchema]).
  /// - If the config carries a `supabase` block, Supabase is initialized
  ///   (skipped when the app already called `Supabase.initialize`) and the
  ///   signed-in session's access token becomes the sync bearer token —
  ///   throws [StateError] when nobody is signed in (same contract as
  ///   [CairnDatabase.supabase]).
  static Future<CairnDatabase> open({
    required CairnConfig config,
    CairnSchema? schema,
    required String sqliteDir,
  }) async {
    final sqlitePath = '$sqliteDir/${config.sqliteFilename}';
    String? token;
    if (config.hasSupabase) {
      final initialized = _supabaseInitialized();
      if (!initialized) {
        await Supabase.initialize(
          url: config.supabaseUrl!,
          publishableKey: config.supabaseAnonKey!,
        );
      }
      final session = Supabase.instance.client.auth.currentSession;
      if (session == null) {
        throw StateError(
          'cairn config has a "supabase" block but there is no live session '
          '— sign in before calling CairnDatabase.open()',
        );
      }
      token = session.accessToken;
    }
    return _open(
      url: config.url,
      token: token,
      schema: schema,
      sqlitePath: sqlitePath,
    );
  }

  /// `Supabase.initialize` is process-global and once-only; probing
  /// [Supabase.instance] is the only supported "is it initialized?" check
  /// (it throws [AssertionError] before initialize).
  static bool _supabaseInitialized() {
    try {
      Supabase.instance;
      return true;
    } on AssertionError {
      return false;
    }
  }

  /// Open a [Cairn] connection for a Supabase-authenticated app.
  ///
  /// The caller MUST run `Supabase.initialize(...)` once at app start
  /// (before `runApp`) — `Supabase.initialize` is process-global and
  /// once-only, so this factory does NOT call it. The caller MUST also
  /// ensure a session exists (sign-in completed) before invoking this
  /// factory; the live session's `accessToken` is read via
  /// `Supabase.instance.client.auth.currentSession?.accessToken` and
  /// passed as the bearer token to the underlying [Cairn] connection.
  ///
  /// [cairnUrl] is the `cairn-server` `/sync` WebSocket URL. [sqlitePath]
  /// is the on-disk SQLite file location. [schema], if `null`, is fetched
  /// via `GET {httpBase}/schema` (see [connect] for the derivation rules).
  ///
  /// Throws [StateError] if there is no live Supabase session (the user
  /// must sign in before calling this factory).
  ///
  /// ponytail: the access token is read ONCE at connect time. Transparent
  /// refresh on token rotation via
  /// `Supabase.instance.client.auth.onAuthStateChange` (re-binding the
  /// token on `tokenRefreshed` / `initialSession` events) is a deliberate
  /// v1 fast-follow — until then, long-lived sessions that rotate the
  /// token mid-flight will eventually hit 401s and need a reconnect. The
  /// upgrade path is to subscribe to `onAuthStateChange` inside this
  /// factory and forward the new token to the underlying `Cairn` (see
  /// `CairnSupabase` for the token-swap primitive).
  static Future<CairnDatabase> supabase({
    required String cairnUrl,
    CairnSchema? schema,
    required String sqlitePath,
  }) async {
    final session = Supabase.instance.client.auth.currentSession;
    if (session == null) {
      throw StateError(
        'no Supabase session — sign in before calling CairnDatabase.supabase()',
      );
    }
    return _open(
      url: cairnUrl,
      token: session.accessToken,
      schema: schema,
      sqlitePath: sqlitePath,
    );
  }

  /// Shared open path for [connect] and [supabase]: open the [Cairn]
  /// connection, resolve the schema (passed or fetched), and apply it.
  /// Both factories delegate here so the connect/apply sequence has one
  /// home.
  static Future<CairnDatabase> _open({
    required String url,
    String? token,
    CairnSchema? schema,
    required String sqlitePath,
  }) async {
    final cairn = await Cairn.connect(
      url: url,
      token: token,
      sqlitePath: sqlitePath,
    );
    final resolved = schema ?? await _fetchSchema(_deriveHttpBase(url));
    cairn.applySchema(resolved.toClientTables());
    return CairnDatabase._(cairn, resolved);
  }

  /// Connection-state transitions for the underlying [Cairn] session.
  Stream<CairnConnectionState> get connectionState =>
      _cairn.connectionState;

  /// Subscribe to [table], optionally filtered by [where] (a safe-SQL
  /// predicate — see `Cairn.subscribe`). Must be called before [watch] /
  /// [getAll] / [write] for that table. For multiple tables on one
  /// connection, use [subscribeTables].
  Future<void> subscribe(String table, {String? where}) =>
      _cairn.subscribe(table, where: where);

  /// Subscribe to [tables] over one `/sync` socket (D1/ADR-0022 multi-table).
  /// Each entry may carry its own `whereSql`. Replaces any prior subscription.
  /// Call once with the full table set, then [watch] / [getAll] / [write] per
  /// table.
  Future<void> subscribeTables(List<CairnTableSub> tables) =>
      _cairn.subscribeTables(tables);

  /// Reactive SQL watch: re-runs [sql] whenever the synced data changes and
  /// emits the decoded result set. Thin delegate over `Cairn.watchQuery`
  /// (PowerSync-parity P1). Requires an active [subscribe] first.
  Stream<List<Map<String, dynamic>>> watch(String sql) =>
      _cairn.watchQuery(sql);

  /// Run a one-shot SELECT against on-device SQLite and return the decoded
  /// rows. Non-reactive counterpart to [watch]. Requires an active
  /// [subscribe] (the engine enforces this).
  Future<List<Map<String, dynamic>>> getAll(String sql) async =>
      (jsonDecode(await _cairn.query(sql)) as List<dynamic>)
          .cast<Map<String, dynamic>>();

  /// Raw-SQL execute. Currently a READ-ONLY alias of [getAll].
  ///
  /// ponytail: writes through raw SQL are a deliberate fast-follow ceiling
  /// — the demo's add/delete/edit flows all route through [write] (which
  /// enqueues into the durable outbox and round-trips the applied row back
  /// through [watch]). Accepting arbitrary INSERT/UPDATE/DELETE here would
  /// bypass the outbox and desync the local view from the server's
  /// replication stream. Parse raw SQL for writes in a follow-up and route
  /// them into [write]; until then, [execute] is SELECT-only.
  Future<List<Map<String, dynamic>>> execute(String sql) => getAll(sql);

  /// Reactive typed-record watch (WS6): like [watch] but maps each row to a
  /// typed record via [fromRow]. Thin delegate over `Cairn.watchMapped`.
  Stream<List<T>> watchMapped<T>(
    String sql,
    T Function(Map<String, dynamic> row) fromRow,
  ) =>
      _cairn.watchMapped(sql, fromRow);

  /// One-shot typed-record query (WS6): like [getAll] but maps each row to a
  /// typed record via [fromRow].
  Future<List<T>> getAllMapped<T>(
    String sql,
    T Function(Map<String, dynamic> row) fromRow,
  ) async =>
      (await getAll(sql)).map(fromRow).toList(growable: false);

  /// Enqueue a durable write into the local outbox. Returns the local outbox
  /// id (NOT a server ack — the applied row round-trips back through [watch];
  /// see `Cairn.write`). [op] is one of `"upsert"`, `"delete"`, `"patch"`.
  /// [table] must match the active subscription (v1).
  ///
  /// [payload] is the row image (for `upsert`) or column subset (for
  /// `patch`); it is JSON-encoded by `Cairn.write` before crossing FFI.
  Future<int> write({
    required String table,
    required String op,
    required String pk,
    Map<String, dynamic>? payload,
  }) =>
      _cairn.write(table, op: op, pk: pk, payload: payload);

  /// Tear down the underlying [Cairn] session (sync loop + watch pump).
  /// Safe to call with no subscription and safe to call more than once.
  Future<void> close() => _cairn.close();

  /// Pause syncing (delegate to [Cairn.disconnect]); reads/writes/UI keep
  /// working offline. See `Cairn.disconnect`.
  Future<void> disconnect() => _cairn.disconnect();

  /// Resume syncing after [disconnect] (delegate to [Cairn.resume]).
  void resume() => _cairn.resume();

  /// Derive the HTTP base for `GET /schema` from the WS `/sync` URL:
  /// `wss`→`https`, `ws`→`http`, host+port preserved, trailing path stripped.
  static String _deriveHttpBase(String wsUrl) {
    final uri = Uri.parse(wsUrl);
    final scheme = switch (uri.scheme) {
      'wss' => 'https',
      'ws' => 'http',
      _ => uri.scheme,
    };
    final port = uri.port == 0 ? '' : ':${uri.port}';
    return '$scheme://${uri.host}$port';
  }

  static Future<CairnSchema> _fetchSchema(String httpBase) async {
    final response = await http.get(Uri.parse('$httpBase/schema'));
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return CairnSchema.fromSchemaDescriptor(body);
  }
}
