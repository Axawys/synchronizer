import 'dart:convert';
import 'dart:io';

import 'package:sync_core/sync_core.dart';
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

  // The shared secret both sides hold after pairing.
  const secret = 'a-shared-secret';
  final desktopKnowsPhone = TrustedPeer(
      id: 'phone-id', name: 'Phone', platform: DevicePlatform.android, secret: secret);
  final phoneKnowsDesktop = TrustedPeer(
      id: 'desktop-id', name: 'Desktop', platform: DevicePlatform.linux, secret: secret);

  late Directory vault;
  late PeerServer server;
  late TrustStore serverTrust;

  setUp(() async {
    vault = Directory.systemTemp.createTempSync('session_vault');
    File('${vault.path}/a.md').writeAsStringSync('alpha');
    File('${vault.path}/b.md').writeAsStringSync('bravo');

    serverTrust = MemoryTrustStore();
    // The server is the desktop; it must recognise the phone by the phone's id.
    await serverTrust.add(desktopKnowsPhone);

    // The server (say, the desktop) shares the vault under the name 'notes'.
    server = PeerServer(
      desktop,
      serverTrust,
      port: 0,
      directories: MapDirectorySource({'notes': vault.path}),
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
    vault.deleteSync(recursive: true);
  });

  Future<SyncClient> connectClient() => SyncClient.connect(
        '127.0.0.1',
        server.boundPort,
        self: phone,
        trusted: phoneKnowsDesktop,
      );

  test('authenticated client can list, fetch a manifest and a file', () async {
    final client = await connectClient();
    addTearDown(client.close);

    final dirs = await client.listDirectories();
    expect(dirs.map((d) => d.name), ['notes']);

    final manifest = await client.fetchManifest('notes');
    expect(manifest.entries.keys, containsAll(['a.md', 'b.md']));

    final bytes = await client.fetchFile('notes', 'a.md');
    expect(utf8.decode(bytes), 'alpha');
  });

  test('a remote manifest diffs against a local one', () async {
    // The phone has an older copy: b.md edited, c.md added, a.md missing.
    final local = Manifest({
      'b.md': FileEntry(
          path: 'b.md', size: 1, modified: DateTime.utc(2026), hash: 'stale'),
      'c.md': FileEntry(
          path: 'c.md', size: 1, modified: DateTime.utc(2026), hash: 'local-only'),
    });

    final client = await connectClient();
    addTearDown(client.close);
    final remote = await client.fetchManifest('notes');

    // What the phone would need to do to match the desktop.
    final changes = ChangeSet.between(local, remote);
    expect(changes.added.map((c) => c.path), ['a.md']);
    expect(changes.modified.map((c) => c.path), ['b.md']);
    expect(changes.deleted.map((c) => c.path), ['c.md']);
  });

  test('an unpaired device is refused', () async {
    final stranger = TrustedPeer(
        id: 'stranger', name: 'X', platform: DevicePlatform.unknown, secret: secret);
    expect(
      SyncClient.connect('127.0.0.1', server.boundPort,
          self: const DeviceInfo(
              id: 'stranger',
              name: 'X',
              platform: DevicePlatform.unknown,
              port: 0),
          trusted: stranger),
      throwsA(isA<SessionException>()),
    );
  });

  test('a wrong secret is refused', () async {
    final wrong = TrustedPeer(
        id: 'phone-id', name: 'Phone', platform: DevicePlatform.android, secret: 'nope');
    expect(
      SyncClient.connect('127.0.0.1', server.boundPort,
          self: phone, trusted: wrong),
      throwsA(isA<SessionException>()),
    );
  });

  test('paths escaping the shared directory are rejected', () async {
    final client = await connectClient();
    addTearDown(client.close);
    expect(
      client.fetchFile('notes', '../secret.txt'),
      throwsA(isA<SessionException>()),
    );
  });
}
