import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sync_core/sync_core.dart';

import 'session.dart';

/// A [MergeItem] together with how it will be applied.
///
/// Most items just move one way. A conflict that was merged instead carries
/// [content]: the combined text, which goes to *both* devices, so neither side
/// loses its edits.
class ResolvedMerge {
  const ResolvedMerge(this.item, {required this.toLocal, this.content});

  final MergeItem item;

  /// True to bring the remote's version here (pull); false to send this
  /// device's version to the remote (push). Ignored when [content] is set.
  final bool toLocal;

  /// Merged text to write to both sides, or null to just move one side's
  /// version across.
  final List<int>? content;

  bool get isMerged => content != null;

  /// The natural resolution for a non-conflict item.
  factory ResolvedMerge.natural(MergeItem item) =>
      ResolvedMerge(item, toLocal: item.kind == MergeKind.pullToLocal);

  /// A conflict settled by combining both sides.
  factory ResolvedMerge.merged(MergeItem item, List<String> lines) =>
      ResolvedMerge(item,
          toLocal: true, content: utf8.encode(joinLines(lines)));
}

/// A conflicting file with the three-way merge already worked out.
class MergedConflict {
  const MergedConflict({
    required this.item,
    this.merge,
    this.ourLines = const [],
    this.theirLines = const [],
    this.ancestorKnown = true,
  });

  final MergeItem item;

  /// The merge, or null when the file cannot be merged at all: it is binary,
  /// too large, or one side deleted it. Those still have to be settled by
  /// choosing a side outright.
  final TextMergeResult? merge;

  final List<String> ourLines;
  final List<String> theirLines;

  /// False when no copy from a previous sync existed and the merge was worked
  /// out by comparing the two versions alone. The result is still worth
  /// showing, but a line one device deleted can reappear, so the user should be
  /// told which kind of merge this is.
  final bool ancestorKnown;

  bool get isMergeable => merge != null;

  /// True when merging settled everything and nothing needs asking.
  bool get isClean => merge != null && !merge!.hasConflicts;
}

/// Works out the merge for one conflicting file.
///
/// Both sides must still have the file and both must be mergeable text;
/// otherwise there is nothing to line up and the caller has to ask for a side.
///
/// A base copy from the last sync is what makes this a true three-way merge.
/// Without one - the first sync of a folder both devices already had - the
/// lines the two versions share stand in for the ancestor, which still merges
/// the parts that differ instead of throwing the whole file at the user. That
/// case is flagged with [MergedConflict.ancestorKnown] rather than passed off
/// as the real thing.
Future<MergedConflict> mergeConflict(
  SyncClient client,
  String name,
  Directory localRoot,
  MergeItem item,
) async {
  if (item.local == null || item.remote == null) {
    return MergedConflict(item: item); // an edit against a delete
  }

  final localBytes = await _localFile(localRoot, item.path).readAsBytes();
  final remoteBytes = await client.fetchFile(name, item.path);
  if (!isMergeableText(localBytes) || !isMergeableText(remoteBytes)) {
    return MergedConflict(item: item);
  }

  final ourLines = splitLines(utf8.decode(localBytes));
  final theirLines = splitLines(utf8.decode(remoteBytes));

  final baseText = await BaseStore(localRoot).read(item.path);
  final known = baseText != null;
  final base =
      known ? splitLines(baseText) : commonBase(ourLines, theirLines);

  return MergedConflict(
    item: item,
    merge: merge3(base, ourLines, theirLines),
    ourLines: ourLines,
    theirLines: theirLines,
    ancestorKnown: known,
  );
}

/// Brings the base copies in line with what the two devices have just agreed
/// on, so the next sync has an ancestor to merge against.
///
/// Only files whose content actually moved are rewritten - comparing the old
/// base manifest with the new one is what identifies them - so this costs a
/// full pass over the folder only on a first sync.
Future<void> refreshBaseStore(
  Directory localRoot,
  Manifest previousBase,
  Manifest current,
) async {
  final store = BaseStore(localRoot);

  for (final entry in current.entries.values) {
    if (previousBase.entries[entry.path]?.hash == entry.hash &&
        store.fileFor(entry.path).existsSync()) {
      continue; // unchanged and already kept
    }
    final file = _localFile(localRoot, entry.path);
    if (file.existsSync()) {
      await store.write(entry.path, await file.readAsBytes());
    }
  }

  for (final path in previousBase.entries.keys) {
    if (!current.entries.containsKey(path)) await store.remove(path);
  }
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
      final merged = r.content;
      if (merged != null) {
        // A merged file is the same on both sides now, so it goes both ways.
        await _writeLocal(localRoot, item.path, merged);
        await client.putFile(name, item.path, merged);
      } else if (r.toLocal) {
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

/// What a whole sync did, and what the caller should now remember.
///
/// [newBase] is the manifest to record as the agreed ancestor, or null if the
/// sync did not finish and the old one must be kept.
class SyncOutcome {
  const SyncOutcome({required this.report, required this.newBase});

  final MergeReport report;
  final Manifest? newBase;
}

/// Applies [resolved] and, if every file made it, brings the recorded ancestor
/// up to date: both the manifest and the base copies of the text.
///
/// This exists so callers cannot do half of it. The two records only mean
/// something together - the manifest says a file changed, the text says what it
/// changed from - and a sync that saved one without the other would leave every
/// later conflict with nothing to merge against. Nothing but a finished sync may
/// move the ancestor either, since a half-applied one leaves the devices out of
/// step and the old base is what still tells their edits apart.
Future<SyncOutcome> runSync(
  SyncClient client,
  String name,
  Directory localRoot,
  Manifest base,
  List<ResolvedMerge> resolved, {
  void Function(int done, int total)? onProgress,
}) async {
  final report =
      await applyMerge(client, name, localRoot, resolved, onProgress: onProgress);
  if (!report.ok) return SyncOutcome(report: report, newBase: null);

  final current = await Manifest.scan(localRoot);
  await refreshBaseStore(localRoot, base, current);
  return SyncOutcome(report: report, newBase: current);
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
  // Drop folders emptied by the deletion, so a folder removed on the other
  // device disappears here too rather than lingering empty.
  await removeEmptyParents(file.path, root.path);
}
