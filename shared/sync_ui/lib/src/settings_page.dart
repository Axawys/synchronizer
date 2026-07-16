import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'app_settings.dart';
import 'autostart.dart';
import 'storage.dart';

/// The year this is released under, shown in the about block.
const int kCopyrightYear = 2026;
const String kDeveloper = 'Axawys';

/// Appearance, sync behaviour, startup, and what this app actually is.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.settings});

  final AppSettings settings;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool? _plainSync;
  bool _autostart = false;
  String _version = '';

  @override
  void initState() {
    super.initState();
    _loadAsyncBits();
  }

  Future<void> _loadAsyncBits() async {
    final plain = await SyncSettings.lightMode();
    final autostart = await Autostart.isEnabled();
    final version = await _appVersion();
    if (!mounted) return;
    setState(() {
      _plainSync = plain;
      _autostart = autostart;
      _version = version;
    });
  }

  /// The version from the app bundle. Falls back to blank rather than failing
  /// the screen if the platform will not report it (as in a widget test).
  Future<String> _appVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return info.buildNumber.isEmpty
          ? info.version
          : '${info.version} (${info.buildNumber})';
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final plainSync = _plainSync;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          _Heading('Appearance'),
          ListTile(
            title: const Text('Colour scheme'),
            trailing: DropdownButton<AppColorScheme>(
              value: widget.settings.scheme,
              onChanged: (value) {
                if (value != null) widget.settings.setScheme(value);
              },
              items: [
                for (final scheme in AppColorScheme.values)
                  DropdownMenuItem(value: scheme, child: Text(scheme.label)),
              ],
            ),
          ),
          ListTile(
            title: const Text('Theme'),
            trailing: DropdownButton<ThemeMode>(
              value: widget.settings.themeMode,
              onChanged: (value) {
                if (value != null) widget.settings.setThemeMode(value);
              },
              items: const [
                DropdownMenuItem(value: ThemeMode.system, child: Text('System')),
                DropdownMenuItem(value: ThemeMode.light, child: Text('Light')),
                DropdownMenuItem(value: ThemeMode.dark, child: Text('Dark')),
              ],
            ),
          ),
          const Divider(),

          _Heading('Syncing'),
          SwitchListTile(
            title: const Text('Plain sync'),
            subtitle: const Text(
                'Apply changes without showing the diff for confirmation. '
                'Conflicts are resolved by taking the more recently edited side.'),
            value: plainSync ?? false,
            onChanged: plainSync == null
                ? null
                : (value) {
                    setState(() => _plainSync = value);
                    SyncSettings.setLightMode(value);
                  },
          ),

          if (Autostart.supported) ...[
            const Divider(),
            _Heading('Startup'),
            SwitchListTile(
              title: const Text('Start when I log in'),
              subtitle: const Text(
                  'Launch Synchronizer automatically with the desktop session.'),
              value: _autostart,
              onChanged: (value) async {
                setState(() => _autostart = value);
                await Autostart.setEnabled(value);
              },
            ),
          ],

          const Divider(),
          _Heading('About'),
          ListTile(
            title: const Text('Synchronizer'),
            subtitle: Text(
              [
                if (_version.isNotEmpty) 'Version $_version',
                '© $kCopyrightYear $kDeveloper',
              ].join('\n'),
            ),
          ),
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        label,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }
}
