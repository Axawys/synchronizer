import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sync_core/sync_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late BaseStore store;

  String hashOf(String text) =>
      sha256.convert(utf8.encode(text)).toString();

  setUp(() {
    root = Directory.systemTemp.createTempSync('base_store');
    store = BaseStore(root);
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('round-trips a version under the hash a manifest would record it by',
      () async {
    await store.write(hashOf('hello'), utf8.encode('hello'));
    await store.write(hashOf('deep'), utf8.encode('deep'));

    expect(await store.read(hashOf('hello')), 'hello');
    expect(await store.read(hashOf('deep')), 'deep');
  });

  test('two pairs that agreed on different versions both keep theirs',
      () async {
    // The same file, agreed with one device before an edit and with another
    // after it. One slot per path is exactly what used to lose the first.
    await store.write(hashOf('v1'), utf8.encode('v1'));
    await store.write(hashOf('v2'), utf8.encode('v2'));

    expect(await store.read(hashOf('v1')), 'v1');
    expect(await store.read(hashOf('v2')), 'v2');
  });

  test('a version never stored reads back as null', () async {
    expect(await store.read(hashOf('missing')), isNull);
  });

  test('the store hides from syncing', () async {
    await store.write(hashOf('hello'), utf8.encode('hello'));
    File('${root.path}/note.md').writeAsStringSync('hello');

    // Manifests skip dotted segments, so the base copies never sync themselves.
    final manifest = await Manifest.scan(root);
    expect(manifest.entries.keys, ['note.md']);
  });

  test('keeping drops the versions nobody refers to any more', () async {
    await store.write(hashOf('still used'), utf8.encode('still used'));
    await store.write(hashOf('long gone'), utf8.encode('long gone'));

    await store.keep({hashOf('still used')});

    expect(await store.read(hashOf('still used')), 'still used');
    expect(await store.read(hashOf('long gone')), isNull);
  });

  test('and sweeps up what the old store left under paths', () async {
    final old = Directory('${store.directory.path}/sub')
      ..createSync(recursive: true);
    File('${old.path}/note.md').writeAsStringSync('from the old shape');

    await store.keep({hashOf('anything')});

    expect(old.existsSync(), isFalse);
  });

  test('clear drops the whole store', () async {
    await store.write(hashOf('a'), utf8.encode('a'));
    await store.write(hashOf('b'), utf8.encode('b'));

    await store.clear();

    expect(store.directory.existsSync(), isFalse);
    expect(await store.read(hashOf('a')), isNull);
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
    await store.write('deadbeef', [0x89, 0x50, 0x00, 0x4E]);
    expect(await store.read('deadbeef'), isNull);
  });
}
