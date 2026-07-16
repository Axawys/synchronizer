import 'dart:io';

import 'package:crypto/crypto.dart';
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

/// One file that could not be reconciled, and why.
class MergeFailure {
  const MergeFailure(this.path, this.reason);
  final String path;
  final String reason;

  @override
  String toString() => '$path: $reason';
}

/// The outcome of [applyMerge]. [ok] means every file was reconciled, which is
/// the only case where the caller may record a new agreed base.
class MergeReport {
  const MergeReport({required this.applied, required this.failures});

  /// Files reconciled successfully.
  final int applied;
  final List<MergeFailure> failures;

  bool get ok => failures.isEmpty;
}

/// Applies the [resolved] items, streaming files each way over the session.
///
/// A file that fails (a dropped connection, an unreadable file, a checksum
/// mismatch) does not abort the rest: it is collected in the report and the
/// remaining files are still reconciled. Anything transferred is verified
/// against the hash the sender advertised, so corrupted content never lands.
///
/// Only when [MergeReport.ok] may the caller record the local manifest as the
/// next base: if some files did not make it, the two sides do not agree yet and
/// keeping the older base is what lets the next sync classify them correctly.
Future<MergeReport> applyMerge(
  SyncClient client,
  String name,
  Directory localRoot,
  List<ResolvedMerge> resolved, {
  void Function(int done, int total)? onProgress,
}) async {
  await localRoot.create(recursive: true);

  var applied = 0;
  var done = 0;
  final failures = <MergeFailure>[];

  for (final r in resolved) {
    final item = r.item;
    try {
      if (r.toLocal) {
        // Bring the remote's version here.
        if (item.remote == null) {
          await _deleteLocal(localRoot, item.path);
        } else {
          final bytes = await client.fetchFile(name, item.path);
          final actual = sha256.convert(bytes).toString();
          if (actual != item.remote!.hash) {
            throw const SessionException('content did not match its checksum');
          }
          await _writeLocal(localRoot, item.path, bytes);
        }
      } else {
        // Send this device's version to the remote. putFile sends the hash with
        // it, so the peer rejects a corrupted body.
        if (item.local == null) {
          await client.deleteFile(name, item.path);
        } else {
          await client.putFile(
              name, item.path, await _readLocal(localRoot, item.path));
        }
      }
      applied++;
    } catch (e) {
      failures.add(MergeFailure(item.path, '$e'));
    }
    onProgress?.call(++done, resolved.length);
  }

  return MergeReport(applied: applied, failures: failures);
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
