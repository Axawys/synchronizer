/// A single tracked file inside a synchronized directory.
///
/// The [path] is always relative to the root of the synchronized directory and
/// uses forward slashes regardless of platform, so that a manifest produced on
/// Linux can be compared against one produced on Android without translation.
class FileEntry {
  const FileEntry({
    required this.path,
    required this.size,
    required this.modified,
    required this.hash,
  });

  /// Relative path from the directory root, using `/` as separator.
  final String path;

  /// File size in bytes.
  final int size;

  /// Last modification time, stored in UTC.
  final DateTime modified;

  /// Hex-encoded SHA-256 of the file contents. This is the identity of the
  /// file: two entries with the same hash hold the same bytes.
  final String hash;

  Map<String, Object?> toJson() => {
        'path': path,
        'size': size,
        'modified': modified.toUtc().toIso8601String(),
        'hash': hash,
      };

  factory FileEntry.fromJson(Map<String, Object?> json) => FileEntry(
        path: json['path']! as String,
        size: json['size']! as int,
        modified: DateTime.parse(json['modified']! as String).toUtc(),
        hash: json['hash']! as String,
      );

  @override
  String toString() => 'FileEntry($path, ${size}B, $hash)';
}
