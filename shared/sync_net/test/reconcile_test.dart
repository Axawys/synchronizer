import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
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

  test('a merge reports success and lets the caller trust the result', () async {
    File('${local.path}/a.md').writeAsStringSync('a');
    final client = await connect();
    addTearDown(client.close);

    final merge = await computeMerge(client, 'notes', local, Manifest({}));
    final report = await applyMerge(
        client, 'notes', local, merge.items.map(ResolvedMerge.natural).toList());

    expect(report.ok, isTrue);
    expect(report.applied, 1);
    expect(report.failures, isEmpty);
  });

  test('one unreadable file fails alone; the rest still sync', () async {
    File('${local.path}/good.md').writeAsStringSync('fine');
    // A path recorded in the manifest but missing on disk stands in for a file
    // that cannot be read when the push tries to send it.
    final ghost = FileEntry(
        path: 'ghost.md', size: 1, modified: DateTime.utc(2026), hash: 'deadbeef');

    final client = await connect();
    addTearDown(client.close);

    final merge = await computeMerge(client, 'notes', local, Manifest({}));
    final resolved = [
      ...merge.items.map(ResolvedMerge.natural),
      ResolvedMerge(
        MergeItem(
            path: 'ghost.md', kind: MergeKind.pushToRemote, local: ghost),
        toLocal: false,
      ),
    ];

    final report = await applyMerge(client, 'notes', local, resolved);

    expect(report.ok, isFalse);
    expect(report.applied, 1); // good.md still made it
    expect(report.failures.single.path, 'ghost.md');
    expect(File('${remote.path}/good.md').readAsStringSync(), 'fine');
  });

  test('the peer rejects a put whose body does not match its hash', () async {
    // putFile always sends the true hash, so speak the protocol directly to
    // advertise a wrong one and prove the peer refuses to write it.
    final conn = await PeerConnection.connect('127.0.0.1', server.boundPort);
    final frames = StreamIterator(conn.frames);
    addTearDown(() async {
      await frames.cancel();
      await conn.close();
    });

    conn.send({'type': SessionType.hello, 'deviceId': phone.id});
    await frames.moveNext();
    final serverNonce = frames.current.header['nonce']! as String;

    conn.send({
      'type': SessionType.auth,
      'nonce': 'client-nonce',
      'mac': Hmac(sha256, utf8.encode(secret))
          .convert(utf8.encode('client:$serverNonce'))
          .toString(),
    });
    await frames.moveNext();
    expect(frames.current.type, SessionType.ok);

    conn.send({
      'type': SessionType.putFile,
      'name': 'notes',
      'path': 'bad.md',
      'hash': 'not-the-real-hash',
    }, [1, 2, 3]);
    await frames.moveNext();

    expect(frames.current.type, SessionType.error);
    expect(frames.current.header['message'], 'hash mismatch');
    expect(File('${remote.path}/bad.md').existsSync(), isFalse);
  });

  test('a folder deleted here is removed on the peer too', () async {
    // Both sides agree on a vault holding a subfolder.
    for (final root in [local, remote]) {
      File('${root.path}/notes/deep.md')
        ..createSync(recursive: true)
        ..writeAsStringSync('x');
      File('${root.path}/keep.md').writeAsStringSync('k');
    }
    final base = await Manifest.scan(local);

    // Delete the whole subfolder locally.
    Directory('${local.path}/notes').deleteSync(recursive: true);

    final client = await connect();
    addTearDown(client.close);

    final merge = await computeMerge(client, 'notes', local, base);
    await applyMerge(
        client, 'notes', local, merge.items.map(ResolvedMerge.natural).toList());

    expect(Directory('${remote.path}/notes').existsSync(), isFalse,
        reason: 'the folder itself should be gone, not just its files');
    expect(File('${remote.path}/keep.md').existsSync(), isTrue);
    await expectSidesMatch();
  });

  test('a folder deleted on the peer is removed here too', () async {
    for (final root in [local, remote]) {
      File('${root.path}/notes/deep.md')
        ..createSync(recursive: true)
        ..writeAsStringSync('x');
    }
    final base = await Manifest.scan(local);

    Directory('${remote.path}/notes').deleteSync(recursive: true);

    final client = await connect();
    addTearDown(client.close);

    final merge = await computeMerge(client, 'notes', local, base);
    await applyMerge(
        client, 'notes', local, merge.items.map(ResolvedMerge.natural).toList());

    expect(Directory('${local.path}/notes').existsSync(), isFalse);
    expect(local.existsSync(), isTrue, reason: 'the sync root itself stays');
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
