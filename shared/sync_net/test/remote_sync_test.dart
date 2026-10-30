import 'dart:async';

import 'package:sync_net/sync_net.dart';
import 'package:test/test.dart';

/// A device being synced with hears about it, for as long as it lasts: it is
/// how the animation starts there too and not only where the tap was.
void main() {
  const desktop = DeviceInfo(
      id: 'desktop', name: 'Desktop', platform: DevicePlatform.linux, port: 0);
  const phone = DeviceInfo(
      id: 'phone', name: 'Phone', platform: DevicePlatform.android, port: 0);
  const tablet = DeviceInfo(
      id: 'tablet', name: 'Tablet', platform: DevicePlatform.android, port: 0);

  late PeerServer server;

  setUp(() async {
    final trust = MemoryTrustStore();
    await trust.add(const TrustedPeer(
        id: 'phone',
        name: 'Phone',
        platform: DevicePlatform.android,
        secret: 's'));
    server = PeerServer(desktop, trust, port: 0);
    await server.start();
  });

  tearDown(() => server.stop());

  Future<SyncAnnouncement?> announce(List<DeviceInfo> participants) =>
      SyncAnnouncement.open(
        '127.0.0.1',
        server.boundPort,
        self: phone,
        trusted: const TrustedPeer(
            id: 'desktop',
            name: 'Desktop',
            platform: DevicePlatform.linux,
            secret: 's'),
        participants: participants,
      );

  test('the announced sync names everyone in it, the sender first', () async {
    final heard = server.remoteSyncs.first;
    final announcement = await announce([desktop, phone, tablet]);
    addTearDown(() => announcement?.close());

    expect(announcement, isNotNull);
    final sync = await heard.timeout(const Duration(seconds: 5));
    expect(sync.from.id, 'phone');
    expect(sync.participants.map((d) => d.id), ['phone', 'desktop', 'tablet']);
    expect(sync.isOver, isFalse);
  });

  test('closing the announcement ends the sync on the other side', () async {
    final heard = server.remoteSyncs.first;
    final announcement = await announce([phone, desktop]);
    final sync = await heard.timeout(const Duration(seconds: 5));

    await announcement!.close();
    await sync.ended.timeout(const Duration(seconds: 5));
    expect(sync.isOver, isTrue);
    expect(sync.succeeded, isFalse);
  });

  test('a sync that went through says so as it ends', () async {
    final heard = server.remoteSyncs.first;
    final announcement = await announce([phone, desktop]);
    final sync = await heard.timeout(const Duration(seconds: 5));

    await announcement!.close(succeeded: true);
    await sync.ended.timeout(const Duration(seconds: 5));
    expect(sync.succeeded, isTrue);
  });

  test('the sender is the device that authenticated, whatever it claims',
      () async {
    final heard = server.remoteSyncs.first;
    final announcement = await announce([
      const DeviceInfo(
          id: 'phone',
          name: 'Somebody else',
          platform: DevicePlatform.linux,
          port: 0),
      desktop,
    ]);
    addTearDown(() => announcement?.close());

    final sync = await heard.timeout(const Duration(seconds: 5));
    // The name the pairing knows, not the one in the list.
    expect(sync.from.name, 'Phone');
    expect(sync.participants.where((d) => d.id == 'phone'), hasLength(1));
  });

  test('an unpaired device announces nothing', () async {
    var heard = false;
    final sub = server.remoteSyncs.listen((_) => heard = true);
    addTearDown(sub.cancel);

    final announcement = await SyncAnnouncement.open(
      '127.0.0.1',
      server.boundPort,
      self: tablet,
      trusted: const TrustedPeer(
          id: 'desktop',
          name: 'Desktop',
          platform: DevicePlatform.linux,
          secret: 's'),
      participants: [tablet, desktop],
    );

    expect(announcement, isNull);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(heard, isFalse);
  });
}
