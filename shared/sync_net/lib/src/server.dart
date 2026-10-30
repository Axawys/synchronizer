import 'dart:async';
import 'dart:io';

import 'connection.dart';
import 'device_info.dart';
import 'pairing.dart';
import 'remote_sync.dart';
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
    bool? windowsNames,
  })  : directories = directories ?? MapDirectorySource(const {}),
        windowsNames = windowsNames ?? Platform.isWindows;

  /// How this device introduces itself in a handshake. Not final: the user can
  /// rename the device, and the next device to pair should hear the new name.
  DeviceInfo self;

  final TrustStore trust;
  final int port;

  /// Directories offered to authenticated peers. Empty until the app shares
  /// some, which is fine: pairing still works, listing just returns nothing.
  final DirectorySource directories;

  /// The shared folders live on a Windows file system, so names it cannot hold
  /// are refused and peers are told to leave them out. True on Windows; tests
  /// set it to play a Windows device anywhere.
  final bool windowsNames;

  ServerSocket? _server;
  final _pairingRequests = StreamController<IncomingPairing>.broadcast();

  /// Inbound pairing requests awaiting the user's accept/reject.
  Stream<IncomingPairing> get pairingRequests => _pairingRequests.stream;

  /// The token behind a QR code this device is showing, if any. A request that
  /// proves it read that code is accepted without asking; set it while the code
  /// is on screen and clear it when it comes off.
  QrPairingToken? qrToken;

  /// Which folders are being synced right now: one device at a time per folder.
  final _locks = FolderLocks();

  final _folderRequests = StreamController<FolderRequest>.broadcast();

  /// Paired devices asking this one to make a folder available. The app answers
  /// by putting a folder chooser in front of the user.
  Stream<FolderRequest> get folderRequests => _folderRequests.stream;

  final _remoteSyncs = StreamController<RemoteSync>.broadcast();

  /// Syncs another device has started that this one is part of, so the screen
  /// can show them here too and not only on the device that was tapped.
  Stream<RemoteSync> get remoteSyncs => _remoteSyncs.stream;

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
            qrToken: qrToken,
          );
        case SessionType.hello:
          await handleSession(
            conn,
            frames,
            first,
            self: self,
            trust: trust,
            directories: directories,
            onFolderRequest: _folderRequests.add,
            onRemoteSync: _remoteSyncs.add,
            locks: _locks,
            windowsNames: windowsNames,
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
    if (!_folderRequests.isClosed) await _folderRequests.close();
    if (!_remoteSyncs.isClosed) await _remoteSyncs.close();
  }
}
