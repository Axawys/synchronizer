import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Files above this are not kept as a base copy. Merging is a line-by-line
/// affair, so it only ever applies to human-sized text; the limit stops a large
/// attachment from doubling in size on disk for nothing.
const int kMaxBaseBytes = 2 * 1024 * 1024;

/// Keeps the text of each version two devices have agreed on: the common
/// ancestor a three-way merge needs.
///
/// The base manifest records only hashes, which say *that* a file changed but
/// not what it used to say. Without the old text there is nothing to merge
/// against and every difference would look like a conflict, so the text itself
/// has to be kept.
///
/// Kept under its hash, not under its path, and that is the whole design. A
/// folder can be synced with several devices, each of which agreed with this
/// one at a different moment, so there is no single "the" ancestor for a file -
/// there is one per pair. One slot per path meant the last sync to finish
/// overwrote what another pair was still merging against; the merge then read
/// as "only they changed anything" and quietly dropped this side's edits. Under
/// the hash, every ancestor still in use is there to be found, pairs that
/// happen to share one share the file, and the only thing left to get right is
/// throwing away the ones nobody refers to any more.
///
/// Copies live in `.synchronizer/base` inside the synced folder. A leading dot
/// keeps the folder out of manifests (scanning skips dotted segments), so the
/// store never syncs itself - the same trick `.git` relies on. Only text within
/// [kMaxBaseBytes] is stored, since nothing else can be merged anyway.
class BaseStore {
  BaseStore(this.root);

  final Directory root;

  Directory get directory =>
      Directory(p.join(root.path, '.synchronizer', 'base'));

  File fileFor(String hash) => File(p.join(directory.path, hash));

  /// The text both devices last agreed on, given the hash their base manifest
  /// recorded for it. Null when it was never kept, was too large, or is not
  /// text - and then a conflict on that file has to be settled by choosing a
  /// side rather than by merging.
  Future<String?> read(String hash) async {
    final file = fileFor(hash);
    if (!file.existsSync()) return null;
    try {
      return utf8.decode(await file.readAsBytes());
    } on FormatException {
      return null;
    }
  }

  /// Records [bytes] as one of the agreed versions. Silently skips anything
  /// unmergeable, so callers can hand it every file without checking first.
  Future<void> write(String hash, List<int> bytes) async {
    if (!isMergeableText(bytes)) return;
    final file = fileFor(hash);
    if (file.existsSync()) return; // the same bytes, by definition
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  /// Throws away every version nobody refers to any more.
  ///
  /// Called with every hash any pair still counts as its ancestor, plus what
  /// the folder holds now. Anything else is a version of a file that no sync
  /// will ever need again - including, on the first run after this store
  /// changed shape, the copies the old one left behind under their paths.
  Future<void> keep(Set<String> hashes) async {
    final dir = directory;
    if (!dir.existsSync()) return;
    await for (final item in dir.list()) {
      if (item is File) {
        if (!hashes.contains(p.basename(item.path))) await item.delete();
      } else if (item is Directory) {
        // Only the old path-shaped store put folders here.
        await item.delete(recursive: true);
      }
    }
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
