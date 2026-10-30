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
    // A group and port of their own: on the real ones these tests share the
    // air with any copy of the app running on this machine, and a passing suite
    // would depend on nobody having it open.
    const fastConfig = DiscoveryConfig(
      multicastAddress: '239.255.42.98',
      port: 47911,
      announceInterval: Duration(milliseconds: 150),
      staleAfter: Duration(milliseconds: 400),
    );

    late DiscoveryService alice;
    late DiscoveryService bob;

    setUp(() {
      // These are about the mechanics of finding each other, not about whether
      // the far end has its app open - so the door is always answered here, and
      // the knocking has a group of its own below.
      alice = DiscoveryService(
        const DeviceInfo(
            id: 'alice', name: 'Alice', platform: DevicePlatform.linux, port: 1000),
        config: fastConfig,
        probe: _answers,
      );
      bob = DiscoveryService(
        const DeviceInfo(
            id: 'bob', name: 'Bob', platform: DevicePlatform.android, port: 2000),
        config: fastConfig,
        probe: _answers,
      );
    });

    tearDown(() async {
      await alice.dispose();
      await bob.dispose();
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

    test('discovery survives being stopped and started again', () async {
      // What the phone does every time the app goes to the background and
      // comes back: the screen keeps its subscription across the pause.
      await bob.start();
      await alice.start();
      await alice.peers
          .firstWhere((list) => list.any((d) => d.id == 'bob'))
          .timeout(const Duration(seconds: 5));

      final afterRestart =
          alice.peers.firstWhere((list) => list.any((d) => d.id == 'bob'));

      await alice.stop();
      expect(alice.isRunning, isFalse);
      expect(alice.current, isEmpty, reason: 'nothing is reachable while off');

      await alice.start();
      await afterRestart.timeout(const Duration(seconds: 5));
    });

    test('a socket taken away under us is rebuilt without being asked',
        () async {
      await bob.start();
      await alice.start();
      await alice.peers
          .firstWhere((list) => list.any((d) => d.id == 'bob'))
          .timeout(const Duration(seconds: 5));

      // What Android does to a backgrounded app, and what an interface going
      // down does on a laptop. Nobody tells the service; it has to notice.
      alice.dropSocketForTesting();

      await _until(() => alice.current.any((d) => d.id == 'bob'),
          timeout: const Duration(seconds: 10));
      expect(alice.isRunning, isTrue);
    });

    test('asking to look again starts discovery that had been paused',
        () async {
      await bob.start();
      await alice.start();
      await alice.stop();
      expect(alice.isRunning, isFalse);

      await alice.refresh();

      expect(alice.isRunning, isTrue);
      await _until(() => alice.current.any((d) => d.id == 'bob'));
    });

    test('a renamed device is called by its new name on the other screen',
        () async {
      await bob.start();
      await alice.start();
      await alice.peers
          .firstWhere((list) => list.any((d) => d.name == 'Bob'))
          .timeout(const Duration(seconds: 5));

      final renamed =
          alice.peers.firstWhere((list) => list.any((d) => d.name == 'Study'));
      bob.rename('Study');

      // Straight away, not at the next tick: the point of renaming a device is
      // to stop looking at the old name.
      await renamed.timeout(const Duration(seconds: 2));
      expect(alice.current.single.id, 'bob', reason: 'same device, new name');
    });

    test('the list is in a stable order, not the order packets arrived',
        () async {
      final probe = await _openProbe(fastConfig);
      addTearDown(probe.close);
      await alice.start();

      for (final name in ['Zebra', 'apple', 'Mango']) {
        _announceFrom(probe, fastConfig, {
          'id': 'id-$name',
          'name': name,
          'platform': 'linux',
          'port': 47800,
        });
      }

      await _until(() => alice.current.length == 3);
      expect(alice.current.map((d) => d.name), ['apple', 'Mango', 'Zebra']);
    });

    test('a device announcing down two paths keeps one address', () async {
      // A machine with a docker bridge, a VPN, or two networks onto the same
      // segment announces on every interface, and several copies arrive from
      // different source addresses. Taking the latest would flap the address
      // every couple of seconds and reconnect any open sync screen with it.
      // Sent as unicast so both copies certainly arrive, which is the point;
      // what is being tested is what happens when they do.
      final elsewhere = await _anotherLocalAddress();
      if (elsewhere == null) return; // one interface, nothing to flap between

      final viaLoopback = await _openSender(InternetAddress.loopbackIPv4);
      final viaInterface = await _openSender(elsewhere);
      addTearDown(viaLoopback.close);
      addTearDown(viaInterface.close);
      await alice.start();

      const device = {
        'id': 'twinned',
        'name': 'Twinned',
        'platform': 'linux',
        'port': 47800,
      };

      _announceFrom(viaLoopback, fastConfig, device,
          to: InternetAddress.loopbackIPv4);
      await _until(() => alice.current.isNotEmpty);
      final settled = alice.current.single.address;
      expect(settled, InternetAddress.loopbackIPv4.address);

      for (var i = 0; i < 5; i++) {
        _announceFrom(viaInterface, fastConfig, device, to: elsewhere);
        _announceFrom(viaLoopback, fastConfig, device,
            to: InternetAddress.loopbackIPv4);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }

      expect(alice.current.single.address, settled,
          reason: 'the address in use answers, so it is kept');
    });

    test('a device that stops answering at its address is followed to the new one',
        () async {
      final elsewhere = await _anotherLocalAddress();
      if (elsewhere == null) return;

      final viaLoopback = await _openSender(InternetAddress.loopbackIPv4);
      final viaInterface = await _openSender(elsewhere);
      addTearDown(viaLoopback.close);
      addTearDown(viaInterface.close);
      await alice.start();

      const device = {
        'id': 'mover',
        'name': 'Mover',
        'platform': 'android',
        'port': 47800,
      };

      _announceFrom(viaLoopback, fastConfig, device,
          to: InternetAddress.loopbackIPv4);
      await _until(() => alice.current.isNotEmpty);

      // The old path goes quiet - a phone that rejoined the Wi-Fi with a new
      // lease. Once it has been silent for staleAfter, the new one is adopted.
      await Future<void>.delayed(fastConfig.staleAfter);
      _announceFrom(viaInterface, fastConfig, device, to: elsewhere);

      await _until(() => alice.current.any((d) => d.address == elsewhere.address));
    });

    test('an announcement that cannot be true is ignored', () async {
      final probe = await _openProbe(fastConfig);
      addTearDown(probe.close);
      await alice.start();

      const wire = {'platform': 'linux', 'port': 47800};
      _announceFrom(probe, fastConfig, {...wire, 'id': '', 'name': 'Nameless'});
      _announceFrom(probe, fastConfig, {...wire, 'id': 'blank', 'name': '   '});
      _announceFrom(probe, fastConfig,
          {'id': 'noport', 'name': 'No port', 'platform': 'linux', 'port': 0});
      _announceFrom(probe, fastConfig, {...wire, 'id': 'ok', 'name': 'Real'});

      await _until(() => alice.current.any((d) => d.id == 'ok'));
      expect(alice.current.map((d) => d.id),
          isNot(anyOf(contains(''), contains('blank'), contains('noport'))));
    });

    test('a name that would wreck the list is cut down to size', () async {
      final probe = await _openProbe(fastConfig);
      addTearDown(probe.close);
      await alice.start();

      _announceFrom(probe, fastConfig, {
        'id': 'shouty',
        'name': 'Line one\nLine two${'!' * 200}',
        'platform': 'android',
        'port': 47800,
      });

      await _until(() => alice.current.isNotEmpty);
      final name = alice.current.single.name;
      expect(name.length, lessThanOrEqualTo(64));
      expect(name, isNot(contains('\n')));
      expect(name, startsWith('Line one Line two'));
    });

    test('invented devices cannot crowd out the real ones', () async {
      const capped = DiscoveryConfig(
        multicastAddress: '239.255.42.98',
        port: 47911,
        announceInterval: Duration(milliseconds: 150),
        staleAfter: Duration(milliseconds: 400),
        maxPeers: 2,
      );
      final service = DiscoveryService(
        const DeviceInfo(
            id: 'alice',
            name: 'Alice',
            platform: DevicePlatform.linux,
            port: 1),
        config: capped,
        probe: _answers,
      );
      addTearDown(service.dispose);

      final probe = await _openProbe(capped);
      addTearDown(probe.close);
      await service.start();

      for (var i = 0; i < 20; i++) {
        _announceFrom(probe, capped, {
          'id': 'flood-$i',
          'name': 'Flood $i',
          'platform': 'linux',
          'port': 47800,
        });
      }

      await _until(() => service.current.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(service.current, hasLength(2));
    });

    test('a device that announces but is not listening is never shown',
        () async {
      // The packets a network makes on its own - a reflected broadcast, an app
      // that closed a second ago - used to sit in the list for a few seconds
      // before being pruned. Nothing is behind them, so nothing is shown.
      final probe = await _openProbe(fastConfig);
      addTearDown(probe.close);
      await alice.dispose();

      final strict = DiscoveryService(
        const DeviceInfo(
            id: 'alice', name: 'Alice', platform: DevicePlatform.linux, port: 1),
        config: fastConfig,
        probe: (address, port) async => false, // nobody home
      );
      addTearDown(strict.dispose);
      await strict.start();

      _announceFrom(probe, fastConfig, {
        'id': 'phantom',
        'name': 'Phantom',
        'platform': 'linux',
        'port': 47800,
      });
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(strict.current, isEmpty);
    });

    test('a device with the app open is shown once it answers', () async {
      final probe = await _openProbe(fastConfig);
      addTearDown(probe.close);
      await alice.dispose();

      final knocks = <String>[];
      final strict = DiscoveryService(
        const DeviceInfo(
            id: 'alice', name: 'Alice', platform: DevicePlatform.linux, port: 1),
        config: fastConfig,
        probe: (address, port) async {
          knocks.add('$address:$port');
          return true;
        },
      );
      addTearDown(strict.dispose);
      await strict.start();

      for (var i = 0; i < 4; i++) {
        _announceFrom(probe, fastConfig, {
          'id': 'real',
          'name': 'Real',
          'platform': 'android',
          'port': 47800,
        });
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }

      await _until(() => strict.current.any((d) => d.id == 'real'));
      // Announcements keep coming every couple of seconds; the door is knocked
      // on once, not once per packet.
      expect(knocks, hasLength(1));
      expect(knocks.single, endsWith(':47800'));
    });

    test('a device answers a peer it has never heard of at once', () async {
      // The interval is long enough that a scheduled announcement cannot be
      // what the probe hears: anything arriving is a direct answer.
      const slow = DiscoveryConfig(
        multicastAddress: '239.255.42.98',
        port: 47911,
        announceInterval: Duration(seconds: 10),
        staleAfter: Duration(seconds: 30),
      );
      final service = DiscoveryService(
        const DeviceInfo(
            id: 'alice',
            name: 'Alice',
            platform: DevicePlatform.linux,
            port: 1),
        config: slow,
        probe: _answers,
      );
      addTearDown(service.dispose);

      final probe = await _openProbe(slow);
      addTearDown(probe.close);

      var answers = 0;
      probe.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = probe.receive();
        if (datagram == null) return;
        final message =
            jsonDecode(utf8.decode(datagram.data)) as Map<String, Object?>;
        if (message['type'] != 'announce') return;
        final device = message['device']! as Map<String, Object?>;
        if (device['id'] == 'alice') answers++;
      });

      await service.start();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final before = answers; // the announcement made on startup

      _announceFrom(probe, slow, {
        'id': 'newcomer',
        'name': 'Newcomer',
        'platform': 'android',
        'port': 47800,
      });

      await _until(() => answers > before,
          timeout: const Duration(seconds: 2));
      expect(answers, greaterThan(before));
    });
  });
}

/// Says yes to every knock: for tests about discovery itself.
Future<bool> _answers(String address, int port) async => true;

/// A bare socket on the discovery group, standing in for another device.
Future<RawDatagramSocket> _openProbe(DiscoveryConfig config) async {
  final socket = await RawDatagramSocket.bind(
    InternetAddress.anyIPv4,
    config.port,
    reuseAddress: true,
    reusePort: !Platform.isWindows,
  );
  socket.multicastLoopback = true;
  socket.broadcastEnabled = true;
  socket.joinMulticast(InternetAddress(config.multicastAddress));
  return socket;
}

/// An address of this machine other than loopback, or null if it has none - on
/// such a machine there is nothing for an address to flap between.
Future<InternetAddress?> _anotherLocalAddress() async {
  final interfaces = await NetworkInterface.list(
    includeLoopback: false,
    includeLinkLocal: false,
    type: InternetAddressType.IPv4,
  );
  for (final interface in interfaces) {
    for (final address in interface.addresses) {
      return address;
    }
  }
  return null;
}

/// A socket bound to one interface, so its packets carry that source address.
Future<RawDatagramSocket> _openSender(InternetAddress address) async {
  final socket = await RawDatagramSocket.bind(address, 0);
  socket.multicastLoopback = true;
  socket.broadcastEnabled = true;
  return socket;
}

void _announceFrom(
  RawDatagramSocket socket,
  DiscoveryConfig config,
  Map<String, Object?> device, {
  InternetAddress? to,
}) {
  socket.send(
    utf8.encode(jsonEncode({
      'magic': 'synchronizer/1',
      'type': 'announce',
      'device': device,
    })),
    to ?? InternetAddress(config.multicastAddress),
    config.port,
  );
}

/// Waits for [condition], which becomes true when a packet lands rather than
/// when a future completes.
Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
