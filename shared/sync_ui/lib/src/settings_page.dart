import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../l10n/gen/app_localizations.dart';
import 'app_settings.dart';
import 'layout.dart';
import 'rename_dialog.dart';
import 'sync_folder_page.dart';
import 'autostart.dart';
import 'storage.dart';

/// The year this is released under, shown in the about block.
const int kCopyrightYear = 2026;
const String kDeveloper = 'Axawys';

/// Appearance, sync behaviour, startup, and what this app actually is.
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.settings,
    this.folders,
    this.deviceName,
    this.onRename,
  });

  final AppSettings settings;

  /// This device's name and how to change it. What every other device shows
  /// for this one, so it belongs among the settings rather than nowhere.
  final String? deviceName;
  final Future<void> Function(String name)? onRename;

  /// What this device offers. The same choice as on the devices screen, in the
  /// place people go looking for settings - it is one setting, and it is worth
  /// being findable twice rather than nowhere.
  final SharedFolders? folders;

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
      body: ContentPane(
        child: ListView(
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

          if (widget.deviceName != null) ...[
            _Heading(l10n.deviceName),
            ListTile(
              leading: const Icon(Icons.badge_outlined),
              title: Text(widget.deviceName!),
              subtitle: Text(l10n.deviceNameHint),
              trailing: const Icon(Icons.edit_outlined),
              onTap: () => renameDeviceDialog(
                context,
                current: widget.deviceName!,
                onRename: widget.onRename,
              ),
            ),
            const Divider(),
          ],

          _Heading(l10n.syncFolderTitle),
          if (widget.folders != null)
            ListenableBuilder(
              listenable: widget.folders!,
              builder: (context, _) {
                final shared = widget.folders!.folder;
                return ListTile(
                  leading: const Icon(Icons.folder_shared),
                  title:
                      Text(shared?.name ?? l10n.syncFolderChoose),
                  subtitle: Text(shared == null
                      ? l10n.syncFolderNone
                      : prettyPath(shared.path)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          SyncFolderPage(folders: widget.folders!),
                    ),
                  ),
                );
              },
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
      padding: const EdgeInsets.fromLTRB(
          Layout.gutter, Layout.gutter, Layout.gutter, Layout.tight),
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
