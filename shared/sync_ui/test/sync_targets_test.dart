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
