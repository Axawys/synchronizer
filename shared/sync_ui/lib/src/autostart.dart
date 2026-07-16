import 'dart:io';

import 'package:path/path.dart' as p;

/// Starting the app when the desktop session begins, via an XDG autostart
/// entry. Enabling it drops a .desktop file in the user's autostart folder;
/// disabling removes it. Nothing is installed system-wide and no elevated
/// rights are needed.
///
/// Only applies to the Linux desktop: on Android the system decides what runs
/// at boot, so the setting is hidden there.
class Autostart {
  static bool get supported => Platform.isLinux;

  static File get _entry {
    final home = Platform.environment['HOME'] ?? '';
    final configHome = Platform.environment['XDG_CONFIG_HOME'];
    final config = (configHome == null || configHome.isEmpty)
        ? p.join(home, '.config')
        : configHome;
    return File(p.join(config, 'autostart', 'synchronizer.desktop'));
  }

  static Future<bool> isEnabled() async =>
      supported && await _entry.exists();

  static Future<void> setEnabled(bool enabled) async {
    if (!supported) return;
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
}
