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
///
/// [token] is the one-time secret from a QR code, when the pairing was started
/// by scanning one. Mixing it in matters: both nonces travel in the clear, so
/// without it anyone who watched the handshake go by could derive the same
/// secret. The token never goes on the wire - only a proof of knowing it does -
/// so a QR pairing is the only one a passive listener cannot follow.
String pairingSecret(String clientNonce, String serverNonce, {String? token}) {
  final material = token == null
      ? 'secret:$clientNonce:$serverNonce'
      : 'secret:$clientNonce:$serverNonce:$token';
  return sha256.convert(utf8.encode(material)).toString();
}

/// Proof that the device asking to pair has seen the QR code, without putting
/// the token it read into the exchange.
String pairingTokenProof(String token, String clientNonce) {
  return Hmac(sha256, utf8.encode(token))
      .convert(utf8.encode('qr:$clientNonce'))
      .toString();
}

/// A fresh QR pairing token: 256 bits, hex. It is shown as part of a QR code,
/// used once, and forgotten.
String generatePairingToken() {
  final rng = Random.secure();
  final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// How a pairing attempt ended.
enum PairingStatus {
  paired,
  rejected,
  failed,

  /// Called off from this side while it was still waiting - most often on the
  /// other device's user, who may be nowhere near it.
  cancelled,
}

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
  /// [token] is the one-time secret read from the other device's QR code. With
  /// one, the far end accepts without asking anybody: showing the code was the
  /// decision, and having read it off that screen is what proves this device
  /// was in front of it. Without one, the user confirms the six digits on both
  /// screens as before.
  /// [cancel] calls the whole thing off: the link is dropped, and whatever it
  /// was waiting for stops being waited for. Pairing waits on a person at the
  /// other device, which can be a long wait for someone who has changed their
  /// mind.
  Future<PairingResult> pair(
    String host,
    int port, {
    void Function(DeviceInfo peer, String code)? onCode,
    String? token,
    Future<void>? cancel,
  }) async {
    PeerConnection conn;
    try {
      conn = await PeerConnection.connect(host, port, cancel: cancel);
    } on SyncCancelled {
      return const PairingResult(PairingStatus.cancelled);
    } on SocketException catch (e) {
      return PairingResult(PairingStatus.failed, error: e.message);
    }

    var cancelled = false;
    // Dropping the link is what stops a wait that has no timeout of its own:
    // the frame reader ends, and everything below unwinds.
    unawaited(cancel?.then((_) {
      cancelled = true;
      conn.close();
    }));

    final frames = StreamIterator(conn.frames);
    try {
      final clientNonce = generateNonce();
      conn.send({
        'type': PairType.request,
        'protocol': kPairingProtocol,
        'device': self.toAnnouncement(),
        'nonce': clientNonce,
        if (token != null) 'tokenProof': pairingTokenProof(token, clientNonce),
      });

      if (!await frames.moveNext()) {
        if (cancelled) return const PairingResult(PairingStatus.cancelled);
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
        if (cancelled) return const PairingResult(PairingStatus.cancelled);
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

      // The far end says whether it recognised the token. It might not have:
      // a stale code, one already scanned by someone else, or the wrong device
      // entirely - all of which fall back to the handshake the user confirms,
      // and to the secret that goes with it.
      final byToken = result.header['qr'] == true;

      await trust.add(TrustedPeer(
        id: peer.id,
        name: peer.name,
        platform: peer.platform,
        secret: pairingSecret(
          clientNonce,
          serverNonce,
          token: byToken ? token : null,
        ),
      ));
      return PairingResult(PairingStatus.paired, peer: peer, code: code);
    } finally {
      await closeConnection(conn, frames);
    }
  }
}

/// Server side of the handshake for one connection whose first frame is a
/// [PairType.request]. Sends the challenge and hands an [IncomingPairing] to
/// [emit]; the connection stays open until the user accepts or rejects.
///
/// This is driven by [PeerServer], which owns the listening socket and routes
/// each connection to pairing or to a sync session based on its first frame.
Future<void> handlePairingRequest(
  PeerConnection conn,
  StreamIterator<Frame> frames,
  Frame request, {
  required DeviceInfo self,
  required TrustStore trust,
  required void Function(IncomingPairing) emit,
  QrPairingToken? qrToken,
}) async {
  final peer = _readDevice(request.header, conn.remoteAddress);
  final clientNonce = request.header['nonce']! as String;
  final serverNonce = generateNonce();
  final code = pairingCode(clientNonce, serverNonce);

  // A request that proves it read this device's QR code needs no confirming:
  // putting the code on screen was the consent, and only something looking at
  // that screen could produce this proof. It is good for one pairing.
  final proof = request.header['tokenProof'];
  final token = proof is String ? qrToken?.take(proof, clientNonce) : null;

  conn.send({
    'type': PairType.challenge,
    'device': self.toAnnouncement(),
    'nonce': serverNonce,
  });

  var decided = false;
  Future<void> decide(bool accepted) async {
    if (decided) return;
    decided = true;
    // Whether the token was actually used decides how the secret is derived,
    // and only this side knows: a proof that did not match falls back to the
    // ordinary handshake, and the client must derive the same thing we do.
    conn.send({
      'type': PairType.result,
      'accepted': accepted,
      'qr': token != null,
    });
    if (accepted) {
      await trust.add(TrustedPeer(
        id: peer.id,
        name: peer.name,
        platform: peer.platform,
        secret: pairingSecret(clientNonce, serverNonce, token: token),
      ));
    }
    await closeConnection(conn, frames);
  }

  if (token != null) {
    await decide(true);
    emit(IncomingPairing._(peer, code, decide, settled: true));
    return;
  }

  emit(IncomingPairing._(peer, code, decide));
}

/// The one-time token behind a QR code being shown right now.
///
/// It lives on the device that displays the code and is spent by the first
/// device that proves it read it: a code left on screen cannot be used twice,
/// and a code nobody scanned expires with the screen that showed it.
class QrPairingToken {
  QrPairingToken(this.value);

  /// A fresh one, ready to be put in a QR code.
  factory QrPairingToken.generate() =>
      QrPairingToken(generatePairingToken());

  final String value;
  bool _spent = false;

  bool get isSpent => _spent;

  /// Checks a proof against this token and consumes it, returning the token
  /// itself so the caller can derive the shared secret with it. Null if the
  /// proof does not match or the token has already been used.
  String? take(String proof, String clientNonce) {
    if (_spent) return null;
    if (proof != pairingTokenProof(value, clientNonce)) return null;
    _spent = true;
    return value;
  }
}

/// A pending request from another device, waiting on the user's decision.
class IncomingPairing {
  IncomingPairing._(this.peer, this.code, this._decide, {this.settled = false});

  /// The device asking to pair.
  final DeviceInfo peer;

  /// The verification code to show; it must match what [peer] shows.
  final String code;

  /// Whether this one has already been decided - a QR pairing, which needs
  /// nobody to confirm anything. The screen shows it as news, not as a
  /// question.
  final bool settled;

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
