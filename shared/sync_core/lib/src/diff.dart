import 'file_entry.dart';
import 'manifest.dart';

/// The kind of change a single file underwent between two manifests.
enum ChangeKind { added, modified, deleted }

/// One reviewable change. This is what the interactive mode renders to the user
/// before anything touches the filesystem, in the same spirit as a diff shown
/// before applying an edit.
class Change {
  const Change({
    required this.kind,
    required this.path,
    this.before,
    this.after,
  });

  final ChangeKind kind;
  final String path;

  /// State on the side that will be overwritten (null when [kind] is added).
  final FileEntry? before;

  /// State on the side that holds the new content (null when [kind] is deleted).
  final FileEntry? after;

  @override
  String toString() => '${kind.name}: $path';
}

/// A two-way comparison: what changed to turn [ChangeSet.base] into
/// [ChangeSet.target].
///
/// This is deliberately a plain two-way diff. Real conflict handling needs the
/// last common manifest as a third input for a three-way merge; that lives in
/// the sync session and is tracked in todo.md. Two-way diffing is enough to
/// drive a one-directional "push these changes" flow, which is the first
/// milestone.
class ChangeSet {
  ChangeSet(this.changes);

  final List<Change> changes;

  bool get isEmpty => changes.isEmpty;
  int get length => changes.length;

  Iterable<Change> get added =>
      changes.where((c) => c.kind == ChangeKind.added);
  Iterable<Change> get modified =>
      changes.where((c) => c.kind == ChangeKind.modified);
  Iterable<Change> get deleted =>
      changes.where((c) => c.kind == ChangeKind.deleted);

  /// Computes the changes needed to bring [base] in line with [target].
  ///
  /// A file present only in [target] is [ChangeKind.added]; present only in
  /// [base] is [ChangeKind.deleted]; present in both with a differing hash is
  /// [ChangeKind.modified]. Identical hashes produce no change, even if the
  /// modification timestamps differ.
  static ChangeSet between(Manifest base, Manifest target) {
    final changes = <Change>[];

    for (final entry in target.entries.values) {
      final existing = base.entries[entry.path];
      if (existing == null) {
        changes.add(Change(kind: ChangeKind.added, path: entry.path, after: entry));
      } else if (existing.hash != entry.hash) {
        changes.add(Change(
          kind: ChangeKind.modified,
          path: entry.path,
          before: existing,
          after: entry,
        ));
      }
    }

    for (final entry in base.entries.values) {
      if (!target.entries.containsKey(entry.path)) {
        changes.add(Change(
          kind: ChangeKind.deleted,
          path: entry.path,
          before: entry,
        ));
      }
    }

    changes.sort((a, b) => a.path.compareTo(b.path));
    return ChangeSet(changes);
  }
}
