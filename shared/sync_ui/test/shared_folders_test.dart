import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sync_ui/sync_ui.dart';

/// One folder per device: what the store does about it, and what the screen
/// offers instead of an "add" and a bin.
void main() {
  setUp(() {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues({});
  });

  test('choosing a folder replaces the one before it', () async {
    final folders = SharedFolders();
    await folders.choose('/home/me/Obsidian');
    await folders.choose('/home/me/Vault');

    expect(folders.folder?.path, '/home/me/Vault');
    expect(folders.folders, hasLength(1));
    // And the old one is not still being served to peers under its name.
    expect(folders.pathOf('Obsidian'), isNull);
    expect(folders.pathOf('Vault'), '/home/me/Vault');
  });

  test('a folder is named after itself, and under a name a peer asked for',
      () async {
    final folders = SharedFolders();
    await folders.choose('/home/me/Documents/Obsidian');
    expect(folders.folder?.name, 'Obsidian');

    await folders.chooseAs('Notes', '/home/me/Documents/Obsidian');
    expect(folders.folder?.name, 'Notes',
        reason: 'both ends have to address it by the same name');
  });

  test('an install that had several folders keeps the first', () async {
    // It was a list before this, and it is stored as one. Picking for somebody
    // beats dropping the lot, and the screen shows which one it kept.
    SharedPreferences.setMockInitialValues({
      'shared_folders': jsonEncode([
        {'name': 'Obsidian', 'path': '/home/me/Obsidian'},
        {'name': 'photos', 'path': '/home/me/photos'},
      ]),
    });

    final folders = SharedFolders();
    await folders.load();

    expect(folders.folders, hasLength(1));
    expect(folders.folder?.name, 'Obsidian');
  });

  testWidgets('the folder screen replaces rather than adds or removes',
      (tester) async {
    final folders = SharedFolders();
    await folders.choose('/home/me/Documents/Obsidian');

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SyncFolderPage(folders: folders),
    ));
    await tester.pump();

    expect(find.text('Obsidian'), findsOneWidget);
    expect(find.text('~/Documents/Obsidian'), findsOneWidget);
    expect(find.text('Replace folder'), findsOneWidget);
    // The two ways to end up with a device that cannot sync at all.
    expect(find.byIcon(Icons.delete_outline), findsNothing);
    expect(find.byType(FloatingActionButton), findsNothing);
  });

  testWidgets('with no folder yet the button chooses one', (tester) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SyncFolderPage(folders: SharedFolders()),
    ));
    await tester.pump();

    expect(find.text('Choose a folder'), findsOneWidget);
    expect(find.text('Replace folder'), findsNothing);
  });

  testWidgets('an empty folder is asked about when the app opens',
      (tester) async {
    final vault = Directory.systemTemp.createTempSync('empty_vault');
    addTearDown(() => vault.deleteSync(recursive: true));

    final folders = SharedFolders();
    await folders.choose(vault.path);

    await _open(tester, folders);

    // Either this device is waiting for its first sync or it is pointed at the
    // wrong folder, and the second is how a vault gets emptied on the other
    // device. Asking is cheap; finding out afterwards is not.
    expect(find.textContaining('has nothing in it'), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);
  });

  testWidgets('a folder with a vault in it is left alone', (tester) async {
    final vault = Directory.systemTemp.createTempSync('full_vault');
    addTearDown(() => vault.deleteSync(recursive: true));
    File('${vault.path}/note.md').writeAsStringSync('something');

    final folders = SharedFolders();
    await folders.choose(vault.path);

    await _open(tester, folders);

    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('with no folder at all it says what to do', (tester) async {
    await _open(tester, SharedFolders());

    expect(find.text('Nothing to sync yet'), findsOneWidget);
    expect(find.text('Choose a folder'), findsOneWidget);
  });
}

/// Runs the check the app runs when it opens, with the clock turning:
/// measuring a folder is real disk work, which a widget test's fake clock does
/// not carry.
Future<void> _open(WidgetTester tester, SharedFolders folders) async {
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: const Scaffold(body: SizedBox.shrink()),
  ));
  await tester.runAsync(() async {
    ensureStorageReady(tester.element(find.byType(Scaffold)), folders);
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
  await tester.pumpAndSettle();
}
