import 'dart:io';

import 'package:sync_net/sync_net.dart';
import 'package:test/test.dart';

void main() {
  const desktop = DeviceInfo(
    id: 'desktop-id',
    name: 'Desktop',
    platform: DevicePlatform.linux,
    port: 47800,
  );
  const phone = DeviceInfo(
    id: 'phone-id',
    name: 'Phone',
    platform: DevicePlatform.android,
    port: 47800,
  );
  const secret = 'shared';
  final desktopKnowsPhone = TrustedPeer(
      id: 'phone-id', name: 'Phone', platform: DevicePlatform.android, secret: secret);
  final phoneKnowsDesktop = TrustedPeer(
      id: 'desktop-id', name: 'Desktop', platform: DevicePlatform.linux, secret: secret);

  late Directory remote;
  late Directory local;
  late PeerServer server;

  setUp(() async {
    remote = Directory.systemTemp.createTempSync('mc_remote');
    local = Directory.systemTemp.createTempSync('mc_local');
    final trust = MemoryTrustStore();
    await trust.add(desktopKnowsPhone);
    server = PeerServer(desktop, trust,
        port: 0, directories: MapDirectorySource({'notes': remote.path}));
    await server.start();
  });

  tearDown(() async {
    await server.stop();
    remote.deleteSync(recursive: true);
    local.deleteSync(recursive: true);
  });

  Future<SyncClient> connect() => SyncClient.connect('127.0.0.1', server.boundPort,
      self: phone, trusted: phoneKnowsDesktop);

  /// Puts both sides at the same content and records it as the agreed base,
  /// the way a finished sync would.
  Future<Manifest> settleAt(String content) async {
    File('${local.path}/note.md').writeAsStringSync(content);
    File('${remote.path}/note.md').writeAsStringSync(content);
    final base = await Manifest.scan(local);
    await refreshBaseStore(local, Manifest({}), base);
    return base;
  }

  test('edits to different parts of one note merge without asking', () async {
    final base = await settleAt('# Notes\n\n- milk\n- bread\n');

    // Each device edits a different line while offline.
    File('${local.path}/note.md').writeAsStringSync('# Notes\n\n- milk\n- bread\n- cheese\n');
    File('${remote.path}/note.md').writeAsStringSync('# Shopping\n\n- milk\n- bread\n');

    final client = await connect();
    addTearDown(client.close);

    final result = await computeMerge(client, 'notes', local, base);
    expect(result.conflicts, hasLength(1), reason: 'both touched the file');

    final merged = await mergeConflict(client, 'notes', local, result.conflicts.single);
    expect(merged.isMergeable, isTrue);
    expect(merged.isClean, isTrue, reason: 'the edits do not overlap');

    await applyMerge(client, 'notes', local,
        [ResolvedMerge.merged(merged.item, merged.merge!.clean!)]);

    // Both devices end up with both edits.
    const expected = '# Shopping\n\n- milk\n- bread\n- cheese\n';
    expect(File('${local.path}/note.md').readAsStringSync(), expected);
    expect(File('${remote.path}/note.md').readAsStringSync(), expected);
  });

  test('edits to the same line come back as a conflict to settle', () async {
    final base = await settleAt('title\nbody\n');

    File('${local.path}/note.md').writeAsStringSync('mine\nbody\n');
    File('${remote.path}/note.md').writeAsStringSync('theirs\nbody\n');

    final client = await connect();
    addTearDown(client.close);

    final result = await computeMerge(client, 'notes', local, base);
    final merged = await mergeConflict(client, 'notes', local, result.conflicts.single);

    expect(merged.isMergeable, isTrue);
    expect(merged.isClean, isFalse);
    final hunk = merged.merge!.conflicts.single;
    expect(hunk.ours, ['mine']);
    expect(hunk.theirs, ['theirs']);
  });

  test('without a base copy the shared lines stand in for the ancestor',
      () async {
    // The first sync of a folder both devices already had: no base was ever
    // kept, but the two versions still have most of their text in common.
    File('${local.path}/note.md')
        .writeAsStringSync('title\nmine\nshared tail\n');
    File('${remote.path}/note.md')
        .writeAsStringSync('title\ntheirs\nshared tail\n');

    final client = await connect();
    addTearDown(client.close);

    final result = await computeMerge(client, 'notes', local, Manifest({}));
    final merged =
        await mergeConflict(client, 'notes', local, result.conflicts.single);

    // Mergeable, so the user is asked about the one line that differs rather
    // than about the whole file...
    expect(merged.isMergeable, isTrue);
    expect(merged.ancestorKnown, isFalse, reason: 'the base was guessed');
    final hunk = merged.merge!.conflicts.single;
    expect(hunk.ours, ['mine']);
    expect(hunk.theirs, ['theirs']);

    // ...and the lines both agree on survive either choice.
    expect(merged.merge!.resolve((c) => c.theirs),
        ['title', 'theirs', 'shared tail', '']);
  });

  test('a guessed base still merges edits in different places', () async {
    // Nothing was deleted, so with no ancestor both additions are kept - which
    // is the whole point of not forcing a whole-file choice on a first sync.
    File('${local.path}/note.md').writeAsStringSync('a\nb\nmine\n');
    File('${remote.path}/note.md').writeAsStringSync('theirs\na\nb\n');

    final client = await connect();
    addTearDown(client.close);

    final result = await computeMerge(client, 'notes', local, Manifest({}));
    final merged =
        await mergeConflict(client, 'notes', local, result.conflicts.single);

    expect(merged.isClean, isTrue);
    expect(merged.merge!.clean, ['theirs', 'a', 'b', 'mine', '']);
  });

  test('a guessed base cannot tell a deletion from an addition', () async {
    // The honest limitation: with no ancestor, "they deleted b" is
    // indistinguishable from "we added b", and it errs towards keeping text.
    final localFile = File('${local.path}/note.md')..writeAsStringSync('a\nb\n');
    File('${remote.path}/note.md').writeAsStringSync('a\n');

    final client = await connect();
    addTearDown(client.close);

    final result = await computeMerge(client, 'notes', local, Manifest({}));
    final merged =
        await mergeConflict(client, 'notes', local, result.conflicts.single);

    expect(merged.isClean, isTrue);
    expect(merged.merge!.clean, contains('b'), reason: 'the line comes back');
    expect(localFile.readAsStringSync(), 'a\nb\n', reason: 'nothing written');
  });

  test('binary conflicts are not merged', () async {
    final base = await settleAt('placeholder');
    File('${local.path}/note.md').writeAsBytesSync([0x89, 0x50, 0x00, 0x01]);
    File('${remote.path}/note.md').writeAsBytesSync([0x89, 0x50, 0x00, 0x02]);

    final client = await connect();
    addTearDown(client.close);

    final result = await computeMerge(client, 'notes', local, base);
    final merged = await mergeConflict(client, 'notes', local, result.conflicts.single);

    expect(merged.isMergeable, isFalse);
  });

  group('refreshBaseStore', () {
    test('keeps a copy so the next sync can merge', () async {
      File('${local.path}/note.md').writeAsStringSync('v1');
      final current = await Manifest.scan(local);

      await refreshBaseStore(local, Manifest({}), current);

      expect(await BaseStore(local).read('note.md'), 'v1');
    });

    test('follows the content forward and forgets deleted files', () async {
      File('${local.path}/note.md').writeAsStringSync('v1');
      final first = await Manifest.scan(local);
      await refreshBaseStore(local, Manifest({}), first);

      File('${local.path}/note.md').writeAsStringSync('v2');
      final second = await Manifest.scan(local);
      await refreshBaseStore(local, first, second);
      expect(await BaseStore(local).read('note.md'), 'v2');

      File('${local.path}/note.md').deleteSync();
      await refreshBaseStore(local, second, await Manifest.scan(local));
      expect(await BaseStore(local).read('note.md'), isNull);
    });
  });

  group('runSync', () {
    /// Syncs "notes" the way the app does, from a fresh connection.
    Future<SyncOutcome> sync(Manifest base) async {
      final client = await connect();
      addTearDown(client.close);
      final merge = await computeMerge(client, 'notes', local, base);
      final resolved = <ResolvedMerge>[];
      for (final item in merge.items) {
        if (item.kind == MergeKind.conflict) {
          final merged = await mergeConflict(client, 'notes', local, item);
          resolved.add(merged.isClean
              ? ResolvedMerge.merged(item, merged.merge!.clean!)
              : ResolvedMerge(item, toLocal: conflictResolvesToLocal(item)));
        } else {
          resolved.add(ResolvedMerge.natural(item));
        }
      }
      return runSync(client, 'notes', local, base, resolved);
    }

    test('a finished sync records the text, not just the hashes', () async {
      File('${remote.path}/note.md').writeAsStringSync('# Notes\n- milk\n');

      final outcome = await sync(Manifest({}));

      expect(outcome.report.ok, isTrue);
      expect(outcome.newBase!.entries.keys, ['note.md']);
      // The regression: recording the manifest while forgetting the text left
      // the merge with no ancestor, so every later conflict had to guess.
      expect(await BaseStore(local).read('note.md'), '# Notes\n- milk\n');
    });

    test('two syncs later, edits from both devices merge exactly', () async {
      File('${remote.path}/note.md').writeAsStringSync('# Notes\n- milk\n');
      final base = (await sync(Manifest({}))).newBase!;

      // Each device edits a different line, offline.
      File('${local.path}/note.md')
          .writeAsStringSync('# Notes\n- milk\n- bread\n');
      File('${remote.path}/note.md').writeAsStringSync('# Shopping\n- milk\n');

      expect((await sync(base)).report.ok, isTrue);

      const expected = '# Shopping\n- milk\n- bread\n';
      expect(File('${local.path}/note.md').readAsStringSync(), expected);
      expect(File('${remote.path}/note.md').readAsStringSync(), expected,
          reason: 'the merge goes to both devices');
    });

    test('a sync that did not finish leaves the ancestor alone', () async {
      File('${remote.path}/note.md').writeAsStringSync('v1\n');
      await sync(Manifest({}));
      final base = await Manifest.scan(local);

      File('${local.path}/note.md').writeAsStringSync('mine\n');
      final client = await connect();
      addTearDown(client.close);
      final merge = await computeMerge(client, 'notes', local, base);
      await client.close(); // the connection drops mid-sync

      final outcome = await runSync(client, 'notes', local, base,
          [for (final item in merge.items) ResolvedMerge.natural(item)]);

      expect(outcome.report.ok, isFalse);
      expect(outcome.newBase, isNull, reason: 'nothing to stand behind');
      expect(await BaseStore(local).read('note.md'), 'v1\n',
          reason: 'the retry still needs to tell the two edits apart');
    });

    test('the base store never becomes something to sync', () async {
      File('${remote.path}/note.md').writeAsStringSync('hello\n');
      final outcome = await sync(Manifest({}));

      expect(BaseStore(local).directory.existsSync(), isTrue);
      // A store that synced itself would grow every time, each sync copying the
      // copies the last one made.
      expect(outcome.newBase!.entries.keys, ['note.md']);
    });
  });
}
