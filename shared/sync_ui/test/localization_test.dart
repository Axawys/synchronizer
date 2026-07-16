import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_ui/sync_ui.dart';

/// Guards the translation itself, not the plumbing: a half-translated screen is
/// worse than an untranslated one, and it is the kind of thing that rots
/// quietly as strings get added.
void main() {
  Future<AppLocalizations> load(Locale locale) =>
      AppLocalizations.delegate.load(locale);

  test('every string in the template is translated into Russian', () async {
    // Compared through the generated classes rather than the .arb files, so a
    // key that was translated but never wired up still counts as missing.
    final en = await load(const Locale('en'));
    final ru = await load(const Locale('ru'));

    final untranslated = <String>[];
    for (final entry in _plainStrings.entries) {
      if (entry.value(ru) == entry.value(en)) untranslated.add(entry.key);
    }

    expect(untranslated, isEmpty,
        reason: 'these read as English in a Russian UI');
  });

  test('the app name is deliberately left alone', () async {
    // The exception to the rule above: it is a name, not a word.
    final ru = await load(const Locale('ru'));
    expect(ru.appTitle, 'Synchronizer');
  });

  test('Russian counts things the way Russian does', () async {
    final ru = await load(const Locale('ru'));

    // One, few, many: the whole reason these strings are plurals and not
    // "{count} строк".
    expect(ru.unchangedLines(1), contains('строка'));
    expect(ru.unchangedLines(3), contains('строки'));
    expect(ru.unchangedLines(11), contains('строк '));
    expect(ru.syncedChanges(1, 'notes'), contains('изменение'));
    expect(ru.syncedChanges(5, 'notes'), contains('изменений'));
  });

  test('placeholders survive translation', () async {
    final ru = await load(const Locale('ru'));

    expect(ru.thisDevice('Pixel'), contains('Pixel'));
    expect(ru.reviewFolder('Obsidian'), contains('Obsidian'));
    expect(ru.goingThereSection('Pixel', 3), allOf(contains('Pixel'), contains('3')));
    expect(ru.versionLabel('1.2'), contains('1.2'));
  });

  testWidgets('choosing a language changes the interface, not just a setting',
      (tester) async {
    Widget app(Locale? locale) => MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) =>
                Scaffold(body: Text(AppLocalizations.of(context).navSettings)),
          ),
        );

    await tester.pumpWidget(app(const Locale('en')));
    expect(find.text('Settings'), findsOneWidget);

    await tester.pumpWidget(app(const Locale('ru')));
    await tester.pumpAndSettle();
    expect(find.text('Настройки'), findsOneWidget);
  });

  testWidgets('an unsupported system language falls back to English rather '
      'than failing', (tester) async {
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('ja'),
      localizationsDelegates: [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      // Japanese is not in supportedLocales, so Flutter resolves to the first
      // supported one. The template language has to stay first for that to be
      // English.
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) =>
            Scaffold(body: Text(AppLocalizations.of(context).navSettings)),
      ),
    ));

    expect(find.text('Settings'), findsOneWidget);
  });
}

/// The strings with no placeholders, paired with how to read them. Kept by hand
/// because the generated class has no way to enumerate itself; a new string
/// belongs here.
final Map<String, String Function(AppLocalizations)> _plainStrings = {
  'navSync': (l) => l.navSync,
  'navFolders': (l) => l.navFolders,
  'navSettings': (l) => l.navSettings,
  'devicesTitle': (l) => l.devicesTitle,
  'lookingForDevices': (l) => l.lookingForDevices,
  'openOnOtherDevice': (l) => l.openOnOtherDevice,
  'syncHistoryTooltip': (l) => l.syncHistoryTooltip,
  'pairingTitle': (l) => l.pairingTitle,
  'accept': (l) => l.accept,
  'reject': (l) => l.reject,
  'confirmCodeOnOther': (l) => l.confirmCodeOnOther,
  'checkCodeMatches': (l) => l.checkCodeMatches,
  'contactingDevice': (l) => l.contactingDevice,
  'waitingForConfirmation': (l) => l.waitingForConfirmation,
  'sharedFoldersTitle': (l) => l.sharedFoldersTitle,
  'shareAFolder': (l) => l.shareAFolder,
  'noFoldersShared': (l) => l.noFoldersShared,
  'folderPickingUnavailable': (l) => l.folderPickingUnavailable,
  'chooseFolder': (l) => l.chooseFolder,
  'useThisFolder': (l) => l.useThisFolder,
  'newFolder': (l) => l.newFolder,
  'folderName': (l) => l.folderName,
  'create': (l) => l.create,
  'cancel': (l) => l.cancel,
  'noSubFolders': (l) => l.noSubFolders,
  'notSharingFolders': (l) => l.notSharingFolders,
  'storageAccessNeeded': (l) => l.storageAccessNeeded,
  'syncingTitle': (l) => l.syncingTitle,
  'nothingWrittenYet': (l) => l.nothingWrittenYet,
  'conflictsSubtitle': (l) => l.conflictsSubtitle,
  'mergedSubtitle': (l) => l.mergedSubtitle,
  'keepMine': (l) => l.keepMine,
  'takeMine': (l) => l.takeMine,
  'takeTheirs': (l) => l.takeTheirs,
  'undo': (l) => l.undo,
  'labelMine': (l) => l.labelMine,
  'labelTheirs': (l) => l.labelTheirs,
  'labelAdded': (l) => l.labelAdded,
  'labelRemoved': (l) => l.labelRemoved,
  'cannotBeMerged': (l) => l.cannotBeMerged,
  'cannotBeCompared': (l) => l.cannotBeCompared,
  'noLinePreview': (l) => l.noLinePreview,
  'guessedBaseNote': (l) => l.guessedBaseNote,
  'kindNewFile': (l) => l.kindNewFile,
  'kindUpdated': (l) => l.kindUpdated,
  'kindDeleted': (l) => l.kindDeleted,
  'kindMerged': (l) => l.kindMerged,
  'kindConflict': (l) => l.kindConflict,
  'folderCreatedHere': (l) => l.folderCreatedHere,
  'folderCreatedThere': (l) => l.folderCreatedThere,
  'folderRemovedHere': (l) => l.folderRemovedHere,
  'folderRemovedThere': (l) => l.folderRemovedThere,
  'historyTitle': (l) => l.historyTitle,
  'clearHistory': (l) => l.clearHistory,
  'nothingSyncedYet': (l) => l.nothingSyncedYet,
  'logNoChanges': (l) => l.logNoChanges,
  'settingsTitle': (l) => l.settingsTitle,
  'sectionAppearance': (l) => l.sectionAppearance,
  'colourScheme': (l) => l.colourScheme,
  'theme': (l) => l.theme,
  'themeSystem': (l) => l.themeSystem,
  'themeLight': (l) => l.themeLight,
  'themeDark': (l) => l.themeDark,
  'language': (l) => l.language,
  'languageSystem': (l) => l.languageSystem,
  'sectionSyncing': (l) => l.sectionSyncing,
  'plainSync': (l) => l.plainSync,
  'plainSyncSubtitle': (l) => l.plainSyncSubtitle,
  'sectionStartup': (l) => l.sectionStartup,
  'startAtLogin': (l) => l.startAtLogin,
  'startAtLoginSubtitle': (l) => l.startAtLoginSubtitle,
  'sectionAbout': (l) => l.sectionAbout,
  'noResult': (l) => l.noResult,
  'unknownAddress': (l) => l.unknownAddress,
};
