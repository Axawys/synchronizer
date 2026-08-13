import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'frame.dart';

/// Thrown where a connection or a handshake was called off by the person who
/// started it. Not a failure to report - it is what they asked for.
class SyncCancelled implements Exception {
  const SyncCancelled();

  @override
  String toString() => 'SyncCancelled';
}

/// How long a link may stay completely silent while we are waiting for an
/// answer before we give up on it.
///
/// TCP does not notice a peer that vanished - a phone that left the network, a
/// killed app - so without this a request simply waits forever.
const Duration kSilenceTimeout = Duration(seconds: 20);

/// A framed message channel over a single TCP socket. Both the pairing
/// handshake and, later, the sync session talk through one of these.
///
/// The transport is currently plain TCP. It is deliberately the only place that
/// touches the socket, so wrapping it in TLS later is a change here and nowhere
/// else.
class PeerConnection {
  PeerConnection(this.socket, {int maxBodyBytes = kDefaultMaxBodyBytes}) {
    frames = readFrames(socket.map(_touch), maxBodyBytes: maxBodyBytes);
  }

  final Socket socket;

  /// Incoming messages, in order. Single-subscription: read it with a
  /// [StreamIterator] for request/response exchanges.
  late final Stream<Frame> frames;

  /// When the far end last gave any sign of life.
  DateTime _lastHeard = DateTime.now();

  List<int> _touch(Uint8List chunk) {
    _lastHeard = DateTime.now();
    return chunk;
  }

  /// The address of the far end, useful for logging and for stamping a peer's
  /// reachable address.
  String get remoteAddress => socket.remoteAddress.address;

  void send(Map<String, Object?> header, [List<int>? body]) {
    socket.add(encodeFrame(header, body));
  }

  /// Waits for [reply], giving up if the link falls silent for [silence].
  ///
  /// It watches for silence rather than putting a deadline on the whole wait:
  /// a large file over a slow link takes a long time yet never stops arriving,
  /// and a plain timeout would kill exactly the transfers that need patience
  /// most. Only a link with nothing coming over it at all is a dead one.
  Future<T> awaitReply<T>(
    Future<T> reply, {
    Duration silence = kSilenceTimeout,
  }) {
    final result = Completer<T>();
    _lastHeard = DateTime.now();

    final watchdog = Timer.periodic(silence ~/ 4, (timer) {
      if (result.isCompleted) return timer.cancel();
      if (DateTime.now().difference(_lastHeard) >= silence) {
        timer.cancel();
        result.completeError(
          TimeoutException('the other device stopped responding', silence),
        );
      }
    });

    reply.then(
      (value) {
        if (!result.isCompleted) result.complete(value);
      },
      onError: (Object e, StackTrace s) {
        if (!result.isCompleted) result.completeError(e, s);
      },
    );

    return result.future.whenComplete(watchdog.cancel);
  }

  Future<void> close() async {
    try {
      // A peer that stopped reading would otherwise hold the flush open, so a
      // goodbye is worth a moment's wait and not a second more.
      await socket.flush().timeout(const Duration(seconds: 2));
    } on SocketException {
      // Peer may have already dropped; nothing left to flush.
    } on TimeoutException {
      // Not going anywhere. Drop it.
    }
    socket.destroy();
  }

  /// Opens a link to [host]:[port].
  ///
  /// [cancel] gives the caller a way out while it is still trying. A connection
  /// attempt to a device that is not there takes the full [timeout] to fail,
  /// and a person who has changed their mind should not have to sit through it;
  /// completing that future gives up the attempt at once.
  static Future<PeerConnection> connect(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 10),
    Future<void>? cancel,
  }) async {
    if (cancel == null) {
      final socket = await Socket.connect(host, port, timeout: timeout);
      return PeerConnection(socket);
    }

    // startConnect, not connect: it hands back the attempt itself, which is the
    // only thing that can actually be called off.
    final task = await Socket.startConnect(host, port);
    var cancelled = false;
    unawaited(cancel.then((_) {
      cancelled = true;
      task.cancel();
    }));

    try {
      final socket = await task.socket.timeout(timeout);
      if (cancelled) {
        socket.destroy();
        throw const SyncCancelled();
      }
      return PeerConnection(socket);
    } on SocketException {
      if (cancelled) throw const SyncCancelled();
      rethrow;
    }
  }
}

/// Shuts down a connection and the iterator reading its frames.
///
/// The order is the whole point, and it is the opposite of the obvious one.
/// Cancelling the iterator first waits for the frame reader to finish, and the
/// frame reader is sitting there waiting for bytes from a peer that is never
/// going to send any - so the cancel never returns and the app hangs on a dead
/// link. Killing the socket ends that wait, and then the cancel completes at
/// once. Always go through here rather than doing it by hand.
Future<void> closeConnection(
  PeerConnection conn,
  StreamIterator<Frame> frames,
) async {
  await conn.close();
  await frames.cancel();
}
