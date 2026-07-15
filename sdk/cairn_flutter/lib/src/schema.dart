import 'engine.dart' show ClientTableFfi;

/// The server's table schema for a publication, resolved at connect time.
///
/// This is the Dart-side mirror of the cairn-server `GET /schema` response
/// (ADR-0019): a list of [CairnTable]s, each with a primary key and typed [CairnColumn]s.
/// It exists so [CairnDatabase.connect] can call `Cairn.applySchema` with a
/// typed value rather than a hand-rolled list of `ClientTableFfi`s, and so the
/// app can inspect the resolved shape (and derive typed records — WS6) without
/// re-fetching.
///
/// Build it either by parsing the server descriptor ([CairnSchema.fromSchemaDescriptor])
/// — which [CairnDatabase.connect] does automatically when no `schema` is
/// passed — or by DECLARING it in the app (PowerSync-style):
///
/// ```dart
/// const schema = CairnSchema(tables: [
///   CairnTable(name: 'tasks', primaryKey: ['id'], columns: [
///     CairnColumn.text('id'),
///     CairnColumn.text('title'),
///     CairnColumn.integer('completed'),
///   ]),
/// ]);
/// ```
///
/// ## Migrations
///
/// A declared schema IS the migration story: every connect re-applies the
/// schema, and the engine drops + recreates the per-table read-views
/// (`SqliteStorage::apply_schema`, DROP VIEW + CREATE VIEW). To migrate,
/// edit the declaration and ship — adding a column exposes it from already
/// -synced payloads on next launch; removing one drops it from the view.
/// No migration files, no version counters: the row payloads in
/// `cairn_data` are schema-less JSON, so only the view projection changes.
///
/// Convert to the FFI mirror with [toClientTables].
class CairnSchema {
  const CairnSchema({required this.tables});

  /// Tables in publication order.
  final List<CairnTable> tables;

  /// Parse the cairn-server `GET /schema` response body.
  ///
  /// Expected shape:
  /// ```
  /// {
  ///   "publication": String,             // carried on the wire; unused here
  ///   "tables": [
  ///     {
  ///       "name": String,
  ///       "primary_key": [String, ...],
  ///       "columns": [
  ///         { "name": String, "pg_oid": int, "affinity": String }
  ///       ]
  ///     }, ...
  ///   ]
  /// }
  /// ```
  /// `pg_oid` is the Postgres type tag; `affinity` is the derived SQLite
  /// affinity (`"TEXT"`|`"INTEGER"`|`"REAL"`, from `oid_to_sqlite_affinity` —
  /// ADR-0019). Both land on [CairnColumn]; the WS2 view path itself keys reads off
  /// names via `json_extract`, so affinity is for typed-record derivation, not
  /// for view materialization.
  factory CairnSchema.fromSchemaDescriptor(Map<String, dynamic> json) {
    final rawTables =
        (json['tables'] as List<dynamic>).cast<Map<String, dynamic>>();
    return CairnSchema(
      tables: rawTables.map(CairnTable._fromJson).toList(growable: false),
    );
  }

  /// Map this schema to the FFI mirror consumed by `Cairn.applySchema` (which
  /// creates one `CREATE VIEW` per table). The WS2 views are name-keyed
  /// `json_extract` projections, so column *names* are all the view layer
  /// needs — the type metadata stays in the Dart [CairnColumn], the FFI mirror
  /// stays name-only (hexagonal: `ClientTableFfi` never needs affinity).
  List<ClientTableFfi> toClientTables() => tables
      .map(
        (t) => ClientTableFfi(
          name: t.name,
          primaryKey: t.primaryKey,
          columns: t.columns.map((c) => c.name).toList(growable: false),
        ),
      )
      .toList(growable: false);
}

/// One table in a resolved [CairnSchema].
class CairnTable {
  const CairnTable({
    required this.name,
    required this.primaryKey,
    required this.columns,
  });

  /// Canonical table id (matches `cairn_data.table_name` / the wire `table`).
  final String name;

  /// Primary-key column names. Informational for the current WS2 view path
  /// (reads are name-keyed); carried for the future materialized-table path.
  final List<String> primaryKey;

  /// Columns in tuple order — the JSON keys inside `cairn_data.payload`, each
  /// carrying the server-reported type. WS6 (typed records): the
  /// affinity/pg_oid let a typed record's fields be derived from the schema
  /// rather than hand-cast. Both type fields are nullable so a hand-built
  /// schema (tests, pinned apps, fake-mode where `GET /schema` 404s) compiles
  /// without server metadata — reads then stay name-keyed as in WS2.
  final List<CairnColumn> columns;

  factory CairnTable._fromJson(Map<String, dynamic> json) => CairnTable(
        name: json['name'] as String,
        primaryKey: (json['primary_key'] as List<dynamic>).cast<String>(),
        columns: (json['columns'] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .map(CairnColumn._fromJson)
            .toList(growable: false),
      );
}

/// One column in a resolved [CairnTable].
///
/// [affinity] is the SQLite affinity the server derives from the column's
/// Postgres OID (`oid_to_sqlite_affinity`, ADR-0019): `"TEXT"` | `"INTEGER"` |
/// `"REAL"`. It mirrors the JSON token shape `PgReplicator` emits, so a typed
/// record's field can be cast to the matching Dart type (TEXT→String,
/// INTEGER→int, REAL→double). [pgOid] is the raw Postgres type OID
/// (informational — the source-of-truth type tag). Both are `null` for a
/// hand-built schema that never fetched `GET /schema`.
///
/// `CairnColumn` is intentionally NOT exported from the package barrel — it would
/// shadow Flutter material's `CairnColumn` widget. Reach it via `src/schema.dart`
/// when constructing a typed [CairnSchema], as the integration test does.
class CairnColumn {
  const CairnColumn({required this.name, this.affinity, this.pgOid});

  /// Declared TEXT column (String reads) — for app-declared schemas.
  const CairnColumn.text(this.name)
      : affinity = 'TEXT',
        pgOid = null;

  /// Declared INTEGER column (int / 0-1 bool reads) — for app-declared
  /// schemas.
  const CairnColumn.integer(this.name)
      : affinity = 'INTEGER',
        pgOid = null;

  /// Declared REAL column (double reads) — for app-declared schemas.
  const CairnColumn.real(this.name)
      : affinity = 'REAL',
        pgOid = null;

  final String name;
  final String? affinity;
  final int? pgOid;

  factory CairnColumn._fromJson(Map<String, dynamic> json) => CairnColumn(
        name: json['name'] as String,
        affinity: json['affinity'] as String?,
        pgOid: json['pg_oid'] as int?,
      );
}

/// Collision-free alias for [CairnTable], exported from the package barrel.
///
/// `CairnTable`/`CairnColumn` themselves are NOT re-exported at the package root
/// because they shadow Flutter's `CairnTable`/`CairnColumn` widgets; declare your app
/// schema with `CairnTable` / `CairnColumn` instead (same classes, safe
/// names next to `material.dart`).

/// Collision-free alias for [CairnColumn] — see [CairnTable].
