import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sync_net/sync_net.dart';
import 'package:sync_ui/sync_ui.dart';

void main() {
  setUp(() {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues({});
  });

  test('a folder remembers where it syncs to, per peer', () async {
    await SyncTargets.setLocalPath('desktop', 'notes', '/home/me/notes');
    await SyncTargets.setLocalPath('laptop', 'notes', '/home/me/elsewhere');

    expect(await SyncTargets.localPath('desktop', 'notes'), '/home/me/notes');
    expect(await SyncTargets.localPath('laptop', 'notes'), '/home/me/elsewhere');
    expect(await SyncTargets.localPath('desktop', 'photos'), isNull);
  });

  test('the path can be changed afterwards', () async {
    await SyncTargets.setLocalPath('desktop', 'notes', '/old/place');
    await SyncTargets.setLocalPath('desktop', 'notes', '/new/place');

    expect(await SyncTargets.localPath('desktop', 'notes'), '/new/place');
  });

  test('clearing the base makes the next sync a first sync', () async {
    // What has to happen when a folder moves: the old ancestor describes the
    // old place, and against a different folder it reads as every file having
    // been deleted.
    final manifest = Manifest({
      'note.md': FileEntry(
          path: 'note.md', size: 1, modified: DateTime.utc(2026), hash: 'h'),
    });
    await BaseManifests.save('desktop', 'notes', manifest);
    expect((await BaseManifests.load('desktop', 'notes')).entries, isNotEmpty);

    await BaseManifests.clear('desktop', 'notes');

    expect((await BaseManifests.load('desktop', 'notes')).entries, isEmpty);
  });

  test('pointing a pair at a new folder drops the ancestor of the old one',
      () async {
    // Levelling several devices uses one folder for all of them. For a pair
    // that had been syncing this name somewhere else that is a move, and an
    // ancestor describing the old place reads as "everything was deleted".
    await SyncTargets.setLocalPath('desktop', 'notes', '/old/place');
    final manifest = Manifest({
      'note.md': FileEntry(
          path: 'note.md', size: 1, modified: DateTime.utc(2026), hash: 'h'),
    });
    await BaseManifests.save('desktop', 'notes', manifest);

    final dropped = await alignSyncTarget('desktop', 'notes', '/new/place');

    expect(dropped, isTrue);
    expect(await SyncTargets.localPath('desktop', 'notes'), '/new/place');
    expect((await BaseManifests.load('desktop', 'notes')).entries, isEmpty);
  });

  test('a pair already pointed at that folder is left alone', () async {
    await SyncTargets.setLocalPath('desktop', 'notes', '/place');
    final manifest = Manifest({
      'note.md': FileEntry(
          path: 'note.md', size: 1, modified: DateTime.utc(2026), hash: 'h'),
    });
    await BaseManifests.save('desktop', 'notes', manifest);

    expect(await alignSyncTarget('desktop', 'notes', '/place'), isFalse);
    expect((await BaseManifests.load('desktop', 'notes')).entries, isNotEmpty,
        reason: 'nothing moved, so the ancestor is still about this folder');
  });

  test('a pair that never synced anywhere has no ancestor to drop', () async {
    expect(await alignSyncTarget('phone', 'notes', '/place'), isFalse);
    expect(await SyncTargets.localPath('phone', 'notes'), '/place');
  });

  test('a folder already shared here is where a peer\'s copy of it lands',
      () async {
    // The complaint: a folder chosen on the desktop and a folder chosen on the
    // tablet, and the first sync between them still asked for a folder - the
    // one already on the screen behind the dialog.
    final folders = SharedFolders();
    await folders.chooseAs('Obsidian', '/home/me/Documents/Obsidian');

    expect(await resolveSyncTarget('tablet', 'Obsidian', folders),
        '/home/me/Documents/Obsidian');
    // And recorded, so the answer does not have to be worked out twice.
    expect(await SyncTargets.localPath('tablet', 'Obsidian'),
        '/home/me/Documents/Obsidian');
  });

  test('the shared folder wins over where the pair synced last time', () async {
    // What this device shares under a name is what it hands to any peer asking
    // for that name. A pair syncing the same name somewhere else means this
    // device answers about one folder and writes into another depending on
    // which end started - and a folder changed in settings would go on syncing
    // to the old place.
    await SyncTargets.setLocalPath('tablet', 'Obsidian', '/old/vault');
    final manifest = Manifest({
      'note.md': FileEntry(
          path: 'note.md', size: 1, modified: DateTime.utc(2026), hash: 'h'),
    });
    await BaseManifests.save('tablet', 'Obsidian', manifest);

    final folders = SharedFolders();
    await folders.chooseAs('Obsidian', '/home/me/Documents/Obsidian');

    expect(await resolveSyncTarget('tablet', 'Obsidian', folders),
        '/home/me/Documents/Obsidian');
    // It is a move, so what the two of them last agreed on is about a folder
    // that is no longer the one being synced.
    expect((await BaseManifests.load('tablet', 'Obsidian')).entries, isEmpty);
  });

  test('a folder only the peer has falls back to where the pair put it',
      () async {
    await SyncTargets.setLocalPath('tablet', 'Photos', '/home/me/Pictures');

    expect(await resolveSyncTarget('tablet', 'Photos', SharedFolders()),
        '/home/me/Pictures');
  });

  test('a folder this device knows nothing about is still worth asking about',
      () async {
    final folders = SharedFolders();
    await folders.chooseAs('Obsidian', '/home/me/Documents/Obsidian');

    // Null is the one case a chooser should open for: guessing that "Photos"
    // means the vault would sync the wrong folder without being asked.
    expect(await resolveSyncTarget('tablet', 'Photos', folders), isNull);
  });

  test('clearing one folder leaves the others alone', () async {
    final manifest = Manifest({
      'a.md': FileEntry(
          path: 'a.md', size: 1, modified: DateTime.utc(2026), hash: 'h'),
    });
    await BaseManifests.save('desktop', 'notes', manifest);
    await BaseManifests.save('desktop', 'photos', manifest);

    await BaseManifests.clear('desktop', 'notes');

    expect((await BaseManifests.load('desktop', 'photos')).entries, isNotEmpty);
  });
}
