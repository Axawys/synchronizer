import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sync_core/sync_core.dart';

import 'session.dart';

/// A [MergeItem] together with the direction it will be applied. Non-conflict
/// items take the direction implied by their kind; a conflict must be resolved
/// to one direction before it can be applied.
class ResolvedMerge {
  const ResolvedMerge(this.item, {required this.toLocal});

  final MergeItem item;

  /// True to bring the remote's version here (pull); false to send this
  /// device's version to the remote (push).
  final bool toLocal;

  /// The natural resolution for a non-conflict item.
  factory ResolvedMerge.natural(MergeItem item) =>
      ResolvedMerge(item, toLocal: item.kind == MergeKind.pullToLocal);
}

/// Fetches the peer's manifest, scans the local copy, and reconciles both
/// against [base] (the last agreed manifest, empty on a first sync).
Future<MergeResult> computeMerge(
  SyncClient client,
  String name,
  Directory localRoot,
  Manifest base,
) async {
  final remote = await client.fetchManifest(name);
  final local = localRoot.existsSync()
      ? await Manifest.scan(localRoot)
      : Manifest(<String, FileEntry>{});
  return threeWayMerge(base, local, remote);
}

/// A reasonable automatic resolution for a conflict: whichever side was
/// modified more recently wins. Used by the plain (non-interactive) mode, where
/// there is no one to ask. A missing side (a delete) is treated as older, so an
/// edit beats a delete.
bool conflictResolvesToLocal(MergeItem item) {
  final localTime = item.local?.modified;
  final remoteTime = item.remote?.modified;
  if (remoteTime == null) return false; // remote deleted -> keep local (push)
  if (localTime == null) return true; // local deleted -> take remote (pull)
  return remoteTime.isAfter(localTime); // newer wins
}

/// Applies the [resolved] items, streaming files each way over the session.
/// After it returns, the reconciled files match on both devices, so the caller
/// can record the new local manifest as the next [base].
Future<void> applyMerge(
  SyncClient client,
  String name,
  Directory localRoot,
  List<ResolvedMerge> resolved, {
  void Function(int applied, int total)? onProgress,
}) async {
  await localRoot.create(recursive: true);

  var applied = 0;
  for (final r in resolved) {
    final item = r.item;
    if (r.toLocal) {
      // Bring the remote's version here.
      if (item.remote == null) {
        await _deleteLocal(localRoot, item.path);
      } else {
        final bytes = await client.fetchFile(name, item.path);
        await _writeLocal(localRoot, item.path, bytes);
      }
    } else {
      // Send this device's version to the remote.
      if (item.local == null) {
        await client.deleteFile(name, item.path);
      } else {
        final bytes = await _readLocal(localRoot, item.path);
        await client.putFile(name, item.path, bytes);
      }
    }
    onProgress?.call(++applied, resolved.length);
  }
}

File _localFile(Directory root, String path) =>
    File(p.joinAll([root.path, ...p.posix.split(path)]));

Future<void> _writeLocal(Directory root, String path, List<int> bytes) async {
  final file = _localFile(root, path);
  await file.parent.create(recursive: true);
  final temp = File('${file.path}.synctmp');
  await temp.writeAsBytes(bytes, flush: true);
  await temp.rename(file.path);
}

Future<List<int>> _readLocal(Directory root, String path) =>
    _localFile(root, path).readAsBytes();

Future<void> _deleteLocal(Directory root, String path) async {
  final file = _localFile(root, path);
  if (file.existsSync()) await file.delete();
}
