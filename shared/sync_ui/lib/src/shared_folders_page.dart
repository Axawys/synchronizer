import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';

import 'storage.dart';

/// Lets the user choose which local folders this device offers to paired peers.
/// Picking a folder uses the native directory chooser (desktop); on a phone,
/// sharing outward is a later concern, so the picker may be unavailable.
class SharedFoldersPage extends StatefulWidget {
  const SharedFoldersPage({super.key, required this.folders});

  final SharedFolders folders;

  @override
  State<SharedFoldersPage> createState() => _SharedFoldersPageState();
}

class _SharedFoldersPageState extends State<SharedFoldersPage> {
  Future<void> _add() async {
    String? path;
    try {
      path = await getDirectoryPath();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content:
                  Text(AppLocalizations.of(context).folderPickingUnavailable)),
        );
      }
      return;
    }
    if (path != null) await widget.folders.addPath(path);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.sharedFoldersTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.create_new_folder),
        label: Text(l10n.shareAFolder),
      ),
      body: ListenableBuilder(
        listenable: widget.folders,
        builder: (context, _) {
          final folders = widget.folders.folders;
          if (folders.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  l10n.noFoldersShared,
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.separated(
            itemCount: folders.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final folder = folders[i];
              return ListTile(
                leading: const Icon(Icons.folder),
                title: Text(folder.name),
                subtitle: Text(folder.path),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => widget.folders.remove(folder.name),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
