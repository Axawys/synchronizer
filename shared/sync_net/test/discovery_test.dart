import 'dart:convert';
import 'dart:io';

import 'package:sync_net/sync_net.dart';
import 'package:test/test.dart';

void main() {
  group('DeviceInfo', () {
    test('announcement round-trips and takes address from the wire', () {
      final device = DeviceInfo(
        id: 'abc123',
        name: 'thinkpad',
        platform: DevicePlatform.linux,
        port: 47800,
      );

      final restored = DeviceInfo.fromAnnouncement(
        device.toAnnouncement(),
        address: '192.168.1.5',
      );

      expect(restored.id, device.id);
      expect(restored.name, 'thinkpad');
      expect(restored.platform, DevicePlatform.linux);
      expect(restored.port, 47800);
      expect(restored.address, '192.168.1.5');
    });

    test('an announcement never carries its own address', () {
      final device = DeviceInfo(
        id: 'x',
        name: 'phone',
        platform: DevicePlatform.android,
        port: 1,
        address: '10.0.0.9',
      );
      expect(device.toAnnouncement().containsKey('address'), isFalse);
    });

    test('generateId produces distinct 32-char hex ids', () {
      final a = DeviceInfo.generateId();
      final b = DeviceInfo.generateId();
      expect(a, hasLength(32));
      expect(a, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(a, isNot(b));
    });

    test('randomFriendlyName is a readable two-word name', () {
      final name = DeviceInfo.randomFriendlyName();
      expect(name, matches(RegExp(r'^[A-Z][a-z]+ [A-Z][a-z]+$')));

      // Enough variety that two devices are unlikely to collide.
      final names = {for (var i = 0; i < 50; i++) DeviceInfo.randomFriendlyName()};
      expect(names.length, greaterThan(10));
    });

    test('identity is the id, not the name', () {
      const a = DeviceInfo(
          id: 'same', name: 'old', platform: DevicePlatform.linux, port: 1);
      const b = DeviceInfo(
          id: 'same', name: 'new', platform: DevicePlatform.linux, port: 2);
      expect(a, b);
    });
  });

  group('DiscoveryService over loopback', () {
    const fastConfig = DiscoveryConfig(
      announceInterval: Duration(milliseconds: 150),
      staleAfter: Duration(milliseconds: 400),
    );

    late DiscoveryService alice;
    late DiscoveryService bob;

    setUp(() {
      alice = DiscoveryService(
        const DeviceInfo(
            id: 'alice', name: 'Alice', platform: DevicePlatform.linux, port: 1000),
        config: fastConfig,
      );
      bob = DiscoveryService(
        const DeviceInfo(
            id: 'bob', name: 'Bob', platform: DevicePlatform.android, port: 2000),
        config: fastConfig,
      );
    });

    tearDown(() async {
      await alice.stop();
      await bob.stop();
    });

    test('two devices find each other', () async {
      await alice.start();
      await bob.start();

      final aliceSeesBob = alice.peers.firstWhere(
        (list) => list.any((d) => d.id == 'bob'),
      );
      final bobSeesAlice = bob.peers.firstWhere(
        (list) => list.any((d) => d.id == 'alice'),
      );

      final bobAsSeen =
          (await aliceSeesBob.timeout(const Duration(seconds: 5)))
              .firstWhere((d) => d.id == 'bob');
      await bobSeesAlice.timeout(const Duration(seconds: 5));

      expect(bobAsSeen.name, 'Bob');
      expect(bobAsSeen.platform, DevicePlatform.android);
      expect(bobAsSeen.port, 2000);
      expect(bobAsSeen.address, isNotNull);
    });

    test('a device never discovers itself', () async {
      await alice.start();
      // Give announcements time to circulate.
      await alice.peers.firstWhere((_) => true).timeout(
            const Duration(seconds: 5),
            onTimeout: () => const <DeviceInfo>[],
          );
      expect(alice.current.any((d) => d.id == 'alice'), isFalse);
    });

    test('a peer that shuts down cleanly disappears at once', () async {
      await alice.start();
      await bob.start();

      await alice.peers
          .firstWhere((list) => list.any((d) => d.id == 'bob'))
          .timeout(const Duration(seconds: 5));

      final bobGone = alice.peers.firstWhere(
        (list) => list.every((d) => d.id != 'bob'),
      );
      await bob.stop(); // sends the goodbye

      // Well inside staleAfter, so this can only be the goodbye taking effect.
      await bobGone.timeout(const Duration(milliseconds: 300));
      expect(alice.current.any((d) => d.id == 'bob'), isFalse);
    });

    test('a peer that is killed without a goodbye is pruned on timeout',
        () async {
      await alice.start();

      // Announce a device once from a raw socket and then go quiet, the way a
      // force-closed app or a dropped Wi-Fi connection would.
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.send(
        utf8.encode(jsonEncode({
          'magic': 'synchronizer/1',
          'type': 'announce',
          'device': const DeviceInfo(
            id: 'ghost',
            name: 'Ghost',
            platform: DevicePlatform.android,
            port: 47800,
          ).toAnnouncement(),
        })),
        InternetAddress(fastConfig.multicastAddress),
        fastConfig.port,
      );
      addTearDown(socket.close);

      await alice.peers
          .firstWhere((list) => list.any((d) => d.id == 'ghost'))
          .timeout(const Duration(seconds: 5));

      final gone =
          alice.peers.firstWhere((list) => list.every((d) => d.id != 'ghost'));
      await gone.timeout(const Duration(seconds: 5));
      expect(alice.current.any((d) => d.id == 'ghost'), isFalse);
    });
  });
}
