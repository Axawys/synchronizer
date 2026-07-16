import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sync_net/sync_net.dart';

import 'folder_picker_page.dart';
import 'merge_preview_page.dart';
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
      resolved = await _resolveWithoutAsking(client, name, root, merge);
    } else {
      final SyncPreview preview;
      try {
        preview = await buildPreview(client, name, root, merge);
      } catch (e) {
        _toast('Could not prepare the preview: $e');
        return;
      }
      if (!mounted) return;
      final choice = await Navigator.of(context).push<List<ResolvedMerge>>(
        MaterialPageRoute(
          builder: (_) => MergePreviewPage(
            folderName: name,
            deviceName: widget.device.name,
            preview: preview,
          ),
        ),
      );
      if (choice == null) return; // backed out
      resolved = choice;
    }

    await _apply(client, name, root, resolved, base);
  }

  /// Plain mode: merge what merges, and settle the rest by taking whichever
  /// side was edited more recently, since there is nobody to ask.
  Future<List<ResolvedMerge>> _resolveWithoutAsking(
    SyncClient client,
    String name,
    Directory root,
    MergeResult merge,
  ) async {
    final resolved = <ResolvedMerge>[];
    for (final item in merge.items) {
      if (item.kind != MergeKind.conflict) {
        resolved.add(ResolvedMerge.natural(item));
        continue;
      }
      final merged = await mergeConflict(client, name, root, item);
      resolved.add(merged.isClean
          ? ResolvedMerge.merged(item, merged.merge!.clean!)
          : ResolvedMerge(item, toLocal: conflictResolvesToLocal(item)));
    }
    return resolved;
  }

  Future<void> _apply(SyncClient client, String name, Directory root,
      List<ResolvedMerge> resolved, Manifest base) async {
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
      final outcome = await runSync(client, name, root, base, resolved,
          onProgress: (done, _) => progress.value = done);
      final report = outcome.report;

      // Set only when the sync finished, in which case both sides now match and
      // this is the ancestor the next merge works from.
      if (outcome.newBase != null) {
        await BaseManifests.save(widget.device.id, name, outcome.newBase!);
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
