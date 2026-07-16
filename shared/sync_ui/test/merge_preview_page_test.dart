import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_net/sync_net.dart';
import 'package:sync_ui/sync_ui.dart';

/// Opens the preview and returns what it pops. Kept out of the tests because
/// the result only lands after the pushed route closes.
Future<List<ResolvedMerge>> _openAndApply(
  WidgetTester tester,
  SyncPreview preview, {
  Future<void> Function()? beforeApply,
}) async {
  List<ResolvedMerge>? result;
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => ElevatedButton(
        onPressed: () async =>
            result = await Navigator.of(context).push<List<ResolvedMerge>>(
          MaterialPageRoute(
            builder: (_) => MergePreviewPage(
              folderName: 'notes',
              deviceName: 'Desktop',
              preview: preview,
            ),
          ),
        ),
        child: const Text('open'),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();

  await beforeApply?.call();

  await tester.tap(find.textContaining('Apply'));
  await tester.pumpAndSettle();
  return result!;
}

void main() {
  FileEntry entry(String path) =>
      FileEntry(path: path, size: 1, modified: DateTime.utc(2026), hash: 'h');

  MergeItem item(String path, MergeKind kind) => MergeItem(
        path: path,
        kind: kind,
        local: entry(path),
        remote: entry(path),
      );

  Future<List<ResolvedMerge>?> show(WidgetTester tester, SyncPreview preview) async {
    List<ResolvedMerge>? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            result = await Navigator.of(context).push<List<ResolvedMerge>>(
              MaterialPageRoute(
                builder: (_) => MergePreviewPage(
                  folderName: 'notes',
                  deviceName: 'Desktop',
                  preview: preview,
                ),
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('shows the lines a file gains and loses', (tester) async {
    final preview = SyncPreview(
      files: [
        FilePreview(
          item: item('note.md', MergeKind.pullToLocal),
          kind: PreviewKind.update,
          side: PreviewSide.here,
          lines: const [
            DiffLine(DiffOp.equal, 'keep me'),
            DiffLine(DiffOp.delete, 'old line'),
            DiffLine(DiffOp.insert, 'new line'),
          ],
        ),
      ],
      folders: const [],
    );

    await show(tester, preview);

    expect(find.text('note.md'), findsOneWidget);
    expect(find.textContaining('+1'), findsOneWidget);
    expect(find.textContaining('-1'), findsOneWidget);

    // The diff itself is behind the tile.
    await tester.tap(find.text('note.md'));
    await tester.pumpAndSettle();
    expect(find.text('− old line'), findsOneWidget);
    expect(find.text('+ new line'), findsOneWidget);
    expect(find.text('  keep me'), findsOneWidget);
  });

  testWidgets('names the folders that will be created and removed',
      (tester) async {
    final preview = SyncPreview(
      files: [
        FilePreview(
          item: item('vault/new.md', MergeKind.pullToLocal),
          kind: PreviewKind.create,
          side: PreviewSide.here,
        ),
      ],
      folders: const [
        FolderPreview('vault', created: true, side: PreviewSide.here),
        FolderPreview('old', created: false, side: PreviewSide.here),
      ],
    );

    await show(tester, preview);

    expect(find.text('vault'), findsOneWidget);
    expect(find.textContaining('Created'), findsOneWidget);
    expect(find.text('old'), findsOneWidget);
    expect(find.textContaining('Removed'), findsOneWidget);
  });

  testWidgets('a clean merge carries the combined text, for both sides',
      (tester) async {
    // Each side edited a different end, so merging settles it with no choice.
    final merged = merge3(['a'], ['a', 'ours'], ['theirs', 'a']);
    expect(merged.hasConflicts, isFalse);

    final mergedItem = item('note.md', MergeKind.conflict);
    final preview = SyncPreview(
      files: [
        FilePreview(
          item: mergedItem,
          kind: PreviewKind.merged,
          side: PreviewSide.both,
          conflict: MergedConflict(item: mergedItem, merge: merged),
          lines: const [DiffLine(DiffOp.insert, 'theirs')],
        ),
      ],
      folders: const [],
    );

    final holder = await _openAndApply(tester, preview);

    final resolved = holder.single;
    expect(resolved.isMerged, isTrue, reason: 'goes to both devices');
    // The applied text is the merge, not one side or the other.
    expect(utf8.decode(resolved.content!), joinLines(['theirs', 'a', 'ours']));
  });

  testWidgets('choosing per hunk decides what a conflict becomes',
      (tester) async {
    // One conflicting spot: ours vs theirs.
    final merge = merge3(['base'], ['mine'], ['theirs']);
    final conflictItem = item('note.md', MergeKind.conflict);
    final preview = SyncPreview(
      files: [
        FilePreview(
          item: conflictItem,
          kind: PreviewKind.conflict,
          side: PreviewSide.both,
          conflict: MergedConflict(
            item: conflictItem,
            merge: merge,
            ourLines: const ['mine'],
            theirLines: const ['theirs'],
          ),
        ),
      ],
      folders: const [],
    );

    // Defaults to keeping ours, so a careless Apply cannot lose local work.
    final kept = await _openAndApply(tester, preview, beforeApply: () async {
      // Both versions are on screen to compare before deciding.
      expect(find.text('+ mine'), findsOneWidget);
      expect(find.text('− theirs'), findsOneWidget);
    });
    expect(utf8.decode(kept.single.content!), 'mine');

    // Switching the hunk to theirs changes what gets written.
    final taken = await _openAndApply(tester, preview, beforeApply: () async {
      await tester.tap(find.text('Take theirs'));
      await tester.pumpAndSettle();
    });
    expect(utf8.decode(taken.single.content!), 'theirs');
  });

  testWidgets('a conflict that cannot be merged still shows both versions',
      (tester) async {
    // Nothing to merge against, but the text is readable, so the choice is not
    // made blind: the screen used to show the file name and nothing else.
    final conflictItem = item('note.md', MergeKind.conflict);
    final preview = SyncPreview(
      files: [
        FilePreview(
          item: conflictItem,
          kind: PreviewKind.conflict,
          side: PreviewSide.both,
          lines: const [
            DiffLine(DiffOp.delete, 'theirs'),
            DiffLine(DiffOp.insert, 'mine'),
          ],
          conflict: MergedConflict(item: conflictItem),
        ),
      ],
      folders: const [],
    );

    await show(tester, preview);

    expect(find.text('+ mine'), findsOneWidget);
    expect(find.text('− theirs'), findsOneWidget);
    expect(find.textContaining('keep one version'), findsOneWidget);
  });

  testWidgets('a merge with a guessed ancestor says so', (tester) async {
    // The user is approving this, so the screen must not pass a guess off as a
    // real merge: a line deleted on one device can come back.
    final merge = merge3(['a'], ['a', 'mine'], ['theirs', 'a']);
    final mergedItem = item('note.md', MergeKind.conflict);
    final preview = SyncPreview(
      files: [
        FilePreview(
          item: mergedItem,
          kind: PreviewKind.merged,
          side: PreviewSide.both,
          lines: const [DiffLine(DiffOp.insert, 'theirs')],
          conflict: MergedConflict(
              item: mergedItem, merge: merge, ancestorKnown: false),
        ),
      ],
      folders: const [],
    );

    await show(tester, preview);
    await tester.tap(find.text('note.md'));
    await tester.pumpAndSettle();

    expect(find.textContaining('no copy from a previous sync'), findsOneWidget);
  });
}
