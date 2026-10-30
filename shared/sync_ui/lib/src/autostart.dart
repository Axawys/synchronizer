import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

/// Starting the app when the desktop session begins. On Linux that is an XDG
/// autostart entry: enabling it drops a .desktop file in the user's autostart
/// folder, disabling removes it. On Windows it is a value under the user's own
/// `Run` key, which is what the Startup apps page in Settings lists and can
/// switch off. Nothing is installed system-wide and no elevated rights are
/// needed either way.
///
/// Only applies to the desktop: on Android the system decides what runs at
/// boot, so the setting is hidden there.
class Autostart {
  static bool get supported => Platform.isLinux || Platform.isWindows;

  static File get _entry {
    final home = Platform.environment['HOME'] ?? '';
    final configHome = Platform.environment['XDG_CONFIG_HOME'];
    final config = (configHome == null || configHome.isEmpty)
        ? p.join(home, '.config')
        : configHome;
    return File(p.join(config, 'autostart', 'synchronizer.desktop'));
  }

  static const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const _runValue = 'Synchronizer';

  static Future<bool> isEnabled() async {
    if (!supported) return false;
    if (Platform.isWindows) {
      // Waited for in an isolate rather than with Process.run: the answer is
      // asked for whenever Settings is built, and Process.run keeps a timer
      // alive that a widget test refuses to end with.
      return Isolate.run(() =>
          Process.runSync('reg', ['query', _runKey, '/v', _runValue])
              .exitCode ==
          0);
    }
    return _entry.exists();
  }

  static Future<void> setEnabled(bool enabled) async {
    if (!supported) return;
    if (Platform.isWindows) return _setRunValue(enabled);
    final entry = _entry;

    if (!enabled) {
      if (await entry.exists()) await entry.delete();
      return;
    }

    await entry.parent.create(recursive: true);
    // resolvedExecutable is this app's binary, wherever it was installed to.
    await entry.writeAsString('''
[Desktop Entry]
Type=Application
Name=Synchronizer
Comment=Keep folders in step across your devices
Exec=${Platform.resolvedExecutable}
Terminal=false
X-GNOME-Autostart-enabled=true
''');
  }

  /// Whether it worked is read back with [isEnabled], not taken from here:
  /// deleting a value that was never there fails and is still the state that
  /// was asked for.
  static Future<void> _setRunValue(bool enabled) async {
    await Process.run(
        'reg',
        enabled
            ? [
                'add', _runKey, '/v', _runValue, '/t', 'REG_SZ', //
                // Quoted, since the folder it was unpacked to may have spaces.
                '/d', '"${Platform.resolvedExecutable}"', '/f',
              ]
            : ['delete', _runKey, '/v', _runValue, '/f']);
  }
}
