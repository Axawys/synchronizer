import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:sync_net/sync_net.dart';

import '../l10n/gen/app_localizations.dart';

import 'app_settings.dart';
import 'app_shell.dart';
import 'storage.dart';
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
    this.autoStart = true,
  });

  final DeviceInfo self;
  final Future<void> Function()? prepareNetwork;

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
            self: widget.self,
            settings: _settings,
            prepareNetwork: widget.prepareNetwork,
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
    this.prepareNetwork,
    this.autoStart = true,
  });

  final DeviceInfo self;
  final TrustStore trust;
  final SharedFolders folders;
  final Future<void> Function()? prepareNetwork;
  final bool autoStart;

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  late final DiscoveryService _discovery;
  late final PeerServer _pairingServer;
  AppLifecycleListener? _lifecycle;

  List<DeviceInfo> _devices = const [];
  Set<String> _trustedIds = {};
  bool _busy = false; // a pairing dialog is on screen

  @override
  void initState() {
    super.initState();
    _discovery = DiscoveryService(widget.self);
    _pairingServer = PeerServer(
      widget.self,
      widget.trust,
      port: widget.self.port,
      directories: widget.folders,
    );
    if (widget.autoStart) {
      // Closing the app should take this device off other people's lists right
      // away, rather than leaving it there until the staleness timeout.
      _lifecycle = AppLifecycleListener(onDetach: _shutdownNetworking);
      _init();
    }
  }

  bool _networkingStopped = false;

  void _shutdownNetworking() {
    if (_networkingStopped) return;
    _networkingStopped = true;
    _discovery.stop(); // announces our goodbye
    _pairingServer.stop();
  }

  Future<void> _init() async {
    await _refreshTrusted();
    await widget.prepareNetwork?.call();
    _discovery.peers.listen((devices) {
      if (mounted) setState(() => _devices = devices);
    });
    await _discovery.start();
    _pairingServer.pairingRequests.listen(_onIncomingRequest);
    await _pairingServer.start();
  }

  Future<void> _refreshTrusted() async {
    final trusted = await widget.trust.all();
    if (mounted) setState(() => _trustedIds = trusted.map((p) => p.id).toSet());
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _shutdownNetworking();
    super.dispose();
  }

  // Another device is asking to pair with us.
  Future<void> _onIncomingRequest(IncomingPairing request) async {
    if (!mounted) return;
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _ConfirmPairingDialog(request: request),
    );
    if (accepted == true) {
      await request.accept();
      await _refreshTrusted();
    } else {
      await request.reject();
    }
  }

  // Tapping a device: open the sync screen if already paired, otherwise pair.
  Future<void> _openDevice(DeviceInfo device) async {
    if (device.address == null) return;
    final trusted = await widget.trust.get(device.id);
    if (trusted == null) {
      await _startPairing(device);
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SyncPage(
        self: widget.self,
        trusted: trusted,
        device: device,
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
    final future = PairingClient(widget.self, widget.trust).pair(
      address,
      device.port,
      onCode: (_, code) => codeNotifier.value = code,
    );

    if (mounted) {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => _OutgoingPairingDialog(
          device: device,
          code: codeNotifier,
          result: future,
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
            icon: const Icon(Icons.history),
            tooltip: l10n.syncHistoryTooltip,
            onPressed: _openHistory,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8, left: 16, right: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                l10n.thisDevice(widget.self.name),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        ),
      ),
      body: _devices.isEmpty
          ? const _Searching()
          : ListView.separated(
              itemCount: _devices.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final device = _devices[i];
                final paired = _trustedIds.contains(device.id);
                return ListTile(
                  leading: Icon(_iconFor(device.platform)),
                  title: Text(device.name),
                  subtitle: Text(
                      '${device.address ?? l10n.unknownAddress}:${device.port}'),
                  trailing: paired
                      ? Icon(Icons.link,
                          color: Theme.of(context).colorScheme.primary)
                      : const Icon(Icons.chevron_right),
                  onTap: () => _openDevice(device),
                );
              },
            ),
    );
  }
}

IconData _iconFor(DevicePlatform platform) => switch (platform) {
      DevicePlatform.android => Icons.smartphone,
      DevicePlatform.linux => Icons.computer,
      DevicePlatform.unknown => Icons.devices_other,
    };


class _Searching extends StatelessWidget {
  const _Searching();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 3)),
          const SizedBox(height: 16),
          Text(AppLocalizations.of(context).lookingForDevices),
          const SizedBox(height: 4),
          Text(AppLocalizations.of(context).openOnOtherDevice),
        ],
      ),
    );
  }
}

/// Shown on the device that receives a pairing request. The user compares the
/// code with the other screen before accepting.
class _ConfirmPairingDialog extends StatelessWidget {
  const _ConfirmPairingDialog({required this.request});

  final IncomingPairing request;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.pairRequest(request.peer.name)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.checkCodeMatches),
          const SizedBox(height: 16),
          Center(child: _CodeText(request.code)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.reject),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(l10n.accept),
        ),
      ],
    );
  }
}

/// Shown on the device that initiates pairing. It first waits for the code,
/// displays it while the other side decides, then reports the outcome.
class _OutgoingPairingDialog extends StatelessWidget {
  const _OutgoingPairingDialog({
    required this.device,
    required this.code,
    required this.result,
  });

  final DeviceInfo device;
  final ValueListenable<String?> code;
  final Future<PairingResult> result;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return FutureBuilder<PairingResult>(
      future: result,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return AlertDialog(
            title: Text(l10n.pairingWith(device.name)),
            content: ValueListenableBuilder<String?>(
              valueListenable: code,
              builder: (context, value, _) {
                if (value == null) {
                  return _Waiting(l10n.contactingDevice);
                }
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(l10n.confirmCodeOnOther),
                    const SizedBox(height: 16),
                    _CodeText(value),
                    const SizedBox(height: 16),
                    _Waiting(l10n.waitingForConfirmation),
                  ],
                );
              },
            ),
          );
        }

        final outcome = snapshot.data ??
            PairingResult(PairingStatus.failed, error: l10n.noResult);
        final message = switch (outcome.status) {
          PairingStatus.paired => l10n.pairedWith(device.name),
          PairingStatus.rejected => l10n.pairingDeclined(device.name),
          PairingStatus.failed => l10n.couldNotPair('${outcome.error}'),
        };
        return AlertDialog(
          title: Text(l10n.pairingTitle),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.ok),
            ),
          ],
        );
      },
    );
  }
}

class _CodeText extends StatelessWidget {
  const _CodeText(this.code);
  final String code;

  @override
  Widget build(BuildContext context) {
    return Text(
      code,
      style: const TextStyle(
        fontSize: 34,
        fontWeight: FontWeight.bold,
        letterSpacing: 8,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    );
  }
}

class _Waiting extends StatelessWidget {
  const _Waiting(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
            width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: 12),
        Flexible(child: Text(label)),
      ],
    );
  }
}
