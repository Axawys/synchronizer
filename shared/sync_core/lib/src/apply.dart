import 'dart:io';

import 'package:path/path.dart' as p;

import 'diff.dart';

/// Applies a [ChangeSet] to [root] on disk, bringing this copy in line with the
/// side the changes came from.
///
/// For an added or modified file the bytes are pulled through [fetchBody]
/// (which the caller wires to the network, or to anything in tests) and written
/// atomically: into a temporary file first, then renamed over the target, so an
/// interrupted transfer never leaves a half-written file in the vault. Deleted
/// files are removed. Parent directories are created as needed.
///
/// [onProgress] is called after each change is applied, with the running count,
/// so the UI can show progress.
Future<void> applyChanges(
  Directory root,
  ChangeSet changes,
  Future<List<int>> Function(String path) fetchBody, {
  void Function(int applied, int total)? onProgress,
}) async {
  var applied = 0;
  for (final change in changes.changes) {
    final target = File(p.joinAll([root.path, ...p.posix.split(change.path)]));

    switch (change.kind) {
      case ChangeKind.added:
      case ChangeKind.modified:
        final bytes = await fetchBody(change.path);
        await target.parent.create(recursive: true);
        final temp = File('${target.path}.synctmp');
        await temp.writeAsBytes(bytes, flush: true);
        await temp.rename(target.path);
      case ChangeKind.deleted:
        if (target.existsSync()) await target.delete();
        await removeEmptyParents(target.path, root.path);
    }

    onProgress?.call(++applied, changes.length);
  }
}

/// After a file is removed, deletes the directories that just became empty, up
/// to but never including [rootPath].
///
/// A manifest only lists files, so deleting a folder reaches the other device
/// as the deletion of the files inside it. Without this, the folder itself
/// would linger there as an empty husk; with it, removing a folder on one
/// device removes it on the other.
Future<void> removeEmptyParents(String filePath, String rootPath) async {
  final root = p.normalize(p.absolute(rootPath));
  var dir = Directory(p.dirname(p.normalize(p.absolute(filePath))));

  while (p.isWithin(root, dir.path)) {
    if (!dir.existsSync()) {
      dir = dir.parent;
      continue;
    }
    if (dir.listSync().isNotEmpty) break;
    try {
      await dir.delete();
    } on FileSystemException {
      break; // Busy or not ours to remove; leave it be.
    }
    dir = dir.parent;
  }
}
