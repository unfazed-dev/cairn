import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// App-level Cairn configuration, normally loaded from a bundled
/// `cairn.json` asset (the analogue of `firebase_options` / Supabase's
/// config block): where the cairn-server lives, optional Supabase-cloud
/// credentials, and the local SQLite filename.
///
/// ```jsonc
/// // assets/cairn.json
/// {
///   "url": "wss://cairn.example.com/sync",   // required — cairn-server /sync
///   "supabase": {                            // optional — Supabase cloud
///     "url": "https://xyz.supabase.co",
///     "anon_key": "eyJ..."
///   },
///   "sqlite_filename": "cairn.sqlite"        // optional — default shown
/// }
/// ```
///
/// Register the asset in `pubspec.yaml` (`assets: [assets/cairn.json]`),
/// then:
///
/// ```dart
/// final config = await CairnConfig.load();           // assets/cairn.json
/// final db = await CairnDatabase.open(
///   config: config,
///   schema: appSchema,       // your declared CairnSchema (the migration story)
///   sqliteDir: dir.path,     // e.g. getApplicationSupportDirectory()
/// );
/// ```
///
/// When the `supabase` block is present, [CairnDatabase.open] initializes
/// Supabase (if the app hasn't already) and forwards the signed-in
/// session's access token as the sync bearer token.
class CairnConfig {
  const CairnConfig({
    required this.url,
    this.supabaseUrl,
    this.supabaseAnonKey,
    this.sqliteFilename = 'cairn.sqlite',
  });

  /// Parse a decoded `cairn.json` map. Throws [FormatException] with a
  /// pointed message when required keys are missing/mistyped, so a bad
  /// config fails loudly at startup rather than as a dangling socket.
  factory CairnConfig.fromJson(Map<String, dynamic> json) {
    final url = json['url'];
    if (url is! String || url.isEmpty) {
      throw const FormatException(
        'cairn config: "url" is required — the cairn-server /sync WebSocket '
        'URL (e.g. "ws://localhost:8800/sync")',
      );
    }
    final scheme = Uri.tryParse(url)?.scheme;
    if (scheme != 'ws' && scheme != 'wss') {
      throw FormatException(
        'cairn config: "url" must be a ws:// or wss:// URL, got "$url"',
      );
    }
    String? supabaseUrl;
    String? supabaseAnonKey;
    final supabase = json['supabase'];
    if (supabase != null) {
      if (supabase is! Map<String, dynamic>) {
        throw const FormatException(
          'cairn config: "supabase" must be an object with "url" and '
          '"anon_key"',
        );
      }
      supabaseUrl = supabase['url'] as String?;
      // `publishable_key` is Supabase's successor name for the anon key;
      // accept either spelling.
      supabaseAnonKey =
          (supabase['anon_key'] ?? supabase['publishable_key']) as String?;
      if (supabaseUrl == null || supabaseAnonKey == null) {
        throw const FormatException(
          'cairn config: "supabase" requires both "url" and "anon_key" '
          '(or "publishable_key")',
        );
      }
    }
    final filename = json['sqlite_filename'] as String? ?? 'cairn.sqlite';
    return CairnConfig(
      url: url,
      supabaseUrl: supabaseUrl,
      supabaseAnonKey: supabaseAnonKey,
      sqliteFilename: filename,
    );
  }

  /// Load and parse a bundled JSON asset (default `assets/cairn.json`).
  ///
  /// The asset must be registered under `flutter/assets` in the app's
  /// `pubspec.yaml`. Throws [FlutterError] if the asset is missing and
  /// [FormatException] if it fails validation (see [CairnConfig.fromJson]).
  static Future<CairnConfig> load({String asset = 'assets/cairn.json'}) async {
    final raw = await rootBundle.loadString(asset);
    return CairnConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  /// cairn-server `/sync` WebSocket URL (`ws://` or `wss://`).
  final String url;

  /// Supabase project URL — set together with [supabaseAnonKey] to run
  /// against Supabase cloud (auth token forwarded to the sync connection).
  final String? supabaseUrl;

  /// Supabase anon (publishable) key — see [supabaseUrl].
  final String? supabaseAnonKey;

  /// Local SQLite filename, joined onto the directory the app passes to
  /// [CairnDatabase.open] (`sqliteDir`). Default `cairn.sqlite`.
  final String sqliteFilename;

  /// Whether this config carries Supabase-cloud credentials.
  bool get hasSupabase => supabaseUrl != null && supabaseAnonKey != null;
}
