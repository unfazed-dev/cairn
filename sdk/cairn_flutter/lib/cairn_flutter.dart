/// cairn_flutter — plug-and-play local-first sync for Flutter, backed by a
/// Rust `cairn-client` (SQLite + WebSocket sync loop) via
/// flutter_rust_bridge's native-assets backend.
///
/// No connector class, no client-side schema artifact: `subscribe` sets the
/// server-side predicate, `watch` gives you a reactive `Stream` of rows,
/// `write` is a durable local outbox. See the package README for the
/// quickstart.
library;

export 'src/cairn.dart' show Cairn, CairnSupabase, CairnConnectionState;
