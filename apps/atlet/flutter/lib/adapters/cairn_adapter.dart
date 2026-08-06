import 'dart:async';

import 'package:cairn_flutter/cairn_flutter.dart';

import '../bench/marks.dart';
import 'sync_adapter.dart';

/// Cairn engine implementation of [SyncAdapter] for the Atlet pilot.
///
/// Wraps [CairnDatabase] (sdk/cairn_flutter/lib/src/cairn_database.dart).
/// Row mapping and the write payload are pure top-level functions below so
/// they're unit-testable without the native Rust bridge — see
/// cairn_adapter_test.dart.
class CairnAdapter implements SyncAdapter {
  @override
  final String engine = 'cairn';

  /// cairn-server `/sync` endpoint for the Atlet local profile
  /// (docker-compose.atlet.yml binds cairn-server on 0.0.0.0:8080; `/sync`
  /// is CAIRN_WS_PATH's default in crates/cairn-server/src/main.rs).
  static const String _cairnUrl = String.fromEnvironment(
    'CAIRN_SYNC_URL',
    defaultValue: 'ws://localhost:8080/sync',
  );

  // Created once, never recreated: the conformance test's `marks` listener
  // is attached before signOut() and must keep seeing emissions after a
  // second init(), so _deriver must outlive individual sync sessions.
  final MarkDeriver _deriver = MarkDeriver(Stopwatch()..start());

  CairnDatabase? _db;
  StreamSubscription<List<Map<String, dynamic>>>? _sessionsSub;
  StreamSubscription<List<Map<String, dynamic>>>? _productsSub;
  StreamSubscription<CairnConnectionState>? _connSub;
  StreamController<List<SessionRow>>? _sessionsController;
  StreamController<List<ProductRow>>? _productsController;
  StreamController<bool>? _connectedController;

  @override
  Future<void> init({
    required String supabaseUrl,
    required String accessToken,
    required String userId,
    required String dbDir,
  }) async {
    _sessionsController = StreamController<List<SessionRow>>.broadcast();
    _productsController = StreamController<List<ProductRow>>.broadcast();
    _connectedController = StreamController<bool>.broadcast();

    final db = await CairnDatabase.connect(
      url: _cairnUrl,
      token: accessToken,
      schema: _schema,
      sqlitePath: '$dbDir/cairn.sqlite',
    );
    _db = db;

    await db.subscribeTables(const [
      CairnTableSub(name: 'sessions'),
      CairnTableSub(name: 'products'),
    ]);

    _sessionsSub = db.watch('SELECT * FROM sessions').listen((rows) {
      final sessions = rows.map(sessionFromRow).toList(growable: false);
      _deriver.onEmission(sessions);
      _sessionsController?.add(sessions);
    });

    _productsSub = db.watch('SELECT * FROM products').listen((rows) {
      _productsController
          ?.add(rows.map(productFromRow).toList(growable: false));
    });

    _connSub = db.connectionState.listen((state) {
      _connectedController?.add(state == CairnConnectionState.connected);
    });
  }

  @override
  Future<String> addSession(SessionRow s) async {
    assert(s.serverCommittedAt == null, 'serverCommittedAt must be null');
    _deriver.localIds.add(s.id); // before write(): see class doc on ordering
    await _requireDb().write(
      table: 'sessions',
      op: 'upsert',
      pk: s.id,
      payload: sessionWritePayload(s),
    );
    return s.id;
  }

  @override
  Future<void> deleteSession(String id) =>
      _requireDb().write(table: 'sessions', op: 'delete', pk: id);

  @override
  Stream<List<SessionRow>> watchSessions() => _requireController(
      _sessionsController, 'watchSessions() before init()');

  @override
  Stream<List<ProductRow>> watchProducts() => _requireController(
      _productsController, 'watchProducts() before init()');

  @override
  Stream<bool> get connected =>
      _requireController(_connectedController, 'connected before init()');

  @override
  Future<void> setConnected(bool up) async {
    final db = _requireDb();
    if (up) {
      // ponytail: CairnDatabase.resume() is fire-and-forget (no Future) —
      // setConnected(true) does not itself await a reconnect. Record this in
      // RunRecord if the bench needs a reconnect-observed timestamp instead.
      db.resume();
    } else {
      await db.disconnect();
    }
  }

  @override
  Stream<SyncMark> get marks => _deriver.marks;

  @override
  Future<void> signOut() async {
    await _sessionsSub?.cancel();
    await _productsSub?.cancel();
    await _connSub?.cancel();
    _sessionsSub = null;
    _productsSub = null;
    _connSub = null;

    await _db?.signOut(); // ADR-0029: full local wipe + client teardown
    _db = null;

    await _sessionsController?.close();
    await _productsController?.close();
    await _connectedController?.close();
    _sessionsController = null;
    _productsController = null;
    _connectedController = null;

    _deriver.reset();
    // spec/adapter.md item 4: signOut leaves no live engine session — the
    // caller re-runs init() to cold-sync from zero. _deriver survives (see
    // field comment) so marks resume once init() rebuilds the controllers.
  }

  CairnDatabase _requireDb() =>
      _db ?? (throw StateError('CairnAdapter.init() must be called first'));

  Stream<T> _requireController<T>(StreamController<T>? c, String what) =>
      (c ?? (throw StateError('CairnAdapter: $what'))).stream;
}

final CairnSchema _schema = CairnSchema(tables: [
  CairnTable(name: 'sessions', primaryKey: const ['id'], columns: [
    CairnColumn.text('id'),
    CairnColumn.text('title'),
    CairnColumn.text('type'),
    CairnColumn.integer('metric'),
    CairnColumn.text('unit'),
    CairnColumn.text('note'),
    CairnColumn.integer('streak'),
    CairnColumn.text('occurred_on'),
    CairnColumn.text('server_committed_at'),
  ]),
  CairnTable(name: 'products', primaryKey: const ['id'], columns: [
    CairnColumn.text('id'),
    CairnColumn.text('name'),
    CairnColumn.text('category'),
    CairnColumn.integer('price_cents'),
    CairnColumn.real('rating'),
    CairnColumn.integer('plant_based'),
    CairnColumn.text('image_url'),
  ]),
]);

/// Maps a decoded row from `CairnDatabase.watch('SELECT * FROM sessions')`
/// to [SessionRow]. Top-level and pure so it's testable without the FFI
/// bridge — see cairn_adapter_test.dart.
SessionRow sessionFromRow(Map<String, dynamic> row) => SessionRow(
      id: row['id'] as String,
      title: row['title'] as String,
      type: row['type'] as String,
      metric: _asInt(row['metric']),
      unit: row['unit'] as String,
      note: row['note'] as String?,
      streak: row['streak'] == null ? 0 : _asInt(row['streak']),
      occurredOn: DateTime.parse(row['occurred_on'] as String),
      serverCommittedAt: _asDateTimeOrNull(row['server_committed_at']),
    );

ProductRow productFromRow(Map<String, dynamic> row) => ProductRow(
      id: row['id'] as String,
      name: row['name'] as String,
      category: row['category'] as String,
      priceCents: _asInt(row['price_cents']),
      rating: _asDoubleOrNull(row['rating']),
      plantBased: _asBool(row['plant_based']),
      imageUrl: row['image_url'] as String?,
    );

/// Write image for `addSession`. Omits `server_committed_at` — Postgres's
/// `default now()` is the clock authority for the serverAcked mark; sending
/// an explicit null would overwrite that default and the mark would never
/// fire. Omits `user_id` — cairn-server stamps the tenant column from the
/// JWT server-side (CAIRN_TENANT_COLUMN=user_id, write_back.rs's
/// stamp_tenant_column), overwriting whatever the client sends.
Map<String, dynamic> sessionWritePayload(SessionRow s) => {
      'id': s.id,
      'title': s.title,
      'type': s.type,
      'metric': s.metric,
      'unit': s.unit,
      if (s.note != null) 'note': s.note,
      'streak': s.streak,
      'occurred_on': _dateOnly(s.occurredOn),
    };

String _dateOnly(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

int _asInt(Object? v) => switch (v) {
      int i => i,
      num n => n.toInt(),
      String s => int.parse(s),
      _ => throw ArgumentError('expected int, got $v (${v.runtimeType})'),
    };

double? _asDoubleOrNull(Object? v) => switch (v) {
      null => null,
      double d => d,
      num n => n.toDouble(),
      String s => double.parse(s),
      _ => throw ArgumentError('expected double?, got $v (${v.runtimeType})'),
    };

bool _asBool(Object? v) => switch (v) {
      bool b => b,
      int i => i != 0,
      num n => n != 0,
      String s => s == 'true' || s == '1',
      _ => throw ArgumentError('expected bool, got $v (${v.runtimeType})'),
    };

DateTime? _asDateTimeOrNull(Object? v) => switch (v) {
      null => null,
      String s => DateTime.parse(s),
      _ => throw ArgumentError('expected DateTime?, got $v (${v.runtimeType})'),
    };
