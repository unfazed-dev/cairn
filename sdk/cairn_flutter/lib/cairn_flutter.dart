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
// Schema only — `Table` and `Column` are intentionally NOT re-exported at
// the package root because they shadow Flutter's `Table`/`Column` widgets
// (a hard collision for any app importing both this package and
// `material.dart`). Reach them via `import 'package:cairn_flutter/src/schema.dart'`
// when you need to bind them by name.
export 'src/schema.dart' show Schema;
export 'src/cairn_database.dart' show CairnDatabase;
