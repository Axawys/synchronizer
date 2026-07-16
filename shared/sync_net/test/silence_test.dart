import 'dart:async';
import 'dart:io';

import 'package:sync_net/sync_net.dart';
import 'package:test/test.dart';

/// A peer that vanishes without closing the socket - a phone carried out of
/// Wi-Fi range, or one whose app was killed. TCP has no idea, so the only thing
/// that tells the two apart is silence.
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
  final phoneKnowsDesktop = TrustedPeer(
      id: 'desktop-id',
      name: 'Desktop',
      platform: DevicePlatform.linux,
      secret: 'shared');

  test('a request against a peer that went quiet gives up instead of hanging',
      () async {
    // A socket that accepts and then says nothing, ever.
    final deaf = await ServerSocket.bind('127.0.0.1', 0);
    addTearDown(deaf.close);
    final held = <Socket>[];
    deaf.listen(held.add);

    final conn = await PeerConnection.connect('127.0.0.1', deaf.port);
    addTearDown(conn.close);
    conn.send({'type': 'anything'});

    final reply = StreamIterator(conn.frames);
    // Waiting for a frame that will never come.
    await expectLater(
      conn.awaitReply(reply.moveNext(),
          silence: const Duration(milliseconds: 300)),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('connecting to a peer that never answers hello does not hang forever',
      () async {
    final deaf = await ServerSocket.bind('127.0.0.1', 0);
    addTearDown(deaf.close);
    deaf.listen((socket) {}); // accepted, then ignored

    // The real client path: no challenge ever arrives.
    await expectLater(
      SyncClient.connect('127.0.0.1', deaf.port,
          self: phone, trusted: phoneKnowsDesktop),
      throwsA(isA<TimeoutException>()),
    );
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('a link that keeps delivering is never cut off for being slow',
      () async {
    // The point of watching silence rather than elapsed time: this exchange
    // takes far longer than the timeout but never actually stops.
    final chatty = await ServerSocket.bind('127.0.0.1', 0);
    addTearDown(chatty.close);
    chatty.listen((socket) async {
      final frame = encodeFrame({'type': 'reply'}, List.filled(600, 65));
      // Dribble the answer out over well past the silence limit.
      for (var i = 0; i < frame.length; i += 60) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        socket.add(frame.sublist(i, (i + 60).clamp(0, frame.length)));
      }
    });

    final conn = await PeerConnection.connect('127.0.0.1', chatty.port);
    addTearDown(conn.close);
    conn.send({'type': 'go'});

    final frames = StreamIterator(conn.frames);
    final got = await conn.awaitReply(frames.moveNext(),
        silence: const Duration(milliseconds: 150));

    expect(got, isTrue, reason: 'slow is not the same as dead');
    expect(frames.current.body, hasLength(600));
  });

  test('a peer that answers promptly is not slowed down by the watchdog',
      () async {
    final trust = MemoryTrustStore();
    await trust.add(TrustedPeer(
        id: 'phone-id',
        name: 'Phone',
        platform: DevicePlatform.android,
        secret: 'shared'));
    final dir = Directory.systemTemp.createTempSync('silence');
    addTearDown(() => dir.deleteSync(recursive: true));

    final server = PeerServer(desktop, trust,
        port: 0, directories: MapDirectorySource({'notes': dir.path}));
    await server.start();
    addTearDown(server.stop);

    final client = await SyncClient.connect('127.0.0.1', server.boundPort,
        self: phone, trusted: phoneKnowsDesktop);
    addTearDown(client.close);

    expect((await client.listDirectories()).single.name, 'notes');
  });
}
