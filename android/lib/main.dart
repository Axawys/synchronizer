import 'package:flutter/material.dart';
import 'package:sync_ui/sync_ui.dart';

import 'device_identity.dart';
import 'multicast_lock.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final self = await DeviceIdentity.load();
  // Android drops inbound multicast unless we hold the lock, so grab it before
  // discovery starts.
  runApp(SynchronizerApp(self: self, prepareNetwork: MulticastLock.acquire));
}
