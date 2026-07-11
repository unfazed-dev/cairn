import 'package:cairn_flutter/cairn_flutter.dart';
import 'package:flutter/material.dart';

/// A minimal example: connect to a local `cairn-server`, subscribe to
/// `tasks`, and render whatever rows show up. Run a server first:
/// `cargo run -p cairn-server` (zero-setup default: fake replicator, no
/// auth, ws://127.0.0.1:8800/sync).
void main() {
  runApp(const CairnExampleApp());
}

class CairnExampleApp extends StatelessWidget {
  const CairnExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(home: TasksPage());
  }
}

class TasksPage extends StatefulWidget {
  const TasksPage({super.key});

  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  Cairn? _cairn;
  CairnConnectionState _state = CairnConnectionState.disconnected;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  Future<void> _connect() async {
    final cairn = await Cairn.connect(url: 'ws://127.0.0.1:8800/sync');
    await cairn.subscribe('tasks');
    cairn.connectionState.listen((s) {
      if (mounted) setState(() => _state = s);
    });
    if (mounted) setState(() => _cairn = cairn);
  }

  @override
  Widget build(BuildContext context) {
    final cairn = _cairn;
    return Scaffold(
      appBar: AppBar(title: Text('cairn_flutter example — ${_state.name}')),
      body: cairn == null
          ? const Center(child: CircularProgressIndicator())
          : StreamBuilder<List<Map<String, dynamic>>>(
              stream: cairn.watch('tasks'),
              builder: (context, snapshot) {
                final rows = snapshot.data ?? const <Map<String, dynamic>>[];
                if (rows.isEmpty) {
                  return const Center(child: Text('No rows yet'));
                }
                return ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (context, i) => ListTile(
                    title: Text(rows[i]['_pk']?.toString() ?? '?'),
                    subtitle: Text(rows[i].toString()),
                  ),
                );
              },
            ),
    );
  }
}
