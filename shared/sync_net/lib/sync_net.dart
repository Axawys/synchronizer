/// Networking layer shared by the desktop and mobile applications.
///
/// For now this is local-network peer discovery: announcing this device and
/// finding others over UDP multicast. The pairing handshake and the sync
/// transport will be added alongside it.
library;

export 'src/device_info.dart';
export 'src/discovery.dart';
