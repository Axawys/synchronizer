import 'dart:async';
import 'dart:io';
import 'dart:math' show pi;

import 'package:flutter/foundation.dart' show ValueListenable;

import 'package:flutter/material.dart';
import 'package:sync_net/sync_net.dart';

import '../l10n/gen/app_localizations.dart';

import 'app_settings.dart';
import 'app_shell.dart';
import 'direct_link.dart';
import 'folder_choice.dart';
import 'layout.dart';
import 'multi_sync_page.dart';
import 'pairing_dialogs.dart';
import 'rename_dialog.dart';
import 'qr_pairing.dart';
import 'storage.dart';
import 'sync_folder_page.dart';
import 'sync_log_page.dart';
import 'sync_page.dart';
import 'theme.dart';

/// Root widget for both apps. The only per-platform difference is
/// [prepareNetwork]: Android passes a hook that grabs the multicast lock before
/// discovery starts; the desktop passes nothing.
///
/// It owns [AppSettings] because the palette and light/dark choice have to be
/// applied above [MaterialApp], where the themes are declared.
class SynchronizerApp extends StatefulWidget {
  const SynchronizerApp({
    super.key,
    required this.self,
    this.prepareNetwork,
    this.applyWindowBrightness,
    this.directLink,
    this.qrScanner,
    this.onRename,
    this.autoStart = true,
  });

  final DeviceInfo self;

  /// Where a new name is kept, so it survives a restart. The apps own the
  /// identity file; null in tests, where a rename need not outlive the test.
  final Future<void> Function(String name)? onRename;
  final Future<void> Function()? prepareNetwork;

  /// What this platform can do about making a direct link - hosting a hotspot,
  /// opening the tethering settings. Null on a platform that can do neither,
  /// which is the desktop.
  final DirectLinkControls? directLink;

  /// Reads QR codes with the camera. Null on a platform without one to offer,
  /// which is the desktop.
  final QrScanner? qrScanner;

  /// Called with the brightness the app is actually painted in, whenever it
  /// changes. The desktop uses it to match the window frame, which GTK draws
  /// and which would otherwise stay light under a dark theme. Null where the
  /// platform owns the frame anyway, as on Android.
  final Future<void> Function(Brightness)? applyWindowBrightness;

  /// Whether to start discovery and the pairing server on launch. Off in widget
  /// tests so no real sockets or timers are created.
  final bool autoStart;

  @override
  State<SynchronizerApp> createState() => _SynchronizerAppState();
}

class _SynchronizerAppState extends State<SynchronizerApp> {
  final AppSettings _settings = AppSettings();

  /// This device as it currently calls itself. Held here rather than passed
  /// straight down, because renaming has to reach everything below at once -
  /// the announcements, the handshake, and the screen showing the name.
  late DeviceInfo _self = widget.self;

  Future<void> _rename(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == _self.name) return;
    await widget.onRename?.call(trimmed);
    if (!mounted) return;
    setState(() => _self = DeviceInfo(
          id: _self.id,
          name: trimmed,
          platform: _self.platform,
          port: _self.port,
          address: _self.address,
        ));
  }

  @override
  void initState() {
    super.initState();
    _settings.load();
  }

  @override
  void dispose() {
    _settings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _settings,
      builder: (context, _) => MaterialApp(
        onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
        theme: buildTheme(_settings.scheme, Brightness.light),
        darkTheme: buildTheme(_settings.scheme, Brightness.dark),
        themeMode: _settings.themeMode,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        // Null follows the system, and an unsupported system language falls
        // back to the template, English.
        locale: _settings.locale,
        home: _WindowFrameSync(
          apply: widget.applyWindowBrightness,
          child: HomeShell(
            self: _self,
            onRename: _rename,
            settings: _settings,
            prepareNetwork: widget.prepareNetwork,
            directLink: widget.directLink,
            qrScanner: widget.qrScanner,
            autoStart: widget.autoStart,
          ),
        ),
      ),
    );
  }
}

/// Reports the brightness the app is actually painted in to [apply].
///
/// It reads it from the inherited theme rather than from the settings, so it
/// stays right for [ThemeMode.system] too, where the brightness comes from the
/// platform and can change without any setting changing.
class _WindowFrameSync extends StatefulWidget {
  const _WindowFrameSync({required this.child, this.apply});

  final Widget child;
  final Future<void> Function(Brightness)? apply;

  @override
  State<_WindowFrameSync> createState() => _WindowFrameSyncState();
}

class _WindowFrameSyncState extends State<_WindowFrameSync> {
  Brightness? _reported;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brightness = Theme.of(context).brightness;
    if (brightness == _reported) return;
    _reported = brightness;
    widget.apply?.call(brightness);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Lists devices found on the network and drives pairing in both directions:
/// tapping a device starts an outgoing request, and an inbound request pops a
/// confirmation dialog on this device.
///
/// The trust store and shared folders come from [HomeShell], because the
/// folders screen edits the very set this screen serves to peers.
class DevicesPage extends StatefulWidget {
  const DevicesPage({
    super.key,
    required this.self,
    required this.trust,
    required this.folders,
    required this.discovery,
    required this.server,
    this.networkFailed,
    this.boundToLocalNetwork,
    this.onRetryNetwork,
    this.onRename,
  });

  final DeviceInfo self;
  final TrustStore trust;
  final SharedFolders folders;

  /// The networking, owned by the shell: this screen watches and drives it but
  /// does not start or stop it, because the direct tab needs the same server.
  final DiscoveryService discovery;
  final PeerServer server;

  /// Whether the network could be opened at all, and how to try again. Null in
  /// tests, which start nothing.
  final ValueListenable<bool>? networkFailed;

  /// What this app's traffic was pinned to when a VPN was in the way, so the
  /// screen can say why it is not behaving like everything else on the device.
  final ValueListenable<String?>? boundToLocalNetwork;

  final Future<void> Function()? onRetryNetwork;

  /// Renames this device. Offered on its own card, which is where someone
  /// looking at the name is already looking.
  final Future<void> Function(String name)? onRename;

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  DiscoveryService get _discovery => widget.discovery;
  PeerServer get _pairingServer => widget.server;

  List<DeviceInfo> _devices = const [];
  List<TrustedPeer> _trusted = const [];
  bool _busy = false; // a pairing dialog is on screen
  bool _networkFailed = false;
  bool _refreshing = false;

  /// What this device's own shared folders weigh, once they have been walked.
  /// Null while nothing has been measured, which is also what an unchosen
  /// folder looks like.
  int? _selfBytes;

  /// What each paired device holds, by device id: its folders, where it keeps
  /// them and what they weigh. Absent for a device that has not answered yet.
  final Map<String, List<SharedDir>> _peerFolders = {};
  bool _asking = false;

  /// How long to look before admitting nothing is there. Answers arrive in
  /// well under a second on a working network, so this is long enough that a
  /// slow one is not called dead, and short enough that the user is not left
  /// watching an animation that will never resolve.
  static const _searchPatience = Duration(seconds: 12);
  Timer? _searchTimer;
  bool _searchTimedOut = false;

  /// The devices on the network right now, and whether each is already paired
  /// with.
  ///
  /// Only what is reachable is listed: every row here is something a tap can
  /// actually do. A device that has gone quiet leaves the list, paired or not.
  /// The trust store still matters, but as a fact about the devices on screen
  /// rather than as a source of rows of its own.
  List<_Listed> get _listed {
    final paired = {for (final peer in _trusted) peer.id};
    return [
      for (final device in _devices)
        _Listed(device: device, paired: paired.contains(device.id)),
    ];
  }

  @override
  void initState() {
    super.initState();
    // Paired devices are worth listing before anything is heard from the
    // network: they are the ones this device syncs with, present or not.
    _refreshTrusted();
    // The countdown is about what the screen says, not about the network, so
    // it runs even where discovery does not.
    _startSearchCountdown();
    _listen();
    _checkVpn();
    _measureSelf();
    widget.folders.addListener(_measureSelf);
    widget.networkFailed?.addListener(_onNetworkStatus);
  }

  /// Walks this device's own folders and remembers what they weigh.
  ///
  /// The path alone answers which folder is being synced; the weight answers
  /// whether it is the folder with the vault in it. Both belong on the card,
  /// and the second is the one that catches an empty folder chosen by mistake.
  Future<void> _measureSelf() async {
    final shared = widget.folders.folders;
    if (shared.isEmpty) {
      if (mounted && _selfBytes != null) setState(() => _selfBytes = null);
      return;
    }
    var bytes = 0;
    for (final folder in shared) {
      bytes += (await Manifest.measure(Directory(folder.path))).bytes;
    }
    if (mounted) setState(() => _selfBytes = bytes);
  }

  /// Asks each paired device what it is holding.
  ///
  /// The address was what a paired card used to show, and it is the one thing
  /// about a paired device nobody needs: it is reached by tapping it, not by
  /// reading its address off a card. What is worth showing there is what the
  /// sync is actually about - which folder, and how much is in it - and that is
  /// a question the device can be asked in one short session that reads nothing
  /// and writes nothing.
  Future<void> _askPaired() async {
    if (_asking) return;
    _asking = true;
    try {
      for (final device in _pairedOnline) {
        if (_peerFolders.containsKey(device.id)) continue;
        final address = device.address;
        if (address == null) continue;
        final trusted = await widget.trust.get(device.id);
        if (trusted == null) continue;

        SyncClient? client;
        try {
          client = await SyncClient.connect(address, device.port,
              self: widget.self, trusted: trusted);
          final dirs = await client.listDirectories();
          if (!mounted) return;
          setState(() => _peerFolders[device.id] = dirs);
        } catch (_) {
          // It answered discovery and will not answer this - busy with another
          // device, or already gone. The card falls back to saying where it is,
          // which is what it always said.
        } finally {
          await client?.close();
        }
      }
    } finally {
      _asking = false;
    }
  }

  /// Forgets what a device said, so it is asked again: after a sync, which is
  /// exactly when the numbers changed, and when it leaves the network, so a
  /// device coming back is not described by what it held last time.
  void _forgetFolders(String deviceId) => _peerFolders.remove(deviceId);

  /// Whether a VPN is up. Read from the interfaces, so it works on both
  /// platforms and does not need the platform hook.
  bool _vpn = false;

  Future<void> _checkVpn() async {
    final up = await vpnIsUp();
    if (mounted && up != _vpn) setState(() => _vpn = up);
  }

  void _onNetworkStatus() {
    if (mounted) setState(() => _networkFailed = widget.networkFailed!.value);
  }

  StreamSubscription<List<DeviceInfo>>? _peerUpdates;
  StreamSubscription<IncomingPairing>? _incomingRequests;
  StreamSubscription<FolderRequest>? _folderRequests;

  /// Watches what the shell's networking reports. Subscribed once: both
  /// streams outlive a failed start, and listening twice would double every
  /// update.
  void _listen() {
    _peerUpdates ??= _discovery.peers.listen((devices) {
      if (!mounted) return;
      final present = {for (final device in devices) device.id};
      _peerFolders.removeWhere((id, _) => !present.contains(id));
      setState(() => _devices = devices);
      _followRenames(devices);
      unawaited(_askPaired());
      // Found something: the search is over, whatever the clock said. Emptied
      // out again: it has started over, so give it the same patience afresh.
      if (devices.isEmpty) {
        _startSearchCountdown();
      } else {
        _searchTimer?.cancel();
        if (_searchTimedOut) setState(() => _searchTimedOut = false);
      }
    });
    _incomingRequests ??=
        _pairingServer.pairingRequests.listen(_onIncomingRequest);
    // The other device wants a folder this one has no place for yet. Only the
    // person here can say where it goes, so the question surfaces here.
    _folderRequests ??=
        _pairingServer.folderRequests.listen(_onFolderRequest);
  }

  /// Retry after the network could not be opened, from the button the failure
  /// puts on screen.
  Future<void> _retryNetworking() async {
    setState(() => _networkFailed = false);
    await widget.onRetryNetwork?.call();
  }

  /// A paired device that renamed itself: the announcement is the authority on
  /// what it is called, so the stored pairing is brought into line. Without
  /// this the old name would keep turning up in dialogs and in anything that
  /// reads the trust store rather than the list.
  Future<void> _followRenames(List<DeviceInfo> devices) async {
    var changed = false;
    for (final device in devices) {
      for (final peer in _trusted) {
        if (peer.id != device.id || peer.name == device.name) continue;
        await widget.trust.add(TrustedPeer(
          id: peer.id,
          name: device.name,
          platform: device.platform,
          secret: peer.secret,
        ));
        changed = true;
      }
    }
    if (changed) await _refreshTrusted();
  }

  Future<void> _refreshTrusted() async {
    final trusted = await widget.trust.all();
    if (!mounted) return;
    setState(() => _trusted = trusted);
    // A device that has just become paired is a device with something to say
    // about its folders. Not waited on: the list is usable while the answers
    // come in, and one device that stopped answering should not hold the
    // refresh spinner up for the length of a connect timeout.
    unawaited(_askPaired());
  }

  /// Starts (or restarts) the wait after which the screen stops claiming to be
  /// looking and offers to look again.
  void _startSearchCountdown() {
    _searchTimer?.cancel();
    if (_searchTimedOut) setState(() => _searchTimedOut = false);
    _searchTimer = Timer(_searchPatience, () {
      if (mounted && _devices.isEmpty) setState(() => _searchTimedOut = true);
    });
  }

  /// The refresh button and the pull gesture. Both re-read the network and the
  /// trust store, and both hold the spinner for a moment: a burst of queries
  /// takes about a second to be answered, and a control that flashes and
  /// settles before any answer arrives reads as broken.
  Future<void> _refreshEverything() async {
    if (_refreshing) return;
    _startSearchCountdown();
    setState(() => _refreshing = true);
    // Refreshing means the numbers too: a folder that has grown since the
    // screen opened is exactly what someone pressing this wants to see.
    _peerFolders.clear();
    await Future.wait([
      _discovery.refresh(),
      _refreshTrusted(),
      _checkVpn(),
      _measureSelf(),
      Future<void>.delayed(const Duration(milliseconds: 900)),
    ]);
    if (mounted) setState(() => _refreshing = false);
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _peerUpdates?.cancel();
    _incomingRequests?.cancel();
    _folderRequests?.cancel();
    widget.folders.removeListener(_measureSelf);
    widget.networkFailed?.removeListener(_onNetworkStatus);
    // The networking itself belongs to the shell and outlives this screen.
    super.dispose();
  }

  // Another device is asking to pair with us.
  Future<void> _onIncomingRequest(IncomingPairing request) async {
    if (!mounted) return;

    // Already decided: it proved it had read the code this device is showing,
    // and that was the decision. Nothing to ask - only to report.
    if (request.settled) {
      await _refreshTrusted();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              AppLocalizations.of(context).pairedWith(request.peer.name)),
        ));
      }
      return;
    }

    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => ConfirmPairingDialog(request: request),
    );
    if (accepted == true) {
      await request.accept();
      await _refreshTrusted();
    } else {
      await request.reject();
    }
  }

  // Tapping a device: open the sync screen if already paired, otherwise pair.
  Future<void> _openDevice(_Listed entry) async {
    if (entry.device.address == null) return;

    final trusted = await widget.trust.get(entry.device.id);
    if (trusted == null) {
      await _startPairing(entry.device);
      return;
    }
    if (!mounted) return;

    // With more than one paired device present, opening one of them and
    // ignoring the others would be showing half the picture: the folder is the
    // same folder on all of them, and what matters is where each stands. So a
    // tap opens all of them, counts and all.
    if (_pairedOnline.length > 1) {
      await _openMultiSync();
      return;
    }

    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SyncPage(
        self: widget.self,
        trusted: trusted,
        device: entry.device,
        // The folder is already chosen on this device; the screen should not
        // ask for it again just because this pair has not met before.
        folders: widget.folders,
        // Tapping a device is asking for a sync, not for a list of one folder
        // to tap a second time.
        autoSync: true,
        // So the screen notices the device leaving the network or coming back
        // at a different address, instead of holding a dead connection.
        presence: _discovery,
      ),
    ));
    // Both sides have moved: the numbers on the cards are last week's.
    _forgetFolders(entry.device.id);
    await _measureSelf();
    await _refreshTrusted();
  }

  /// A paired device asked for a folder this one does not offer yet: put the
  /// chooser in front of the user and share what they pick under that name.
  bool _choosingFolder = false;

  Future<void> _onFolderRequest(FolderRequest request) async {
    // One at a time: a device retrying its request should not stack dialogs.
    if (!mounted || _choosingFolder) return;
    _choosingFolder = true;
    try {
      final l10n = AppLocalizations.of(context);
      final peer = await widget.trust.get(request.peerId);
      if (!mounted) return;
      final peerName = peer?.name ?? request.peerId;

      final agreed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.create_new_folder_outlined),
          title: Text(l10n.folderAsked(peerName, request.folder)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.folderAskedBody(request.folder, peerName)),
              // This device syncs one folder, so saying yes here is not adding
              // anything - it is putting something else in the place of what is
              // already being synced, and that has to be said before the
              // chooser opens rather than discovered afterwards.
              if (widget.folders.folder != null) ...[
                const SizedBox(height: Layout.gap),
                Text(
                  l10n.folderAskedReplaces(widget.folders.folder!.name),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.folderAskedLater),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.folderAskedChoose),
            ),
          ],
        ),
      );
      if (agreed != true || !mounted) return;

      final path = await pickFolder(context);
      if (path == null || !mounted) return;

      await widget.folders.chooseAs(request.folder, path);
      if (mounted) {
        final said = AppLocalizations.of(context)
            .folderNowShared(request.folder, path);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(said)));
      }
    } finally {
      _choosingFolder = false;
    }
  }

  /// Drops a pairing. Offered on a long press rather than a button, because it
  /// is rare and destructive: the shared secret goes, and the next sync with
  /// that device needs the code confirmed on both screens again.
  Future<void> _forgetDevice(_Listed entry) async {
    final l10n = AppLocalizations.of(context);
    if (!entry.paired) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.link_off),
        title: Text(l10n.forgetDevice),
        content: Text(l10n.forgetDeviceBody(entry.device.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.forget),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await widget.trust.remove(entry.device.id);
    await _refreshTrusted();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.deviceForgotten(entry.device.name))),
      );
    }
  }

  /// The paired devices that are on the network right now.
  List<DeviceInfo> get _pairedOnline {
    final paired = {for (final peer in _trusted) peer.id};
    return [
      for (final device in _devices)
        if (paired.contains(device.id)) device,
    ];
  }

  /// Choosing what this device syncs: the same flow wherever it is asked for.
  Future<void> _chooseSyncFolder() async {
    final path = await chooseSyncFolder(context);
    if (path == null) return;
    await widget.folders.choose(path);
  }

  Future<void> _openFolders() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SyncFolderPage(folders: widget.folders),
    ));
  }

  Future<void> _openMultiSync() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => MultiSyncPage(
        self: widget.self,
        devices: _pairedOnline,
        trust: widget.trust,
        folders: widget.folders,
      ),
    ));
  }

  void _openHistory() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => const SyncLogPage(),
    ));
  }

  // We are asking another device to pair.
  Future<void> _startPairing(DeviceInfo device) async {
    final address = device.address;
    if (address == null || _busy) return;
    setState(() => _busy = true);

    final codeNotifier = ValueNotifier<String?>(null);
    // The wait here is on somebody at the other device. Giving up has to be
    // possible, and has to actually drop the attempt rather than hide it.
    final cancel = Completer<void>();
    final future = PairingClient(widget.self, widget.trust).pair(
      address,
      device.port,
      onCode: (_, code) => codeNotifier.value = code,
      cancel: cancel.future,
    );

    if (mounted) {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => OutgoingPairingDialog(
          name: device.name,
          code: codeNotifier,
          result: future,
          onCancel: () {
            if (!cancel.isCompleted) cancel.complete();
          },
        ),
      );
    } else {
      await future;
    }

    codeNotifier.dispose();
    await _refreshTrusted();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.devicesTitle),
        actions: [
          IconButton(
            icon: _refreshing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                : const Icon(Icons.refresh),
            tooltip: l10n.searchAgain,
            onPressed: _refreshing ? null : _refreshEverything,
          ),
          // Only worth offering when there is more than one device to bring
          // into line; with one it is the ordinary sync screen.
          if (_pairedOnline.length > 1)
            IconButton(
              icon: const Icon(Icons.hub),
              tooltip: l10n.bringInLine,
              onPressed: _openMultiSync,
            ),
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: l10n.syncHistoryTooltip,
            onPressed: _openHistory,
          ),
        ],
      ),
      // Crossing from "looking" to a found device is the moment the app is
      // waited on; a fade makes it land rather than blink.
      body: Column(
        children: [
          // Always on screen, not only once something has been found: on a
          // first run the list is empty for a while, and this is where the
          // folder to sync is chosen.
          Padding(
            padding: const EdgeInsets.fromLTRB(
                Layout.gutter, Layout.gap, Layout.gutter, 0),
            child: ContentPane(
              child: SelfCard(
                self: widget.self,
                folders: widget.folders,
                bytes: _selfBytes,
                onChooseFolder: _chooseSyncFolder,
                onOpenFolders: _openFolders,
                onRename: () => renameDeviceDialog(
                  context,
                  current: widget.self.name,
                  onRename: widget.onRename,
                ),
              ),
            ),
          ),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: _body(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_networkFailed) {
      return _DiscoveryFailed(
          key: const ValueKey('failed'), onRetry: _retryNetworking);
    }
    final entries = _listed;
    if (entries.isEmpty) {
      return SearchingPanel(
        key: const ValueKey('searching'),
        timedOut: _searchTimedOut,
        onRefresh: _refreshEverything,
        vpn: _vpn,
        bypassed: widget.boundToLocalNetwork?.value != null,
      );
    }

    // Pull down to look again, which on a phone is where the hand already is.
    // The desktop has the button in the app bar for the same thing.
    final paired = [for (final e in entries) if (e.paired) e];
    final strangers = [for (final e in entries) if (!e.paired) e];

    return RefreshIndicator(
      key: const ValueKey('devices'),
      onRefresh: _refreshEverything,
      child: ContentPane(
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          // No gap at the top: the first line of the tree starts against the
          // card pinned above, which is what makes it read as hanging off it.
          padding: const EdgeInsets.fromLTRB(
              Layout.gutter, 0, Layout.gutter, Layout.section),
          children: [
            for (var i = 0; i < paired.length; i++)
              LinkedDevice(
                last: i == paired.length - 1,
                child: DeviceCard(
                  key: ValueKey(paired[i].device.id),
                  device: paired[i].device,
                  paired: true,
                  folders: _peerFolders[paired[i].device.id],
                  onTap: () => _openDevice(paired[i]),
                  onForget: () => _forgetDevice(paired[i]),
                ),
              ),
            if (strangers.isNotEmpty) ...[
              const SizedBox(height: Layout.section),
              Padding(
                padding: const EdgeInsets.only(bottom: Layout.snug),
                child: Text(
                  AppLocalizations.of(context).notPairedGroup,
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              for (final entry in strangers)
                Padding(
                  padding: const EdgeInsets.only(bottom: Layout.gap),
                  child: DeviceCard(
                    key: ValueKey(entry.device.id),
                    device: entry.device,
                    paired: false,
                    onTap: () => _openDevice(entry),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// This device, at the head of the list.
///
/// The screen used to show everything except the device you were holding, which
/// left pairing as a fact with nothing to attach it to. With it here, the lines
/// down to the paired devices have somewhere to start, and "these two are
/// paired" becomes something visible rather than a word on a card.
class SelfCard extends StatelessWidget {
  const SelfCard({
    super.key,
    required this.self,
    this.folders,
    this.bytes,
    this.onChooseFolder,
    this.onOpenFolders,
    this.onRename,
  });

  final DeviceInfo self;

  /// What this device offers. Shown right here because it is the one setting
  /// the whole app turns on, and it used to live behind a tab of its own that
  /// people had no reason to open until something did not work.
  final SharedFolders? folders;

  /// What those folders weigh, once somebody has walked them. Null until then,
  /// so the path appears at once and the size catches up.
  final int? bytes;

  /// Called when there is no folder yet: choosing one is the thing to do.
  final VoidCallback? onChooseFolder;

  /// Called when there is one: the list, where it can be changed.
  final VoidCallback? onOpenFolders;

  /// Renaming this device, on a long press: rare, and it changes what everyone
  /// else calls it.
  final VoidCallback? onRename;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = AppLocalizations.of(context);

    return ListenableBuilder(
      listenable: folders ?? ChangeNotifier(),
      builder: (context, _) {
        final shared = folders?.folder;
        final chosen = shared != null;

        return AppCard(
          onTap: chosen ? onOpenFolders : onChooseFolder,
          onLongPress: onRename,
          padding: const EdgeInsets.symmetric(
              horizontal: Layout.gap + 2, vertical: Layout.gap),
          child: Row(
            children: [
              IconBadge(icon: _iconFor(self.platform), accented: true),
              const SizedBox(width: Layout.gap + 2),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            self.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        const SizedBox(width: Layout.snug),
                        Text(
                          l10n.thisDeviceCard,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    // The folder and what is in it, right here: it is what this
                    // device brings to every sync, not having chosen one is the
                    // single reason a sync has nothing to do, and the weight is
                    // what tells a vault from an empty folder picked by
                    // mistake.
                    FolderLine(
                      text: chosen
                          ? prettyPath(shared.path)
                          : l10n.syncFolderNone,
                      size: chosen && bytes != null
                          ? formatSize(l10n, bytes!)
                          : null,
                      warn: !chosen,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Layout.snug),
              Icon(
                chosen
                    ? Icons.chevron_right
                    : Icons.create_new_folder_outlined,
                color: chosen ? colors.onSurfaceVariant : colors.error,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A device hanging off the one above it, with the line that says so.
///
/// Each row draws its own piece of the line - the trunk coming down from above
/// and the branch into the card - so no part of this has to measure anything or
/// know where the other rows ended up.
class LinkedDevice extends StatelessWidget {
  const LinkedDevice({super.key, required this.child, required this.last});

  final Widget child;

  /// The last one: the trunk stops at this branch instead of carrying on.
  final bool last;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 28,
            child: CustomPaint(
              painter: _LinkPainter(
                colour: colors.primary.withValues(alpha: 0.55),
                last: last,
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: Layout.gap),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

class _LinkPainter extends CustomPainter {
  const _LinkPainter({required this.colour, required this.last});

  final Color colour;
  final bool last;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = colour
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;

    const x = 14.0;
    // The card below the gap is where the branch meets it: half the gap plus
    // half the card, which is what the middle of this row works out to.
    final branchY = (size.height + Layout.gap) / 2;

    final trunkEnd = last ? branchY : size.height;
    canvas.drawLine(Offset(x, 0), Offset(x, trunkEnd), line);
    canvas.drawLine(Offset(x, branchY), Offset(size.width, branchY), line);
  }

  @override
  bool shouldRepaint(_LinkPainter old) =>
      old.colour != colour || old.last != last;
}

/// A device as the list shows it: what it is, and whether this device has
/// paired with it.
class _Listed {
  const _Listed({required this.device, required this.paired});

  final DeviceInfo device;
  final bool paired;
}

/// One device on the network, as a card: what it calls itself, what it is
/// holding, and whether this device has been paired with it.
///
/// Public because it is the whole of what the devices screen shows, and worth
/// being able to put on screen on its own in a test.
class DeviceCard extends StatelessWidget {
  const DeviceCard({
    super.key,
    required this.device,
    required this.paired,
    this.folders,
    this.onTap,
    this.onForget,
  });

  final DeviceInfo device;
  final bool paired;

  /// What this device said it was holding, when it has been asked.
  ///
  /// It replaces the address, which is worth showing only for a device there is
  /// nothing else to say about: an address is how the app finds a device, not
  /// how a person recognises one, and on a paired device the folder and its
  /// weight are what the tap is going to act on. Null while the answer has not
  /// arrived - or did not - and then the address stands in.
  final List<SharedDir>? folders;

  final VoidCallback? onTap;

  /// Drops the pairing. Null for a device there is no pairing to drop.
  final VoidCallback? onForget;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = AppLocalizations.of(context);

    return AppCard(
      // A paired device is the one you came here to tap, so it carries the
      // accent; the rest sit quietly behind a hairline.
      accented: paired,
      onTap: onTap,
      onLongPress: onForget,
      padding: const EdgeInsets.symmetric(
          horizontal: Layout.gap + 2, vertical: Layout.gap),
      child: Row(
        children: [
          IconBadge(icon: _iconFor(device.platform), accented: paired),
          const SizedBox(width: Layout.gap + 2),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The pairing sits against the name, where it belongs: it says
                // something about the device, not about its folder. Down the
                // right-hand side it was taking a pill's width off every row,
                // and the line it was taking it from was the one with the path
                // and the size on it.
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        device.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: Layout.snug),
                    Tag(
                      label: paired ? l10n.pairedLabel : l10n.notPairedLabel,
                      icon: paired ? Icons.link : null,
                      filled: paired,
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                _detail(theme, colors, l10n),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The line under the name: the folder where there is one to report, the
  /// address where there is not.
  Widget _detail(ThemeData theme, ColorScheme colors, AppLocalizations l10n) {
    final dirs = folders;
    if (dirs == null) {
      return Text(
        '${device.address ?? l10n.unknownAddress}:${device.port}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: colors.onSurfaceVariant,
          // Addresses are columns of digits; keeping them from shuffling width
          // as they change is worth the setting.
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      );
    }

    // Paired and sharing nothing: a sync with it would have nothing to do, and
    // that is worth knowing before tapping rather than after.
    if (dirs.isEmpty) {
      return FolderLine(text: l10n.syncFolderNone, warn: true);
    }

    if (dirs.length == 1) {
      final dir = dirs.single;
      if (dir.missing) {
        return FolderLine(text: l10n.folderMissingThere, warn: true);
      }
      return FolderLine(
        text: dir.path == null ? dir.name : prettyPath(dir.path!),
        size: dir.bytes == null ? null : formatSize(l10n, dir.bytes!),
      );
    }

    var bytes = 0;
    for (final dir in dirs) {
      bytes += dir.bytes ?? 0;
    }
    return FolderLine(
      text: l10n.syncFolderCount(dirs.length),
      size: formatSize(l10n, bytes),
    );
  }
}

/// Where a device keeps what it syncs, and how much of it there is.
///
/// One line, because it is a subtitle: the path gives way first when the card
/// is narrow - its tail is the part that names the folder, and [prettyPath] has
/// already kept that - while the weight stays, being three characters that
/// answer "is this the full vault or an empty folder".
class FolderLine extends StatelessWidget {
  const FolderLine({
    super.key,
    required this.text,
    this.size,
    this.warn = false,
  });

  final String text;
  final String? size;

  /// Nothing to sync here: no folder chosen, or one that is not there any more.
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final style = theme.textTheme.bodySmall?.copyWith(
      color: warn ? colors.error : colors.onSurfaceVariant,
      fontWeight: warn ? FontWeight.w600 : null,
    );

    return Row(
      children: [
        Flexible(
          child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: style),
        ),
        if (size != null)
          Text(' · ${size!}', maxLines: 1, style: style),
      ],
    );
  }
}

IconData _iconFor(DevicePlatform platform) => switch (platform) {
      DevicePlatform.android => Icons.smartphone,
      DevicePlatform.linux => Icons.computer,
      DevicePlatform.unknown => Icons.devices_other,
    };

/// The screen while nothing has been found: a square tumbling back and forth,
/// and what to do about it.
///
/// Until [timedOut] the square is rolling and there is nothing to press - the
/// answer is a second away and a button would only invite pressing it. Once the
/// wait is over the square stops, the heading stops claiming to be looking, and
/// the way to try again appears, because by then it is worth offering.
/// The waiting state, public so the reasons it gives can be checked.
class SearchingPanel extends StatelessWidget {
  const SearchingPanel({
    super.key,
    required this.timedOut,
    required this.onRefresh,
    this.vpn = false,
    this.bypassed = false,
  });

  final bool timedOut;
  final Future<void> Function() onRefresh;

  /// A VPN is up, and whether this app was pinned to the local network in spite
  /// of it. Said here because it is the likeliest reason an empty screen stays
  /// empty, and because the user cannot see it from anywhere else.
  final bool vpn;
  final bool bypassed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    // Scrollable so the pull gesture works on an empty screen too - which is
    // the screen someone is most likely to pull on - while the content itself
    // stays centred in the panel however tall it is.
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _RollingSquare(rolling: !timedOut),
                    const SizedBox(height: 24),
                    Text(
                      timedOut ? l10n.noDevicesFound : l10n.lookingForDevices,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      l10n.openOnOtherDevice,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    // The likeliest reason an empty screen stays empty, and
                    // the one thing the user cannot see from anywhere else.
                    if (vpn) ...[
                      const SizedBox(height: Layout.gutter),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.vpn_key_outlined,
                              size: 16,
                              color: theme.colorScheme.onSurfaceVariant),
                          const SizedBox(width: Layout.snug),
                          Flexible(
                            child: Text(
                              bypassed ? l10n.vpnBypassed : l10n.vpnInTheWay,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant),
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (timedOut) ...[
                      const SizedBox(height: 20),
                      FilledButton.tonalIcon(
                        onPressed: onRefresh,
                        icon: const Icon(Icons.refresh),
                        label: Text(l10n.searchAgain),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A square that rolls a few steps to the right, then back to the left.
///
/// A spinner says "something is happening"; this says the same thing without
/// the app's one waiting screen looking like every other app's. It tumbles the
/// way a die would - each step pivots on the corner it is about to land on -
/// because a square that slides rather than rolls looks like a bug.
class _RollingSquare extends StatefulWidget {
  const _RollingSquare({required this.rolling});

  /// False parks it flat: the search is over, and motion would say otherwise.
  final bool rolling;

  @override
  State<_RollingSquare> createState() => _RollingSquareState();
}

class _RollingSquareState extends State<_RollingSquare>
    with SingleTickerProviderStateMixin {
  static const double _side = 16;
  static const int _steps = 3;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1150),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_RollingSquare old) {
    super.didUpdateWidget(old);
    if (old.rolling != widget.rolling) _sync();
  }

  void _sync() {
    // Someone who has asked the system for less motion gets a still square
    // rather than a livelier spinner.
    final wanted =
        widget.rolling && !MediaQuery.disableAnimationsOf(context);
    if (wanted == _controller.isAnimating) return;
    if (wanted) {
      // Reversing is the roll back: played backwards, the same tumble unwinds
      // step by step to where it started.
      _controller.repeat(reverse: true);
    } else {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return SizedBox(
      // Room for the whole run, plus the height a corner reaches mid-tumble.
      width: _side * (_steps + 1),
      height: _side * 1.5,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          // Parked: the middle of the run, sitting flat. The left end of the
          // track is where a roll starts, not where a square belongs when it
          // is not rolling at all.
          if (!_controller.isAnimating) {
            return Align(alignment: Alignment.bottomCenter, child: child);
          }

          final progress = _controller.value * _steps;
          final step = progress.floor().clamp(0, _steps - 1);
          final turn = progress - step;

          return Align(
            alignment: Alignment.bottomLeft,
            child: Transform.translate(
              offset: Offset(step * _side, 0),
              child: Transform.rotate(
                // Pivot on the bottom-right corner: a quarter turn about it
                // lands the square exactly one side further along.
                alignment: Alignment.bottomRight,
                angle: turn * (pi / 2),
                child: child,
              ),
            ),
          );
        },
        child: Container(
          width: _side,
          height: _side,
          decoration: BoxDecoration(
            color: colors.primary,
            borderRadius: const BorderRadius.all(Radius.circular(3)),
          ),
        ),
      ),
    );
  }
}

/// Discovery could not be started at all - a different thing from finding no
/// devices, and one the user can do something about.
class _DiscoveryFailed extends StatelessWidget {
  const _DiscoveryFailed({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_off,
                size: 32, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 20),
            Text(l10n.networkSearchFailed, style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              l10n.networkSearchFailedHint,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            FilledButton.tonal(onPressed: onRetry, child: Text(l10n.tryAgain)),
          ],
        ),
      ),
    );
  }
}
