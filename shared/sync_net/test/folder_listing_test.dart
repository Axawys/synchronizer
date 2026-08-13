import 'dart:io';

import 'package:sync_net/sync_net.dart';
import 'package:test/test.dart';

/// What a device says about the folders it offers. The counts are not
/// decoration: they are what makes "nothing to do" checkable by the person
/// looking at it.
void main() {
  const server = DeviceInfo(
      id: 'server', name: 'Desktop', platform: DevicePlatform.linux, port: 0);
  const client = DeviceInfo(
      id: 'client', name: 'Phone', platform: DevicePlatform.android, port: 0);
  const secret = 'shared';

  late Directory vault;
  late PeerServer peer;
  late SyncClient session;

  Future<SyncClient> connect(Map<String, String> shared) async {
    final trust = MemoryTrustStore();
    await trust.add(const TrustedPeer(
        id: 'client',
        name: 'Phone',
        platform: DevicePlatform.android,
        secret: secret));
    peer = PeerServer(server, trust,
        port: 0, directories: MapDirectorySource(shared));
    await peer.start();

    return SyncClient.connect(
      '127.0.0.1',
      peer.boundPort,
      self: client,
      trusted: const TrustedPeer(
          id: 'server',
          name: 'Desktop',
          platform: DevicePlatform.linux,
          secret: secret),
    );
  }

  setUp(() {
    vault = Directory.systemTemp.createTempSync('vault');
  });

  tearDown(() async {
    await session.close();
    await peer.stop();
    if (vault.existsSync()) vault.deleteSync(recursive: true);
  });

  test('a folder says how many files it holds and what they weigh', () async {
    File('${vault.path}/note.md').writeAsStringSync('one');
    Directory('${vault.path}/deep').createSync();
    File('${vault.path}/deep/other.md').writeAsStringSync('two');
    // The same rules as a scan: what never travels is not counted either.
    Directory('${vault.path}/.obsidian').createSync();
    File('${vault.path}/.obsidian/config').writeAsStringSync('{}');

    session = await connect({'notes': vault.path});
    final dirs = await session.listDirectories();

    expect(dirs.single.name, 'notes');
    expect(dirs.single.files, 2);
    // Weight is the number worth showing, so it has to actually come across.
    expect(dirs.single.bytes, 6);
    expect(dirs.single.missing, isFalse);
  });

  test('a folder says where it is, so the wrong folder can be seen to be wrong',
      () async {
    // Two devices reporting "in sync" while one of them is empty is the one
    // failure that looks like success, and the path is what settles it: a
    // person reading the two cards can see that one of them is pointed
    // somewhere they did not mean.
    session = await connect({'notes': vault.path});
    final dirs = await session.listDirectories();

    expect(dirs.single.path, vault.path);
  });

  test('an empty folder says zero, which is a different thing from silence',
      () async {
    session = await connect({'notes': vault.path});
    final dirs = await session.listDirectories();

    expect(dirs.single.files, 0);
    expect(dirs.single.bytes, 0);
    expect(dirs.single.missing, isFalse);
  });

  test('a folder that is shared but gone says so', () async {
    final path = vault.path;
    vault.deleteSync(recursive: true);

    session = await connect({'notes': path});
    final dirs = await session.listDirectories();

    expect(dirs.single.missing, isTrue);
    expect(dirs.single.files, isNull, reason: 'gone is not empty');
    expect(dirs.single.bytes, isNull);
  });

  test('an empty folder here and a full one there is a pull, not "in sync"',
      () async {
    // The case that was reported. Through the real client and server, because
    // the report was about the whole thing and not about the merge in
    // isolation: what matters is that the manifest crossing the wire carries
    // the files, and that the count on the folder listing agrees with it.
    File('${vault.path}/note.md').writeAsStringSync('one\ntwo\n');
    Directory('${vault.path}/sub').createSync();
    File('${vault.path}/sub/deep.md').writeAsStringSync('three\n');

    final here = Directory.systemTemp.createTempSync('empty_side');
    addTearDown(() => here.deleteSync(recursive: true));

    session = await connect({'notes': vault.path});

    final dirs = await session.listDirectories();
    expect(dirs.single.files, 2, reason: 'the listing already says there are');

    final empty = Manifest(<String, FileEntry>{});
    final merge = await computeMerge(session, 'notes', here, empty);

    expect(merge.isEmpty, isFalse);
    expect(merge.pulls.map((i) => i.path).toList(), ['note.md', 'sub/deep.md']);
  });

  test('a folder the device already has needs no asking', () async {
    session = await connect({'notes': vault.path});
    expect(await session.prepareDirectory('notes'), isTrue);
  });

  test('a folder it does not have puts the question to its own user', () async {
    session = await connect({'notes': vault.path});
    final asked = <FolderRequest>[];
    peer.folderRequests.listen(asked.add);

    // The answer comes back at once - somebody has to choose a folder over
    // there, and a connection held open across that would time out.
    expect(await session.prepareDirectory('photos'), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(asked.single.folder, 'photos');
    expect(asked.single.peerId, 'client');
  });

  test('and refuses to hand over a manifest for it', () async {
    // Otherwise the other device reads "no files" as "everything was deleted"
    // and a sync in that state empties a vault.
    final path = vault.path;
    vault.deleteSync(recursive: true);

    session = await connect({'notes': path});

    expect(
      () => session.fetchManifest('notes'),
      throwsA(isA<SessionException>()),
    );
  });
}
