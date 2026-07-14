import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'connection.dart';
import 'device_info.dart';
import 'frame.dart';
import 'trust.dart';

/// Message type discriminators for the pairing handshake.
abstract final class PairType {
  static const request = 'pair.request';
  static const challenge = 'pair.challenge';
  static const result = 'pair.result';
}

/// Protocol version carried in the first message. Bumped when the handshake
/// changes in an incompatible way.
const int kPairingProtocol = 1;

/// A 16-byte random value, hex encoded, mixed into the pairing so a code and
/// secret are unique to this one exchange.
String generateNonce() {
  final rng = Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Short human-comparable code both devices display. The user checks the two
/// screens match, which defeats a man-in-the-middle inserting itself during
/// pairing. Derived from both nonces so neither side alone controls it.
String pairingCode(String clientNonce, String serverNonce) {
  final digest = sha256.convert(utf8.encode('code:$clientNonce:$serverNonce'));
  final n = (digest.bytes[0] << 16) | (digest.bytes[1] << 8) | digest.bytes[2];
  return (n % 1000000).toString().padLeft(6, '0');
}

/// The long shared secret both devices keep for the pair. Same inputs as the
/// code but a different domain tag, so knowing the 6-digit code tells an
/// attacker nothing about the secret.
String pairingSecret(String clientNonce, String serverNonce) {
  return sha256
      .convert(utf8.encode('secret:$clientNonce:$serverNonce'))
      .toString();
}

/// How a pairing attempt ended.
enum PairingStatus { paired, rejected, failed }

class PairingResult {
  const PairingResult(this.status, {this.peer, this.code, this.error});

  final PairingStatus status;
  final DeviceInfo? peer;
  final String? code;
  final String? error;

  bool get isPaired => status == PairingStatus.paired;
}

/// Desktop side: reaches out to a discovered device and asks to pair.
class PairingClient {
  PairingClient(this.self, this.trust);

  final DeviceInfo self;
  final TrustStore trust;

  /// Connects to [host]:[port] and runs the handshake. [onCode] fires as soon
  /// as the verification code is known, so the UI can show it while the user on
  /// the other device decides.
  Future<PairingResult> pair(
    String host,
    int port, {
    void Function(DeviceInfo peer, String code)? onCode,
  }) async {
    PeerConnection conn;
    try {
      conn = await PeerConnection.connect(host, port);
    } on SocketException catch (e) {
      return PairingResult(PairingStatus.failed, error: e.message);
    }

    final frames = StreamIterator(conn.frames);
    try {
      final clientNonce = generateNonce();
      conn.send({
        'type': PairType.request,
        'protocol': kPairingProtocol,
        'device': self.toAnnouncement(),
        'nonce': clientNonce,
      });

      if (!await frames.moveNext()) {
        return const PairingResult(PairingStatus.failed,
            error: 'connection closed before challenge');
      }
      final challenge = frames.current;
      if (challenge.type != PairType.challenge) {
        return const PairingResult(PairingStatus.failed,
            error: 'unexpected reply to pair request');
      }

      final peer = _readDevice(challenge.header, host);
      final serverNonce = challenge.header['nonce']! as String;
      final code = pairingCode(clientNonce, serverNonce);
      onCode?.call(peer, code);

      if (!await frames.moveNext()) {
        return PairingResult(PairingStatus.failed,
            peer: peer, error: 'connection closed before decision');
      }
      final result = frames.current;
      if (result.type != PairType.result) {
        return PairingResult(PairingStatus.failed,
            peer: peer, error: 'unexpected reply awaiting decision');
      }

      if (result.header['accepted'] != true) {
        return PairingResult(PairingStatus.rejected, peer: peer, code: code);
      }

      await trust.add(TrustedPeer(
        id: peer.id,
        name: peer.name,
        platform: peer.platform,
        secret: pairingSecret(clientNonce, serverNonce),
      ));
      return PairingResult(PairingStatus.paired, peer: peer, code: code);
    } finally {
      await frames.cancel();
      await conn.close();
    }
  }
}

/// Phone side: listens for pairing attempts and surfaces each as an
/// [IncomingPairing] the UI resolves by calling accept or reject.
class PairingServer {
  PairingServer(this.self, this.trust, {this.port = 47800});

  final DeviceInfo self;
  final TrustStore trust;
  final int port;

  ServerSocket? _server;
  final _requests = StreamController<IncomingPairing>.broadcast();

  Stream<IncomingPairing> get requests => _requests.stream;

  /// The port actually bound. Differs from [port] only when 0 was requested to
  /// get an ephemeral port (used in tests).
  int get boundPort => _server?.port ?? port;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    _server!.listen(_onSocket);
  }

  Future<void> _onSocket(Socket socket) async {
    final conn = PeerConnection(socket);
    final frames = StreamIterator(conn.frames);
    try {
      if (!await frames.moveNext()) {
        await conn.close();
        return;
      }
      final request = frames.current;
      if (request.type != PairType.request) {
        await conn.close();
        return;
      }

      final peer = _readDevice(request.header, conn.remoteAddress);
      final clientNonce = request.header['nonce']! as String;
      final serverNonce = generateNonce();
      final code = pairingCode(clientNonce, serverNonce);

      conn.send({
        'type': PairType.challenge,
        'device': self.toAnnouncement(),
        'nonce': serverNonce,
      });

      var decided = false;
      Future<void> decide(bool accepted) async {
        if (decided) return;
        decided = true;
        conn.send({'type': PairType.result, 'accepted': accepted});
        if (accepted) {
          await trust.add(TrustedPeer(
            id: peer.id,
            name: peer.name,
            platform: peer.platform,
            secret: pairingSecret(clientNonce, serverNonce),
          ));
        }
        await frames.cancel();
        await conn.close();
      }

      _requests.add(IncomingPairing._(peer, code, decide));
    } catch (_) {
      await frames.cancel();
      await conn.close();
    }
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
    if (!_requests.isClosed) await _requests.close();
  }
}

/// A pending request from another device, waiting on the user's decision.
class IncomingPairing {
  IncomingPairing._(this.peer, this.code, this._decide);

  /// The device asking to pair.
  final DeviceInfo peer;

  /// The verification code to show; it must match what [peer] shows.
  final String code;

  final Future<void> Function(bool accepted) _decide;

  Future<void> accept() => _decide(true);
  Future<void> reject() => _decide(false);
}

DeviceInfo _readDevice(Map<String, Object?> header, String address) {
  final body = header['device'];
  if (body is! Map<String, Object?>) {
    throw const FrameFormatException('pairing message missing device');
  }
  return DeviceInfo.fromAnnouncement(body, address: address);
}
