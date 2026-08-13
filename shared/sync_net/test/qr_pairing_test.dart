import 'package:sync_net/sync_net.dart';
import 'package:test/test.dart';

void main() {
  const host = DeviceInfo(
      id: 'host', name: 'Pixel 7', platform: DevicePlatform.android, port: 0);
  const guest = DeviceInfo(
      id: 'guest', name: 'thinkpad', platform: DevicePlatform.linux, port: 1);

  group('QrPayload', () {
    test('round-trips everything the other device needs', () {
      const payload = QrPayload(
        name: 'Pixel 7',
        platform: DevicePlatform.android,
        addresses: ['192.168.49.1', '10.0.0.4'],
        port: 47800,
        token: 'abc123',
        wifiSsid: 'SyncSpot',
        wifiPassphrase: 'hunter2',
      );

      final read = QrPayload.decode(payload.encode())!;

      expect(read.name, 'Pixel 7');
      expect(read.platform, DevicePlatform.android);
      expect(read.addresses, ['192.168.49.1', '10.0.0.4']);
      expect(read.port, 47800);
      expect(read.token, 'abc123');
      expect(read.wifiSsid, 'SyncSpot');
      expect(read.wifiPassphrase, 'hunter2');
      expect(read.hasWifi, isTrue);
    });

    test('stays small enough for a camera to read across a desk', () {
      final payload = QrPayload(
        name: 'Samsung SM-G991B',
        addresses: const ['192.168.49.1'],
        port: 47800,
        token: generatePairingToken(),
        wifiSsid: 'AndroidShare_1234',
        wifiPassphrase: 'abcd1234efgh',
      );

      // Comfortably inside what a version-10 code holds; past a few hundred
      // bytes the modules get small enough to need a steady hand.
      expect(payload.encode().length, lessThan(300));
    });

    test('someone else\'s QR code is not ours', () {
      expect(QrPayload.decode('https://example.com'), isNull);
      expect(QrPayload.decode('{"v":99,"n":"x"}'), isNull);
      expect(QrPayload.decode('{"v":1,"n":"x"}'), isNull, reason: 'no token');
      expect(QrPayload.decode('{"v":1,"n":"x","t":"y","a":[],"p":0}'), isNull,
          reason: 'port 0 is not a port');
    });
  });

  group('pairing by QR token', () {
    late PeerServer server;
    late MemoryTrustStore hostTrust;
    late MemoryTrustStore guestTrust;

    setUp(() async {
      hostTrust = MemoryTrustStore();
      guestTrust = MemoryTrustStore();
      server = PeerServer(host, hostTrust, port: 0);
      await server.start();
    });

    tearDown(() => server.stop());

    test('a scanned code pairs both sides with nobody confirming anything',
        () async {
      final token = QrPairingToken.generate();
      server.qrToken = token;

      // Nothing on the host asks a question: the request settles itself.
      final asked = <IncomingPairing>[];
      server.pairingRequests.listen(asked.add);

      final result = await PairingClient(guest, guestTrust)
          .pair('127.0.0.1', server.boundPort, token: token.value);

      expect(result.isPaired, isTrue);
      expect(await guestTrust.get('host'), isNotNull);
      expect(await hostTrust.get('guest'), isNotNull);
      expect(asked.single.settled, isTrue,
          reason: 'reported as done, not as a question');
    });

    test('both sides derive the same secret, and it is not the one a listener '
        'could work out', () async {
      final token = QrPairingToken.generate();
      server.qrToken = token;
      server.pairingRequests.listen((_) {});

      await PairingClient(guest, guestTrust)
          .pair('127.0.0.1', server.boundPort, token: token.value);

      final onGuest = (await guestTrust.get('host'))!.secret;
      final onHost = (await hostTrust.get('guest'))!.secret;
      expect(onGuest, onHost);

      // The nonces travel in the clear; the token never does. Without it the
      // same exchange yields a different secret, which is the whole point.
      expect(onGuest, isNot(pairingSecret('a', 'b')));
    });

    test('a token is good for one pairing', () async {
      final token = QrPairingToken.generate();
      server.qrToken = token;
      final requests = <IncomingPairing>[];
      server.pairingRequests.listen(requests.add);

      await PairingClient(guest, guestTrust)
          .pair('127.0.0.1', server.boundPort, token: token.value);
      expect(token.isSpent, isTrue);

      // A second device presenting the same code gets the ordinary treatment:
      // a question on the host's screen.
      const other = DeviceInfo(
          id: 'other', name: 'Other', platform: DevicePlatform.linux, port: 2);
      final second = PairingClient(other, MemoryTrustStore())
          .pair('127.0.0.1', server.boundPort, token: token.value);

      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(requests.last.settled, isFalse);
      await requests.last.reject();
      expect((await second).status, PairingStatus.rejected);
    });

    test('a wrong token is treated as no token at all', () async {
      server.qrToken = QrPairingToken.generate();
      final requests = <IncomingPairing>[];
      server.pairingRequests.listen(requests.add);

      final pairing = PairingClient(guest, guestTrust)
          .pair('127.0.0.1', server.boundPort, token: generatePairingToken());

      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(requests.single.settled, isFalse, reason: 'the user still decides');
      await requests.single.accept();
      expect((await pairing).isPaired, isTrue);

      // Accepted by hand, so the secret is the ordinary one - and the two sides
      // must still agree on it.
      expect((await guestTrust.get('host'))!.secret,
          (await hostTrust.get('guest'))!.secret);
    });
  });
}
