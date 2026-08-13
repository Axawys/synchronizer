import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_net/sync_net.dart';
import 'package:sync_ui/sync_ui.dart';

/// The row for a shared folder: the name, the control that belongs to it, and
/// where the files actually land.
void main() {
  Widget host(Widget child, {double width = 600}) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: Center(child: SizedBox(width: width, child: child))),
      );

  testWidgets('a chosen folder shows where it lands', (tester) async {
    await tester.pumpWidget(host(const SyncFolderCard(
      name: 'notes',
      localPath: '/home/me/Documents/notes',
    )));

    expect(find.text('notes'), findsOneWidget);
    expect(find.textContaining('Documents/notes'), findsOneWidget);
  });

  testWidgets('the button that changes the folder sits next to its name',
      (tester) async {
    await tester.pumpWidget(host(const SyncFolderCard(
      name: 'notes',
      localPath: '/home/me/Documents/notes',
    )));

    final name = tester.getRect(find.text('notes'));
    final button = tester.getRect(find.byIcon(Icons.drive_file_move_outline));
    final card = tester.getRect(find.byType(SyncFolderCard));

    // Beside the name, not pinned to the far end of the window: the gap
    // between them is a thumb's width, not a hand's.
    expect(button.left - name.right, lessThan(24));
    expect(card.right - button.right, greaterThan(24),
        reason: 'and not at the edge either');
  });

  testWidgets('a folder with no place yet says so instead of offering to move it',
      (tester) async {
    await tester.pumpWidget(host(const SyncFolderCard(name: 'notes', localPath: null)));

    expect(find.text('Folder not chosen yet'), findsOneWidget);
    expect(find.byIcon(Icons.drive_file_move_outline), findsNothing);
  });

  testWidgets('tapping syncs, the button changes the folder', (tester) async {
    var synced = 0;
    var changed = 0;
    await tester.pumpWidget(host(SyncFolderCard(
      name: 'notes',
      localPath: '/home/me/notes',
      onSync: () => synced++,
      onChangeFolder: () => changed++,
    )));

    await tester.tap(find.byIcon(Icons.drive_file_move_outline));
    expect(changed, 1);
    expect(synced, 0, reason: 'the button is not the row');

    await tester.tap(find.text('notes'));
    expect(synced, 1);
  });

  testWidgets('the folder being synced says so, and the others wait their turn',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(host(Column(children: [
      SyncFolderCard(
        name: 'notes',
        localPath: '/home/me/notes',
        syncing: true,
        onSync: () => taps++,
      ),
      SyncFolderCard(
        name: 'photos',
        localPath: '/home/me/photos',
        enabled: false,
        onSync: () => taps++,
      ),
    ])));

    // One session, one sync: while one folder is working the others cannot be
    // started, and a tap that did nothing would look like a broken row.
    await tester.tap(find.text('photos'));
    await tester.pump();
    expect(taps, 0);

    expect(find.byIcon(Icons.sync), findsNWidgets(2));
  });

  testWidgets('a folder says what each side weighs', (tester) async {
    await tester.pumpWidget(host(const SyncFolderCard(
      name: 'Obsidian',
      localPath: '/home/me/Obsidian',
      bytesHere: 0,
      bytesThere: 1288490188,
    )));

    // The line that answers "it says synced, but one of them is empty" - and
    // weight says it better than a count: 1.3 GB against nothing.
    expect(find.textContaining('empty here'), findsOneWidget);
    expect(find.textContaining('1.3 GB there'), findsOneWidget);
  });

  testWidgets('a folder the other device no longer has says so', (tester) async {
    await tester.pumpWidget(host(const SyncFolderCard(
      name: 'Obsidian',
      localPath: '/home/me/Obsidian',
      bytesHere: 1288490188,
      missingThere: true,
    )));

    // Not "empty there": an empty folder is a legitimate thing to sync, a
    // vanished one is a mistake waiting to delete a vault.
    expect(find.text('Not there any more on that device'), findsOneWidget);
    expect(find.textContaining('there'), findsOneWidget,
        reason: 'only the warning, not a size for a folder that is gone');
  });

  testWidgets('the status bar says which stage the sync is in', (tester) async {
    await tester.pumpWidget(host(const SyncStatusBar(
      folder: 'notes',
      progress: SyncProgress(SyncPhase.reading, done: 3, total: 8),
    )));

    expect(find.text('Reading the changes… 3 of 8'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator));
    expect(bar.value, closeTo(3 / 8, 0.001));
  });

  testWidgets('a stage with nothing to count shows motion, not a proportion',
      (tester) async {
    await tester.pumpWidget(host(const SyncStatusBar(
      folder: 'notes',
      progress: SyncProgress(SyncPhase.asking),
    )));

    expect(find.text('Asking the other device what it has…'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator));
    expect(bar.value, isNull, reason: 'an honest indeterminate bar');
  });

  group('formatSize', () {
    late AppLocalizations l10n;

    setUp(() async {
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
    });

    test('reads as a size, not as a number of bytes', () {
      expect(formatSize(l10n, 0), 'empty');
      expect(formatSize(l10n, 900), '900 B');
      expect(formatSize(l10n, 8_400), '8.4 kB');
      expect(formatSize(l10n, 120_000), '120 kB');
      expect(formatSize(l10n, 3_200_000), '3.2 MB');
      expect(formatSize(l10n, 1_288_490_188), '1.3 GB');
    });

    test('an empty folder is empty, not "0 B"', () {
      // "0 B" reads as a measurement that failed; "empty" is the fact.
      expect(formatSize(l10n, 0), 'empty');
    });
  });

  group('prettyPath', () {
    test('leaves a short path alone', () {
      expect(prettyPath('/srv/notes', home: '/home/me'), '/srv/notes');
    });

    test('writes the home directory as a tilde', () {
      expect(prettyPath('/home/me/notes', home: '/home/me'), '~/notes');
    });

    test('somebody else\'s home is still a home', () {
      // The path on the card comes from the other device now. Read on a phone,
      // a desktop's home matches nothing here, and the two segments that say
      // "a Linux machine, somebody's account" would push the folder off the
      // row.
      expect(prettyPath('/home/axawys/Documents/Obsidian', home: '/data/user'),
          '~/Documents/Obsidian');
      expect(prettyPath('/home/axawys', home: '/data/user'), '~');
    });

    test('a path that merely starts with those letters is left alone', () {
      expect(prettyPath('/homework/notes', home: '/home/me'),
          '/homework/notes');
    });

    test('drops the prefix every path on a phone starts with', () {
      expect(prettyPath('/storage/emulated/0/Obsidian/vault'), '/Obsidian/vault');
    });

    test('keeps the end of a path too long to show, which is the part that '
        'names the folder', () {
      final short = prettyPath(
        '/home/me/very/deeply/nested/place/for/things/Obsidian/vault',
        home: '/home/me',
      );
      expect(short, '…/things/Obsidian/vault');
      expect(short.length, lessThan(46));
    });
  });
}
