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

  late Directory remote; // desktop's shared vault
  late Directory local; // phone's copy
  late PeerServer server;

  setUp(() async {
    remote = Directory.systemTemp.createTempSync('rec_remote');
    local = Directory.systemTemp.createTempSync('rec_local');
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

  Future<void> expectSidesMatch() async {
    final a = await Manifest.scan(local);
    final b = await Manifest.scan(remote);
    expect(b.entries.keys.toSet(), a.entries.keys.toSet());
    for (final key in a.entries.keys) {
      expect(b.entries[key]!.hash, a.entries[key]!.hash, reason: key);
    }
  }

  test('non-conflicting edits on both sides merge to an identical state',
      () async {
    // Base: both had a.md and b.md identical.
    File('${remote.path}/a.md').writeAsStringSync('a0');
    File('${remote.path}/b.md').writeAsStringSync('b0');
    File('${local.path}/a.md').writeAsStringSync('a0');
    File('${local.path}/b.md').writeAsStringSync('b0');
    final base = await Manifest.scan(local);

    // Local edits a.md; remote edits b.md; each adds a new file.
    File('${local.path}/a.md').writeAsStringSync('a1');
    File('${local.path}/localonly.md').writeAsStringSync('L');
    File('${remote.path}/b.md').writeAsStringSync('b1');
    File('${remote.path}/remoteonly.md').writeAsStringSync('R');

    final client = await connect();
    addTearDown(client.close);

    final merge = await computeMerge(client, 'notes', local, base);
    expect(merge.hasConflicts, isFalse);
    expect(merge.pushes.map((i) => i.path).toSet(), {'a.md', 'localonly.md'});
    expect(merge.pulls.map((i) => i.path).toSet(), {'b.md', 'remoteonly.md'});

    await applyMerge(
      client,
      'notes',
      local,
      merge.items.map(ResolvedMerge.natural).toList(),
    );

    await expectSidesMatch();
    expect(File('${remote.path}/a.md').readAsStringSync(), 'a1');
    expect(File('${local.path}/b.md').readAsStringSync(), 'b1');
  });

  test('a conflict resolved toward local pushes the local version', () async {
    File('${remote.path}/note.md').writeAsStringSync('base');
    File('${local.path}/note.md').writeAsStringSync('base');
    final base = await Manifest.scan(local);

    // Both edit the same file differently.
    File('${local.path}/note.md').writeAsStringSync('mine');
    File('${remote.path}/note.md').writeAsStringSync('theirs');

    final client = await connect();
    addTearDown(client.close);

    final merge = await computeMerge(client, 'notes', local, base);
    expect(merge.hasConflicts, isTrue);

    // Keep local (toLocal: false pushes our version to the remote).
    final resolved = [
      for (final item in merge.items)
        ResolvedMerge(item, toLocal: false),
    ];
    await applyMerge(client, 'notes', local, resolved);

    await expectSidesMatch();
    expect(File('${remote.path}/note.md').readAsStringSync(), 'mine');
  });

  test('automatic conflict resolution takes the newer side', () async {
    final older = DateTime.now().subtract(const Duration(hours: 1));

    File('${remote.path}/note.md').writeAsStringSync('base');
    File('${local.path}/note.md').writeAsStringSync('base');
    final base = await Manifest.scan(local);

    File('${local.path}/note.md').writeAsStringSync('local-old');
    File('${local.path}/note.md').setLastModifiedSync(older);
    File('${remote.path}/note.md').writeAsStringSync('remote-new');

    final client = await connect();
    addTearDown(client.close);

    final merge = await computeMerge(client, 'notes', local, base);
    final item = merge.conflicts.single;
    // Remote is newer, so auto-resolution should take the remote version.
    expect(conflictResolvesToLocal(item), isTrue);
  });
}
