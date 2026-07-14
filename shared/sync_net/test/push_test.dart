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

  // The desktop is the server here; the phone pushes its local changes up into
  // the desktop's shared "notes" directory.
  late Directory remote; // desktop's shared vault (the push destination)
  late Directory local; // phone's copy (the source of truth for a push)
  late PeerServer server;

  setUp(() async {
    remote = Directory.systemTemp.createTempSync('push_remote');
    local = Directory.systemTemp.createTempSync('push_local');

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

  Future<void> expectRemoteMatchesLocal() async {
    final a = await Manifest.scan(local);
    final b = await Manifest.scan(remote);
    expect(b.entries.keys.toSet(), a.entries.keys.toSet());
    for (final key in a.entries.keys) {
      expect(b.entries[key]!.hash, a.entries[key]!.hash, reason: key);
    }
  }

  test('pushing to an empty remote uploads everything', () async {
    File('${local.path}/a.md').writeAsStringSync('alpha');
    File('${local.path}/sub/b.md')
      ..createSync(recursive: true)
      ..writeAsStringSync('bravo');

    final client = await connect();
    addTearDown(client.close);

    final plan = await planPush(client, 'notes', local);
    expect(plan.added.map((c) => c.path).toSet(), {'a.md', 'sub/b.md'});

    await applyPush(client, 'notes', local, plan);
    await expectRemoteMatchesLocal();
    expect(File('${remote.path}/sub/b.md').readAsStringSync(), 'bravo');
  });

  test('a later push applies edits, additions and deletions on the remote',
      () async {
    // Remote (desktop) has an older state.
    File('${remote.path}/keep.md').writeAsStringSync('same');
    File('${remote.path}/edit.md').writeAsStringSync('old');
    File('${remote.path}/stale.md').writeAsStringSync('remove me');

    // Local (phone) is the desired state.
    File('${local.path}/keep.md').writeAsStringSync('same');
    File('${local.path}/edit.md').writeAsStringSync('new');
    File('${local.path}/added.md').writeAsStringSync('fresh');

    final client = await connect();
    addTearDown(client.close);

    final plan = await planPush(client, 'notes', local);
    expect(plan.added.map((c) => c.path), ['added.md']);
    expect(plan.modified.map((c) => c.path), ['edit.md']);
    expect(plan.deleted.map((c) => c.path), ['stale.md']);

    await applyPush(client, 'notes', local, plan);
    await expectRemoteMatchesLocal();
    expect(File('${remote.path}/edit.md').readAsStringSync(), 'new');
    expect(File('${remote.path}/stale.md').existsSync(), isFalse);
  });

  test('a push rejects a path escaping the shared directory', () async {
    final client = await connect();
    addTearDown(client.close);
    expect(
      client.putFile('notes', '../escape.md', [1, 2, 3]),
      throwsA(isA<SessionException>()),
    );
  });
}
