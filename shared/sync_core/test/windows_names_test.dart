import 'package:sync_core/sync_core.dart';
import 'package:test/test.dart';

void main() {
  FileEntry e(String path, String hash) =>
      FileEntry(path: path, size: 1, modified: DateTime.utc(2026), hash: hash);

  Manifest m(Map<String, String> pathToHash) => Manifest({
        for (final entry in pathToHash.entries)
          entry.key: e(entry.key, entry.value),
      });

  group('isWindowsSafe', () {
    test('ordinary notes are fine, Cyrillic and spaces included', () {
      expect(isWindowsSafe('Daily/2026-10-30.md'), isTrue);
      expect(isWindowsSafe('Заметки/Встреча в среду.md'), isTrue);
      expect(isWindowsSafe('a.b.c/file.tar.gz'), isTrue);
    });

    test('characters Windows gives another meaning are refused', () {
      // A colon writes a hidden stream on NTFS; the rest are refused or
      // read as wildcards and separators.
      for (final name in [
        'Встреча 10:30.md',
        'what?.md',
        'a*b.md',
        'say "hi".md',
        'a<b>.md',
        'pipe|d.md',
        r'back\slash.md',
        'tab\there.md',
      ]) {
        expect(isWindowsSafe(name), isFalse, reason: name);
      }
    });

    test('a folder with a bad name spoils everything below it', () {
      expect(isWindowsSafe('10:30/note.md'), isFalse);
      expect(isWindowsSafe('draft./note.md'), isFalse);
    });

    test('a trailing dot or space is refused, since Windows drops it', () {
      expect(isWindowsSafe('draft.'), isFalse);
      expect(isWindowsSafe('draft '), isFalse);
      expect(isWindowsSafe('.hidden-but-fine'), isTrue);
    });

    test('device names are refused with or without an extension', () {
      for (final name in ['CON', 'nul.md', 'Aux.txt', 'com1', 'LPT9.md']) {
        expect(isWindowsSafe(name), isFalse, reason: name);
      }
      expect(isWindowsSafe('console.md'), isTrue);
      expect(isWindowsSafe('com10.md'), isTrue);
      expect(isWindowsSafe('nullable.md'), isTrue);
    });
  });

  group('windowsUnsafePaths', () {
    test('two spellings of one file in a manifest are both left out', () {
      final unsafe = windowsUnsafePaths([
        m({'Note.md': '1', 'note.md': '2', 'other.md': '3'}),
      ]);
      expect(unsafe, {'Note.md', 'note.md'});
    });

    test('two spellings of one folder take out everything in both', () {
      final unsafe = windowsUnsafePaths([
        m({'Notes/a.md': '1', 'notes/b.md': '2', 'Notes2/c.md': '3'}),
      ]);
      expect(unsafe, {'Notes/a.md', 'notes/b.md'});
    });

    test('a pair is left out of every manifest, not only the one it is in', () {
      final unsafe = windowsUnsafePaths([
        m({'Note.md': '1'}),
        m({'Note.md': '1', 'note.md': '2'}),
      ]);
      expect(unsafe, {'Note.md', 'note.md'});
    });

    test('different spellings on different sides are a rename, not a clash',
        () {
      final unsafe = windowsUnsafePaths([
        m({'Note.md': '1'}),
        m({'note.md': '1'}),
      ]);
      expect(unsafe, isEmpty);
    });
  });

  group('threeWayMerge with windowsNames', () {
    test('a name Windows cannot hold is skipped, not synced', () {
      final result = threeWayMerge(
        m({}),
        m({'ok.md': '1'}),
        m({'ok.md': '1', '10:30.md': '2'}),
        windowsNames: true,
      );
      expect(result.isEmpty, isTrue);
      expect(result.skipped, ['10:30.md']);
    });

    test('a skipped file the other side lacks is not read as deleted', () {
      // The Linux side syncs with a Windows peer: its last agreed base was its
      // own whole folder, which includes the file Windows never got.
      final base = m({'ok.md': '1', 'a:b.md': '2'});
      final local = m({'ok.md': '1', 'a:b.md': '2'});
      final remote = m({'ok.md': '1'});

      final result = threeWayMerge(base, local, remote, windowsNames: true);
      expect(result.items, isEmpty, reason: 'nothing to delete on either side');
      expect(result.skipped, ['a:b.md']);

      // Without the rule this is exactly what would have happened.
      final unguarded = threeWayMerge(base, local, remote);
      expect(unguarded.items.single.kind, MergeKind.pullToLocal);
      expect(unguarded.items.single.remote, isNull);
    });

    test('a second spelling turning up does not delete the first elsewhere',
        () {
      final base = m({'Note.md': '1'});
      final local = m({'Note.md': '1', 'note.md': '2'});
      final remote = m({'Note.md': '1'});

      final result = threeWayMerge(base, local, remote, windowsNames: true);
      expect(result.items, isEmpty);
      expect(result.skipped, ['Note.md', 'note.md']);
    });

    test('a rename that only changes case still goes through', () {
      final result = threeWayMerge(
        m({'Note.md': '1'}),
        m({'note.md': '1'}),
        m({'Note.md': '1'}),
        windowsNames: true,
      );
      expect(result.skipped, isEmpty);
      expect(result.items.map((i) => i.path), ['Note.md', 'note.md']);
    });

    test('without the flag nothing is filtered', () {
      final result = threeWayMerge(m({}), m({}), m({'a:b.md': '1'}));
      expect(result.skipped, isEmpty);
      expect(result.items.single.path, 'a:b.md');
    });
  });
}
