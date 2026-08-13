import 'dart:io';

import 'package:sync_net/sync_net.dart';
import 'package:test/test.dart';

/// The stages a sync reports on its way to showing what will change. They are
/// the only thing standing between a tap and several silent seconds.
void main() {
  const desktop = DeviceInfo(
      id: 'desktop', name: 'Desktop', platform: DevicePlatform.linux, port: 0);
  const phone = DeviceInfo(
      id: 'phone', name: 'Phone', platform: DevicePlatform.android, port: 0);
  const secret = 'shared';

  late Directory remote;
  late Directory local;
  late PeerServer server;
  late SyncClient client;

  setUp(() async {
    remote = Directory.systemTemp.createTempSync('prog_remote');
    local = Directory.systemTemp.createTempSync('prog_local');

    final trust = MemoryTrustStore();
    await trust.add(const TrustedPeer(
        id: 'phone', name: 'Phone', platform: DevicePlatform.android,
        secret: secret));
    server = PeerServer(desktop, trust,
        port: 0, directories: MapDirectorySource({'notes': remote.path}));
    await server.start();

    client = await SyncClient.connect(
      '127.0.0.1',
      server.boundPort,
      self: phone,
      trusted: const TrustedPeer(
          id: 'desktop', name: 'Desktop', platform: DevicePlatform.linux,
          secret: secret),
    );
  });

  tearDown(() async {
    await client.close();
    await server.stop();
    remote.deleteSync(recursive: true);
    local.deleteSync(recursive: true);
  });

  test('working out what changed reports each stage in order', () async {
    File('${remote.path}/note.md').writeAsStringSync('one\n');

    final seen = <SyncPhase>[];
    await computeMerge(client, 'notes', local, Manifest({}),
        onProgress: (p) => seen.add(p.phase));

    expect(seen, [SyncPhase.asking, SyncPhase.scanning, SyncPhase.comparing]);
  });

  test('building the preview counts the files it reads', () async {
    for (final name in ['a.md', 'b.md', 'c.md']) {
      File('${remote.path}/$name').writeAsStringSync('text of $name\n');
    }

    final merge = await computeMerge(client, 'notes', local, Manifest({}));
    final progress = <SyncProgress>[];
    await buildPreview(client, 'notes', local, merge,
        onProgress: progress.add);

    expect(progress.every((p) => p.phase == SyncPhase.reading), isTrue);
    expect(progress.first.done, 0);
    expect(progress.first.total, 3);
    // The last one says it is finished, so the bar reaches its end rather than
    // vanishing at two thirds.
    expect(progress.last.done, 3);
    expect(progress.last.fraction, 1.0);
  });

  test('a stage with nothing to count says so instead of guessing', () {
    const asking = SyncProgress(SyncPhase.asking);
    expect(asking.isCountable, isFalse);
    expect(asking.fraction, isNull);
  });
}
