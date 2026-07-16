import 'dart:io';

import 'package:sync_net/sync_net.dart';
import 'package:test/test.dart';

void main() {
  const desktop = DeviceInfo(
    id: 'desktop-id',
    name: 'Desktop',
    platform: DevicePlatform.linux,
    port: 47800,
  );
  const phone = DeviceInfo(
    id: 'phone-id',
    name: 'Phone',
    platform: DevicePlatform.android,
    port: 47800,
  );
  const secret = 'shared';
  final desktopKnowsPhone = TrustedPeer(
      id: 'phone-id', name: 'Phone', platform: DevicePlatform.android, secret: secret);
  final phoneKnowsDesktop = TrustedPeer(
      id: 'desktop-id', name: 'Desktop', platform: DevicePlatform.linux, secret: secret);

  late Directory remote;
  late Directory local;
  late PeerServer server;

  setUp(() async {
    remote = Directory.systemTemp.createTempSync('pv_remote');
    local = Directory.systemTemp.createTempSync('pv_local');
    final trust = MemoryTrustStore();
    await trust.add(desktopKnowsPhone);
    server = PeerServer(desktop, trust,
        port: 0, directories: MapDirectorySource({'notes': remote.path}));
    await server.start();
  });

  tearDown(() async {
    await server.stop();
    remote.deleteSync(recursive: true);
    local.deleteSync(recursive: true);
  });

  Future<SyncClient> connect() => SyncClient.connect('127.0.0.1', server.boundPort,
      self: phone, trusted: phoneKnowsDesktop);

  Future<SyncPreview> previewOf(Manifest base) async {
    final client = await connect();
    addTearDown(client.close);
    final merge = await computeMerge(client, 'notes', local, base);
    return buildPreview(client, 'notes', local, merge);
  }

  FilePreview forPath(SyncPreview preview, String path) =>
      preview.files.firstWhere((f) => f.path == path);

  test('a new remote file reads as a creation here, with its lines added',
      () async {
    File('${remote.path}/new.md').writeAsStringSync('one\ntwo\n');

    final preview = await previewOf(Manifest({}));
    final file = forPath(preview, 'new.md');

    expect(file.kind, PreviewKind.create);
    expect(file.side, PreviewSide.here);
    expect(file.added, 3); // two lines plus the trailing newline's empty line
    expect(file.removed, 0);
  });

  test('an edited file shows exactly which lines come and go', () async {
    File('${local.path}/note.md').writeAsStringSync('a\nb\nc');
    File('${remote.path}/note.md').writeAsStringSync('a\nB\nc');
    final base = await Manifest.scan(local);
    // Only the remote moved on from the base.
    File('${local.path}/note.md').writeAsStringSync('a\nb\nc');

    final preview = await previewOf(base);
    final file = forPath(preview, 'note.md');

    expect(file.kind, PreviewKind.update);
    expect(file.side, PreviewSide.here);
    expect(file.lines.where((l) => l.op == DiffOp.delete).map((l) => l.text),
        ['b']);
    expect(file.lines.where((l) => l.op == DiffOp.insert).map((l) => l.text),
        ['B']);
    expect(file.lines.where((l) => l.op == DiffOp.equal).map((l) => l.text),
        ['a', 'c']);
  });

  test('a local-only file reads as a creation on the other device', () async {
    File('${local.path}/mine.md').writeAsStringSync('hello\n');

    final preview = await previewOf(Manifest({}));
    final file = forPath(preview, 'mine.md');

    expect(file.kind, PreviewKind.create);
    expect(file.side, PreviewSide.there);
  });

  test('a deletion reads as a delete', () async {
    File('${local.path}/gone.md').writeAsStringSync('x');
    File('${remote.path}/gone.md').writeAsStringSync('x');
    final base = await Manifest.scan(local);
    File('${remote.path}/gone.md').deleteSync();

    final preview = await previewOf(base);
    final file = forPath(preview, 'gone.md');

    expect(file.kind, PreviewKind.delete);
    expect(file.side, PreviewSide.here);
  });

  test('non-overlapping edits show up as merged for both devices', () async {
    const start = '# Notes\n\n- milk\n';
    File('${local.path}/note.md').writeAsStringSync(start);
    File('${remote.path}/note.md').writeAsStringSync(start);
    final base = await Manifest.scan(local);
    await refreshBaseStore(local, Manifest({}), base);

    File('${local.path}/note.md').writeAsStringSync('# Notes\n\n- milk\n- bread\n');
    File('${remote.path}/note.md').writeAsStringSync('# Shopping\n\n- milk\n');

    final preview = await previewOf(base);
    final file = forPath(preview, 'note.md');

    expect(file.kind, PreviewKind.merged);
    expect(file.side, PreviewSide.both);
    // Against our copy, merging brings in their heading change.
    expect(file.lines.where((l) => l.op == DiffOp.insert).map((l) => l.text),
        contains('# Shopping'));
  });

  test('overlapping edits stay a conflict, carrying the hunks', () async {
    File('${local.path}/note.md').writeAsStringSync('title\n');
    File('${remote.path}/note.md').writeAsStringSync('title\n');
    final base = await Manifest.scan(local);
    await refreshBaseStore(local, Manifest({}), base);

    File('${local.path}/note.md').writeAsStringSync('mine\n');
    File('${remote.path}/note.md').writeAsStringSync('theirs\n');

    final preview = await previewOf(base);
    final file = forPath(preview, 'note.md');

    expect(file.kind, PreviewKind.conflict);
    expect(preview.hasConflicts, isTrue);
    expect(file.conflict!.merge!.conflicts.single.ours, ['mine']);
    // A conflict used to arrive with no lines at all, so the screen could only
    // name the file. The two versions are readable, so they are shown.
    expect(file.lines.where((l) => l.op == DiffOp.insert).map((l) => l.text),
        contains('mine'));
    expect(file.lines.where((l) => l.op == DiffOp.delete).map((l) => l.text),
        contains('theirs'));
  });

  test('a conflict with no ancestor still shows its lines, and says so',
      () async {
    // The first sync of a file both devices already had: nothing was ever
    // recorded to merge against.
    File('${local.path}/note.md').writeAsStringSync('title\nmine\n');
    File('${remote.path}/note.md').writeAsStringSync('title\ntheirs\n');

    final preview = await previewOf(Manifest({}));
    final file = forPath(preview, 'note.md');

    expect(file.kind, PreviewKind.conflict);
    expect(file.conflict!.ancestorKnown, isFalse);
    expect(file.lines, isNotEmpty, reason: 'the diff is still worth showing');
    // Only the line that actually differs needs deciding; "title" is agreed.
    expect(file.conflict!.merge!.conflicts.single.ours, ['mine']);
  });

  test('a binary conflict admits it has nothing to show', () async {
    File('${local.path}/pic.png').writeAsBytesSync([0x89, 0x00, 0x01]);
    File('${remote.path}/pic.png').writeAsBytesSync([0x89, 0x00, 0x02]);

    final file = forPath(await previewOf(Manifest({})), 'pic.png');

    expect(file.kind, PreviewKind.conflict);
    expect(file.conflict!.isMergeable, isFalse);
    expect(file.lines, isEmpty, reason: 'no lines invented for binary');
  });

  group('folders', () {
    test('a new file in a new folder announces the folder', () async {
      File('${remote.path}/vault/sub/deep.md')
        ..createSync(recursive: true)
        ..writeAsStringSync('x');

      final preview = await previewOf(Manifest({}));

      expect(preview.folders.map((f) => f.path), ['vault', 'vault/sub']);
      expect(preview.folders.every((f) => f.created), isTrue);
      expect(preview.folders.every((f) => f.side == PreviewSide.here), isTrue);
    });

    test('removing the last file in a folder removes the folder', () async {
      for (final root in [local, remote]) {
        File('${root.path}/vault/only.md')
          ..createSync(recursive: true)
          ..writeAsStringSync('x');
      }
      final base = await Manifest.scan(local);
      Directory('${remote.path}/vault').deleteSync(recursive: true);

      final preview = await previewOf(base);

      expect(preview.folders.single.path, 'vault');
      expect(preview.folders.single.created, isFalse);
    });

    test('a folder keeping another file is not reported as removed', () async {
      for (final root in [local, remote]) {
        Directory('${root.path}/vault').createSync();
        File('${root.path}/vault/gone.md').writeAsStringSync('x');
        File('${root.path}/vault/stays.md').writeAsStringSync('y');
      }
      final base = await Manifest.scan(local);
      File('${remote.path}/vault/gone.md').deleteSync();
      File('${remote.path}/vault/stays.md').writeAsStringSync('changed');

      final preview = await previewOf(base);

      expect(preview.folders, isEmpty);
    });
  });
}
