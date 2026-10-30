import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:sync_net/sync_net.dart';

import '../l10n/gen/app_localizations.dart';

import 'folder_picker_page.dart';
import 'layout.dart';
import 'storage.dart';

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

/// Everything that has to be true before a sync can do anything, checked when
/// the app opens and put in front of the user when it is not.
///
/// Two things, and they fail in the same silent way. Without Android's file
/// access every folder reads as empty, and an empty folder is a legitimate
/// thing to sync - so the app would sit there reporting "nothing to do" over a
/// vault it simply cannot see. And a folder that really is empty is worth
/// asking about too: it is either a device waiting for its first sync or the
/// wrong folder, and the second is how a vault gets emptied on the other
/// device.
///
/// Asked once per launch, and always answerable with "not now": the folder may
/// legitimately be empty on a device that has never synced.
Future<void> ensureStorageReady(
  BuildContext context,
  SharedFolders folders,
) async {
  if (!await ensureFileAccess(context)) return;
  if (!context.mounted) return;

  final folder = folders.folder;
  if (folder != null) {
    final size = await Manifest.measure(Directory(folder.path));
    if (!size.isEmpty) return; // there is a vault here; nothing to ask about
  }
  if (!context.mounted) return;

  final l10n = AppLocalizations.of(context);
  final choose = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: Icon(folder == null
          ? Icons.create_new_folder_outlined
          : Icons.folder_off_outlined),
      title: Text(folder == null
          ? l10n.storageNoneTitle
          : l10n.storageEmptyTitle),
      content: Text(folder == null
          ? l10n.syncFolderNoneBody
          : l10n.storageEmptyBody(folder.name)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.folderAskedLater),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(folder == null
              ? l10n.syncFolderChoose
              : l10n.syncFolderReplace),
        ),
      ],
    ),
  );
  if (choose != true || !context.mounted) return;

  final path = await chooseSyncFolder(context);
  if (path != null) await folders.choose(path);
}

/// Asks for the file access this platform needs, explaining first.
///
/// The explanation is not politeness: what Android shows for this permission is
/// a settings page listing every app on the device, and arriving there without
/// being told why is how people turn round and come back.
///
/// True when there is nothing in the way - always so off Android.
Future<bool> ensureFileAccess(BuildContext context) async {
  if (!Platform.isAndroid) return true;
  if (await Permission.manageExternalStorage.isGranted) return true;
  if (!context.mounted) return false;

  final l10n = AppLocalizations.of(context);
  final ask = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.folder_shared_outlined),
      title: Text(l10n.storageAccessTitle),
      content: Text(l10n.storageWhyAll),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.folderAskedLater),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(l10n.storageGrant),
        ),
      ],
    ),
  );
  if (ask != true) return false;

  final status = await Permission.manageExternalStorage.request();
  if (status.isGranted) return true;
  if (!context.mounted) return false;

  // Refused for good: the request will not appear again, so the only way back
  // is the settings page, and the app has to say so or it looks broken.
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(l10n.storageRefused),
    duration: const Duration(seconds: 8),
    action: SnackBarAction(
      label: l10n.storageOpenSettings,
      onPressed: openAppSettings,
    ),
  ));
  return false;
}

/// All-files access, which is what reading a folder the user picked needs on
/// Android. Asked for without a word of explanation, so it is only for the
/// paths that have already explained themselves - [ensureFileAccess] is the
/// one that says why first.
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

/// Where a vault most likely already is: `Documents/Obsidian`, if there is
/// anything in it.
///
/// Looked for before asking anyone to go browsing, because on most devices this
/// is the answer, and a file browser opened at the root of a phone's storage is
/// a small chore for something the app could have guessed.
///
/// An empty one is not offered. Obsidian leaves the folder behind when a vault
/// is moved or deleted, and suggesting that shell is worse than suggesting
/// nothing: it is the answer people accept without looking, and it syncs
/// nothing while looking exactly like it worked.
Future<String?> suggestedVault() async {
  final home = Platform.isAndroid ? '/storage/emulated/0' : userHome();
  if (home == null || home.isEmpty) return null;

  final candidates = [
    for (final documents in _documentFolders(home)) p.join(documents, 'Obsidian'),
    p.join(home, 'Obsidian'),
  ];
  for (final candidate in candidates) {
    try {
      final directory = Directory(candidate);
      if (!directory.existsSync()) continue;
      if ((await Manifest.measure(directory)).isEmpty) continue;
      return candidate;
    } catch (_) {
      // Not readable without the permission, which the caller asks for first.
    }
  }
  return null;
}

/// Where the browser should open when there is nothing to suggest: the
/// documents folder if there is one, the top of storage otherwise.
Future<String> browseRoot() async {
  final home = Platform.isAndroid ? '/storage/emulated/0' : userHome();
  if (home == null || home.isEmpty) return p.rootPrefix(Directory.current.path);
  for (final documents in _documentFolders(home)) {
    if (Directory(documents).existsSync()) return documents;
  }
  return home;
}

/// Where this user's documents may be, most likely first.
///
/// Windows moves the documents folder into OneDrive when OneDrive is set up to
/// back it up, and there it may carry the system's language in its name. The
/// environment says where OneDrive is; looking in both places is cheaper than
/// asking the shell, and an absent folder is simply passed over.
List<String> _documentFolders(String home) {
  final oneDrive = Platform.isWindows ? Platform.environment['OneDrive'] : null;
  return [
    p.join(home, 'Documents'),
    if (oneDrive != null && oneDrive.isNotEmpty) ...[
      p.join(oneDrive, 'Documents'),
      p.join(oneDrive, 'Документы'),
    ],
  ];
}
