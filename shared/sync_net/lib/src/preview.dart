import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sync_core/sync_core.dart';

import 'reconcile.dart';
import 'session.dart';

/// What a sync will do to one file.
enum PreviewKind {
  /// The file does not exist on the target yet.
  create,

  /// The file exists on the target and its contents change.
  update,

  /// The file goes away on the target.
  delete,

  /// Both sides edited it; the edits were combined and both get the result.
  merged,

  /// Both sides edited the same lines and it still needs settling.
  conflict,
}

/// Which device a change lands on.
enum PreviewSide { here, there, both }

/// One file's entry in the preview, with the line-level detail behind it.
class FilePreview {
  const FilePreview({
    required this.item,
    required this.kind,
    required this.side,
    this.lines = const [],
    this.conflict,
  });

  /// The change this stands for, so the screen showing it can turn the user's
  /// decision straight back into something applyMerge understands.
  final MergeItem item;

  String get path => item.path;
  final PreviewKind kind;
  final PreviewSide side;

  /// The line-by-line change that will be written, ready to show as a diff.
  /// Empty when there is nothing readable to show (binary, or a plain delete).
  final List<DiffLine> lines;

  /// Set for [PreviewKind.conflict]: the merge whose hunks still need a choice.
  final MergedConflict? conflict;

  int get added => lines.where((l) => l.op == DiffOp.insert).length;
  int get removed => lines.where((l) => l.op == DiffOp.delete).length;
}

/// Folders that appear or disappear as a result of the file changes.
///
/// Manifests list only files, so a new folder is implied by a new file inside
/// it, and a folder goes away when the last file under it does. Working that
/// out here is what lets the preview say "this folder will be created" rather
/// than leaving the user to infer it from paths.
class FolderPreview {
  const FolderPreview(this.path, {required this.created, required this.side});
  final String path;
  final bool created;
  final PreviewSide side;
}

/// Everything a sync is about to do, ready to be shown before anything is
/// written.
class SyncPreview {
  const SyncPreview({required this.files, required this.folders});

  final List<FilePreview> files;
  final List<FolderPreview> folders;

  bool get isEmpty => files.isEmpty;
  Iterable<FilePreview> get conflicts =>
      files.where((f) => f.kind == PreviewKind.conflict);
  bool get hasConflicts => conflicts.isNotEmpty;
}

/// Builds the preview for [merge], fetching what it needs to show real line
/// changes rather than just file names.
///
/// This does pull the remote side of every changed file, which is the same data
/// the sync would move anyway; it just moves it before the user commits rather
/// than after.
Future<SyncPreview> buildPreview(
  SyncClient client,
  String name,
  Directory localRoot,
  MergeResult merge,
) async {
  final files = <FilePreview>[];

  for (final item in merge.items) {
    files.add(switch (item.kind) {
      MergeKind.pullToLocal =>
        await _oneWay(client, name, localRoot, item, toLocal: true),
      MergeKind.pushToRemote =>
        await _oneWay(client, name, localRoot, item, toLocal: false),
      MergeKind.conflict => await _conflict(client, name, localRoot, item),
    });
  }

  return SyncPreview(files: files, folders: _folders(files, localRoot));
}

Future<FilePreview> _oneWay(
  SyncClient client,
  String name,
  Directory localRoot,
  MergeItem item, {
  required bool toLocal,
}) async {
  final side = toLocal ? PreviewSide.here : PreviewSide.there;
  final incoming = toLocal ? item.remote : item.local;
  final existing = toLocal ? item.local : item.remote;

  if (incoming == null) {
    return FilePreview(item: item, kind: PreviewKind.delete, side: side);
  }

  final newBytes = toLocal
      ? await client.fetchFile(name, item.path)
      : await _localFile(localRoot, item.path).readAsBytes();

  // Binary, or too big to line up: say what happens without pretending to show
  // lines that would be meaningless.
  if (!isMergeableText(newBytes)) {
    return FilePreview(
      item: item,
      kind: existing == null ? PreviewKind.create : PreviewKind.update,
      side: side,
    );
  }

  var oldLines = <String>[];
  if (existing != null) {
    final oldBytes = toLocal
        ? await _localFile(localRoot, item.path).readAsBytes()
        : await client.fetchFile(name, item.path);
    if (isMergeableText(oldBytes)) oldLines = splitLines(utf8.decode(oldBytes));
  }

  return FilePreview(
    item: item,
    kind: existing == null ? PreviewKind.create : PreviewKind.update,
    side: side,
    lines: diffLines(oldLines, splitLines(utf8.decode(newBytes))),
  );
}

Future<FilePreview> _conflict(
  SyncClient client,
  String name,
  Directory localRoot,
  MergeItem item,
) async {
  final merged = await mergeConflict(client, name, localRoot, item);

  if (merged.isClean) {
    // Settled by merging: both devices end up with the combined text, so show
    // what each of them gains against what it has now.
    return FilePreview(
      item: item,
      kind: PreviewKind.merged,
      side: PreviewSide.both,
      lines: diffLines(merged.ourLines, merged.merge!.clean!),
      conflict: merged,
    );
  }

  return FilePreview(
    item: item,
    kind: PreviewKind.conflict,
    side: PreviewSide.both,
    conflict: merged,
  );
}

/// Derives the folders implied by the file changes.
List<FolderPreview> _folders(List<FilePreview> files, Directory localRoot) {
  final created = <String, PreviewSide>{};
  final removed = <String, PreviewSide>{};

  for (final file in files) {
    for (final folder in _parents(file.path)) {
      switch (file.kind) {
        case PreviewKind.create:
          // Only a folder that is not already here is really being created.
          if (file.side == PreviewSide.here &&
              Directory(p.joinAll([localRoot.path, ...p.posix.split(folder)]))
                  .existsSync()) {
            continue;
          }
          created[folder] = file.side;
        case PreviewKind.delete:
          removed.putIfAbsent(folder, () => file.side);
        case _:
          break;
      }
    }
  }

  // A folder losing one file is only gone if it is not keeping another.
  final surviving = files
      .where((f) => f.kind != PreviewKind.delete)
      .expand((f) => _parents(f.path))
      .toSet();
  removed.removeWhere((folder, _) => surviving.contains(folder));

  return [
    for (final entry in created.entries)
      FolderPreview(entry.key, created: true, side: entry.value),
    for (final entry in removed.entries)
      FolderPreview(entry.key, created: false, side: entry.value),
  ]..sort((a, b) => a.path.compareTo(b.path));
}

/// Every folder along a file's path, e.g. "a/b/note.md" -> ["a", "a/b"].
Iterable<String> _parents(String path) sync* {
  final parts = p.posix.split(path);
  for (var i = 1; i < parts.length; i++) {
    yield parts.take(i).join('/');
  }
}

File _localFile(Directory root, String path) =>
    File(p.joinAll([root.path, ...p.posix.split(path)]));
