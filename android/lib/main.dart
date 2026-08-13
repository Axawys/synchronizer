import 'package:flutter/material.dart';
import 'package:sync_ui/sync_ui.dart';

import 'device_identity.dart';
import 'direct_link.dart';
import 'multicast_lock.dart';
import 'qr_scanner.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final self = await DeviceIdentity.load();
  // Android drops inbound multicast unless we hold the lock, so grab it before
  // discovery starts.
  runApp(SynchronizerApp(
    self: self,
    prepareNetwork: MulticastLock.acquire,
    // Only Android can offer to become a hotspot or open the tethering
    // settings; the desktop passes nothing and the screen adapts.
    directLink: AndroidDirectLink(),
    // The camera is the phone's to offer; the desktop screen does without.
    qrScanner: AndroidQrScanner(),
    onRename: DeviceIdentity.rename,
  ));
}
