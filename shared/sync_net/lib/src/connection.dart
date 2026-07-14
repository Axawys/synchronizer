import 'dart:io';

import 'frame.dart';

/// A framed message channel over a single TCP socket. Both the pairing
/// handshake and, later, the sync session talk through one of these.
///
/// The transport is currently plain TCP. It is deliberately the only place that
/// touches the socket, so wrapping it in TLS later is a change here and nowhere
/// else.
class PeerConnection {
  PeerConnection(this.socket, {int maxBodyBytes = kDefaultMaxBodyBytes})
      : frames = readFrames(socket, maxBodyBytes: maxBodyBytes);

  final Socket socket;

  /// Incoming messages, in order. Single-subscription: read it with a
  /// [StreamIterator] for request/response exchanges.
  final Stream<Frame> frames;

  /// The address of the far end, useful for logging and for stamping a peer's
  /// reachable address.
  String get remoteAddress => socket.remoteAddress.address;

  void send(Map<String, Object?> header, [List<int>? body]) {
    socket.add(encodeFrame(header, body));
  }

  Future<void> close() async {
    try {
      await socket.flush();
    } on SocketException {
      // Peer may have already dropped; nothing left to flush.
    }
    socket.destroy();
  }

  static Future<PeerConnection> connect(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final socket = await Socket.connect(host, port, timeout: timeout);
    return PeerConnection(socket);
  }
}
