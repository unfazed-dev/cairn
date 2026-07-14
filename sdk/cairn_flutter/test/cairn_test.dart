// Unit tests for the Cairn public API surface, against a fake CairnEngine —
// no native library involved (see lib/src/engine.dart's doc for why the
// CairnEngine seam exists). Covers subscribe/watch/write wiring, the
// single-table-per-instance constraint, and JSON decode of the rows stream.

import 'dart:async';

import 'package:cairn_flutter/cairn_flutter.dart';
import 'package:cairn_flutter/src/engine.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeCairnEngine implements CairnEngine {
  final rowsController = StreamController<String>.broadcast();
  final stateController = StreamController<CairnConnectionState>.broadcast();

  String? lastSubscribedTable;
  String? lastWhereSql;
  int subscribeCallCount = 0;

  final List<({String table, String op, String pk, String? payloadJson})>
  writes = [];
  int nextWriteId = 1;
  int closeCallCount = 0;

  /// The JSON-array string [query] returns. Tests set this to control the
  /// decoded result [watchQuery] emits. Defaults to an empty result set.
  String queryResult = '[]';
  final List<String> queries = [];

  @override
  Future<String> query({required String sql}) async {
    queries.add(sql);
    return queryResult;
  }

  @override
  Future<CairnSubscriptionStreams> subscribe({
    required String table,
    String? whereSql,
  }) async {
    subscribeCallCount++;
    lastSubscribedTable = table;
    lastWhereSql = whereSql;
    return CairnSubscriptionStreams(
      rows: rowsController.stream,
      state: stateController.stream,
    );
  }

  @override
  Future<int> write({
    required String table,
    required String op,
    required String pk,
    String? payloadJson,
  }) async {
    writes.add((table: table, op: op, pk: pk, payloadJson: payloadJson));
    return nextWriteId++;
  }

  @override
  void applySchema(List<ClientTableFfi> tables) {
    // Stub: record nothing for now. Tests that exercise applySchema wiring
    // can assert on this fake's captured tables once added (WS3 follow-up).
  }

  @override
  Future<void> close() async {
    closeCallCount++;
  }
}

void main() {
  group('Cairn.subscribe/watch', () {
    test('watch() before subscribe() throws StateError', () {
      final cairn = Cairn.withEngine(FakeCairnEngine());
      expect(() => cairn.watch('tasks'), throwsStateError);
    });

    test('subscribe() then watch() decodes the JSON row stream', () async {
      final engine = FakeCairnEngine();
      final cairn = Cairn.withEngine(engine);

      await cairn.subscribe('tasks', where: 'status = open');
      expect(engine.lastSubscribedTable, 'tasks');
      expect(engine.lastWhereSql, 'status = open');

      final future = cairn.watch('tasks').first;
      engine.rowsController.add('[{"_pk":"1","title":"a"}]');
      final rows = await future;
      expect(rows, [
        {'_pk': '1', 'title': 'a'},
      ]);
    });

    test('watch() for a different table than subscribed throws', () async {
      final engine = FakeCairnEngine();
      final cairn = Cairn.withEngine(engine);
      await cairn.subscribe('tasks');
      expect(() => cairn.watch('notes'), throwsStateError);
    });

    test('a second subscribe() call replaces the first', () async {
      final engine = FakeCairnEngine();
      final cairn = Cairn.withEngine(engine);
      await cairn.subscribe('tasks');
      await cairn.subscribe('notes');
      expect(engine.subscribeCallCount, 2);
      expect(() => cairn.watch('tasks'), throwsStateError);
      expect(() => cairn.watch('notes'), returnsNormally);
    });

    test('connectionState forwards engine state transitions', () async {
      final engine = FakeCairnEngine();
      final cairn = Cairn.withEngine(engine);
      await cairn.subscribe('tasks');

      final future = cairn.connectionState.first;
      engine.stateController.add(CairnConnectionState.connected);
      expect(await future, CairnConnectionState.connected);
    });
  });

  group('Cairn.watchQuery', () {
    test('watchQuery() before subscribe() throws StateError', () {
      final cairn = Cairn.withEngine(FakeCairnEngine());
      expect(
        () => cairn.watchQuery('SELECT 1'),
        throwsStateError,
      );
    });

    test('watchQuery() re-runs SQL on each change tick and decodes rows',
        () async {
      final engine = FakeCairnEngine()
        ..queryResult =
            '[{"title":"buy milk"},{"title":"ship cairn"}]';
      final cairn = Cairn.withEngine(engine);
      await cairn.subscribe('tasks');

      const sql =
          "SELECT json_extract(payload, '\$.title') AS title FROM cairn_data";
      final rowsFuture = cairn.watchQuery(sql).take(2).toList();

      // The change-tick pump: watchQuery is wired to the same row stream
      // `watch(table)` uses, so each emitted snapshot retriggers the SQL.
      engine.rowsController.add('[{"_pk":"1"}]');
      engine.rowsController.add('[{"_pk":"1"},{"_pk":"2"}]');

      final rows = await rowsFuture;
      expect(rows, [
        [
          {'title': 'buy milk'},
          {'title': 'ship cairn'},
        ],
        [
          {'title': 'buy milk'},
          {'title': 'ship cairn'},
        ],
      ]);
      // One query call per tick — confirms reactivity, not a one-shot.
      expect(engine.queries, [sql, sql]);
    });

    test(
      'watchQuery(triggerOnTables: [active]) accepts the subscribed table',
      () async {
        final engine = FakeCairnEngine();
        final cairn = Cairn.withEngine(engine);
        await cairn.subscribe('tasks');
        expect(
          () => cairn.watchQuery('SELECT 1', triggerOnTables: ['tasks']),
          returnsNormally,
        );
      },
    );

    test(
      'watchQuery(triggerOnTables: [other]) rejects a non-subscribed table',
      () async {
        final engine = FakeCairnEngine();
        final cairn = Cairn.withEngine(engine);
        await cairn.subscribe('tasks');
        expect(
          () => cairn.watchQuery('SELECT 1', triggerOnTables: ['other']),
          throwsArgumentError,
        );
      },
    );

    test(
      'watchQuery(throttle) coalesces a burst of ticks into one re-query',
      () {
        // FakeAsync is re-exported by flutter_test. The throttle Timer is a
        // fake timer — it only fires when we elapse fake time. Microtask-
        // based awaits (FakeCairnEngine.subscribe/query) flush transparently.
        FakeAsync().run((fake) async {
          final engine = FakeCairnEngine()..queryResult = '[]';
          final cairn = Cairn.withEngine(engine);
          await cairn.subscribe('tasks');

          final emitted = <List<Map<String, dynamic>>>[];
          cairn
              .watchQuery(
                'SELECT 1',
                throttle: const Duration(milliseconds: 100),
              )
              .listen(emitted.add);

          // 5 rapid ticks, all within the 100ms throttle window — the
          // trailing edge must NOT have fired yet.
          for (var i = 0; i < 5; i++) {
            engine.rowsController.add('[]');
          }
          expect(engine.queries, isEmpty);

          fake.elapse(const Duration(milliseconds: 100));

          // After the window closes: exactly ONE query for the whole
          // burst — PowerSync's throttle coalesce contract (N rapid ticks
          // → ≤1 re-query).
          expect(engine.queries.length, 1);
          expect(emitted.length, 1);
        });
      },
    );
  });

  group('Cairn.write', () {
    test('write() before subscribe() throws StateError', () {
      final cairn = Cairn.withEngine(FakeCairnEngine());
      expect(
        () => cairn.write('tasks', op: 'upsert', pk: '1'),
        throwsStateError,
      );
    });

    test('write() for a table other than the active subscription throws', () async {
      final engine = FakeCairnEngine();
      final cairn = Cairn.withEngine(engine);
      await cairn.subscribe('tasks');
      expect(
        () => cairn.write('notes', op: 'upsert', pk: '1'),
        throwsStateError,
      );
    });

    test('write() encodes the payload as JSON and returns the outbox id', () async {
      final engine = FakeCairnEngine();
      final cairn = Cairn.withEngine(engine);
      await cairn.subscribe('tasks');

      final id = await cairn.write(
        'tasks',
        op: 'upsert',
        pk: '42',
        payload: {'title': 'buy milk'},
      );

      expect(id, 1);
      expect(engine.writes, [
        (
          table: 'tasks',
          op: 'upsert',
          pk: '42',
          payloadJson: '{"title":"buy milk"}',
        ),
      ]);
    });

    test('write() with no payload passes payloadJson: null (delete)', () async {
      final engine = FakeCairnEngine();
      final cairn = Cairn.withEngine(engine);
      await cairn.subscribe('tasks');

      await cairn.write('tasks', op: 'delete', pk: '42');

      expect(engine.writes.single.payloadJson, isNull);
      expect(engine.writes.single.op, 'delete');
    });
  });

  group('Cairn.close', () {
    test('close() tears down the engine and is safe to call twice', () async {
      final engine = FakeCairnEngine();
      final cairn = Cairn.withEngine(engine);
      await cairn.subscribe('tasks');

      await cairn.close();
      expect(engine.closeCallCount, 1);

      // Idempotent — a second call must not throw.
      await cairn.close();
      expect(engine.closeCallCount, 2);
    });

    test('close() is safe with no prior subscribe()', () async {
      final engine = FakeCairnEngine();
      final cairn = Cairn.withEngine(engine);

      await cairn.close();
      expect(engine.closeCallCount, 1);
    });
  });
}
