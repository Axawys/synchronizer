import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sync_net/sync_net.dart';

import '../l10n/gen/app_localizations.dart';

import 'folder_choice.dart';
import 'layout.dart';
import 'storage.dart';

/// The folder this device syncs: which one it is, what is in it, and the one
/// thing that can be done to it - point it somewhere else.
///
/// It used to be a list with an "add" button and a bin next to every row. Both
/// were wrong for what people actually do: a vault is one folder, a second one
/// no other device has is nothing but a way to confuse a sync, and "remove"
/// leaves a device that cannot be synced at all until somebody notices. One
/// folder, and the way to change it is to choose the new one.
class SyncFolderPage extends StatefulWidget {
  const SyncFolderPage({super.key, required this.folders});

  final SharedFolders folders;

  @override
  State<SyncFolderPage> createState() => _SyncFolderPageState();
}

class _SyncFolderPageState extends State<SyncFolderPage> {
  /// What the folder weighs, measured when the screen opens.
  ///
  /// The number is the point of the screen as much as the path is: a folder
  /// chosen from the wrong place looks identical to the right one until it says
  /// it has nothing in it, and the device on the other end can only report
  /// "already in sync" about it.
  FolderSize? _size;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<void> _measure() async {
    final folder = widget.folders.folder;
    if (folder == null) {
      if (mounted) setState(() => _size = null);
      return;
    }
    final size = await Manifest.measure(Directory(folder.path));
    if (mounted) setState(() => _size = size);
  }

  /// Chooses the folder, or chooses a different one - the same action either
  /// way, which is why there is one button for it.
  Future<void> _choose() async {
    final path = await chooseSyncFolder(context);
    if (path == null) return;
    await widget.folders.choose(path);
    await _measure();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.syncFolderTitle)),
      body: ListenableBuilder(
        listenable: widget.folders,
        builder: (context, _) {
          final folder = widget.folders.folder;

          return ContentPane(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(Layout.gutter, Layout.gutter,
                  Layout.gutter, Layout.section),
              children: [
                if (folder == null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Layout.gutter),
                    child: Text(
                      l10n.syncFolderNoneBody,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  )
                else ...[
                  AppCard(
                    accented: true,
                    child: Row(
                      children: [
                        const IconBadge(icon: Icons.folder, accented: true),
                        const SizedBox(width: Layout.gap),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                folder.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: Layout.tight),
                              Tooltip(
                                message: folder.path,
                                child: Text(
                                  prettyPath(folder.path),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                      color: colors.onSurfaceVariant),
                                ),
                              ),
                              if (_size != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    formatSize(l10n, _size!.bytes),
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: _size!.isEmpty
                                          ? colors.error
                                          : colors.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: Layout.gutter),
                  Text(
                    l10n.syncFolderOne,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: colors.onSurfaceVariant),
                  ),
                  const SizedBox(height: Layout.gutter),
                ],
                // One button, and it says what it does: with no folder it
                // chooses one, with a folder it puts another in its place.
                FilledButton.icon(
                  onPressed: _choose,
                  icon: Icon(folder == null
                      ? Icons.create_new_folder
                      : Icons.drive_file_move_outline),
                  label: Text(folder == null
                      ? l10n.syncFolderChoose
                      : l10n.syncFolderReplace),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
