import 'package:flutter/services.dart';

/// The window's frame - the header bar and its buttons - is drawn by GTK, not
/// by Flutter, so it does not follow the theme picked inside the app. This
/// tells the native side which variant of the system theme to use, which keeps
/// the frame (and GTK's own dialogs, such as the folder chooser) in step.
class WindowFrame {
  static const _channel = MethodChannel('synchronizer/window');

  static Future<void> applyBrightness(Brightness brightness) async {
    try {
      await _channel.invokeMethod<void>(
        'setDark',
        brightness == Brightness.dark,
      );
    } on MissingPluginException {
      // Running somewhere without the native side; the frame just stays put.
    } on PlatformException {
      // Not worth interrupting the app over the title bar's colour.
    }
  }
}
