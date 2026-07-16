import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sync_net/sync_net.dart';

import 'app_settings.dart';
import 'home.dart';
import 'prefs_trust_store.dart';
import 'settings_page.dart';
import 'shared_folders_page.dart';
import 'storage.dart';

/// The three places in the app.
enum _Destination {
  sync(Icons.sync, 'Sync'),
  folders(Icons.folder, 'Folders'),
  settings(Icons.settings, 'Settings');

  const _Destination(this.icon, this.label);
  final IconData icon;
  final String label;
}

/// Holds the navigation and the state the destinations share: the trust store
/// and the set of shared folders, which both the sync screen (it serves them to
/// peers) and the folders screen (it edits them) need to see the same instance
/// of.
///
/// The layout follows the platform: a rail down the side on a desktop, a bar
/// along the bottom on a phone.
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.self,
    required this.settings,
    this.prepareNetwork,
    this.autoStart = true,
  });

  final DeviceInfo self;
  final AppSettings settings;
  final Future<void> Function()? prepareNetwork;
  final bool autoStart;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final TrustStore _trust = PrefsTrustStore();
  final SharedFolders _folders = SharedFolders();
  int _index = 0;

  @override
  void initState() {
    super.initState();
    if (widget.autoStart) _folders.load();
  }

  @override
  void dispose() {
    _folders.dispose();
    super.dispose();
  }

  void _select(int index) => setState(() => _index = index);

  @override
  Widget build(BuildContext context) {
    // IndexedStack, not a swap: the sync screen keeps discovery and the pairing
    // server running while the user is off looking at folders or settings.
    final body = IndexedStack(
      index: _index,
      children: [
        DevicesPage(
          self: widget.self,
          trust: _trust,
          folders: _folders,
          prepareNetwork: widget.prepareNetwork,
          autoStart: widget.autoStart,
        ),
        SharedFoldersPage(folders: _folders),
        SettingsPage(settings: widget.settings),
      ],
    );

    if (Platform.isAndroid || Platform.isIOS) {
      return Scaffold(
        body: body,
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: _select,
          destinations: [
            for (final d in _Destination.values)
              NavigationDestination(icon: Icon(d.icon), label: d.label),
          ],
        ),
      );
    }

    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            extended: true,
            minExtendedWidth: 180,
            selectedIndex: _index,
            onDestinationSelected: _select,
            leading: const _RailHeader(),
            destinations: [
              for (final d in _Destination.values)
                NavigationRailDestination(
                  icon: Icon(d.icon),
                  label: Text(d.label),
                ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: body),
        ],
      ),
    );
  }
}

/// The app's name above the rail's destinations.
class _RailHeader extends StatelessWidget {
  const _RailHeader();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          'Synchronizer',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
      ),
    );
  }
}
