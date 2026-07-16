import 'dart:convert';
import 'dart:io';

import 'package:sync_core/sync_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late BaseStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('base_store');
    store = BaseStore(root);
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('round-trips a file, including in a subfolder', () async {
    await store.write('note.md', utf8.encode('hello'));
    await store.write('sub/deep.md', utf8.encode('deep'));

    expect(await store.read('note.md'), 'hello');
    expect(await store.read('sub/deep.md'), 'deep');
  });

  test('a file never stored reads back as null', () async {
    expect(await store.read('missing.md'), isNull);
  });

  test('the store hides from syncing', () async {
    await store.write('note.md', utf8.encode('hello'));
    File('${root.path}/note.md').writeAsStringSync('hello');

    // Manifests skip dotted segments, so the base copies never sync themselves.
    final manifest = await Manifest.scan(root);
    expect(manifest.entries.keys, ['note.md']);
  });

  test('removing drops the copy', () async {
    await store.write('note.md', utf8.encode('hello'));
    await store.remove('note.md');
    expect(await store.read('note.md'), isNull);
  });

  test('clear drops the whole store', () async {
    await store.write('a.md', utf8.encode('a'));
    await store.write('b.md', utf8.encode('b'));

    await store.clear();

    expect(store.directory.existsSync(), isFalse);
    expect(await store.read('a.md'), isNull);
  });

  group('isMergeableText', () {
    test('accepts UTF-8 text, including non-Latin scripts', () {
      expect(isMergeableText(utf8.encode('# Заметки\n- пункт')), isTrue);
    });

    test('rejects binary', () {
      expect(isMergeableText([0x89, 0x50, 0x4E, 0x47, 0x00, 0x1A]), isFalse);
    });

    test('rejects anything too large to be worth merging', () {
      expect(isMergeableText(List.filled(kMaxBaseBytes + 1, 0x41)), isFalse);
    });
  });

  test('binary is not kept, so its conflicts fall back to choosing a side',
      () async {
    await store.write('image.png', [0x89, 0x50, 0x00, 0x4E]);
    expect(await store.read('image.png'), isNull);
  });
}
