import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:sync_net/sync_net.dart';

import 'prefs_trust_store.dart';

/// Root widget for both apps. The only per-platform difference is
/// [prepareNetwork]: Android passes a hook that grabs the multicast lock before
/// discovery starts; the desktop passes nothing.
class SynchronizerApp extends StatelessWidget {
  const SynchronizerApp({
    super.key,
    required this.self,
    this.prepareNetwork,
    this.autoStart = true,
  });

  final DeviceInfo self;
  final Future<void> Function()? prepareNetwork;

  /// Whether to start discovery and the pairing server on launch. Off in widget
  /// tests so no real sockets or timers are created.
  final bool autoStart;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Synchronizer',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: DevicesPage(
        self: self,
        prepareNetwork: prepareNetwork,
        autoStart: autoStart,
      ),
    );
  }
}

/// Lists devices found on the network and drives pairing in both directions:
/// tapping a device starts an outgoing request, and an inbound request pops a
/// confirmation dialog on this device.
class DevicesPage extends StatefulWidget {
  const DevicesPage({
    super.key,
    required this.self,
    this.prepareNetwork,
    this.autoStart = true,
  });

  final DeviceInfo self;
  final Future<void> Function()? prepareNetwork;
  final bool autoStart;

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  final TrustStore _trust = PrefsTrustStore();
  late final DiscoveryService _discovery;
  late final PeerServer _pairingServer;

  List<DeviceInfo> _devices = const [];
  Set<String> _trustedIds = {};
  bool _busy = false; // a pairing dialog is on screen

  @override
  void initState() {
    super.initState();
    _discovery = DiscoveryService(widget.self);
    _pairingServer = PeerServer(widget.self, _trust, port: widget.self.port);
    if (widget.autoStart) _init();
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
    final trusted = await _trust.all();
    if (mounted) setState(() => _trustedIds = trusted.map((p) => p.id).toSet());
  }

  @override
  void dispose() {
    _discovery.stop();
    _pairingServer.stop();
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

  // We are asking another device to pair.
  Future<void> _startPairing(DeviceInfo device) async {
    final address = device.address;
    if (address == null || _busy) return;
    setState(() => _busy = true);

    final codeNotifier = ValueNotifier<String?>(null);
    final future = PairingClient(widget.self, _trust).pair(
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Devices on this network'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8, left: 16, right: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'This device: ${widget.self.name}',
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
                  subtitle: Text('${device.address ?? 'unknown'}:${device.port}'),
                  trailing: paired
                      ? const Icon(Icons.link, color: Colors.teal)
                      : const Icon(Icons.chevron_right),
                  onTap: () => _startPairing(device),
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
        children: const [
          SizedBox(
              width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3)),
          SizedBox(height: 16),
          Text('Looking for devices...'),
          SizedBox(height: 4),
          Text('Open Synchronizer on your other device, on the same Wi-Fi.'),
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
    return AlertDialog(
      title: Text('Pair with ${request.peer.name}?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Check this code matches the one on the other device:'),
          const SizedBox(height: 16),
          Center(child: _CodeText(request.code)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Reject'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Accept'),
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
    return FutureBuilder<PairingResult>(
      future: result,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return AlertDialog(
            title: Text('Pairing with ${device.name}'),
            content: ValueListenableBuilder<String?>(
              valueListenable: code,
              builder: (context, value, _) {
                if (value == null) {
                  return const _Waiting('Contacting device...');
                }
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Confirm this code on the other device:'),
                    const SizedBox(height: 16),
                    _CodeText(value),
                    const SizedBox(height: 16),
                    const _Waiting('Waiting for confirmation...'),
                  ],
                );
              },
            ),
          );
        }

        final outcome = snapshot.data ??
            const PairingResult(PairingStatus.failed, error: 'no result');
        final message = switch (outcome.status) {
          PairingStatus.paired => 'Paired with ${device.name}.',
          PairingStatus.rejected => '${device.name} declined the request.',
          PairingStatus.failed => 'Could not pair: ${outcome.error}',
        };
        return AlertDialog(
          title: const Text('Pairing'),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
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
