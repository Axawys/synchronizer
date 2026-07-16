import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Files above this are not kept as a base copy. Merging is a line-by-line
/// affair, so it only ever applies to human-sized text; the limit stops a large
/// attachment from doubling in size on disk for nothing.
const int kMaxBaseBytes = 2 * 1024 * 1024;

/// Keeps a copy of each file as it stood at the last sync: the common ancestor
/// a three-way merge needs.
///
/// The base manifest records only hashes, which say *that* a file changed but
/// not what it used to say. Without the old text there is nothing to merge
/// against and every difference would look like a conflict, so the text itself
/// has to be kept.
///
/// Copies live in `.synchronizer/base` inside the synced folder, mirroring its
/// layout. A leading dot keeps the folder out of manifests (scanning skips
/// dotted segments), so the store never syncs itself — the same trick `.git`
/// relies on. Only text within [kMaxBaseBytes] is stored, since nothing else
/// can be merged anyway.
class BaseStore {
  BaseStore(this.root);

  final Directory root;

  Directory get directory =>
      Directory(p.join(root.path, '.synchronizer', 'base'));

  File fileFor(String path) =>
      File(p.joinAll([directory.path, ...p.posix.split(path)]));

  /// The file's text as of the last sync, or null if no base was kept (never
  /// synced, too large, or not text). A null result means a conflict on this
  /// file cannot be merged and has to be settled by choosing a side.
  Future<String?> read(String path) async {
    final file = fileFor(path);
    if (!file.existsSync()) return null;
    try {
      return utf8.decode(await file.readAsBytes());
    } on FormatException {
      return null;
    }
  }

  /// Records [bytes] as the agreed content of [path]. Silently skips anything
  /// unmergeable, so callers can hand it every file without checking first.
  Future<void> write(String path, List<int> bytes) async {
    if (!isMergeableText(bytes)) return;
    final file = fileFor(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  Future<void> remove(String path) async {
    final file = fileFor(path);
    if (file.existsSync()) await file.delete();
  }

  /// Drops the whole store, for when a folder stops being synced.
  Future<void> clear() async {
    final dir = directory;
    if (dir.existsSync()) await dir.delete(recursive: true);
  }
}

/// Whether [bytes] look like text this app is willing to merge.
///
/// Valid UTF-8 with no NUL byte: the NUL check is what separates real text from
/// binary that happens to decode, and matches how other tools guess.
bool isMergeableText(List<int> bytes) {
  if (bytes.length > kMaxBaseBytes) return false;
  if (bytes.contains(0)) return false;
  try {
    utf8.decode(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
    return true;
  } on FormatException {
    return false;
  }
}
