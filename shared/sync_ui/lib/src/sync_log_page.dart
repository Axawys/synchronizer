import 'package:flutter/material.dart';

import 'storage.dart';

/// The sync history: what was reconciled, with which device, and when.
class SyncLogPage extends StatefulWidget {
  const SyncLogPage({super.key});

  @override
  State<SyncLogPage> createState() => _SyncLogPageState();
}

class _SyncLogPageState extends State<SyncLogPage> {
  List<SyncLogEntry>? _entries;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entries = await SyncLog.all();
    if (mounted) setState(() => _entries = entries);
  }

  Future<void> _clear() async {
    await SyncLog.clear();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sync history'),
        actions: [
          if (entries != null && entries.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: 'Clear history',
              onPressed: _clear,
            ),
        ],
      ),
      body: entries == null
          ? const Center(child: CircularProgressIndicator())
          : entries.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('Nothing synced yet.'),
                  ),
                )
              : ListView.separated(
                  itemCount: entries.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) => _EntryTile(entry: entries[i]),
                ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry});

  final SyncLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final failed = entry.failed > 0;
    return ListTile(
      leading: Icon(
        failed ? Icons.error_outline : Icons.check_circle_outline,
        color: failed ? Colors.red : Colors.teal,
      ),
      title: Text('${entry.folder} — ${entry.peerName}'),
      subtitle: Text(_summary()),
      trailing: Text(
        _when(entry.at),
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }

  String _summary() {
    final parts = <String>[];
    if (entry.downloaded > 0) parts.add('${entry.downloaded} in');
    if (entry.uploaded > 0) parts.add('${entry.uploaded} out');
    if (entry.conflicts > 0) parts.add('${entry.conflicts} conflicts');
    if (entry.failed > 0) parts.add('${entry.failed} failed');
    return parts.isEmpty ? 'no changes' : parts.join(', ');
  }

  String _when(DateTime at) {
    String two(int n) => n.toString().padLeft(2, '0');
    final now = DateTime.now();
    final sameDay =
        at.year == now.year && at.month == now.month && at.day == now.day;
    final time = '${two(at.hour)}:${two(at.minute)}';
    return sameDay ? time : '${two(at.day)}.${two(at.month)} $time';
  }
}
