import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../l10n/gen/app_localizations.dart';

import 'folder_picker_page.dart';

/// Asks the user for a folder, the way this platform does it.
///
/// The phone uses the app's own browser rather than the system picker: the
/// system one hands back a content:// URI, and nothing in the engine can read a
/// path that is not a path. The desktop uses the native chooser. Both need the
/// same handling of "no" and of a platform that cannot ask at all, which is why
/// this is in one place - it is asked for from three screens now.
///
/// Returns null when the user backs out, refuses the storage permission the
/// phone needs, or the platform has no chooser to offer; in the last two cases
/// it says so on screen first.
Future<String?> pickFolder(BuildContext context, {String? confirmLabel}) async {
  final l10n = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);

  if (Platform.isAndroid) {
    if (!await _storageAllowed()) {
      messenger.showSnackBar(
          SnackBar(content: Text(l10n.storageAccessNeeded)));
      return null;
    }
    if (!context.mounted) return null;
    final root = await browseRoot();
    if (!context.mounted) return null;
    return Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => FolderPickerPage(rootPath: root)),
    );
  }

  try {
    return await getDirectoryPath(confirmButtonText: confirmLabel);
  } catch (_) {
    messenger.showSnackBar(
        SnackBar(content: Text(l10n.folderPickingUnavailable)));
    return null;
  }
}

/// All-files access, which is what reading a folder the user picked needs on
/// Android - and it is asked for at the moment a folder is being chosen, never
/// at startup, because until then the app has nothing to read.
///
/// There is no per-folder version of it. Android does have one - the document
/// tree a picker grants - but what it hands back is a `content://` URI, and
/// every part of the engine works in file paths: scanning, hashing, three-way
/// merging and atomic writes all go through dart:io. Making the phone work the
/// other way is a file layer of its own, not a permission flag, and it is
/// written down as such rather than pretended about here.
Future<bool> _storageAllowed() async {
  if (await Permission.manageExternalStorage.isGranted) return true;
  return (await Permission.manageExternalStorage.request()).isGranted;
}

/// The whole of choosing a folder to sync: look where a vault usually is,
/// offer it, and go browsing only if that is not it.
///
/// One call for every place that needs a folder, because the answer has to be
/// the same everywhere and because the choosing is the part people trip over -
/// a browser opened at the root of a phone's storage, for a folder the app
/// could have found itself.
Future<String?> chooseSyncFolder(BuildContext context) async {
  final l10n = AppLocalizations.of(context);

  // The permission first: without it there is nothing to look for and nothing
  // to look at. It is asked for here rather than at startup, when the app has
  // no business reading anything yet.
  if (Platform.isAndroid && !await _storageAllowed()) {
    if (!context.mounted) return null;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(l10n.storageWhyAll),
      duration: const Duration(seconds: 8),
    ));
    return null;
  }
  if (!context.mounted) return null;

  final found = await suggestedVault();
  if (!context.mounted) return null;
  if (found == null) return pickFolder(context);

  final useIt = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.folder_special_outlined),
      title: Text(l10n.obsidianFound(found)),
      content: Text(l10n.obsidianFoundBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.obsidianPickOther),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(l10n.obsidianUse),
        ),
      ],
    ),
  );
  if (useIt == true) return found;
  if (!context.mounted) return null;
  return pickFolder(context);
}

/// Where a vault most likely already is: `Documents/Obsidian`.
///
/// Looked for before asking anyone to go browsing, because on most devices this
/// is the answer, and a file browser opened at the root of a phone's storage is
/// a small chore for something the app could have guessed.
Future<String?> suggestedVault() async {
  final home = Platform.isAndroid
      ? '/storage/emulated/0'
      : Platform.environment['HOME'];
  if (home == null || home.isEmpty) return null;

  for (final candidate in ['$home/Documents/Obsidian', '$home/Obsidian']) {
    try {
      if (Directory(candidate).existsSync()) return candidate;
    } catch (_) {
      // Not readable without the permission, which the caller asks for first.
    }
  }
  return null;
}

/// Where the browser should open when there is nothing to suggest: the
/// documents folder if there is one, the top of storage otherwise.
Future<String> browseRoot() async {
  final home =
      Platform.isAndroid ? '/storage/emulated/0' : Platform.environment['HOME'];
  if (home == null || home.isEmpty) return '/';
  final documents = Directory('$home/Documents');
  return documents.existsSync() ? documents.path : home;
}
