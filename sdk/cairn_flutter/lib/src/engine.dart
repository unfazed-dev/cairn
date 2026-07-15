/// The seam between the public [CairnEngine]-typed API in `cairn.dart` and
/// the generated flutter_rust_bridge bindings.
///
/// Why this exists: the generated `CairnHandle.subscribe` takes a
/// `RustStreamSink<T>`, whose `.stream` getter only works after the FFI call
/// has run `setupAndSerialize` on it (see
/// `flutter_rust_bridge/src/stream/stream_sink.dart`) — a pure-Dart test
/// double cannot satisfy that type without loading the native library. This
/// interface deals only in plain Dart `Stream`s, so a unit test can inject a
/// [CairnEngine] fake and exercise `Cairn`'s API surface (subscribe/watch/
/// write wiring, error paths, table-mismatch checks) with zero native
/// dependency. [RustCairnEngine] is the one adapter that actually talks to
/// Rust; it's the only file in this package that imports
/// `src/rust/api/cairn.dart`.
library;

import 'rust/api/cairn.dart' as rust;

// Re-exported so the public API in `cairn.dart` (`Cairn.applySchema`) and
// `schema.dart` (`CairnSchema.toClientTables`) can name [ClientTableFfi] without
// each importing `rust/api/cairn.dart` directly — keeping this file the sole
// importer of the generated bindings (see the library doc above).
export 'rust/api/cairn.dart' show ClientTableFfi;

/// Connection-state transitions, decoupled from the generated
/// `rust.CairnConnectionState` so consumers never need to import generated
/// code. See `rust/src/api/cairn.rs`'s `CairnConnectionState` doc for the
/// precise (heuristic) semantics of `connected`.
enum CairnConnectionState { connecting, connected, reconnecting, disconnected }

/// One table in a multi-table subscription: a name + an optional safe-SQL
/// `where_sql` (ADR-0012). A connection subscribes to a list of these over
/// one `/sync` socket (D1/ADR-0022 multi-table-per-handle). Plain Dart (not
/// the generated `TableSubFfi`) so tests can build it without the native
/// library.
class CairnTableSub {
  const CairnTableSub({required this.name, this.whereSql});

  /// CairnTable name to subscribe to.
  final String name;

  /// Optional safe-SQL predicate scoped to this table (ADR-0012).
  final String? whereSql;
}

/// What [Cairn] needs from a backend. Implemented for real by [RustCairnEngine];
/// implement it yourself in tests to avoid the native library entirely.
abstract class CairnEngine {
  /// Start a multi-table subscription over one `/sync` socket. Returns the
  /// connection-state stream (the session's lifecycle). Call [watch] per
  /// table to receive that table's rows.
  Stream<CairnConnectionState> subscribe({required List<CairnTableSub> tables});

  /// Attach a row stream for one subscribed table: one JSON-array-of-objects
  /// string per tick (the durable snapshot immediately, then after every
  /// applied change). `table` must be among those passed to [subscribe].
  Stream<String> watch({required String table});

  /// Returns the local outbox id.
  Future<int> write({
    required String table,
    required String op,
    required String pk,
    String? payloadJson,
  });

  /// Run an arbitrary SELECT against on-device SQLite. Returns a JSON-array
  /// string (same shape as [watch]'s ticks); decode with jsonDecode. Requires
  /// an active subscription.
  Future<String> query({required String sql});

  /// Materialize the WS2 read-views for [tables] in the on-device SQLite
  /// file (`CREATE VIEW IF NOT EXISTS <table> AS SELECT json_extract(...)
  /// ... FROM cairn_data WHERE table_name='<table>'` — see
  /// `SqliteStorage::apply_schema`). Idempotent for an unchanged schema;
  /// the views persist in the SQLite file, so this only needs to run once
  /// after connect. Synchronous: the FFI is `Result<(), String>` and throws
  /// on error. Wraps the generated `CairnHandle.applySchema`.
  void applySchema(List<rust.ClientTableFfi> tables);

  /// Pause syncing: abort only the connect loop; reads, writes (durable outbox),
  /// and `watch` pumps keep working offline. Pair with [resume]. Idempotent.
  Future<void> disconnect();

  /// Resume syncing after [disconnect]: respawn the connect loop on the same
  /// client (outbox flushes on reconnect). Returns the fresh connection-state
  /// stream; `Cairn` pipes it into its public `connectionState`.
  Stream<CairnConnectionState> resume();

  /// Tear down the active subscription's background work (the sync loop and
  /// every watch pump). Safe to call with no active subscription and safe to
  /// call more than once.
  Future<void> close();
}

/// The real engine: wraps the generated `rust.CairnHandle`.
class RustCairnEngine implements CairnEngine {
  RustCairnEngine._(this._handle);

  /// Opens a connection (no network activity yet — see `CairnHandle.connect`
  /// in the Rust glue).
  factory RustCairnEngine.connect({
    required String url,
    String? token,
    required String dbPath,
  }) => RustCairnEngine._(
    rust.CairnHandle.connect(url: url, token: token, dbPath: dbPath),
  );

  final rust.CairnHandle _handle;

  @override
  Stream<CairnConnectionState> subscribe({required List<CairnTableSub> tables}) {
    final ffiTables = tables
        .map((t) => rust.TableSubFfi(name: t.name, whereSql: t.whereSql))
        .toList(growable: false);
    return _handle.subscribe(tables: ffiTables).map(_mapState);
  }

  @override
  Stream<String> watch({required String table}) => _handle.watch(table: table);

  @override
  Future<int> write({
    required String table,
    required String op,
    required String pk,
    String? payloadJson,
  }) async {
    final id = await _handle.write(
      table: table,
      op: op,
      pk: pk,
      payloadJson: payloadJson,
    );
    return id.toInt();
  }

  @override
  Future<String> query({required String sql}) =>
      _handle.query(sql: sql);

  @override
  void applySchema(List<rust.ClientTableFfi> tables) =>
      _handle.applySchema(tables: tables);

  @override
  Future<void> close() => _handle.close();

  @override
  Future<void> disconnect() => _handle.disconnect();

  @override
  Stream<CairnConnectionState> resume() => _handle.resume().map(_mapState);
}

CairnConnectionState _mapState(rust.CairnConnectionState s) => switch (s) {
  rust.CairnConnectionState.connecting => CairnConnectionState.connecting,
  rust.CairnConnectionState.connected => CairnConnectionState.connected,
  rust.CairnConnectionState.reconnecting => CairnConnectionState.reconnecting,
  rust.CairnConnectionState.disconnected => CairnConnectionState.disconnected,
};
