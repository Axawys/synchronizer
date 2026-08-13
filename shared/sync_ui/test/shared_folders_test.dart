import 'dart:convert';

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
}
