import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sync_net/sync_net.dart';

import 'folder_picker_page.dart';
import 'storage.dart';

/// Which way a sync moves files. Pull brings the peer's copy down to this
/// device; push sends this device's copy up to the peer.
enum SyncDirection { pull, push }

/// Screen for a paired device: connects a session, lists the folders it shares,
/// and syncs a chosen folder down to this device.
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
  /// the first time. The chosen folder is the sync target itself: files land
  /// directly in it, so the user picks (or makes) the folder they want.
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

  Future<void> _sync(String name, SyncDirection direction) async {
    final client = _client;
    if (client == null) return;

    final localPath = await _resolveTarget(name);
    if (localPath == null || !mounted) return;
    final root = Directory(localPath);

    final ChangeSet plan;
    try {
      plan = direction == SyncDirection.pull
          ? await planPull(client, name, root)
          : await planPush(client, name, root);
    } catch (e) {
      _toast('Could not read changes: $e');
      return;
    }

    if (plan.isEmpty) {
      _toast('"$name" is already up to date.');
      return;
    }

    final light = await SyncSettings.lightMode();
    if (!light) {
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) =>
            _DiffDialog(name: name, plan: plan, direction: direction),
      );
      if (confirmed != true) return;
    }

    await _apply(client, name, root, plan, direction);
  }

  Future<void> _apply(SyncClient client, String name, Directory root,
      ChangeSet plan, SyncDirection direction) async {
    final progress = ValueNotifier<int>(0);
    if (mounted) {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => _ApplyingDialog(total: plan.length, applied: progress),
      );
    }
    try {
      if (direction == SyncDirection.pull) {
        await applyPull(client, name, root, plan,
            onProgress: (applied, _) => progress.value = applied);
      } else {
        await applyPush(client, name, root, plan,
            onProgress: (applied, _) => progress.value = applied);
      }
      if (mounted) Navigator.of(context).pop(); // close applying dialog
      final verb = direction == SyncDirection.pull ? 'Downloaded' : 'Uploaded';
      _toast('$verb ${plan.length} change(s) for "$name".');
    } catch (e) {
      if (mounted) Navigator.of(context).pop();
      _toast('Sync failed: $e');
    } finally {
      progress.dispose();
    }
  }

  // Lets the user choose whether to pull the folder down or push it up.
  Future<void> _chooseDirection(String name) async {
    final direction = await showModalBottomSheet<SyncDirection>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.download),
              title: Text('Get "$name" from ${widget.device.name}'),
              subtitle: const Text('Apply their changes to this device'),
              onTap: () => Navigator.pop(context, SyncDirection.pull),
            ),
            ListTile(
              leading: const Icon(Icons.upload),
              title: Text('Send "$name" to ${widget.device.name}'),
              subtitle: const Text('Apply this device\'s changes to theirs'),
              onTap: () => Navigator.pop(context, SyncDirection.push),
            ),
          ],
        ),
      ),
    );
    if (direction != null) await _sync(name, direction);
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
          onTap: () => _chooseDirection(dir.name),
        );
      },
    );
  }
}

/// Shows what a sync would change, for confirmation before anything is written.
class _DiffDialog extends StatelessWidget {
  const _DiffDialog({
    required this.name,
    required this.plan,
    required this.direction,
  });

  final String name;
  final ChangeSet plan;
  final SyncDirection direction;

  @override
  Widget build(BuildContext context) {
    final where =
        direction == SyncDirection.pull ? 'here' : 'on the other device';
    return AlertDialog(
      title: Text('Changes to "$name" $where'),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(
          shrinkWrap: true,
          children: [
            _section(context, 'New', Icons.add, Colors.green, plan.added),
            _section(context, 'Updated', Icons.edit, Colors.orange, plan.modified),
            _section(context, 'Removed', Icons.remove, Colors.red, plan.deleted),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text('Apply ${plan.length}'),
        ),
      ],
    );
  }

  Widget _section(BuildContext context, String label, IconData icon,
      Color color, Iterable<Change> changes) {
    final list = changes.toList();
    if (list.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Text('$label (${list.length})',
                  style: Theme.of(context).textTheme.titleSmall),
            ],
          ),
        ),
        for (final change in list)
          Padding(
            padding: const EdgeInsets.only(left: 26, bottom: 2),
            child: Text(change.path,
                style: Theme.of(context).textTheme.bodySmall),
          ),
      ],
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
      title: const Text('Applying changes'),
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
