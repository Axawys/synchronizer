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

  test('without a base copy there is nothing to merge against', () async {
    // Both sides have the file but it was never synced, so no base was kept.
    File('${local.path}/note.md').writeAsStringSync('mine\n');
    File('${remote.path}/note.md').writeAsStringSync('theirs\n');

    final client = await connect();
    addTearDown(client.close);

    final result = await computeMerge(client, 'notes', local, Manifest({}));
    final merged = await mergeConflict(client, 'notes', local, result.conflicts.single);

    expect(merged.isMergeable, isFalse);
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
}
