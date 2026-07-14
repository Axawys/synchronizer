import 'package:sync_core/sync_core.dart';
import 'package:test/test.dart';

void main() {
  FileEntry e(String path, String hash) =>
      FileEntry(path: path, size: 1, modified: DateTime.utc(2026), hash: hash);

  Manifest m(Map<String, String> pathToHash) => Manifest({
        for (final entry in pathToHash.entries)
          entry.key: e(entry.key, entry.value),
      });

  MergeKind? kindOf(MergeResult r, String path) {
    for (final item in r.items) {
      if (item.path == path) return item.kind;
    }
    return null;
  }

  test('identical sides produce nothing, even without a base', () {
    final result = threeWayMerge(m({}), m({'a': '1'}), m({'a': '1'}));
    expect(result.isEmpty, isTrue);
  });

  test('changed on remote only pulls to local', () {
    final base = m({'a': '1'});
    final local = m({'a': '1'});
    final remote = m({'a': '2'});
    expect(kindOf(threeWayMerge(base, local, remote), 'a'),
        MergeKind.pullToLocal);
  });

  test('changed on local only pushes to remote', () {
    final base = m({'a': '1'});
    final local = m({'a': '2'});
    final remote = m({'a': '1'});
    expect(kindOf(threeWayMerge(base, local, remote), 'a'),
        MergeKind.pushToRemote);
  });

  test('changed on both sides differently is a conflict', () {
    final base = m({'a': '1'});
    final local = m({'a': '2'});
    final remote = m({'a': '3'});
    final result = threeWayMerge(base, local, remote);
    expect(kindOf(result, 'a'), MergeKind.conflict);
    expect(result.hasConflicts, isTrue);
  });

  test('added on one side propagates to the other', () {
    final result = threeWayMerge(m({}), m({'new': '9'}), m({}));
    expect(kindOf(result, 'new'), MergeKind.pushToRemote);
  });

  test('deleted locally since base pushes the deletion', () {
    // Base had it, remote still has it, local removed it.
    final result = threeWayMerge(m({'a': '1'}), m({}), m({'a': '1'}));
    final item = result.items.single;
    expect(item.kind, MergeKind.pushToRemote);
    expect(item.local, isNull);
    expect(item.remote, isNotNull);
  });

  test('deleted remotely since base pulls the deletion', () {
    final result = threeWayMerge(m({'a': '1'}), m({'a': '1'}), m({}));
    final item = result.items.single;
    expect(item.kind, MergeKind.pullToLocal);
    expect(item.remote, isNull);
  });

  test('same edit on both sides is not a conflict (identical hashes)', () {
    // Both changed a->2 independently; contents match, so nothing to do.
    final result = threeWayMerge(m({'a': '1'}), m({'a': '2'}), m({'a': '2'}));
    expect(result.isEmpty, isTrue);
  });

  test('a mixed reconciliation classifies each file', () {
    final base = m({'keep': '1', 'edithere': '1', 'editthere': '1', 'clash': '1'});
    final local = m({'keep': '1', 'edithere': '2', 'editthere': '1', 'clash': '2', 'newlocal': '5'});
    final remote = m({'keep': '1', 'edithere': '1', 'editthere': '2', 'clash': '3'});

    final result = threeWayMerge(base, local, remote);

    expect(kindOf(result, 'edithere'), MergeKind.pushToRemote);
    expect(kindOf(result, 'editthere'), MergeKind.pullToLocal);
    expect(kindOf(result, 'clash'), MergeKind.conflict);
    expect(kindOf(result, 'newlocal'), MergeKind.pushToRemote);
    expect(kindOf(result, 'keep'), isNull);
  });
}
