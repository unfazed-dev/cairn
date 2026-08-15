/// The native (non-web) [CairnEngine] adapter: wraps the generated
/// `rust.CairnHandle` (flutter_rust_bridge). ADR-0036.
///
/// This file is reached ONLY on non-web platforms, via
/// `engine_selector_io.dart` (the conditional-import barrel
/// `engine_selector.dart` selects it when `dart.library.io` is available). It
/// is NEVER compiled for `flutter build web` — that is the point of the split:
/// frb's `PlatformInt64` type alias resolves to `int` on io but `BigInt` on
/// web, so [RustCairnEngine.counterIncrement]'s body (`delta: delta`) cannot
/// type-check on both platforms from one expression. Isolating the class here
/// keeps the web compile off frb's divergent web signatures entirely, while
/// the native path (`Cairn.connect` → `engine_selector_io` → here) is
/// byte-for-byte the logic that shipped in 4a — only its file location moved.
///
/// The class body is unchanged from its prior inline definition in
/// `engine.dart`; see git history there.
library;

import 'engine.dart';
import 'rust/api/cairn.dart' as rust;

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
  Stream<CairnConnectionState> subscribe({
    required List<CairnTableSub> tables,
    Set<String> orSetTables = const <String>{},
    Set<String> counterTables = const <String>{},
  }) {
    final ffiTables = tables
        .map((t) => rust.TableSubFfi(name: t.name, whereSql: t.whereSql))
        .toList(growable: false);
    // Threaded into SyncClientConfig (verb gate) + SqliteStorage (apply merge)
    // at subscribe — see CairnHandle::subscribe. Empty by default (no CRDT).
    return _handle
        .subscribe(
          tables: ffiTables,
          orSetTables: orSetTables.toList(),
          counterTables: counterTables.toList(),
        )
        .map(_mapState);
  }

  @override
  Stream<String> watch({required String table}) => _handle.watch(table: table);

  @override
  Stream<({int pending, int deadLettered, String? lastError})>
  watchWriteStatus() => _handle.watchWriteStatus().map(
    (s) => (
      pending: s.pending.toInt(),
      deadLettered: s.deadLettered.toInt(),
      lastError: s.lastError,
    ),
  );

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
  Future<List<int>> writeBatch({
    required List<({String table, String op, String pk, String? payloadJson})>
    ops,
  }) async {
    final inputs = ops
        .map(
          (o) => rust.CairnWriteInput(
            table: o.table,
            op: o.op,
            pk: o.pk,
            payloadJson: o.payloadJson,
          ),
        )
        .toList();
    final ids = await _handle.writeBatch(ops: inputs);
    return ids.map((b) => b.toInt()).toList();
  }

  @override
  Future<int> orSetAdd({
    required String table,
    required String pk,
    required String element,
  }) => _handle
      .orSetAdd(table: table, pk: pk, element: element)
      .then((b) => b.toInt());

  @override
  Future<int> orSetRemove({
    required String table,
    required String pk,
    required String element,
  }) => _handle
      .orSetRemove(table: table, pk: pk, element: element)
      .then((b) => b.toInt());

  @override
  Future<int> counterIncrement({
    required String table,
    required String pk,
    required int delta,
  }) => _handle
      .counterIncrement(table: table, pk: pk, delta: delta)
      .then((b) => b.toInt());

  @override
  Future<int> counterDecrement({
    required String table,
    required String pk,
    required int delta,
  }) => _handle
      .counterDecrement(table: table, pk: pk, delta: BigInt.from(delta))
      .then((b) => b.toInt());

  @override
  Future<String> query({required String sql}) => _handle.query(sql: sql);

  @override
  void applySchema(List<rust.ClientTableFfi> tables) =>
      _handle.applySchema(tables: tables);

  @override
  Future<void> setToken(String? token) => _handle.setToken(token: token);

  @override
  Future<void> close() => _handle.close();

  @override
  Future<void> signOut() => _handle.signOut();

  @override
  Future<void> disconnect() => _handle.disconnect();

  @override
  Stream<CairnConnectionState> resume() => _handle.resume().map(_mapState);

  @override
  Stream<bool> get webStorageDegraded => const Stream<bool>.empty();
}

CairnConnectionState _mapState(rust.CairnConnectionState s) => switch (s) {
  rust.CairnConnectionState.connecting => CairnConnectionState.connecting,
  rust.CairnConnectionState.connected => CairnConnectionState.connected,
  rust.CairnConnectionState.reconnecting => CairnConnectionState.reconnecting,
  rust.CairnConnectionState.disconnected => CairnConnectionState.disconnected,
};
