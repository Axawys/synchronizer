/// Networking layer shared by the desktop and mobile applications.
///
/// Local-network peer discovery over UDP multicast, and a framed TCP transport
/// with a pairing handshake on top of it. The sync session (manifest exchange,
/// file transfer) is layered on the same transport next.
library;

export 'src/connection.dart';
export 'src/device_info.dart';
export 'src/discovery.dart';
export 'src/frame.dart';
export 'src/pairing.dart';
export 'src/trust.dart';
