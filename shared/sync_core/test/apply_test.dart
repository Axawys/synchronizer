import 'dart:convert';
import 'dart:io';

import 'package:sync_core/sync_core.dart';
import 'package:test/test.dart';

void main() {
  group('applyChanges', () {
    late Directory root;

    setUp(() => root = Directory.systemTemp.createTempSync('apply_test'));
    tearDown(() => root.deleteSync(recursive: true));

    FileEntry entry(String path, String hash) =>
        FileEntry(path: path, size: 1, modified: DateTime.utc(2026), hash: hash);

    test('writes added files, including in new subdirectories', () async {
      final changes = ChangeSet([
        Change(kind: ChangeKind.added, path: 'note.md', after: entry('note.md', 'a')),
        Change(
            kind: ChangeKind.added,
            path: 'sub/deep.md',
            after: entry('sub/deep.md', 'b')),
      ]);

      await applyChanges(root, changes, (path) async => utf8.encode('body:$path'));

      expect(File('${root.path}/note.md').readAsStringSync(), 'body:note.md');
      expect(File('${root.path}/sub/deep.md').readAsStringSync(), 'body:sub/deep.md');
    });

    test('overwrites modified files and removes deleted ones', () async {
      File('${root.path}/keep.md').writeAsStringSync('old');
      File('${root.path}/gone.md').writeAsStringSync('bye');

      final changes = ChangeSet([
        Change(
            kind: ChangeKind.modified,
            path: 'keep.md',
            before: entry('keep.md', 'x'),
            after: entry('keep.md', 'y')),
        Change(kind: ChangeKind.deleted, path: 'gone.md', before: entry('gone.md', 'z')),
      ]);

      await applyChanges(root, changes, (path) async => utf8.encode('new'));

      expect(File('${root.path}/keep.md').readAsStringSync(), 'new');
      expect(File('${root.path}/gone.md').existsSync(), isFalse);
    });

    test('removes a folder once its last file is deleted', () async {
      File('${root.path}/vault/notes/deep.md')
        ..createSync(recursive: true)
        ..writeAsStringSync('x');

      await applyChanges(
        root,
        ChangeSet([
          Change(
              kind: ChangeKind.deleted,
              path: 'vault/notes/deep.md',
              before: entry('vault/notes/deep.md', 'x')),
        ]),
        (_) async => const <int>[],
      );

      expect(Directory('${root.path}/vault/notes').existsSync(), isFalse);
      expect(Directory('${root.path}/vault').existsSync(), isFalse);
      expect(root.existsSync(), isTrue, reason: 'the sync root itself stays');
    });

    test('keeps a folder that still holds other files', () async {
      File('${root.path}/vault/gone.md')
        ..createSync(recursive: true)
        ..writeAsStringSync('x');
      File('${root.path}/vault/stays.md').writeAsStringSync('y');

      await applyChanges(
        root,
        ChangeSet([
          Change(
              kind: ChangeKind.deleted,
              path: 'vault/gone.md',
              before: entry('vault/gone.md', 'x')),
        ]),
        (_) async => const <int>[],
      );

      expect(Directory('${root.path}/vault').existsSync(), isTrue);
      expect(File('${root.path}/vault/stays.md').existsSync(), isTrue);
    });

    test('leaves no temporary files behind', () async {
      final changes = ChangeSet([
        Change(kind: ChangeKind.added, path: 'a.md', after: entry('a.md', 'a')),
      ]);

      await applyChanges(root, changes, (_) async => [1, 2, 3]);

      final leftovers = root
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.synctmp'));
      expect(leftovers, isEmpty);
    });

    test('reports progress for each change', () async {
      final changes = ChangeSet([
        Change(kind: ChangeKind.added, path: 'a.md', after: entry('a.md', 'a')),
        Change(kind: ChangeKind.added, path: 'b.md', after: entry('b.md', 'b')),
      ]);

      final seen = <int>[];
      await applyChanges(
        root,
        changes,
        (_) async => [0],
        onProgress: (applied, total) => seen.add(applied),
      );

      expect(seen, [1, 2]);
    });
  });
}
