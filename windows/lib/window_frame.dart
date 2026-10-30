import 'package:flutter/services.dart';

/// The window's title bar is drawn by Windows, not by Flutter, so it does not
/// follow the theme picked inside the app. This tells the native side which way
/// the app is painted, and it asks Windows for the matching frame.
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
