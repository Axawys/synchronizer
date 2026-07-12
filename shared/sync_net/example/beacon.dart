// Dev tool: run a discovery beacon from the command line to sanity-check
// local-network discovery without the Flutter apps.
//
//   dart run example/beacon.dart <id> <name>
//
// It announces itself and prints peers as they appear or disappear.
import 'dart:io';

import 'package:sync_net/sync_net.dart';

Future<void> main(List<String> args) async {
  final id = args.isNotEmpty ? args[0] : DeviceInfo.generateId();
  final name = args.length > 1 ? args[1] : 'beacon-$id';

  final self = DeviceInfo(
    id: id,
    name: name,
    platform: DevicePlatform.unknown,
    port: 47800,
  );

  final discovery = DiscoveryService(self);
  discovery.peers.listen((peers) {
    stdout.writeln('[$name] peers: '
        '${peers.map((p) => '${p.name}@${p.address}').join(', ')}');
  });

  await discovery.start();
  stdout.writeln('[$name] announcing as $id');

  ProcessSignal.sigint.watch().listen((_) async {
    await discovery.stop();
    exit(0);
  });
}
