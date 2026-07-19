// Cairn Provider Dashboard — offline-first multi-table booking app (Flutter).
//
// A production-quality booking application showcasing the cairn Flutter SDK:
//   - 6 tables on ONE /sync socket: providers, clients, availabilities,
//     appointments, invoices, messages (D1/ADR-0022 multi-table subscribe).
//   - Reactive typed watch → watchMapped<T>('SELECT * FROM <table>', fromRow)
//     per NavigationRail/BottomNav tab. IndexedStack preserves state across
//     tab switches (the reactive-stream fix).
//   - Durable offline writes → write(table, op, pk, payload) lands in the local
//     SQLite outbox + flushes on reconnect (ADR-0013).
//   - REAL pause/resume (D2) → disconnect() aborts ONLY the /sync loop; reads,
//     writes, and the UI keep working offline.
//   - Auto-calculated billing → invoices compute from provider rates (hourly /
//     flat / subscription) via BillingService; the rate is snapshotted at issue.
//   - Realtime chat → the synced `messages` table IS the realtime stream (no
//     separate WebSocket; 2026 local-first best practice).
//   - Connection state → aggregate badge across the shared session.
//
// Architecture: stacked MVVM methodology + Material 3 (the stacked-kit-designer
// skill's anti-slop blacklist + responsive form-factor thinking applied, but
// with Material 3 + cupertino idioms instead of the unavailable stacked_kit
// tokens — stacked_kit does not exist on pub.dev).
//
// Backend: `cairn dev` binds ws://127.0.0.1:8800; override via --dart-define=
// CAIRN_URL=... Writes round-trip only when CAIRN_WRITE_TABLES lists the 6
// tables (see example/README.md).

import 'dart:async';
import 'dart:io';

import 'package:cairn_flutter/cairn_flutter.dart';
import 'package:flutter/material.dart';

import 'app/app_theme.dart';
import 'cairn.g.dart' show cairnConfig, cairnSchema;
import 'views/dashboard_shell.dart';

/// Optional /sync URL override:
/// `flutter run --dart-define=CAIRN_URL=ws://host:port/sync`.
/// When empty, the URL comes from `cairnConfig` (generated from `.cairn/config.json`
/// by `cairn gen`).
const _kUrlOverride = String.fromEnvironment('CAIRN_URL');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CairnDashboardApp());
}

class CairnDashboardApp extends StatelessWidget {
  const CairnDashboardApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Cairn Provider Dashboard',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        home: const DashboardBoot(),
      );
}

/// Boots the CairnDatabase connection before showing the DashboardShell.
/// Shows a loading spinner (or the connect-failed error) while booting.
class DashboardBoot extends StatefulWidget {
  const DashboardBoot({super.key});
  @override
  State<DashboardBoot> createState() => _DashboardBootState();
}

class _DashboardBootState extends State<DashboardBoot> {
  CairnDatabase? _db;
  String? _error;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      var config = cairnConfig;
      if (_kUrlOverride.isNotEmpty) {
        config = CairnConfig(
          url: _kUrlOverride,
          supabaseUrl: config.supabaseUrl,
          supabaseAnonKey: config.supabaseAnonKey,
          sqliteFilename: config.sqliteFilename,
        );
      }
      final db = await CairnDatabase.open(
        config: config,
        schema: cairnSchema,
        sqliteDir: Directory.systemTemp.path,
      );
      await db.subscribeTables(kTables);
      if (!mounted) return;
      setState(() => _db = db);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_db != null) {
      return DashboardShell(db: _db!);
    }
    return Scaffold(
      body: Center(
        child: _error == null
            ? const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Connecting to cairn…',
                      style: TextStyle(fontSize: 13)),
                ],
              )
            : Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Connect failed:\n$_error',
                    style: const TextStyle(color: Colors.red)),
              ),
      ),
    );
  }
}
