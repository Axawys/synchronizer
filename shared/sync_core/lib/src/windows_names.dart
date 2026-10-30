import 'manifest.dart';

/// Names a folder made on Linux or Android can hold and Windows cannot.
///
/// Nothing on Windows refuses most of them, which is the problem: `10:30.md` is
/// written as a file called `10` with the text tucked into a hidden stream,
/// `draft.` loses its dot, and `Note.md` next to `note.md` is one file written
/// twice. Each is a sync that reports success over a file that is now called
/// something else or holds something else. So wherever Windows is one of the
/// two devices, such paths are left out of the sync - on both sides, so that
/// the side that cannot see them does not read their absence as a deletion.

const _forbidden = ['<', '>', ':', '"', '\\', '|', '?', '*'];

/// The device names Windows keeps for itself, with or without an extension:
/// `nul.md` is as unusable in Explorer as `nul`.
final _reserved = RegExp(
  r'^(con|prn|aux|nul|com[0-9¹²³]|lpt[0-9¹²³])(\..*)?$',
  caseSensitive: false,
);

/// Whether Windows can hold [path] - a relative, slash-separated manifest path -
/// under exactly that name.
bool isWindowsSafe(String path) {
  for (final segment in path.split('/')) {
    if (segment.codeUnits.any((unit) => unit < 0x20)) return false;
    if (_forbidden.any(segment.contains)) return false;
    if (segment.endsWith('.') || segment.endsWith(' ')) return false;
    if (_reserved.hasMatch(segment)) return false;
  }
  return true;
}

/// Every path in [manifests] that a sync with Windows has to leave alone.
///
/// That is the names Windows cannot hold, and the names that differ from one
/// another only in letter case - a file or any folder above it. A pair like
/// that is taken out whole, and from every manifest: if only one spelling were
/// dropped, the other would look deleted on one side and new on the other.
///
/// The case check looks inside one manifest at a time, because that is where a
/// pair actually exists. `Note.md` on one side and `note.md` on the other is a
/// rename, and has to be allowed through.
Set<String> windowsUnsafePaths(Iterable<Manifest> manifests) {
  final unsafe = <String>{};
  final ambiguous = <String>{};

  for (final manifest in manifests) {
    final spelling = <String, String>{};
    for (final path in manifest.entries.keys) {
      if (!isWindowsSafe(path)) {
        unsafe.add(path);
        continue;
      }
      for (final prefix in _prefixes(path)) {
        final key = prefix.toLowerCase();
        if (spelling.putIfAbsent(key, () => prefix) != prefix) {
          ambiguous.add(key);
        }
      }
    }
  }

  if (ambiguous.isNotEmpty) {
    for (final manifest in manifests) {
      for (final path in manifest.entries.keys) {
        if (_prefixes(path).any((p) => ambiguous.contains(p.toLowerCase()))) {
          unsafe.add(path);
        }
      }
    }
  }
  return unsafe;
}

/// `a`, `a/b`, `a/b/c.md` for `a/b/c.md`: the folders a file sits in, and the
/// file itself.
Iterable<String> _prefixes(String path) sync* {
  for (var i = path.indexOf('/'); i != -1; i = path.indexOf('/', i + 1)) {
    yield path.substring(0, i);
  }
  yield path;
}
