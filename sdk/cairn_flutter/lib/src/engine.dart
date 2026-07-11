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

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import 'rust/api/cairn.dart' as rust;

/// Connection-state transitions, decoupled from the generated
/// `rust.CairnConnectionState` so consumers never need to import generated
/// code. See `rust/src/api/cairn.rs`'s `CairnConnectionState` doc for the
/// precise (heuristic) semantics of `connected`.
enum CairnConnectionState { connecting, connected, reconnecting, disconnected }

/// The two streams a subscription produces.
class CairnSubscriptionStreams {
  const CairnSubscriptionStreams({required this.rows, required this.state});

  /// One JSON-array-of-objects string per tick — the full row set for the
  /// subscribed table.
  final Stream<String> rows;

  /// Connection-state transitions for this subscription's session.
  final Stream<CairnConnectionState> state;
}

/// What [Cairn] needs from a backend: start a subscription, perform a
/// durable write. Implemented for real by [RustCairnEngine]; implement it
/// yourself in tests to avoid the native library entirely.
abstract class CairnEngine {
  Future<CairnSubscriptionStreams> subscribe({
    required String table,
    String? whereSql,
  });

  /// Returns the local outbox id.
  Future<int> write({
    required String table,
    required String op,
    required String pk,
    String? payloadJson,
  });

  /// Tear down the active subscription's background work (the sync loop and
  /// the watch-stream pump). Safe to call with no active subscription and
  /// safe to call more than once.
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
  Future<CairnSubscriptionStreams> subscribe({
    required String table,
    String? whereSql,
  }) async {
    final rowsSink = RustStreamSink<String>();
    final stateSink = RustStreamSink<rust.CairnConnectionState>();
    await _handle.subscribe(
      table: table,
      whereSql: whereSql,
      rowsSink: rowsSink,
      stateSink: stateSink,
    );
    return CairnSubscriptionStreams(
      rows: rowsSink.stream,
      state: stateSink.stream.map(_mapState),
    );
  }

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
  Future<void> close() => _handle.close();
}

CairnConnectionState _mapState(rust.CairnConnectionState s) => switch (s) {
  rust.CairnConnectionState.connecting => CairnConnectionState.connecting,
  rust.CairnConnectionState.connected => CairnConnectionState.connected,
  rust.CairnConnectionState.reconnecting => CairnConnectionState.reconnecting,
  rust.CairnConnectionState.disconnected => CairnConnectionState.disconnected,
};
