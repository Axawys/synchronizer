import 'dart:async';
import 'dart:io';

import 'package:sync_net/sync_net.dart';
import 'package:test/test.dart';

/// Backing out of something that is still waiting. It has to actually stop -
/// letting go of the screen while the attempt runs on is how a device ends up
/// paired with something the user walked away from.
void main() {
  const self = DeviceInfo(
      id: 'self', name: 'Self', platform: DevicePlatform.linux, port: 0);

  test('a connection to a device that is not there is given up at once',
      () async {
    final cancel = Completer<void>();
    // 203.0.113.0/24 is reserved for documentation: nothing answers, and the
    // attempt would otherwise sit out its whole timeout.
    final attempt = PeerConnection.connect(
      '203.0.113.1',
      47800,
      timeout: const Duration(seconds: 30),
      cancel: cancel.future,
    );

    final clock = Stopwatch()..start();
    Timer(const Duration(milliseconds: 100), cancel.complete);

    await expectLater(attempt, throwsA(isA<SyncCancelled>()));
    expect(clock.elapsed, lessThan(const Duration(seconds: 5)),
        reason: 'given up when asked, not when the timeout ran out');
  });

  test('pairing that is waiting on the other person can be called off',
      () async {
    final trust = MemoryTrustStore();
    final server = PeerServer(
      const DeviceInfo(
          id: 'peer', name: 'Peer', platform: DevicePlatform.linux, port: 0),
      trust,
      port: 0,
    );
    await server.start();
    addTearDown(server.stop);

    // Nobody answers the request: the dialog on that device is on a screen in
    // another room.
    final requests = <IncomingPairing>[];
    server.pairingRequests.listen(requests.add);

    final cancel = Completer<void>();
    final pairing = PairingClient(self, MemoryTrustStore()).pair(
      '127.0.0.1',
      server.boundPort,
      cancel: cancel.future,
      onCode: (_, _) => cancel.complete(), // gave up as soon as it saw the code
    );

    final result = await pairing.timeout(const Duration(seconds: 5));
    expect(result.status, PairingStatus.cancelled);
    expect(await trust.get('self'), isNull,
        reason: 'nothing was agreed, so nothing is remembered');
  });

  test('an ordinary connection is unaffected by the option', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((socket) => socket.destroy());

    final conn = await PeerConnection.connect(
      '127.0.0.1',
      server.port,
      cancel: Completer<void>().future, // never completes
    );
    await conn.close();
  });
}
