import 'dart:async';
import 'dart:io';

import 'connection.dart';
import 'device_info.dart';
import 'pairing.dart';
import 'session.dart';
import 'trust.dart';

/// The one listening socket a device exposes to the network. It routes each
/// incoming connection by its first frame: a pairing request goes to the
/// pairing handshake, a session hello goes to an authenticated sync session.
///
/// Folding both onto one port keeps discovery simple (a single advertised
/// port) and means a peer only ever dials one place.
class PeerServer {
  PeerServer(
    this.self,
    this.trust, {
    this.port = 47800,
    DirectorySource? directories,
  }) : directories = directories ?? MapDirectorySource(const {});

  final DeviceInfo self;
  final TrustStore trust;
  final int port;

  /// Directories offered to authenticated peers. Empty until the app shares
  /// some, which is fine: pairing still works, listing just returns nothing.
  final DirectorySource directories;

  ServerSocket? _server;
  final _pairingRequests = StreamController<IncomingPairing>.broadcast();

  /// Inbound pairing requests awaiting the user's accept/reject.
  Stream<IncomingPairing> get pairingRequests => _pairingRequests.stream;

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
      final first = frames.current;
      switch (first.type) {
        case PairType.request:
          await handlePairingRequest(
            conn,
            frames,
            first,
            self: self,
            trust: trust,
            emit: _pairingRequests.add,
          );
        case SessionType.hello:
          await handleSession(
            conn,
            frames,
            first,
            self: self,
            trust: trust,
            directories: directories,
          );
        default:
          await closeConnection(conn, frames);
      }
    } catch (_) {
      await closeConnection(conn, frames);
    }
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
    if (!_pairingRequests.isClosed) await _pairingRequests.close();
  }
}
