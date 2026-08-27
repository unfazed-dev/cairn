/// cairn_flutter — plug-and-play local-first sync for Flutter, backed by a
/// Rust `cairn-client` (SQLite + WebSocket sync loop) via
/// flutter_rust_bridge's native-assets backend.
///
/// Start at [CairnDatabase] — `CairnDatabase.open` / `.supabase` is the taught
/// entry point. It resolves the server schema for you (`GET /schema`), so
/// `SELECT * FROM <table>` works immediately, and adds typed
/// [Collection]-per-table handles and a [SyncStatus] signal.
///
/// No connector class and no *hand-written* schema: `subscribe` sets the
/// server-side predicate, `watch` gives you a reactive `Stream` of rows, and
/// `write` applies locally at once and syncs in the background through a
/// durable outbox. A [CairnSchema] is optional — pass one only to constrain or
/// pin what the server reports. See the package README for the quickstart.
///
/// [Cairn] is the low-level engine handle underneath [CairnDatabase]. It stays
/// exported as an escape hatch (and is the seam tests fake against), but it is
/// deliberately not the documented path — prefer [CairnDatabase] unless you have
/// a reason not to.
library;

// `Cairn` is the low-level handle; `CairnDatabase` (below) is the taught surface.
export 'src/cairn.dart'
    show Cairn, CairnSupabase, CairnConnectionState, CairnTableSub;
// The fake-able engine seam (engine.dart's library doc is written FOR test
// doubles) — without this, barrel consumers can name Cairn.withEngine but
// cannot implement the interface it takes.
export 'src/engine.dart' show CairnEngine, ClientTableFfi;
export 'src/cairn_config.dart' show CairnConfig;
// `Table` and `Column` are intentionally NOT re-exported at the package
// root because they shadow Flutter's `Table`/`Column` widgets (a hard
// collision for any app importing both this package and `material.dart`).
// Declare app schemas with the collision-free aliases `CairnTable` /
// `CairnColumn` instead (same classes).
export 'src/schema.dart' show CairnSchema, CairnTable, CairnColumn;
export 'src/predicate.dart' show Where, Order;
export 'src/cairn_database.dart'
    show
        CairnDatabase,
        Collection,
        SyncStatus,
        CairnWrite,
        DeadLetter,
        CairnPushTokenException;
// T6 attachments (ADR-0034): two-plane blob sync. The metadata table syncs
// through Cairn; the blob plane is the app's AttachmentStorageAdapter.
export 'src/attachments.dart'
    show
        Attachments,
        AttachmentDatabase,
        AttachmentStorageAdapter,
        SupabaseStorageAdapter,
        BlobStore,
        LocalFileBlobStore,
        AttachmentRow,
        AttachmentSchema,
        AttachmentStateWire;
