import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sync_net/sync_net.dart';
import 'package:sync_ui/sync_ui.dart';

/// Bringing several devices to the same copy: what the screen offers before it
/// starts, and what it refuses to pretend it can do.
void main() {
  setUp(() {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues({});
  });

  const self = DeviceInfo(
      id: 'self', name: 'This one', platform: DevicePlatform.linux, port: 47800);
  const phone = DeviceInfo(
      id: 'phone',
      name: 'Calm Otter',
      platform: DevicePlatform.android,
      port: 47800,
      address: '192.168.1.5');
  const tablet = DeviceInfo(
      id: 'tablet',
      name: 'Quiet Lynx',
      platform: DevicePlatform.android,
      port: 47800,
      address: '192.168.1.6');

  Future<void> pump(WidgetTester tester, SharedFolders folders) async {
    final trust = MemoryTrustStore();
    for (final peer in [phone, tablet]) {
      await trust.add(TrustedPeer(
          id: peer.id, name: peer.name, platform: peer.platform, secret: 's'));
    }
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MultiSyncPage(
        self: self,
        devices: const [phone, tablet],
        trust: trust,
        folders: folders,
        // No devices to ask in a widget test.
        gather: false,
      ),
    ));
    await tester.pump();
  }

  testWidgets('every device present is included to start with', (tester) async {
    final folders = SharedFolders();
    await folders.choose('/home/me/vault');
    await pump(tester, folders);

    // Named twice over now: once in the folder table, once in the list of
    // devices taking part.
    expect(find.text('Calm Otter'), findsWidgets);
    expect(find.text('Quiet Lynx'), findsWidgets);
    for (final box in tester.widgetList<CheckboxListTile>(
        find.byType(CheckboxListTile))) {
      expect(box.value, isTrue, reason: 'the point of the screen is all of them');
    }
  });

  testWidgets('the folder to level is the one this device syncs',
      (tester) async {
    final folders = SharedFolders();
    // Choosing twice is replacing, not adding: a device syncs one folder.
    await folders.choose('/home/me/photos');
    await folders.choose('/home/me/vault');
    await pump(tester, folders);

    expect(find.text('vault'), findsWidgets);
    expect(find.text('photos'), findsNothing);
    // The table can outgrow a test-sized window; the button is below it.
    await tester.ensureVisible(
        find.text('See what will change', skipOffstage: false));
    await tester.pump();
    expect(find.text('See what will change'), findsOneWidget);

    // Every folder says where each device stands on it, not just this one.
    expect(find.text('Calm Otter'), findsWidgets);
    expect(find.text('Quiet Lynx'), findsWidgets);
    expect(find.text('not offered'), findsWidgets);
  });

  testWidgets('with nothing shared it says what to do instead of offering a '
      'button that cannot work', (tester) async {
    await pump(tester, SharedFolders());

    expect(find.textContaining('Share a folder from this device first'),
        findsOneWidget);
    expect(find.text('Bring into line'), findsNothing);
  });

  testWidgets('nothing is applied until the changes have been looked at',
      (tester) async {
    final folders = SharedFolders();
    await folders.choose('/home/me/vault');
    await pump(tester, folders);

    // The first button works out what would happen; the one that does it comes
    // after, and only after.
    await tester.ensureVisible(
        find.text('See what will change', skipOffstage: false));
    await tester.pump();
    expect(find.text('See what will change'), findsOneWidget);
    expect(find.text('Bring into line'), findsNothing);
  });

  testWidgets('what is waiting for one device is read line by line, not as a '
      'list of names', (tester) async {
    // The list of file names was the whole of this screen once, and it cannot
    // answer what people open it for: whether the paragraph they wrote last
    // night is the one arriving or the one about to be overwritten.
    FileEntry entry(String path) =>
        FileEntry(path: path, size: 1, modified: DateTime.utc(2026), hash: 'h');
    MergeItem item(String path, MergeKind kind) => MergeItem(
          path: path,
          kind: kind,
          local: entry(path),
          remote: entry(path),
        );

    final preview = SyncPreview(files: [
      FilePreview(
        item: item('arriving.md', MergeKind.pullToLocal),
        kind: PreviewKind.update,
        side: PreviewSide.here,
        lines: const [
          DiffLine(DiffOp.equal, 'a heading'),
          DiffLine(DiffOp.insert, 'the line that is coming'),
          DiffLine(DiffOp.delete, 'the line it replaces'),
        ],
      ),
    ], folders: const []);

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MergePreviewPage(
        folderName: 'vault',
        deviceName: 'Calm Otter',
        preview: preview,
        readOnly: true,
        title: 'Changes on Calm Otter',
      ),
    ));
    await tester.pump();

    expect(find.text('Changes on Calm Otter'), findsOneWidget);
    await tester.tap(find.text('arriving.md'));
    await tester.pumpAndSettle();

    // The text itself, which is the point.
    expect(find.textContaining('the line that is coming'), findsOneWidget);
    expect(find.textContaining('the line it replaces'), findsOneWidget);
    // And nothing here decides anything: that happens on the screen below,
    // for every device at once.
    expect(find.byType(FloatingActionButton), findsNothing);
  });

  testWidgets('one file changed in several places is laid out side by side, '
      'with a way to keep each', (tester) async {
    FileEntry entry(String path, int size, DateTime at) =>
        FileEntry(path: path, size: size, modified: at, hash: '$size');

    final conflict = PathConflict('today.md', [
      ConflictVariant(
        sourceId: ConflictVariant.localSource,
        sourceName: 'This device',
        entry: entry('today.md', 120, DateTime.utc(2026, 8, 13, 9)),
      )..text = 'the paragraph I wrote at the desk',
      ConflictVariant(
        sourceId: 'phone',
        sourceName: 'Calm Otter',
        entry: entry('today.md', 340, DateTime.utc(2026, 8, 13, 18)),
      )..text = 'the paragraph I wrote on the train',
      ConflictVariant(
        sourceId: 'tablet',
        sourceName: 'Quiet Lynx',
        entry: entry('today.md', 120, DateTime.utc(2026, 8, 13, 9)),
      )..text = 'the paragraph I wrote at the desk',
    ]);

    // The newest is the starting point, not the decision.
    expect(conflict.newestSource, 'phone');

    String? picked;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: ConflictAcrossDevices(
          conflict: conflict,
          chosen: conflict.newestSource,
          onChoose: (source) => picked = source,
        ),
      ),
    ));
    await tester.pump();

    // Every device that has a copy is named, with what its copy is.
    expect(find.text('This device'), findsOneWidget);
    expect(find.text('Calm Otter'), findsOneWidget);
    expect(find.text('Quiet Lynx'), findsOneWidget);
    expect(find.textContaining('newest'), findsOneWidget);
    // A copy identical to this device's is not a choice to weigh up.
    expect(find.text('same as this device'), findsOneWidget);

    // And what each of them actually says, which is the question being asked.
    expect(find.textContaining('at the desk'), findsNWidgets(2));
    expect(find.textContaining('on the train'), findsOneWidget);

    // One button per copy: the one already chosen says so, the others offer to
    // take its place.
    expect(find.text('Chosen'), findsOneWidget);
    expect(find.text('Apply this one'), findsNWidgets(2));

    // Pressed under this device's text, it keeps this device's text.
    await tester.tap(find.text('Apply this one').first);
    expect(picked, ConflictVariant.localSource);
  });

  testWidgets('a narrow screen stacks the copies instead of splitting',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final conflict = PathConflict('today.md', [
      ConflictVariant(
        sourceId: ConflictVariant.localSource,
        sourceName: 'This device',
        entry: FileEntry(
            path: 'today.md',
            size: 12,
            modified: DateTime.utc(2026, 8, 13, 9),
            hash: 'a'),
      )..text = 'at the desk',
      ConflictVariant(
        sourceId: 'phone',
        sourceName: 'Calm Otter',
        entry: FileEntry(
            path: 'today.md',
            size: 12,
            modified: DateTime.utc(2026, 8, 13, 18),
            hash: 'b'),
      )..text = 'on the train',
    ]);

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: ConflictAcrossDevices(conflict: conflict, chosen: 'phone'),
      ),
    ));
    await tester.pump();

    // One under the other, not two columns of nothing: on a phone there is no
    // room for the second column to say anything.
    final here = tester.getRect(find.text('at the desk'));
    final there = tester.getRect(find.text('on the train'));
    expect(there.top, greaterThan(here.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a conflict asks which device is right, and describes both',
      (tester) async {
    final item = MergeItem(
      path: 'notes/today.md',
      kind: MergeKind.conflict,
      local: FileEntry(
          path: 'notes/today.md',
          size: 120,
          modified: DateTime.utc(2026, 8, 13, 9),
          hash: 'a'),
      remote: FileEntry(
          path: 'notes/today.md',
          size: 340,
          modified: DateTime.utc(2026, 8, 13, 18),
          hash: 'b'),
    );

    ConflictChoice? answer;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            answer = await showDialog<ConflictChoice>(
              context: context,
              builder: (_) => ConflictChoiceDialog(item: item, peer: phone),
            );
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // "Which is right" cannot be answered without knowing what each side is.
    expect(find.text('Which copy of "notes/today.md" is right?'), findsOneWidget);
    expect(find.textContaining('120 bytes'), findsOneWidget);
    expect(find.textContaining('340 bytes'), findsOneWidget);

    await tester.tap(find.text('Use this device for the rest of this run'));
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, 'Calm Otter'));
    await tester.pumpAndSettle();

    expect(answer!.keepLocal, isFalse);
    expect(answer!.remember, isTrue);
  });

  testWidgets('it says up front how conflicts will be settled', (tester) async {
    final folders = SharedFolders();
    await folders.choose('/home/me/vault');
    await pump(tester, folders);

    // The rule is stated before the button is pressed, not discovered
    // afterwards: what merges by itself, and what will be asked about.
    expect(find.textContaining('you choose which device is right'),
        findsOneWidget);
  });
}
