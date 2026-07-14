import 'dart:io';

import 'package:sync_core/sync_core.dart';

import 'session.dart';

/// Works out what pulling [name] from the peer would change locally: scans
/// [localRoot] (treated as empty if it does not exist yet, as on a first sync),
/// fetches the peer's manifest, and diffs them. The result is exactly what the
/// interactive mode shows the user before anything is written.
Future<ChangeSet> planPull(
  SyncClient client,
  String name,
  Directory localRoot,
) async {
  final local = localRoot.existsSync()
      ? await Manifest.scan(localRoot)
      : Manifest(<String, FileEntry>{});
  final remote = await client.fetchManifest(name);
  return ChangeSet.between(local, remote);
}

/// Carries out a plan: applies [changes] to [localRoot], streaming each added or
/// modified file from the peer. Safe to call after the user has confirmed (or
/// straight away, in the plain apply mode).
Future<void> applyPull(
  SyncClient client,
  String name,
  Directory localRoot,
  ChangeSet changes, {
  void Function(int applied, int total)? onProgress,
}) async {
  await localRoot.create(recursive: true);
  await applyChanges(
    localRoot,
    changes,
    (path) => client.fetchFile(name, path),
    onProgress: onProgress,
  );
}
