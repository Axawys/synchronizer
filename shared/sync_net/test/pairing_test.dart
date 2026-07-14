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

  group('code and secret derivation', () {
    test('both sides derive the same code and secret from the same nonces', () {
      expect(pairingCode('aa', 'bb'), pairingCode('aa', 'bb'));
      expect(pairingSecret('aa', 'bb'), pairingSecret('aa', 'bb'));
    });

    test('code is six digits and differs from the secret', () {
      final code = pairingCode('aa', 'bb');
      expect(code, matches(RegExp(r'^\d{6}$')));
      expect(code, isNot(pairingSecret('aa', 'bb')));
    });

    test('nonce order matters', () {
      expect(pairingCode('aa', 'bb'), isNot(pairingCode('bb', 'aa')));
    });
  });

  group('handshake over loopback', () {
    late PeerServer server;
    late TrustStore serverTrust;
    late TrustStore clientTrust;

    setUp(() async {
      serverTrust = MemoryTrustStore();
      clientTrust = MemoryTrustStore();
      server = PeerServer(phone, serverTrust, port: 0);
      await server.start();
    });

    tearDown(() => server.stop());

    test('accepted pairing trusts each other with a matching secret', () async {
      String? serverCode;
      server.pairingRequests.listen((req) {
        serverCode = req.code;
        req.accept();
      });

      String? clientCode;
      final client = PairingClient(desktop, clientTrust);
      final result = await client.pair(
        '127.0.0.1',
        server.boundPort,
        onCode: (_, code) => clientCode = code,
      );

      expect(result.isPaired, isTrue);
      expect(result.peer!.id, 'phone-id');

      // The displayed codes on both devices agree.
      expect(clientCode, isNotNull);
      expect(clientCode, serverCode);

      // Both persisted the other as trusted, with the same shared secret.
      final trustedByClient = await clientTrust.get('phone-id');
      final trustedByServer = await serverTrust.get('desktop-id');
      expect(trustedByClient, isNotNull);
      expect(trustedByServer, isNotNull);
      expect(trustedByClient!.secret, trustedByServer!.secret);
    });

    test('rejected pairing trusts no one', () async {
      server.pairingRequests.listen((req) => req.reject());

      final client = PairingClient(desktop, clientTrust);
      final result = await client.pair('127.0.0.1', server.boundPort);

      expect(result.status, PairingStatus.rejected);
      expect(await clientTrust.all(), isEmpty);
      expect(await serverTrust.all(), isEmpty);
    });

    test('connecting to a closed port fails cleanly', () async {
      await server.stop();
      final client = PairingClient(desktop, clientTrust);
      final result = await client.pair('127.0.0.1', server.boundPort);
      expect(result.status, PairingStatus.failed);
    });
  });
}
