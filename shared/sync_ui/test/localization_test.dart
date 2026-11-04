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

    expect(ru.pairedWith('Pixel'), contains('Pixel'));
    expect(ru.reviewFolder('Obsidian'), contains('Obsidian'));
    expect(ru.goingTo('Pixel'), contains('Pixel'));
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
  'navSettings': (l) => l.navSettings,
  'thisDeviceCard': (l) => l.thisDeviceCard,
  'notPairedGroup': (l) => l.notPairedGroup,
  'pairedGroup': (l) => l.pairedGroup,
  'allPairedDevices': (l) => l.allPairedDevices,
  'folderHereMissing': (l) => l.folderHereMissing,
  'folderNotOffered': (l) => l.folderNotOffered,
  'chooseFolderHere': (l) => l.chooseFolderHere,
  'levelThisFolder': (l) => l.levelThisFolder,
  'gatheringFolders': (l) => l.gatheringFolders,
  'devicesTitle': (l) => l.devicesTitle,
  'lookingForDevices': (l) => l.lookingForDevices,
  'openOnOtherDevice': (l) => l.openOnOtherDevice,
  'noDevicesFound': (l) => l.noDevicesFound,
  'syncHistoryTooltip': (l) => l.syncHistoryTooltip,
  'searchAgain': (l) => l.searchAgain,
  'pairedLabel': (l) => l.pairedLabel,
  'notPairedLabel': (l) => l.notPairedLabel,
  'networkSearchFailed': (l) => l.networkSearchFailed,
  'networkSearchFailedHint': (l) => l.networkSearchFailedHint,
  'tryAgain': (l) => l.tryAgain,
  'forgetDevice': (l) => l.forgetDevice,
  'forget': (l) => l.forget,
  'directModeLocal': (l) => l.directModeLocal,
  'directModeDirect': (l) => l.directModeDirect,
  'hotspotStarting': (l) => l.hotspotStarting,
  'hotspotFailed': (l) => l.hotspotFailed,
  'vpnInTheWay': (l) => l.vpnInTheWay,
  'vpnBypassed': (l) => l.vpnBypassed,
  'cameraNeeded': (l) => l.cameraNeeded,
  'cameraDenied': (l) => l.cameraDenied,
  'cameraSettings': (l) => l.cameraSettings,
  'cameraStarting': (l) => l.cameraStarting,
  'qrScan': (l) => l.qrScan,
  'qrShow': (l) => l.qrShow,
  'qrHide': (l) => l.qrHide,
  'qrExplain': (l) => l.qrExplain,
  'qrExplainNoCamera': (l) => l.qrExplainNoCamera,
  'qrKeepOnScreen': (l) => l.qrKeepOnScreen,
  'qrScanTitle': (l) => l.qrScanTitle,
  'qrScanHint': (l) => l.qrScanHint,
  'qrNotOurs': (l) => l.qrNotOurs,
  'directConnect': (l) => l.directConnect,
  'directConnectSubtitle': (l) => l.directConnectSubtitle,
  'directConnecting': (l) => l.directConnecting,
  'directHowTo': (l) => l.directHowTo,
  'reconnect': (l) => l.reconnect,
  'pairingTitle': (l) => l.pairingTitle,
  'accept': (l) => l.accept,
  'reject': (l) => l.reject,
  'confirmCodeOnOther': (l) => l.confirmCodeOnOther,
  'checkCodeMatches': (l) => l.checkCodeMatches,
  'contactingDevice': (l) => l.contactingDevice,
  'connectCancel': (l) => l.connectCancel,
  'waitingForConfirmation': (l) => l.waitingForConfirmation,
  'folderAskedChoose': (l) => l.folderAskedChoose,
  'folderAskedLater': (l) => l.folderAskedLater,
  'deviceName': (l) => l.deviceName,
  'deviceNameHint': (l) => l.deviceNameHint,
  'deviceNameSave': (l) => l.deviceNameSave,
  'syncFolderTitle': (l) => l.syncFolderTitle,
  'syncFolderNone': (l) => l.syncFolderNone,
  'syncFolderChoose': (l) => l.syncFolderChoose,
  'syncFolderReplace': (l) => l.syncFolderReplace,
  'syncFolderOne': (l) => l.syncFolderOne,
  'syncFolderNoneBody': (l) => l.syncFolderNoneBody,
  'obsidianFoundBody': (l) => l.obsidianFoundBody,
  'obsidianUse': (l) => l.obsidianUse,
  'obsidianPickOther': (l) => l.obsidianPickOther,
  'storageWhyAll': (l) => l.storageWhyAll,
  'folderPickingUnavailable': (l) => l.folderPickingUnavailable,
  'chooseFolder': (l) => l.chooseFolder,
  'changeFolder': (l) => l.changeFolder,
  'folderNotChosenYet': (l) => l.folderNotChosenYet,
  'folderGoneTitle': (l) => l.folderGoneTitle,
  'useThisFolder': (l) => l.useThisFolder,
  'newFolder': (l) => l.newFolder,
  'folderName': (l) => l.folderName,
  'create': (l) => l.create,
  'cancel': (l) => l.cancel,
  'noSubFolders': (l) => l.noSubFolders,
  'notSharingFolders': (l) => l.notSharingFolders,
  'storageAccessNeeded': (l) => l.storageAccessNeeded,
  'levelNeedsFolder': (l) => l.levelNeedsFolder,
  'levelCheckingFolders': (l) => l.levelCheckingFolders,
  'levelCancel': (l) => l.levelCancel,
  'conflictSideHere': (l) => l.conflictSideHere,
  'conflictMissing': (l) => l.conflictMissing,
  'conflictRememberDevice': (l) => l.conflictRememberDevice,
  'bringInLine': (l) => l.bringInLine,
  'bringInLineSubtitle': (l) => l.bringInLineSubtitle,
  'chooseFolderToLevel': (l) => l.chooseFolderToLevel,
  'levelPreview': (l) => l.levelPreview,
  'levelPreviewing': (l) => l.levelPreviewing,
  'levelNothingToDo': (l) => l.levelNothingToDo,
  'changeComesHere': (l) => l.changeComesHere,
  'changeGoesThere': (l) => l.changeGoesThere,
  'changeDeletedThere': (l) => l.changeDeletedThere,
  'changeConflict': (l) => l.changeConflict,
  'levelAllSame': (l) => l.levelAllSame,
  'levelDecideFirst': (l) => l.levelDecideFirst,
  'conflictsAcross': (l) => l.conflictsAcross,
  'conflictsAcrossBody': (l) => l.conflictsAcrossBody,
  'variantSameAsHere': (l) => l.variantSameAsHere,
  'variantNewest': (l) => l.variantNewest,
  'conflictApply': (l) => l.conflictApply,
  'conflictChosen': (l) => l.conflictChosen,
  'conflictNotText': (l) => l.conflictNotText,
  'conflictCouldNotRead': (l) => l.conflictCouldNotRead,
  'conflictDeletedHere': (l) => l.conflictDeletedHere,
  'levelStart': (l) => l.levelStart,
  'levelWaiting': (l) => l.levelWaiting,
  'levelWorking': (l) => l.levelWorking,
  'levelSkipped': (l) => l.levelSkipped,
  'levelAllDone': (l) => l.levelAllDone,
  'levelNoFolders': (l) => l.levelNoFolders,
  'levelPlainNote': (l) => l.levelPlainNote,
  'sizeEmpty': (l) => l.sizeEmpty,
  'folderMissingThere': (l) => l.folderMissingThere,
  'syncAsking': (l) => l.syncAsking,
  'syncComparing': (l) => l.syncComparing,
  'syncingTitle': (l) => l.syncingTitle,
  'deletionsWarningBody': (l) => l.deletionsWarningBody,
  'nothingWrittenYet': (l) => l.nothingWrittenYet,
  'conflictsSubtitle': (l) => l.conflictsSubtitle,
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
  'kindMerged': (l) => l.kindMerged,
  'comingHere': (l) => l.comingHere,
  'groupDeleted': (l) => l.groupDeleted,
  'groupChanged': (l) => l.groupChanged,
  'groupNew': (l) => l.groupNew,
  'nothingForDevice': (l) => l.nothingForDevice,
  'reviewModeChanges': (l) => l.reviewModeChanges,
  'reviewModeTree': (l) => l.reviewModeTree,
  'treeCaption': (l) => l.treeCaption,
  'treeEmpty': (l) => l.treeEmpty,
  'treeToHere': (l) => l.treeToHere,
  'kindConflict': (l) => l.kindConflict,
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
