import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sync_net/sync_net.dart';

import '../l10n/gen/app_localizations.dart';

import 'app_settings.dart';
import 'direct_connect_page.dart';
import 'direct_link.dart';
import 'folder_choice.dart';
import 'qr_pairing.dart';
import 'home.dart';
import 'prefs_trust_store.dart';
import 'settings_page.dart';
import 'storage.dart';

/// The three places in the app.
///
/// Folders used to be one of them, and it was a tab nobody had reason to open
/// until something did not work - while being the one setting everything else
/// depends on. It now sits on the device it belongs to, on the first screen,
/// and again in settings. Direct took its place: it is a way of reaching a
/// device rather than a mode of the device list, and a switch inside one tab
/// hid it from anyone who had not already gone looking.
enum _Destination {
  sync(Icons.sync),
  direct(Icons.cable),
  settings(Icons.settings);

  const _Destination(this.icon);
  final IconData icon;

  /// Resolved against the current language rather than stored, since an enum
  /// constant is fixed at compile time and the language is not.
  String label(AppLocalizations l10n) => switch (this) {
        _Destination.sync => l10n.navSync,
        _Destination.direct => l10n.directModeDirect,
        _Destination.settings => l10n.navSettings,
      };
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
    this.directLink,
    this.qrScanner,
    this.onRename,
    this.autoStart = true,
  });

  final DeviceInfo self;

  /// Renames this device, everywhere at once.
  final Future<void> Function(String name)? onRename;
  final AppSettings settings;
  final Future<void> Function()? prepareNetwork;

  /// Handed to the devices screen, which offers what the platform can do about
  /// making a direct link. Null on the desktop, which can do none of it.
  final DirectLinkControls? directLink;

  /// The camera that reads a pairing code, where there is one.
  final QrScanner? qrScanner;

  final bool autoStart;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final TrustStore _trust = PrefsTrustStore();
  final SharedFolders _folders = SharedFolders();

  /// The networking, owned here rather than by the devices screen: both tabs
  /// need it now. The direct screen shows a code the server must honour, and
  /// the device list shows what discovery finds - one server and one discovery
  /// between them, started once and stopped once.
  late final DiscoveryService _discovery;
  late final PeerServer _server;
  AppLifecycleListener? _lifecycle;

  /// Whether the network could be opened at all. Watched by the devices screen,
  /// which is where a failure is worth reporting.
  final ValueNotifier<bool> _networkFailed = ValueNotifier(false);

  /// What this app's traffic was pinned to, when it had to be. Null when
  /// nothing was in the way.
  final ValueNotifier<String?> _boundTo = ValueNotifier(null);

  int _index = 0;

  @override
  void initState() {
    super.initState();
    _discovery = DiscoveryService(widget.self);
    _server = PeerServer(
      widget.self,
      _trust,
      port: widget.self.port,
      directories: _folders,
    );
    if (widget.autoStart) {
      _folders.load().then((_) => _checkStorage());
      // Closing the app should take this device off other people's lists right
      // away; coming back to it should look again, since the phone may have
      // changed network while it was away.
      _lifecycle = AppLifecycleListener(
        onDetach: _shutdown,
        onResume: _discovery.refresh,
      );
      startNetworking();
    }
  }

  /// Once the stored choice is back: can this app read files, and is there
  /// anything in the folder it is supposed to be syncing?
  ///
  /// Both are checked here rather than left to the first sync, because both
  /// fail as silence - "nothing to do" over a vault the app cannot see, or over
  /// a folder that is not the one with the vault in it - and silence is exactly
  /// what nobody can debug.
  ///
  /// After a frame, so there is a Navigator to put the question in.
  void _checkStorage() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ensureStorageReady(context, _folders);
    });
  }

  Future<void> startNetworking() async {
    await widget.prepareNetwork?.call();
    // Before opening a single socket: if a VPN is carrying this device's
    // traffic, the other device is not in that tunnel. Binding this app to the
    // local network puts it back on the network the other device is on, and
    // leaves every other app on the VPN.
    _boundTo.value = await widget.directLink?.bindToLocalNetwork();
    try {
      await _discovery.start();
      await _server.start();
      _networkFailed.value = false;
    } catch (_) {
      // Nearly always the port already being held by another copy of the app.
      _networkFailed.value = true;
    }
  }

  bool _stopped = false;

  void _shutdown() {
    if (_stopped) return;
    _stopped = true;
    _discovery.dispose(); // announces our goodbye, then closes the stream
    _server.stop();
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _shutdown();
    widget.directLink?.releaseNetwork();
    _networkFailed.dispose();
    _boundTo.dispose();
    _folders.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(HomeShell old) {
    super.didUpdateWidget(old);
    // A rename above has to reach the running services: the name travels in
    // every announcement and in the pairing handshake, and both hold their own
    // copy of who we are.
    if (old.self.name != widget.self.name) {
      _discovery.rename(widget.self.name);
      _server.self = widget.self;
    }
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
          onRename: widget.onRename,
          trust: _trust,
          folders: _folders,
          discovery: _discovery,
          server: _server,
          networkFailed: _networkFailed,
          boundToLocalNetwork: _boundTo,
          onRetryNetwork: startNetworking,
        ),
        DirectConnectPage(
          self: widget.self,
          trust: _trust,
          folders: _folders,
          links: widget.directLink,
          scanner: widget.qrScanner,
          server: _server,
          autoLoad: widget.autoStart,
        ),
        SettingsPage(
          settings: widget.settings,
          folders: _folders,
          deviceName: widget.self.name,
          onRename: widget.onRename,
        ),
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
              NavigationDestination(
                  icon: Icon(d.icon),
                  label: d.label(AppLocalizations.of(context))),
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
                  label: Text(d.label(AppLocalizations.of(context))),
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
          AppLocalizations.of(context).appTitle,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
      ),
    );
  }
}
