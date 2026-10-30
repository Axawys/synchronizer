import 'dart:convert';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'file_entry.dart';

/// A snapshot of a synchronized directory: the set of files it contained at the
/// moment it was scanned, keyed by their relative path.
///
/// A manifest is the unit the two devices exchange. Comparing the local
/// manifest against the remote one (and, later, against the last agreed common
/// manifest) is what tells the application which files were added, changed or
/// removed.
class Manifest {
  Manifest(this.entries);

  /// Relative path -> entry.
  final Map<String, FileEntry> entries;

  int get length => entries.length;

  /// This manifest with [paths] left out.
  Manifest without(Set<String> paths) => paths.isEmpty
      ? this
      : Manifest({
          for (final entry in entries.entries)
            if (!paths.contains(entry.key)) entry.key: entry.value,
        });

  /// Walks [root] and builds a manifest of every regular file below it.
  ///
  /// Anything matched by [ignore] (checked against the relative, slash-joined
  /// path) is skipped. Hidden files and the sync metadata folder are ignored by
  /// default so that they never travel between devices.
  static Future<Manifest> scan(
    Directory root, {
    bool Function(String relativePath)? ignore,
  }) async {
    final rootPath = root.absolute.path;
    final entries = <String, FileEntry>{};

    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;

      final rel = p.posix.joinAll(
        p.split(p.relative(entity.path, from: rootPath)),
      );

      if (_defaultIgnore(rel)) continue;
      if (ignore != null && ignore(rel)) continue;

      final stat = await entity.stat();
      final digest = await _hashFile(entity);

      entries[rel] = FileEntry(
        path: rel,
        size: stat.size,
        modified: stat.modified.toUtc(),
        hash: digest,
      );
    }

    return Manifest(entries);
  }

  /// How much a directory holds, by the same rules [scan] follows, and without
  /// reading any of it.
  ///
  /// This is not a manifest - it says nothing about what changed - but it is
  /// what makes a sync explicable to the person watching it. A folder that
  /// reports "nothing to do" while one side holds a gigabyte and the other
  /// nothing has told you where to look; the same message with no numbers has
  /// told you nothing. Hashing to find that out would mean reading every byte,
  /// so this only walks and stats.
  static Future<FolderSize> measure(Directory root) async {
    if (!root.existsSync()) return const FolderSize(files: 0, bytes: 0);

    final rootPath = root.absolute.path;
    var files = 0;
    var bytes = 0;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = p.posix.joinAll(
        p.split(p.relative(entity.path, from: rootPath)),
      );
      if (_defaultIgnore(rel)) continue;
      files++;
      try {
        bytes += await entity.length();
      } catch (_) {
        // Gone between the listing and the question, or unreadable. It is a
        // measurement, not a manifest; one file short is not worth failing.
      }
    }
    return FolderSize(files: files, bytes: bytes);
  }

  /// How many files a directory holds. Kept for callers that only need the
  /// count; [measure] answers both in one walk.
  static Future<int> countFiles(Directory root) async =>
      (await measure(root)).files;

  static bool _defaultIgnore(String rel) {
    for (final segment in rel.split('/')) {
      if (segment.startsWith('.')) return true;
    }
    return false;
  }

  static Future<String> _hashFile(File file) async {
    final sink = _Sha256Sink();
    await file.openRead().forEach(sink.add);
    return sink.close();
  }

  Map<String, Object?> toJson() => {
        'version': 1,
        'entries': entries.values.map((e) => e.toJson()).toList(),
      };

  String encode() => jsonEncode(toJson());

  factory Manifest.fromJson(Map<String, Object?> json) {
    final list = (json['entries']! as List).cast<Map<String, Object?>>();
    final entries = <String, FileEntry>{};
    for (final raw in list) {
      final entry = FileEntry.fromJson(raw);
      entries[entry.path] = entry;
    }
    return Manifest(entries);
  }

  factory Manifest.decode(String source) =>
      Manifest.fromJson(jsonDecode(source) as Map<String, Object?>);
}

/// What a folder amounts to: how many files, and how much they weigh.
///
/// The weight is the number worth showing. "1240 files" and "3 files" say
/// little about which is the vault and which is a stub; "1.2 GB" and "8 kB"
/// say it at a glance.
class FolderSize {
  const FolderSize({required this.files, required this.bytes});

  final int files;
  final int bytes;

  bool get isEmpty => files == 0;

  @override
  String toString() => 'FolderSize($files files, $bytes bytes)';
}

/// Streams bytes into a SHA-256 digest without holding the whole file in
/// memory, so that large attachments in an Obsidian vault do not blow up the
/// heap on a phone.
class _Sha256Sink {
  final _output = AccumulatorSink<Digest>();
  late final ByteConversionSink _input =
      sha256.startChunkedConversion(_output);

  void add(List<int> chunk) => _input.add(chunk);

  String close() {
    _input.close();
    return _output.events.single.toString();
  }
}
