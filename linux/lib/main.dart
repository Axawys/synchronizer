import 'package:flutter/material.dart';
import 'package:sync_ui/sync_ui.dart';

import 'device_identity.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final self = await DeviceIdentity.load();
  runApp(SynchronizerApp(self: self));
}
