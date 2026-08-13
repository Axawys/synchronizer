import 'dart:io';

import 'package:sync_net/sync_net.dart';
import 'package:test/test.dart';

/// What happens when the far end changes between working out a sync and
/// applying it - which is what two devices syncing with one at the same time
/// looks like from inside.
void main() {
  const pc = DeviceInfo(
      id: 'pc', name: 'PC', platform: DevicePlatform.linux, port: 0);
  const phone = DeviceInfo(
      id: 'phone', name: 'Phone', platform: DevicePlatform.android, port: 0);
  const secret = 'shared';

  late Directory onPc;
  late Directory onPhone;
  late PeerServer server;
  late SyncClient session;

  setUp(() async {
    onPc = Directory.systemTemp.createTempSync('pc_vault');
    onPhone = Directory.systemTemp.createTempSync('phone_vault');

    final trust = MemoryTrustStore();
    await trust.add(const TrustedPeer(
        id: 'phone',
        name: 'Phone',
        platform: DevicePlatform.android,
        secret: secret));
    server = PeerServer(pc, trust,
        port: 0, directories: MapDirectorySource({'vault': onPc.path}));
    await server.start();

    session = await SyncClient.connect(
      '127.0.0.1',
      server.boundPort,
      self: phone,
      trusted: const TrustedPeer(
          id: 'pc', name: 'PC', platform: DevicePlatform.linux, secret: secret),
    );
  });

  tearDown(() async {
    await session.close();
    await server.stop();
    onPc.deleteSync(recursive: true);
    onPhone.deleteSync(recursive: true);
  });

  test('a push does not overwrite what someone else wrote in the meantime',
      () async {
    // Everything agrees on "one".
    File('${onPc.path}/note.md').writeAsStringSync('one\n');
    File('${onPhone.path}/note.md').writeAsStringSync('one\n');
    final base = await Manifest.scan(onPhone);

    // The phone adds a line and works out what to do: send its version.
    File('${onPhone.path}/note.md').writeAsStringSync('one\nphone\n');
    final merge = await computeMerge(session, 'vault', onPhone, base);
    expect(merge.pushes, hasLength(1));

    // Before it gets round to sending it, the PC gains a line of its own -
    // typed there, or pushed by a tablet syncing at the same moment.
    File('${onPc.path}/note.md').writeAsStringSync('one\ntwo\n');

    final report = await applyMerge(session, 'vault', onPhone,
        [for (final item in merge.items) ResolvedMerge.natural(item)]);

    // The plan was made against a file that no longer exists in that form.
    // Carrying it out would delete a line nobody agreed to lose, so it has to
    // fail instead - loudly enough that the base is not advanced and the next
    // sync sees a real conflict.
    expect(report.ok, isFalse,
        reason: 'the PC line "two" must not vanish without anyone deciding it');
    expect(File('${onPc.path}/note.md').readAsStringSync(), 'one\ntwo\n');
  });

  test('a delete does not remove a file that changed in the meantime',
      () async {
    File('${onPc.path}/note.md').writeAsStringSync('one\n');
    File('${onPhone.path}/note.md').writeAsStringSync('one\n');
    final base = await Manifest.scan(onPhone);

    // The phone deletes it and works out that the deletion should travel.
    File('${onPhone.path}/note.md').deleteSync();
    final merge = await computeMerge(session, 'vault', onPhone, base);
    expect(merge.pushes, hasLength(1));

    // Meanwhile it is edited on the PC. An edit beats a delete decided against
    // an older version of the file.
    File('${onPc.path}/note.md').writeAsStringSync('one\ntwo\n');

    final report = await applyMerge(session, 'vault', onPhone,
        [for (final item in merge.items) ResolvedMerge.natural(item)]);

    expect(report.ok, isFalse);
    expect(File('${onPc.path}/note.md').existsSync(), isTrue);
  });

  test('two devices cannot sync the same folder at the same moment', () async {
    File('${onPc.path}/note.md').writeAsStringSync('one\n');

    // A second device opens its own session while the first is mid-sync.
    const tablet = DeviceInfo(
        id: 'tablet',
        name: 'Tablet',
        platform: DevicePlatform.android,
        port: 0);
    await server.trust.add(const TrustedPeer(
        id: 'tablet',
        name: 'Tablet',
        platform: DevicePlatform.android,
        secret: secret));
    final second = await SyncClient.connect(
      '127.0.0.1',
      server.boundPort,
      self: tablet,
      trusted: const TrustedPeer(
          id: 'pc', name: 'PC', platform: DevicePlatform.linux, secret: secret),
    );
    addTearDown(second.close);

    // The first one is holding the folder for the length of its session.
    await session.fetchManifest('vault');

    // Half a sync each and a pile of failures is not better than waiting, so
    // the second is turned away with a reason.
    expect(
      () => second.fetchManifest('vault'),
      throwsA(isA<SessionException>()),
    );
  });

  test('the same device syncing again takes over from itself', () async {
    // A socket closing is not instant: if a device had to compete with its own
    // last session, every second sync would fail.
    File('${onPc.path}/note.md').writeAsStringSync('one\n');
    await session.fetchManifest('vault');

    final again = await SyncClient.connect(
      '127.0.0.1',
      server.boundPort,
      self: phone,
      trusted: const TrustedPeer(
          id: 'pc', name: 'PC', platform: DevicePlatform.linux, secret: secret),
    );
    addTearDown(again.close);

    expect((await again.fetchManifest('vault')).entries, hasLength(1));
  });

  test('the folder is free again once the session ends', () async {
    File('${onPc.path}/note.md').writeAsStringSync('one\n');
    await session.fetchManifest('vault');
    await session.close();

    final again = await SyncClient.connect(
      '127.0.0.1',
      server.boundPort,
      self: phone,
      trusted: const TrustedPeer(
          id: 'pc', name: 'PC', platform: DevicePlatform.linux, secret: secret),
    );
    addTearDown(again.close);

    final manifest = await again.fetchManifest('vault');
    expect(manifest.entries, hasLength(1));
    session = again; // so the teardown closes something live
  });

  test('an ordinary push still goes through', () async {
    File('${onPhone.path}/note.md').writeAsStringSync('one\n');
    final merge =
        await computeMerge(session, 'vault', onPhone, Manifest({}));

    final report = await applyMerge(session, 'vault', onPhone,
        [for (final item in merge.items) ResolvedMerge.natural(item)]);

    expect(report.ok, isTrue);
    expect(File('${onPc.path}/note.md').readAsStringSync(), 'one\n');
  });
}
