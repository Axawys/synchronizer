import 'dart:io';

import 'package:sync_net/sync_net.dart';
import 'package:test/test.dart';

/// Three devices brought to the same state, the way the levelling screen does
/// it: this device is the meeting point, and each of the others is synced
/// against it in turn, twice.
///
/// The screen that drives this is UI; the loop it drives is this, and it is
/// the part that either converges or quietly loses somebody's file.
void main() {
  const hub = DeviceInfo(
      id: 'hub', name: 'PC', platform: DevicePlatform.linux, port: 0);
  const secret = 'shared';

  late Directory onHub;
  final vaults = <String, Directory>{};
  final servers = <String, PeerServer>{};

  Future<SyncClient> dial(String id) => SyncClient.connect(
        '127.0.0.1',
        servers[id]!.boundPort,
        self: hub,
        trusted: TrustedPeer(
            id: id, name: id, platform: DevicePlatform.android, secret: secret),
      );

  Future<PeerServer> peer(String id) async {
    final vault = Directory.systemTemp.createTempSync('vault_$id');
    vaults[id] = vault;

    final trust = MemoryTrustStore();
    await trust.add(const TrustedPeer(
        id: 'hub', name: 'PC', platform: DevicePlatform.linux, secret: secret));
    final server = PeerServer(
      DeviceInfo(
          id: id, name: id, platform: DevicePlatform.android, port: 0),
      trust,
      port: 0,
      directories: MapDirectorySource({'vault': vault.path}),
    );
    await server.start();
    servers[id] = server;
    return server;
  }

  /// What each pair last agreed on, kept between runs exactly as the app keeps
  /// it: an ancestor thrown away turns every later sync into a first sync,
  /// which is a different thing entirely.
  final bases = <String, Manifest>{};

  /// The levelling loop itself: two passes over the peers, resolving conflicts
  /// line by line first and falling back to a side only where that fails.
  Future<void> level(List<String> peers) async {
    for (final id in peers) {
      bases[id] ??= Manifest(<String, FileEntry>{});
    }

    for (var pass = 0; pass < 2; pass++) {
      for (final id in peers) {
        final client = await dial(id);
        final merge = await computeMerge(client, 'vault', onHub, bases[id]!);
        final resolved = <ResolvedMerge>[];
        for (final item in merge.items) {
          if (item.kind != MergeKind.conflict) {
            resolved.add(ResolvedMerge.natural(item));
            continue;
          }
          final merged = await mergeConflict(client, 'vault', onHub, item);
          resolved.add(merged.isClean
              ? ResolvedMerge.merged(item, merged.merge!.clean!)
              : ResolvedMerge(item, toLocal: conflictResolvesToLocal(item)));
        }
        final outcome =
            await runSync(client, 'vault', onHub, bases[id]!, resolved);
        expect(outcome.report.ok, isTrue,
            reason: 'pass $pass with $id: ${outcome.report.failures}');
        if (outcome.newBase != null) bases[id] = outcome.newBase!;
        await client.close();
      }
    }
  }

  setUp(() {
    onHub = Directory.systemTemp.createTempSync('vault_hub');
    bases.clear();
  });

  tearDown(() async {
    for (final server in servers.values) {
      await server.stop();
    }
    for (final vault in vaults.values) {
      if (vault.existsSync()) vault.deleteSync(recursive: true);
    }
    servers.clear();
    vaults.clear();
    onHub.deleteSync(recursive: true);
  });

  Future<Map<String, String>> contents(Directory root) async {
    final manifest = await Manifest.scan(root);
    return {
      for (final path in manifest.entries.keys)
        path: File('${root.path}/$path').readAsStringSync(),
    };
  }

  test('a file from each device ends up on all of them', () async {
    await peer('phone');
    await peer('tablet');

    File('${onHub.path}/from-pc.md').writeAsStringSync('pc\n');
    File('${vaults['phone']!.path}/from-phone.md').writeAsStringSync('phone\n');
    File('${vaults['tablet']!.path}/from-tablet.md')
        .writeAsStringSync('tablet\n');

    await level(['phone', 'tablet']);

    final expected = {
      'from-pc.md': 'pc\n',
      'from-phone.md': 'phone\n',
      'from-tablet.md': 'tablet\n',
    };
    expect(await contents(onHub), expected);
    expect(await contents(vaults['phone']!), expected);
    expect(await contents(vaults['tablet']!), expected);
  });

  test('lines added on this device survive a round of levelling', () async {
    // The report that started this: edited on the PC, synced from the phone
    // and the tablet, and the new lines were gone.
    await peer('phone');
    await peer('tablet');

    File('${onHub.path}/note.md').writeAsStringSync('one\n');
    await level(['phone', 'tablet']);

    File('${onHub.path}/note.md').writeAsStringSync('one\ntwo\nthree\n');
    await level(['phone', 'tablet']);

    for (final root in [onHub, vaults['phone']!, vaults['tablet']!]) {
      expect(File('${root.path}/note.md').readAsStringSync(),
          'one\ntwo\nthree\n');
    }
  });

  test('edits on two devices in different places both survive', () async {
    await peer('phone');
    await peer('tablet');

    File('${onHub.path}/note.md').writeAsStringSync('one\ntwo\nthree\n');
    await level(['phone', 'tablet']);

    // The phone appends, the hub prepends: different places, so both stay.
    File('${vaults['phone']!.path}/note.md')
        .writeAsStringSync('one\ntwo\nthree\nphone\n');
    File('${onHub.path}/note.md').writeAsStringSync('hub\none\ntwo\nthree\n');

    await level(['phone', 'tablet']);

    final text = File('${onHub.path}/note.md').readAsStringSync();
    expect(text, contains('hub'));
    expect(text, contains('phone'));
    expect(File('${vaults['tablet']!.path}/note.md').readAsStringSync(), text,
        reason: 'the third device gets the same result, not a version of it');
    expect(File('${vaults['phone']!.path}/note.md').readAsStringSync(), text);
  });

  test('a deletion on one device reaches the others', () async {
    await peer('phone');
    await peer('tablet');

    File('${onHub.path}/note.md').writeAsStringSync('one\n');
    await level(['phone', 'tablet']);

    File('${vaults['phone']!.path}/note.md').deleteSync();
    await level(['phone', 'tablet']);

    expect(File('${onHub.path}/note.md').existsSync(), isFalse);
    expect(File('${vaults['tablet']!.path}/note.md').existsSync(), isFalse);
  });
}
