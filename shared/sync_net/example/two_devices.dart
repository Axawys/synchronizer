// Dev tool: two devices talking to each other end to end - discovery, pairing,
// a first sync, a merge of edits made on both sides, and one of them leaving
// and coming back. It runs the same DiscoveryService, PeerServer, handshake and
// sync engine the apps do, over this machine's real network interfaces, so it
// covers what unit tests over loopback cannot: several interfaces, broadcast,
// and a real routing table.
//
// It stands in for a pair of phones. It is not a substitute for them - nothing
// here exercises Android's multicast lock or its habit of freezing background
// apps - but everything above the socket is the code the phones run.
//
//   dart run example/two_devices.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sync_net/sync_net.dart';

var failures = 0;

void check(String what, bool ok, [String detail = '']) {
  stdout.writeln('${ok ? '  ok  ' : ' FAIL '} $what${detail.isEmpty ? '' : '  ($detail)'}');
  if (!ok) failures++;
}

Future<T> within<T>(String what, Future<T> future,
    {Duration limit = const Duration(seconds: 15)}) {
  return future.timeout(limit, onTimeout: () {
    stdout.writeln(' FAIL $what: timed out after $limit');
    failures++;
    exit(1);
  });
}

Future<void> main() async {
  final aRoot = Directory.systemTemp.createTempSync('phoneA');
  final bRoot = Directory.systemTemp.createTempSync('phoneB');

  // Two phones would both use 47800; sharing one host they cannot, and the
  // port each listens on is what it announces, so peers still dial correctly.
  // These stay clear of 47800 so a running app is not disturbed.
  const portA = 47820;
  const portB = 47821;

  const phoneA = DeviceInfo(
      id: 'phone-a', name: 'Pixel 7', platform: DevicePlatform.android, port: portA);
  const phoneB = DeviceInfo(
      id: 'phone-b', name: 'Galaxy S23', platform: DevicePlatform.android, port: portB);

  final trustA = MemoryTrustStore();
  final trustB = MemoryTrustStore();

  // ---------------------------------------------------------------- servers
  final serverA = PeerServer(phoneA, trustA,
      port: portA, directories: MapDirectorySource({'notes': aRoot.path}));
  final serverB = PeerServer(phoneB, trustB,
      port: portB, directories: MapDirectorySource({}));
  await serverA.start();
  await serverB.start();

  // B accepts whatever pairing arrives, after checking the code matches what
  // the other screen shows - which is what the user does by eye.
  String? codeSeenByB;
  serverB.pairingRequests.listen((request) async {
    codeSeenByB = request.code;
    await request.accept();
  });

  // -------------------------------------------------------------- discovery
  stdout.writeln('\n== discovery ==');
  final discoveryA = DiscoveryService(phoneA);
  final discoveryB = DiscoveryService(phoneB);

  final aSeesB = discoveryA.peers.firstWhere((l) => l.any((d) => d.id == 'phone-b'));
  final bSeesA = discoveryB.peers.firstWhere((l) => l.any((d) => d.id == 'phone-a'));

  final started = DateTime.now();
  await discoveryA.start();
  await discoveryB.start();

  final seenB = (await within('A sees B', aSeesB)).firstWhere((d) => d.id == 'phone-b');
  final seenA = (await within('B sees A', bSeesA)).firstWhere((d) => d.id == 'phone-a');
  final took = DateTime.now().difference(started);

  check('the two phones find each other', true, 'in ${took.inMilliseconds} ms');
  check('B is named and addressed correctly',
      seenB.name == 'Galaxy S23' && seenB.port == portB && seenB.address != null,
      '${seenB.name} at ${seenB.address}:${seenB.port}');
  check('A is named and addressed correctly',
      seenA.name == 'Pixel 7' && seenA.port == portA && seenA.address != null,
      '${seenA.name} at ${seenA.address}:${seenA.port}');
  check('the address is a real interface, not loopback',
      seenB.address != '127.0.0.1', seenB.address ?? 'none');
  stdout.writeln('  A also sees: '
      '${discoveryA.current.map((d) => '${d.name}@${d.address}:${d.port}').join(', ')}');
  check('neither phone lists itself',
      !discoveryA.current.any((d) => d.id == 'phone-a') &&
          !discoveryB.current.any((d) => d.id == 'phone-b'));

  // ---------------------------------------------------------------- pairing
  stdout.writeln('\n== pairing ==');
  String? codeSeenByA;
  final result = await within(
    'pairing completes',
    PairingClient(phoneA, trustA).pair(
      seenB.address!,
      seenB.port,
      onCode: (_, code) => codeSeenByA = code,
    ),
  );

  check('pairing succeeded', result.isPaired, result.error ?? 'paired');
  check('both screens showed the same six digits',
      codeSeenByA != null && codeSeenByA == codeSeenByB, '$codeSeenByA / $codeSeenByB');
  check('A now trusts B', (await trustA.get('phone-b')) != null);
  check('B now trusts A', (await trustB.get('phone-a')) != null);

  final aKnowsB = (await trustA.get('phone-b'))!;
  final bKnowsA = (await trustB.get('phone-a'))!;
  check('the two derived the same secret independently',
      aKnowsB.secret == bKnowsA.secret);

  // ------------------------------------------------------------- first sync
  stdout.writeln('\n== first sync (A shares "notes", B pulls) ==');
  File('${aRoot.path}/note.md').writeAsStringSync('one\ntwo\nthree\n');
  File('${aRoot.path}/other.md').writeAsStringSync('kept\n');

  var client = await within('B connects a session to A',
      SyncClient.connect(seenA.address!, portA, self: phoneB, trusted: bKnowsA));
  final dirs = await client.listDirectories();
  check('B sees the folder A shares', dirs.map((d) => d.name).contains('notes'),
      dirs.map((d) => d.name).join(', '));

  var base = Manifest(<String, FileEntry>{});
  var merge = await computeMerge(client, 'notes', bRoot, base);
  var outcome = await runSync(client, 'notes', bRoot, base,
      [for (final item in merge.items) ResolvedMerge.natural(item)]);
  await client.close();

  check('first sync applied cleanly', outcome.report.ok,
      '${outcome.report.applied} files, ${outcome.report.failures.length} failed');
  check('the files arrived on B',
      File('${bRoot.path}/note.md').existsSync() &&
          File('${bRoot.path}/other.md').readAsStringSync() == 'kept\n');
  base = outcome.newBase!;

  // --------------------------------------------------- edits on both phones
  stdout.writeln('\n== both phones edit the same file in different places ==');
  File('${aRoot.path}/note.md').writeAsStringSync('one\ntwo\nthree\nfrom A\n');
  File('${bRoot.path}/note.md').writeAsStringSync('ONE\ntwo\nthree\n');

  client = await SyncClient.connect(seenA.address!, portA,
      self: phoneB, trusted: bKnowsA);
  merge = await computeMerge(client, 'notes', bRoot, base);
  final resolved = <ResolvedMerge>[];
  for (final item in merge.items) {
    if (item.kind != MergeKind.conflict) {
      resolved.add(ResolvedMerge.natural(item));
      continue;
    }
    final merged = await mergeConflict(client, 'notes', bRoot, item);
    resolved.add(merged.isClean
        ? ResolvedMerge.merged(item, merged.merge!.clean!)
        : ResolvedMerge(item, toLocal: conflictResolvesToLocal(item)));
  }
  outcome = await runSync(client, 'notes', bRoot, base, resolved);
  await client.close();

  final onB = File('${bRoot.path}/note.md').readAsStringSync();
  final onA = File('${aRoot.path}/note.md').readAsStringSync();
  check('the merge applied', outcome.report.ok);
  check('both edits survived on B', onB.contains('ONE') && onB.contains('from A'),
      onB.replaceAll('\n', ' | '));
  check('both edits survived on A', onA.contains('ONE') && onA.contains('from A'),
      onA.replaceAll('\n', ' | '));
  check('the phones now hold the same text', onA == onB);

  // ------------------------------------------------------- leaving, coming back
  stdout.writeln('\n== one phone leaves the network, then comes back ==');
  final bGone = discoveryA.peers.firstWhere((l) => l.every((d) => d.id != 'phone-b'));
  final leftAt = DateTime.now();
  await discoveryB.stop();
  await within('B disappears from A\'s list', bGone,
      limit: const Duration(seconds: 10));
  check('a phone that closes the app leaves the list at once', true,
      'in ${DateTime.now().difference(leftAt).inMilliseconds} ms');

  final bBack = discoveryA.peers.firstWhere((l) => l.any((d) => d.id == 'phone-b'));
  final backAt = DateTime.now();
  await discoveryB.start();
  await within('B reappears', bBack, limit: const Duration(seconds: 10));
  check('a phone that comes back is found again', true,
      'in ${DateTime.now().difference(backAt).inMilliseconds} ms');

  // A phone killed outright - battery out, app force-stopped, carried out of
  // range - cannot say goodbye. It just stops, and has to be timed out. Stood
  // in for by a bare socket that announces once and goes quiet.
  final ghost = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  ghost.send(
    utf8.encode(jsonEncode({
      'magic': 'synchronizer/1',
      'type': 'announce',
      'device': const DeviceInfo(
        id: 'phone-c',
        name: 'Redmi Note 12',
        platform: DevicePlatform.android,
        port: 47822,
      ).toAnnouncement(),
    })),
    InternetAddress(const DiscoveryConfig().multicastAddress),
    const DiscoveryConfig().port,
  );
  await within('a third phone appears',
      discoveryA.peers.firstWhere((l) => l.any((d) => d.id == 'phone-c')));
  ghost.close();

  final silentAt = DateTime.now();
  await within('the silent phone is pruned',
      discoveryA.peers.firstWhere((l) => l.every((d) => d.id != 'phone-c')),
      limit: const Duration(seconds: 20));
  check('a phone that vanishes without warning is pruned', true,
      'after ${DateTime.now().difference(silentAt).inSeconds} s of silence');

  await discoveryA.dispose();
  await discoveryB.dispose();
  await serverA.stop();
  await serverB.stop();
  aRoot.deleteSync(recursive: true);
  bRoot.deleteSync(recursive: true);

  stdout.writeln(failures == 0
      ? '\nall checks passed'
      : '\n$failures check(s) failed');
  exit(failures == 0 ? 0 : 1);
}
