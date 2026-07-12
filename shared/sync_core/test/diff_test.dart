import 'dart:io';

import 'package:sync_core/sync_core.dart';
import 'package:test/test.dart';

void main() {
  group('Manifest.scan', () {
    late Directory root;

    setUp(() => root = Directory.systemTemp.createTempSync('sync_core_test'));
    tearDown(() => root.deleteSync(recursive: true));

    test('captures regular files and ignores dotfiles', () async {
      File('${root.path}/note.md').writeAsStringSync('hello');
      Directory('${root.path}/sub').createSync();
      File('${root.path}/sub/deep.md').writeAsStringSync('world');
      File('${root.path}/.obsidian').writeAsStringSync('config');

      final manifest = await Manifest.scan(root);

      expect(manifest.entries.keys, containsAll(['note.md', 'sub/deep.md']));
      expect(manifest.entries.containsKey('.obsidian'), isFalse);
    });

    test('survives a JSON round-trip', () async {
      File('${root.path}/note.md').writeAsStringSync('hello');
      final manifest = await Manifest.scan(root);

      final restored = Manifest.decode(manifest.encode());

      expect(restored.entries['note.md']!.hash,
          manifest.entries['note.md']!.hash);
    });
  });

  group('ChangeSet.between', () {
    FileEntry entry(String path, String hash) => FileEntry(
          path: path,
          size: 1,
          modified: DateTime.utc(2026),
          hash: hash,
        );

    test('classifies added, modified and deleted files', () {
      final base = Manifest({
        'keep.md': entry('keep.md', 'a'),
        'edit.md': entry('edit.md', 'b'),
        'gone.md': entry('gone.md', 'c'),
      });
      final target = Manifest({
        'keep.md': entry('keep.md', 'a'),
        'edit.md': entry('edit.md', 'B'),
        'new.md': entry('new.md', 'd'),
      });

      final diff = ChangeSet.between(base, target);

      expect(diff.added.map((c) => c.path), ['new.md']);
      expect(diff.modified.map((c) => c.path), ['edit.md']);
      expect(diff.deleted.map((c) => c.path), ['gone.md']);
    });

    test('identical manifests produce no changes', () {
      final m = Manifest({'a.md': entry('a.md', 'x')});
      expect(ChangeSet.between(m, m).isEmpty, isTrue);
    });
  });
}
