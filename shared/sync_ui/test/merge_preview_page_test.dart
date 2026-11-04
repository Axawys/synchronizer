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
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
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
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
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

  testWidgets('files about to be deleted on the other device are warned about',
      (tester) async {
    final preview = SyncPreview(
      files: [
        FilePreview(
          item: item('gone.md', MergeKind.pushToRemote),
          kind: PreviewKind.delete,
          side: PreviewSide.there,
        ),
        FilePreview(
          item: item('also-gone.md', MergeKind.pushToRemote),
          kind: PreviewKind.delete,
          side: PreviewSide.there,
        ),
        FilePreview(
          item: item('arriving.md', MergeKind.pullToLocal),
          kind: PreviewKind.create,
          side: PreviewSide.here,
        ),
      ],
      folders: const [],
    );

    await show(tester, preview);

    // Under the device they are deleted on, first in its list, and named as
    // the thing that cannot be taken back.
    expect(find.text('Going to Desktop'), findsOneWidget);
    expect(find.text('−2'), findsOneWidget, reason: 'in the header');
    expect(find.text('Deleted · 2'), findsOneWidget);
    expect(find.textContaining('deleted, not moved'), findsOneWidget);

    // And the rows themselves read as losses: same colour as the warning.
    final theme = Theme.of(tester.element(find.text('gone.md')));
    final row = tester.widget<Text>(find.text('gone.md'));
    expect(row.style?.color, theme.colorScheme.error);
    final arriving = tester.widget<Text>(find.text('arriving.md'));
    expect(arriving.style?.color, isNot(theme.colorScheme.error));
  });

  testWidgets('a sync that deletes nothing says nothing about deleting',
      (tester) async {
    final preview = SyncPreview(
      files: [
        FilePreview(
          item: item('arriving.md', MergeKind.pullToLocal),
          kind: PreviewKind.create,
          side: PreviewSide.here,
        ),
      ],
      folders: const [],
    );

    await show(tester, preview);

    expect(find.textContaining('deleted, not moved'), findsNothing);
    expect(find.textContaining('Deleted'), findsNothing);
  });

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
    expect(find.text('+1'), findsOneWidget);
    expect(find.text('−1'), findsOneWidget);

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

    // Among the changes on the device they happen on: a folder that goes with
    // what goes, one that appears with what is new.
    expect(find.text('old/'), findsOneWidget);
    expect(find.text('vault/'), findsOneWidget);
    expect(find.text('Deleted · 1'), findsOneWidget);
    expect(find.text('New · 2'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('old/')).dy,
      lessThan(tester.getTopLeft(find.text('vault/')).dy),
    );
  });

  testWidgets('each device has its own list, and nothing is mixed between',
      (tester) async {
    final preview = SyncPreview(
      files: [
        FilePreview(
          item: item('to-pc.md', MergeKind.pushToRemote),
          kind: PreviewKind.create,
          side: PreviewSide.there,
        ),
        FilePreview(
          item: item('to-here.md', MergeKind.pullToLocal),
          kind: PreviewKind.update,
          side: PreviewSide.here,
          lines: const [DiffLine(DiffOp.insert, 'x')],
        ),
      ],
      folders: const [],
    );

    await show(tester, preview);

    final here = tester.getTopLeft(find.text('Coming here')).dy;
    final there = tester.getTopLeft(find.text('Going to Desktop')).dy;
    expect(here, lessThan(there));
    // Each file sits under the device it lands on.
    final toHere = tester.getTopLeft(find.text('to-here.md')).dy;
    final toPc = tester.getTopLeft(find.text('to-pc.md')).dy;
    expect(toHere, inExclusiveRange(here, there));
    expect(toPc, greaterThan(there));
  });

  testWidgets('a device lists what goes, then what changes, then what is new',
      (tester) async {
    final preview = SyncPreview(
      files: [
        FilePreview(
          item: item('b-new.md', MergeKind.pullToLocal),
          kind: PreviewKind.create,
          side: PreviewSide.here,
        ),
        FilePreview(
          item: item('c-changed.md', MergeKind.pullToLocal),
          kind: PreviewKind.update,
          side: PreviewSide.here,
        ),
        FilePreview(
          item: item('d-gone.md', MergeKind.pullToLocal),
          kind: PreviewKind.delete,
          side: PreviewSide.here,
        ),
      ],
      folders: const [],
    );

    await show(tester, preview);

    double y(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(y('d-gone.md'), lessThan(y('c-changed.md')));
    expect(y('c-changed.md'), lessThan(y('b-new.md')));
  });

  testWidgets('a file going away and a file arriving are coloured panels',
      (tester) async {
    final preview = SyncPreview(
      files: [
        FilePreview(
          item: item('gone.md', MergeKind.pullToLocal),
          kind: PreviewKind.delete,
          side: PreviewSide.here,
        ),
        FilePreview(
          item: item('new.md', MergeKind.pullToLocal),
          kind: PreviewKind.create,
          side: PreviewSide.here,
        ),
      ],
      folders: const [],
    );

    await show(tester, preview);

    // The header strip the name sits on, not only the name.
    Color strip(String path) => tester
        .widget<Material>(find
            .ancestor(of: find.text(path), matching: find.byType(Material))
            .first)
        .color!;
    final red = strip('gone.md');
    final green = strip('new.md');
    expect(red.r, greaterThan(red.g));
    expect(green.g, greaterThan(green.r));
  });

  testWidgets('a device list folds away, and its counts stay in sight',
      (tester) async {
    final preview = SyncPreview(
      files: [
        FilePreview(
          item: item('arriving.md', MergeKind.pullToLocal),
          kind: PreviewKind.create,
          side: PreviewSide.here,
        ),
      ],
      folders: const [],
    );

    await show(tester, preview);
    expect(find.text('arriving.md'), findsOneWidget);

    await tester.tap(find.text('Coming here'));
    await tester.pumpAndSettle();
    expect(find.text('arriving.md'), findsNothing);
    expect(find.text('+1'), findsOneWidget);

    // And the device nothing happens to says so rather than being left out.
    expect(find.text('Nothing changes'), findsOneWidget);
  });

  testWidgets('a merge is shown on both devices, each against its own copy',
      (tester) async {
    final merged = merge3(['a'], ['a', 'ours'], ['theirs', 'a']);
    final mergedItem = item('note.md', MergeKind.conflict);
    final preview = SyncPreview(
      files: [
        FilePreview(
          item: mergedItem,
          kind: PreviewKind.merged,
          side: PreviewSide.both,
          conflict: MergedConflict(
            item: mergedItem,
            merge: merged,
            ourLines: const ['a', 'ours'],
            theirLines: const ['theirs', 'a'],
          ),
          lines: diffLines(['a', 'ours'], merged.clean!),
        ),
      ],
      folders: const [],
    );

    await show(tester, preview);
    expect(find.text('note.md'), findsNWidgets(2));

    await tester.tap(find.text('note.md').first);
    await tester.tap(find.text('note.md').last);
    await tester.pumpAndSettle();

    // Here gains their line; the other device gains ours.
    expect(find.text('+ theirs'), findsOneWidget);
    expect(find.text('+ ours'), findsOneWidget);
  });

  testWidgets('the tree shows the folder as it will be, changes marked',
      (tester) async {
    final preview = SyncPreview(
      files: [
        FilePreview(
          item: item('daily/new.md', MergeKind.pullToLocal),
          kind: PreviewKind.create,
          side: PreviewSide.here,
        ),
        FilePreview(
          item: item('daily/gone.md', MergeKind.pushToRemote),
          kind: PreviewKind.delete,
          side: PreviewSide.there,
        ),
      ],
      folders: const [],
      unchanged: const ['daily/old.md', 'archive/2025.md', 'readme.md'],
    );

    await show(tester, preview);
    await tester.tap(find.text('Tree'));
    await tester.pumpAndSettle();

    // A folder with changes in it is open; one without starts closed.
    expect(find.text('daily'), findsOneWidget);
    expect(find.text('new.md'), findsOneWidget);
    expect(find.text('old.md'), findsOneWidget);
    expect(find.text('archive'), findsOneWidget);
    expect(find.text('2025.md'), findsNothing);
    expect(find.text('readme.md'), findsOneWidget);

    // What goes is still shown, struck through, and says where it goes from.
    final gone = tester.widget<Text>(find.text('gone.md'));
    expect(gone.style?.decoration, TextDecoration.lineThrough);
    expect(find.text('Desktop'), findsOneWidget);
    expect(find.text('here'), findsOneWidget);

    await tester.tap(find.text('archive'));
    await tester.pumpAndSettle();
    expect(find.text('2025.md'), findsOneWidget);
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

  testWidgets('a decided spot leaves the diff, and can be brought back',
      (tester) async {
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

    await show(tester, preview);
    expect(find.text('+ mine'), findsOneWidget);
    expect(find.textContaining('1 spot to decide'), findsOneWidget);

    await tester.tap(find.text('Take mine'));
    await tester.pumpAndSettle();

    // The point of deciding: the spot stops taking up the screen, so what is
    // left is what still needs the user.
    expect(find.text('+ mine'), findsNothing);
    expect(find.text('− theirs'), findsNothing);
    expect(find.textContaining('Line 1: your version'), findsOneWidget);
    expect(find.textContaining('spot decided'), findsOneWidget);

    // Nothing is written until Apply, so a decision must be reversible.
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('+ mine'), findsOneWidget);
    expect(find.textContaining('1 spot to decide'), findsOneWidget);
  });

  testWidgets('deciding some spots and leaving the rest still applies whole',
      (tester) async {
    // Three spots, separated by untouched lines so each is its own conflict.
    final merge = merge3(
      ['a', 'keep', 'b', 'keep too', 'c'],
      ['mine 1', 'keep', 'mine 2', 'keep too', 'mine 3'],
      ['theirs 1', 'keep', 'theirs 2', 'keep too', 'theirs 3'],
    );
    expect(merge.conflicts, hasLength(3));

    final conflictItem = item('note.md', MergeKind.conflict);
    final preview = SyncPreview(
      files: [
        FilePreview(
          item: conflictItem,
          kind: PreviewKind.conflict,
          side: PreviewSide.both,
          conflict: MergedConflict(item: conflictItem, merge: merge),
        ),
      ],
      folders: const [],
    );

    final applied = await _openAndApply(tester, preview, beforeApply: () async {
      // Take theirs for the middle spot only, and leave the other two alone.
      await tester.tap(find.text('Take theirs').at(1));
      await tester.pumpAndSettle();
      expect(find.textContaining('2 spots to decide'), findsOneWidget);
    });

    // The decided spot went their way; the two left alone kept ours, and the
    // untouched lines merged without anyone being asked.
    expect(utf8.decode(applied.single.content!),
        joinLines(['mine 1', 'keep', 'theirs 2', 'keep too', 'mine 3']));
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

  testWidgets('lines are numbered on the side they exist on', (tester) async {
    final preview = SyncPreview(
      files: [
        FilePreview(
          item: item('note.md', MergeKind.pullToLocal),
          kind: PreviewKind.update,
          side: PreviewSide.here,
          lines: const [
            DiffLine(DiffOp.equal, 'one'),
            DiffLine(DiffOp.delete, 'two'),
            DiffLine(DiffOp.insert, 'zwei'),
            DiffLine(DiffOp.equal, 'three'),
          ],
        ),
      ],
      folders: const [],
    );

    await show(tester, preview);
    await tester.tap(find.text('note.md'));
    await tester.pumpAndSettle();

    // One column of numbers: a removed line carries its number in the old
    // file, every other line its number in the new one.
    expect(find.text('1'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    // The removed line was line 2 of the old file; the line replacing it is
    // line 2 of the new one.
    expect(find.text('2'), findsNWidgets(2));
    expect(find.text('− two'), findsOneWidget);
    expect(find.text('+ zwei'), findsOneWidget);
  });

  testWidgets('untouched stretches are folded away, and say how many',
      (tester) async {
    final preview = SyncPreview(
      files: [
        FilePreview(
          item: item('note.md', MergeKind.pullToLocal),
          kind: PreviewKind.update,
          side: PreviewSide.here,
          lines: [
            const DiffLine(DiffOp.insert, 'top'),
            for (var i = 0; i < 20; i++) DiffLine(DiffOp.equal, 'filler $i'),
            const DiffLine(DiffOp.insert, 'bottom'),
          ],
        ),
      ],
      folders: const [],
    );

    await show(tester, preview);
    await tester.tap(find.text('note.md'));
    await tester.pumpAndSettle();

    // Both changes are shown with context around them...
    expect(find.text('+ top'), findsOneWidget);
    expect(find.text('+ bottom'), findsOneWidget);
    expect(find.text('  filler 0'), findsOneWidget);
    expect(find.text('  filler 19'), findsOneWidget);
    // ...and the middle is folded rather than dropped without a word.
    expect(find.text('  filler 10'), findsNothing);
    expect(find.textContaining('14 unchanged lines'), findsOneWidget);

    // Numbering survives the fold: the last line is still line 22.
    expect(find.text('22'), findsOneWidget);
  });

  testWidgets('a conflict is numbered from where it sits in each file',
      (tester) async {
    // We added a line above the conflict and they did not, so the same
    // conflict is at line 4 here and line 3 there.
    final merge = merge3(
      ['a', 'b', 'x'],
      ['a', 'added', 'b', 'mine'],
      ['a', 'b', 'theirs'],
    );
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
            ourLines: const ['a', 'added', 'b', 'mine'],
            theirLines: const ['a', 'b', 'theirs'],
          ),
        ),
      ],
      folders: const [],
    );

    await show(tester, preview);

    expect(find.text('+ mine'), findsOneWidget);
    expect(find.text('− theirs'), findsOneWidget);
    expect(find.text('4'), findsOneWidget, reason: 'our line number');
    expect(find.text('3'), findsOneWidget, reason: 'their line number');
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
    // It lands on both devices, so it is under both; either one says it.
    await tester.tap(find.text('note.md').first);
    await tester.pumpAndSettle();

    expect(find.textContaining('no copy from a previous sync'), findsOneWidget);
  });
}
