import 'package:flutter/material.dart';
import 'package:sync_ui/sync_ui.dart';

import 'device_identity.dart';
import 'window_frame.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final self = await DeviceIdentity.load();
  // GTK draws the window frame, so it has to be told about the theme.
  runApp(SynchronizerApp(
    self: self,
    applyWindowBrightness: WindowFrame.applyBrightness,
  ));
}
