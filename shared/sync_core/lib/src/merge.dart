import 'file_entry.dart';
import 'manifest.dart';

/// What should happen to one file when reconciling two devices.
enum MergeKind {
  /// Changed on the remote only (since the last agreed state): bring it here.
  pullToLocal,

  /// Changed on this device only: send it to the remote.
  pushToRemote,

  /// Changed on both sides in different ways: the user must choose.
  conflict,
}

/// One file's place in a reconciliation. [base], [local] and [remote] are its
/// entry in the last agreed manifest, the current local manifest and the
/// current remote manifest respectively; any may be null (absent on that side).
class MergeItem {
  const MergeItem({
    required this.path,
    required this.kind,
    this.base,
    this.local,
    this.remote,
  });

  final String path;
  final MergeKind kind;
  final FileEntry? base;
  final FileEntry? local;
  final FileEntry? remote;
}

/// The outcome of a three-way comparison: every file that differs between the
/// two devices, each classified as a one-way change or a conflict.
class MergeResult {
  MergeResult(this.items);

  final List<MergeItem> items;

  bool get isEmpty => items.isEmpty;
  int get length => items.length;

  Iterable<MergeItem> get pulls =>
      items.where((i) => i.kind == MergeKind.pullToLocal);
  Iterable<MergeItem> get pushes =>
      items.where((i) => i.kind == MergeKind.pushToRemote);
  Iterable<MergeItem> get conflicts =>
      items.where((i) => i.kind == MergeKind.conflict);

  bool get hasConflicts => items.any((i) => i.kind == MergeKind.conflict);
}

/// Reconciles two manifests against their last agreed common state.
///
/// [base] is the manifest both sides agreed on at the previous sync (empty on a
/// first sync). Comparing each side to [base] is what distinguishes "changed
/// here" from "changed there": a file that moved away from [base] on one side
/// only should propagate to the other, while a file that moved on both sides
/// (to different contents) is a conflict the user resolves.
///
/// Files identical on both sides are left out, even if their timestamps differ,
/// because identity is the content hash.
MergeResult threeWayMerge(Manifest base, Manifest local, Manifest remote) {
  final paths = <String>{
    ...base.entries.keys,
    ...local.entries.keys,
    ...remote.entries.keys,
  };

  final items = <MergeItem>[];
  for (final path in paths) {
    final b = base.entries[path];
    final l = local.entries[path];
    final r = remote.entries[path];

    if (l?.hash == r?.hash) continue; // already in sync (or both absent)

    final localChanged = l?.hash != b?.hash;
    final remoteChanged = r?.hash != b?.hash;

    final MergeKind kind;
    if (localChanged && remoteChanged) {
      kind = MergeKind.conflict;
    } else if (localChanged) {
      kind = MergeKind.pushToRemote;
    } else {
      kind = MergeKind.pullToLocal;
    }

    items.add(MergeItem(path: path, kind: kind, base: b, local: l, remote: r));
  }

  items.sort((a, b) => a.path.compareTo(b.path));
  return MergeResult(items);
}
