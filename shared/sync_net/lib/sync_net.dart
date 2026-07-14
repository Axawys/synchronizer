/// Networking layer shared by the desktop and mobile applications.
///
/// Local-network peer discovery over UDP multicast, a framed TCP transport, a
/// pairing handshake, and an authenticated sync session (directory listing,
/// manifest exchange, file transfer) — all reached through one [PeerServer]
/// port per device.
library;

export 'src/connection.dart';
export 'src/device_info.dart';
export 'src/discovery.dart';
export 'src/frame.dart';
export 'src/pairing.dart';
export 'src/server.dart';
export 'src/session.dart';
export 'src/trust.dart';
