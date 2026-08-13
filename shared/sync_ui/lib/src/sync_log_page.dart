import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';

import 'layout.dart';
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
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.historyTitle),
        actions: [
          if (entries != null && entries.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: l10n.clearHistory,
              onPressed: _clear,
            ),
        ],
      ),
      body: entries == null
          ? const Center(child: CircularProgressIndicator())
          : entries.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(l10n.nothingSyncedYet),
                  ),
                )
              : ContentPane(
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(Layout.gutter,
                        Layout.gap, Layout.gutter, Layout.section),
                    itemCount: entries.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: Layout.gap),
                    itemBuilder: (context, i) => _EntryTile(entry: entries[i]),
                  ),
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
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = AppLocalizations.of(context);

    return AppCard(
      child: Row(
        children: [
          Icon(
            failed ? Icons.error_outline : Icons.check_circle_outline,
            color: failed ? colors.error : colors.primary,
          ),
          const SizedBox(width: Layout.gap),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${entry.folder} — ${entry.peerName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: Layout.tight),
                Text(
                  _summary(l10n),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: Layout.snug),
          Text(
            _when(entry.at),
            style: theme.textTheme.bodySmall
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  String _summary(AppLocalizations l10n) {
    final parts = <String>[];
    if (entry.downloaded > 0) parts.add(l10n.logIn(entry.downloaded));
    if (entry.uploaded > 0) parts.add(l10n.logOut(entry.uploaded));
    if (entry.conflicts > 0) parts.add(l10n.logConflicts(entry.conflicts));
    if (entry.failed > 0) parts.add(l10n.logFailed(entry.failed));
    return parts.isEmpty ? l10n.logNoChanges : parts.join(', ');
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
