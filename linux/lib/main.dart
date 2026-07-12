import 'package:flutter/material.dart';
import 'package:sync_net/sync_net.dart';

import 'device_identity.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final self = await DeviceIdentity.load();
  runApp(SynchronizerApp(self: self));
}

class SynchronizerApp extends StatelessWidget {
  const SynchronizerApp({super.key, required this.self});

  final DeviceInfo self;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Synchronizer',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: DevicesPage(self: self),
    );
  }
}

/// Lists other Synchronizer devices found on the local network. Selecting one
/// will, in a later stage, start the pairing handshake.
class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key, required this.self});

  final DeviceInfo self;

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  late final DiscoveryService _discovery;
  List<DeviceInfo> _devices = const [];

  @override
  void initState() {
    super.initState();
    _discovery = DiscoveryService(widget.self);
    _discovery.peers.listen((devices) {
      if (mounted) setState(() => _devices = devices);
    });
    _discovery.start();
  }

  @override
  void dispose() {
    _discovery.stop();
    super.dispose();
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
      body: _devices.isEmpty ? const _Searching() : _DeviceList(devices: _devices),
    );
  }
}

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
          Text('Open Synchronizer on your phone, on the same Wi-Fi.'),
        ],
      ),
    );
  }
}

class _DeviceList extends StatelessWidget {
  const _DeviceList({required this.devices});

  final List<DeviceInfo> devices;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      itemCount: devices.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final device = devices[i];
        return ListTile(
          leading: Icon(_iconFor(device.platform)),
          title: Text(device.name),
          subtitle: Text('${device.address ?? 'unknown'}:${device.port}'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            // Pairing handshake is the next stage. For now just acknowledge.
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Pairing with ${device.name} is not built yet.')),
            );
          },
        );
      },
    );
  }

  IconData _iconFor(DevicePlatform platform) => switch (platform) {
        DevicePlatform.android => Icons.smartphone,
        DevicePlatform.linux => Icons.computer,
        DevicePlatform.unknown => Icons.devices_other,
      };
}
