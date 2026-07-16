import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../l10n/gen/app_localizations.dart';

/// A minimal folder browser for Android, where there is no built-in directory
/// picker we can rely on. It walks real storage with `dart:io` (which needs
/// all-files access, requested before this opens), lets the user step into
/// folders, make a new one, and select the current folder as the destination.
///
/// Returns the chosen absolute path via [Navigator.pop], or null if cancelled.
class FolderPickerPage extends StatefulWidget {
  const FolderPickerPage({super.key, required this.rootPath});

  /// The floor the user cannot navigate above (typically primary storage).
  final String rootPath;

  @override
  State<FolderPickerPage> createState() => _FolderPickerPageState();
}

class _FolderPickerPageState extends State<FolderPickerPage> {
  late Directory _current;

  @override
  void initState() {
    super.initState();
    _current = Directory(widget.rootPath);
  }

  List<Directory> _subdirs() {
    try {
      final dirs = _current
          .listSync()
          .whereType<Directory>()
          .where((d) => !p.basename(d.path).startsWith('.'))
          .toList()
        ..sort((a, b) => p.basename(a.path)
            .toLowerCase()
            .compareTo(p.basename(b.path).toLowerCase()));
      return dirs;
    } on FileSystemException {
      return const [];
    }
  }

  bool get _atRoot => p.equals(_current.path, widget.rootPath);

  void _open(Directory dir) => setState(() => _current = dir);

  void _up() {
    if (!_atRoot) setState(() => _current = _current.parent);
  }

  Future<void> _newFolder() async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => const _NewFolderDialog(),
    );
    if (name == null || name.isEmpty) return;
    final created = Directory(p.join(_current.path, name));
    try {
      await created.create();
      _open(created);
    } on FileSystemException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context)
                .couldNotCreateFolder(e.message))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final subdirs = _subdirs();
    return Scaffold(
      appBar: AppBar(
        leading: _atRoot
            ? null
            : IconButton(icon: const Icon(Icons.arrow_upward), onPressed: _up),
        title: Text(l10n.chooseFolder),
        actions: [
          IconButton(
            icon: const Icon(Icons.create_new_folder),
            tooltip: l10n.newFolder,
            onPressed: _newFolder,
          ),
        ],
      ),
      persistentFooterButtons: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: FilledButton.icon(
            icon: const Icon(Icons.check),
            label: Text(l10n.useThisFolder),
            onPressed: () => Navigator.pop(context, _current.path),
          ),
        ),
      ],
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Text(_current.path,
                style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(
            child: subdirs.isEmpty
                ? Center(child: Text(l10n.noSubFolders))
                : ListView.separated(
                    itemCount: subdirs.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final dir = subdirs[i];
                      return ListTile(
                        leading: const Icon(Icons.folder),
                        title: Text(p.basename(dir.path)),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _open(dir),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _NewFolderDialog extends StatefulWidget {
  const _NewFolderDialog();

  @override
  State<_NewFolderDialog> createState() => _NewFolderDialogState();
}

class _NewFolderDialogState extends State<_NewFolderDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.newFolder),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(hintText: l10n.folderName),
        onSubmitted: (value) => Navigator.pop(context, value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: Text(l10n.create),
        ),
      ],
    );
  }
}
