import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sync_core/sync_core.dart';

import 'session.dart';

/// Works out what pushing [localRoot] to the peer would change on the peer's
/// side: fetches the peer's manifest, scans the local copy, and diffs them so
/// the changes describe how to make the *remote* match the local copy. This is
/// the mirror of [planPull] and is what the interactive mode shows before
/// uploading.
Future<ChangeSet> planPush(
  SyncClient client,
  String name,
  Directory localRoot,
) async {
  final remote = await client.fetchManifest(name);
  final local = localRoot.existsSync()
      ? await Manifest.scan(localRoot)
      : Manifest(<String, FileEntry>{});
  return ChangeSet.between(remote, local);
}

/// Carries out a push: for each added or modified file, reads it locally and
/// writes it to the peer; for each deleted file, removes it on the peer.
Future<void> applyPush(
  SyncClient client,
  String name,
  Directory localRoot,
  ChangeSet changes, {
  void Function(int applied, int total)? onProgress,
}) async {
  var applied = 0;
  for (final change in changes.changes) {
    switch (change.kind) {
      case ChangeKind.added:
      case ChangeKind.modified:
        final file =
            File(p.joinAll([localRoot.path, ...p.posix.split(change.path)]));
        await client.putFile(name, change.path, await file.readAsBytes());
      case ChangeKind.deleted:
        await client.deleteFile(name, change.path);
    }
    onProgress?.call(++applied, changes.length);
  }
}
