import 'dart:convert';
import 'dart:io';

import 'package:sync_net/sync_net.dart';
import 'package:test/test.dart';

/// Syncing with a device that keeps its files on Windows. The server here plays
/// one wherever the tests run; the names it cannot hold can only be made on a
/// file system that holds them, so those cases skip on Windows itself.
void main() {
  const desktop = DeviceInfo(
    id: 'desktop-id',
    name: 'Desktop',
    platform: DevicePlatform.windows,
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
      id: 'phone-id',
      name: 'Phone',
      platform: DevicePlatform.android,
      secret: secret);
  final phoneKnowsDesktop = TrustedPeer(
      id: 'desktop-id',
      name: 'Desktop',
      platform: DevicePlatform.windows,
      secret: secret);

  const unsafeHere = 'only a file system other than Windows holds these names';

  late Directory remote; // the Windows device's vault
  late Directory local; // the phone's copy
  late PeerServer server;

  Future<PeerServer> serve({required bool windowsNames}) async {
    final trust = MemoryTrustStore();
    await trust.add(desktopKnowsPhone);
    final server = PeerServer(desktop, trust,
        port: 0,
        directories: MapDirectorySource({'notes': remote.path}),
        windowsNames: windowsNames);
    await server.start();
    return server;
  }

  setUp(() async {
    remote = Directory.systemTemp.createTempSync('win_remote');
    local = Directory.systemTemp.createTempSync('win_local');
    server = await serve(windowsNames: true);
  });

  tearDown(() async {
    await server.stop();
    remote.deleteSync(recursive: true);
    local.deleteSync(recursive: true);
  });

  Future<SyncClient> connect([PeerServer? to]) => SyncClient.connect(
      '127.0.0.1', (to ?? server).boundPort,
      self: phone, trusted: phoneKnowsDesktop);

  test('the Windows device says so when the session opens', () async {
    final client = await connect();
    addTearDown(client.close);
    expect(client.peerKeepsWindowsNames, isTrue);

    final other = await serve(windowsNames: false);
    addTearDown(other.stop);
    final plain = await connect(other);
    addTearDown(plain.close);
    expect(plain.peerKeepsWindowsNames, isFalse);
  });

  test('a name Windows cannot hold stays put on both sides, sync after sync',
      () async {
    File('${local.path}/ok.md').writeAsStringSync('fine');
    File('${local.path}/Встреча 10:30.md').writeAsStringSync('kept here');

    final client = await connect();
    addTearDown(client.close);

    final first = await computeMerge(
        client, 'notes', local, Manifest(<String, FileEntry>{}));
    expect(first.skipped, ['Встреча 10:30.md']);
    expect(first.items.map((i) => i.path), ['ok.md']);

    final outcome = await runSync(client, 'notes', local,
        Manifest(<String, FileEntry>{}),
        first.items.map(ResolvedMerge.natural).toList());
    expect(outcome.report.ok, isTrue);
    expect(remote.listSync().map((e) => e.uri.pathSegments.last), ['ok.md']);

    // The recorded base is this whole folder, the skipped file included. The
    // Windows side not having it must not read as a deletion over there.
    final second = await computeMerge(client, 'notes', local, outcome.newBase!);
    expect(second.items, isEmpty);
    expect(File('${local.path}/Встреча 10:30.md').existsSync(), isTrue);
  }, skip: Platform.isWindows ? unsafeHere : false);

  test('two spellings of one name are both left out', () async {
    File('${local.path}/Note.md').writeAsStringSync('one');
    File('${local.path}/note.md').writeAsStringSync('two');

    final client = await connect();
    addTearDown(client.close);
    final merge = await computeMerge(
        client, 'notes', local, Manifest(<String, FileEntry>{}));
    expect(merge.items, isEmpty);
    expect(merge.skipped, ['Note.md', 'note.md']);
  }, skip: Platform.isWindows ? unsafeHere : false);

  test('a device that does not know the rules is refused such a name',
      () async {
    final client = await connect();
    addTearDown(client.close);
    await expectLater(
      client.putFile('notes', 'a:b.md', utf8.encode('x'), expectAbsent: true),
      throwsA(isA<SessionException>()),
    );
    expect(remote.listSync(), isEmpty);
  });

  test('a write that differs only in case does not land in the other file',
      () async {
    File('${remote.path}/Note.md').writeAsStringSync('original');

    final client = await connect();
    addTearDown(client.close);
    await expectLater(
      client.putFile('notes', 'note.md', utf8.encode('other')),
      throwsA(isA<SessionException>()),
    );
    expect(File('${remote.path}/Note.md').readAsStringSync(), 'original');
  }, skip: Platform.isWindows ? false : 'needs a case-insensitive file system');

  test('a rename that only changes letter case reaches the other side',
      () async {
    File('${remote.path}/Note.md').writeAsStringSync('text');
    File('${local.path}/Note.md').writeAsStringSync('text');
    final base = await Manifest.scan(local);
    File('${local.path}/Note.md').renameSync('${local.path}/note.md');

    final client = await connect();
    addTearDown(client.close);
    final merge = await computeMerge(client, 'notes', local, base);
    expect(merge.skipped, isEmpty);

    final outcome = await runSync(client, 'notes', local, base,
        merge.items.map(ResolvedMerge.natural).toList());
    expect(outcome.report.ok, isTrue, reason: '${outcome.report.failures}');
    expect(remote.listSync().map((e) => e.uri.pathSegments.last), ['note.md']);
  });
}
