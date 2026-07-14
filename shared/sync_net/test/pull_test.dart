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

  late Directory remote; // the desktop's vault (source of truth)
  late Directory local; // the phone's copy
  late PeerServer server;

  setUp(() async {
    remote = Directory.systemTemp.createTempSync('pull_remote');
    local = Directory.systemTemp.createTempSync('pull_local');

    final trust = MemoryTrustStore();
    await trust.add(desktopKnowsPhone);
    server = PeerServer(desktop, trust,
        port: 0, directories: MapDirectorySource({'notes': remote.path}));
    await server.start();
  });

  tearDown(() async {
    await server.stop();
    remote.deleteSync(recursive: true);
    if (local.existsSync()) local.deleteSync(recursive: true);
  });

  Future<SyncClient> connect() => SyncClient.connect('127.0.0.1', server.boundPort,
      self: phone, trusted: phoneKnowsDesktop);

  Future<void> expectDirsMatch() async {
    final a = await Manifest.scan(remote);
    final b = await Manifest.scan(local);
    expect(b.entries.keys.toSet(), a.entries.keys.toSet());
    for (final key in a.entries.keys) {
      expect(b.entries[key]!.hash, a.entries[key]!.hash, reason: key);
    }
  }

  test('first pull copies everything into an empty local directory', () async {
    File('${remote.path}/a.md').writeAsStringSync('alpha');
    File('${remote.path}/sub/b.md')
      ..createSync(recursive: true)
      ..writeAsStringSync('bravo');

    final client = await connect();
    addTearDown(client.close);

    final plan = await planPull(client, 'notes', local);
    expect(plan.added.map((c) => c.path).toSet(), {'a.md', 'sub/b.md'});

    await applyPull(client, 'notes', local, plan);
    await expectDirsMatch();
  });

  test('a later pull applies edits, additions and deletions', () async {
    // Local already has an older state.
    File('${local.path}/keep.md').writeAsStringSync('same');
    File('${local.path}/edit.md').writeAsStringSync('old');
    File('${local.path}/stale.md').writeAsStringSync('remove me');

    // Remote is the desired state.
    File('${remote.path}/keep.md').writeAsStringSync('same');
    File('${remote.path}/edit.md').writeAsStringSync('new');
    File('${remote.path}/added.md').writeAsStringSync('fresh');

    final client = await connect();
    addTearDown(client.close);

    final plan = await planPull(client, 'notes', local);
    expect(plan.added.map((c) => c.path), ['added.md']);
    expect(plan.modified.map((c) => c.path), ['edit.md']);
    expect(plan.deleted.map((c) => c.path), ['stale.md']);

    await applyPull(client, 'notes', local, plan);
    await expectDirsMatch();
    expect(File('${local.path}/edit.md').readAsStringSync(), 'new');
  });
}
