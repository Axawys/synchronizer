import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sync_net/sync_net.dart';

import 'folder_picker_page.dart';
import 'storage.dart';

/// Screen for a paired device: connects a session, lists the folders it shares,
/// and reconciles a chosen folder in both directions with a three-way merge.
class SyncPage extends StatefulWidget {
  const SyncPage({
    super.key,
    required this.self,
    required this.trusted,
    required this.device,
  });

  final DeviceInfo self;
  final TrustedPeer trusted;
  final DeviceInfo device;

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  SyncClient? _client;
  List<SharedDir> _dirs = const [];
  String? _error;
  bool _connecting = true;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  Future<void> _connect() async {
    try {
      final client = await SyncClient.connect(
        widget.device.address!,
        widget.device.port,
        self: widget.self,
        trusted: widget.trusted,
      );
      final dirs = await client.listDirectories();
      if (!mounted) {
        await client.close();
        return;
      }
      setState(() {
        _client = client;
        _dirs = dirs;
        _connecting = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _connecting = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _client?.close();
    super.dispose();
  }

  /// Resolves where [name] lives locally, asking the user to pick the folder
  /// the first time. The chosen folder is the sync target itself.
  Future<String?> _resolveTarget(String name) async {
    final existing = await SyncTargets.localPath(widget.device.id, name);
    if (existing != null) return existing;

    String? picked;
    if (Platform.isAndroid) {
      if (!await _ensureStoragePermission()) {
        _toast('All-files access is needed to choose a destination folder.');
        return null;
      }
      if (!mounted) return null;
      picked = await Navigator.of(context).push<String>(
        MaterialPageRoute(
          builder: (_) => const FolderPickerPage(rootPath: '/storage/emulated/0'),
        ),
      );
    } else {
      picked = await getDirectoryPath(
        confirmButtonText: 'Sync "$name" into this folder',
      );
    }
    if (picked == null) return null;

    await SyncTargets.setLocalPath(widget.device.id, name, picked);
    return picked;
  }

  /// Ensures all-files access on Android, sending the user to the system
  /// setting to grant it if needed, so writes into normal storage succeed.
  Future<bool> _ensureStoragePermission() async {
    if (await Permission.manageExternalStorage.isGranted) return true;
    final status = await Permission.manageExternalStorage.request();
    return status.isGranted;
  }

  Future<void> _sync(String name) async {
    final client = _client;
    if (client == null) return;

    final localPath = await _resolveTarget(name);
    if (localPath == null || !mounted) return;
    final root = Directory(localPath);

    final base = await BaseManifests.load(widget.device.id, name);
    final MergeResult merge;
    try {
      merge = await computeMerge(client, name, root, base);
    } catch (e) {
      _toast('Could not read changes: $e');
      return;
    }

    if (merge.isEmpty) {
      _toast('"$name" is already in sync.');
      return;
    }

    final List<ResolvedMerge> resolved;
    if (await SyncSettings.lightMode()) {
      // No one to ask: resolve conflicts by taking the more recently edited side.
      resolved = [
        for (final item in merge.items)
          item.kind == MergeKind.conflict
              ? ResolvedMerge(item, toLocal: conflictResolvesToLocal(item))
              : ResolvedMerge.natural(item),
      ];
    } else {
      if (!mounted) return;
      final choice = await showDialog<List<ResolvedMerge>>(
        context: context,
        builder: (context) => _MergeDialog(
          name: name,
          merge: merge,
          deviceName: widget.device.name,
        ),
      );
      if (choice == null) return; // cancelled
      resolved = choice;
    }

    await _apply(client, name, root, resolved);
  }

  Future<void> _apply(SyncClient client, String name, Directory root,
      List<ResolvedMerge> resolved) async {
    final progress = ValueNotifier<int>(0);
    if (mounted) {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) =>
            _ApplyingDialog(total: resolved.length, applied: progress),
      );
    }
    try {
      final report = await applyMerge(client, name, root, resolved,
          onProgress: (done, _) => progress.value = done);

      if (report.ok) {
        // Both sides now match; record it as the base for next time. If any
        // file failed we keep the old base, so the next sync still knows what
        // changed where.
        await BaseManifests.save(
            widget.device.id, name, await Manifest.scan(root));
      }
      await _log(name, resolved, report);

      if (mounted) Navigator.of(context).pop(); // close applying dialog
      _toast(report.ok
          ? 'Synced ${report.applied} change(s) for "$name".'
          : 'Synced ${report.applied}, ${report.failures.length} failed. '
              'Try again to finish.');
    } catch (e) {
      if (mounted) Navigator.of(context).pop();
      _toast('Sync failed: $e');
    } finally {
      progress.dispose();
    }
  }

  /// Records what this sync actually achieved. Files that failed are counted
  /// only as failures, not as transferred.
  Future<void> _log(
      String name, List<ResolvedMerge> resolved, MergeReport report) async {
    final failed = report.failures.map((f) => f.path).toSet();
    final done = resolved.where((r) => !failed.contains(r.item.path));

    await SyncLog.add(SyncLogEntry(
      at: DateTime.now(),
      peerName: widget.device.name,
      folder: name,
      downloaded: done.where((r) => r.toLocal).length,
      uploaded: done.where((r) => !r.toLocal).length,
      conflicts:
          resolved.where((r) => r.item.kind == MergeKind.conflict).length,
      failed: failed.length,
    ));
  }

  void _toast(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.device.name)),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_connecting) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Could not connect:\n$_error', textAlign: TextAlign.center),
        ),
      );
    }
    if (_dirs.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('This device is not sharing any folders yet.',
              textAlign: TextAlign.center),
        ),
      );
    }
    return ListView.separated(
      itemCount: _dirs.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final dir = _dirs[i];
        return ListTile(
          leading: const Icon(Icons.folder_shared),
          title: Text(dir.name),
          trailing: const Icon(Icons.sync),
          onTap: () => _sync(dir.name),
        );
      },
    );
  }
}

/// Shows a reconciliation before it runs: files to download, files to upload,
/// and any conflicts, each with a per-file choice of which side wins.
class _MergeDialog extends StatefulWidget {
  const _MergeDialog({
    required this.name,
    required this.merge,
    required this.deviceName,
  });

  final String name;
  final MergeResult merge;
  final String deviceName;

  @override
  State<_MergeDialog> createState() => _MergeDialogState();
}

class _MergeDialogState extends State<_MergeDialog> {
  // For each conflicting path, true = keep this device's version. Defaults to
  // the opposite of the automatic "take the newer side" choice.
  late final Map<String, bool> _keepLocal = {
    for (final item in widget.merge.conflicts)
      item.path: !conflictResolvesToLocal(item),
  };

  List<ResolvedMerge> _resolve() {
    return [
      for (final item in widget.merge.items)
        if (item.kind == MergeKind.conflict)
          ResolvedMerge(item, toLocal: !_keepLocal[item.path]!)
        else
          ResolvedMerge.natural(item),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final merge = widget.merge;
    return AlertDialog(
      title: Text('Sync "${widget.name}"'),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(
          shrinkWrap: true,
          children: [
            if (merge.conflicts.isNotEmpty) ...[
              _heading(context, 'Conflicts', Icons.warning, Colors.red),
              const Padding(
                padding: EdgeInsets.only(left: 26, bottom: 4),
                child: Text('Changed on both sides. Choose which to keep:',
                    style: TextStyle(fontStyle: FontStyle.italic)),
              ),
              for (final item in merge.conflicts) _conflictRow(item),
            ],
            _fileList(context, 'Download from ${widget.deviceName}',
                Icons.download, Colors.blue, merge.pulls),
            _fileList(context, 'Upload to ${widget.deviceName}', Icons.upload,
                Colors.teal, merge.pushes),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _resolve()),
          child: Text('Sync ${merge.length}'),
        ),
      ],
    );
  }

  Widget _conflictRow(MergeItem item) {
    return Padding(
      padding: const EdgeInsets.only(left: 26, top: 4, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(item.path, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 4),
          SegmentedButton<bool>(
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(value: true, label: Text('Keep mine')),
              ButtonSegment(value: false, label: Text('Take theirs')),
            ],
            selected: {_keepLocal[item.path]!},
            onSelectionChanged: (s) =>
                setState(() => _keepLocal[item.path] = s.first),
          ),
        ],
      ),
    );
  }

  Widget _heading(BuildContext context, String label, IconData icon, Color c) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: c),
          const SizedBox(width: 8),
          Text(label, style: Theme.of(context).textTheme.titleSmall),
        ],
      ),
    );
  }

  Widget _fileList(BuildContext context, String label, IconData icon,
      Color color, Iterable<MergeItem> items) {
    final list = items.toList();
    if (list.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(context, '$label (${list.length})', icon, color),
        for (final item in list)
          Padding(
            padding: const EdgeInsets.only(left: 26, bottom: 2),
            child: Text(_describe(item),
                style: Theme.of(context).textTheme.bodySmall),
          ),
      ],
    );
  }

  // Marks deletions so the user is not surprised by a removal.
  String _describe(MergeItem item) {
    final gone = item.kind == MergeKind.pullToLocal
        ? item.remote == null
        : item.local == null;
    return gone ? '${item.path}  (delete)' : item.path;
  }
}

class _ApplyingDialog extends StatelessWidget {
  const _ApplyingDialog({required this.total, required this.applied});

  final int total;
  final ValueListenable<int> applied;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Syncing'),
      content: ValueListenableBuilder<int>(
        valueListenable: applied,
        builder: (context, value, _) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(
                  value: total == 0 ? null : value / total),
              const SizedBox(height: 12),
              Text('$value of $total'),
            ],
          );
        },
      ),
    );
  }
}
