import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../l10n/gen/app_localizations.dart';
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
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: ListView(
        children: [
          _Heading(l10n.sectionAppearance),
          ListTile(
            title: Text(l10n.colourScheme),
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
            title: Text(l10n.theme),
            trailing: DropdownButton<ThemeMode>(
              value: widget.settings.themeMode,
              onChanged: (value) {
                if (value != null) widget.settings.setThemeMode(value);
              },
              items: [
                DropdownMenuItem(
                    value: ThemeMode.system, child: Text(l10n.themeSystem)),
                DropdownMenuItem(
                    value: ThemeMode.light, child: Text(l10n.themeLight)),
                DropdownMenuItem(
                    value: ThemeMode.dark, child: Text(l10n.themeDark)),
              ],
            ),
          ),
          ListTile(
            title: Text(l10n.language),
            trailing: DropdownButton<AppLanguage>(
              value: widget.settings.language,
              onChanged: (value) {
                if (value != null) widget.settings.setLanguage(value);
              },
              items: [
                for (final language in AppLanguage.values)
                  DropdownMenuItem(
                    value: language,
                    // Every language names itself, except "follow the system",
                    // which has no language of its own to be named in.
                    child: Text(language == AppLanguage.system
                        ? l10n.languageSystem
                        : language.label),
                  ),
              ],
            ),
          ),
          const Divider(),

          _Heading(l10n.sectionSyncing),
          SwitchListTile(
            title: Text(l10n.plainSync),
            subtitle: Text(l10n.plainSyncSubtitle),
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
            _Heading(l10n.sectionStartup),
            SwitchListTile(
              title: Text(l10n.startAtLogin),
              subtitle: Text(l10n.startAtLoginSubtitle),
              value: _autostart,
              onChanged: (value) async {
                setState(() => _autostart = value);
                await Autostart.setEnabled(value);
              },
            ),
          ],

          const Divider(),
          _Heading(l10n.sectionAbout),
          ListTile(
            title: Text(l10n.appTitle),
            subtitle: Text(
              [
                if (_version.isNotEmpty) l10n.versionLabel(_version),
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
