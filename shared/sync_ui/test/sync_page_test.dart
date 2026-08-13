import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sync_net/sync_net.dart';
import 'package:sync_ui/sync_ui.dart';

/// The sync screen against a real device at the other end of a loopback
/// socket, because the two complaints it answers are about the whole trip: a
/// folder already chosen on both devices being asked for a third time, and a
/// tapped device opening a list of one folder to be tapped again.
void main() {
  const self = DeviceInfo(
      id: 'self', name: 'This one', platform: DevicePlatform.linux, port: 0);
  const peerInfo = DeviceInfo(
      id: 'peer', name: 'Tablet', platform: DevicePlatform.android, port: 0);
  const secret = 'shared';
  const tablet = TrustedPeer(
      id: 'peer',
      name: 'Tablet',
      platform: DevicePlatform.android,
      secret: secret);

  late Directory here;
  late Directory there;
  late PeerServer server;

  setUp(() {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues({});
    here = Directory.systemTemp.createTempSync('here');
    there = Directory.systemTemp.createTempSync('there');
  });

  tearDown(() async {
    await server.stop();
    for (final dir in [here, there]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  /// A device on the other end, sharing [shared].
  Future<DeviceInfo> startPeer(Map<String, String> shared) async {
    final trust = MemoryTrustStore();
    await trust.add(const TrustedPeer(
        id: 'self',
        name: 'This one',
        platform: DevicePlatform.linux,
        secret: secret));
    server = PeerServer(peerInfo, trust,
        port: 0, directories: MapDirectorySource(shared));
    await server.start();

    return DeviceInfo(
      id: 'peer',
      name: 'Tablet',
      platform: DevicePlatform.android,
      port: server.boundPort,
      address: '127.0.0.1',
    );
  }

  /// Puts the screen up and lets the real sockets and the real disk get on
  /// with it: a widget test's clock does not carry either.
  Future<void> open(
    WidgetTester tester, {
    required DeviceInfo device,
    required SharedFolders folders,
    required bool autoSync,
  }) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SyncPage(
          self: self,
          trusted: tablet,
          device: device,
          folders: folders,
          autoSync: autoSync,
        ),
      ));
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        await tester.pump();
      }
    });
    // The route the screen pushed on its own, animated into place.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Takes the screen down with the real clock running: the session it closes
  /// on the way out waits a moment on the flush, and that wait would otherwise
  /// be left pending in the test's clock.
  Future<void> shut(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
  }

  testWidgets('one folder starts syncing on its own, and asks for nothing',
      (tester) async {
    File('${there.path}/note.md').writeAsStringSync('written on the tablet\n');
    final device = await startPeer({'Obsidian': there.path});

    final folders = SharedFolders();
    await folders.chooseAs('Obsidian', here.path);

    await open(tester, device: device, folders: folders, autoSync: true);

    // Nothing was tapped: the tap that opened this screen was the request.
    expect(find.byType(MergePreviewPage), findsOneWidget);
    expect(find.textContaining('note.md'), findsWidgets);
    // And the folder chosen on this device was used as it stands. Had it been
    // asked for again, no chooser would have answered here and the screen
    // would still be showing the folder list.
    expect(await SyncTargets.localPath('peer', 'Obsidian'), here.path);

    await shut(tester);
  });

  testWidgets('with more than one folder there is a choice, so nothing starts',
      (tester) async {
    final photos = Directory('${there.path}/photos')..createSync();
    final notes = Directory('${there.path}/notes')..createSync();
    File('${notes.path}/note.md').writeAsStringSync('one\n');
    final device =
        await startPeer({'notes': notes.path, 'photos': photos.path});

    final folders = SharedFolders();
    await folders.chooseAs('notes', here.path);

    await open(tester, device: device, folders: folders, autoSync: true);

    expect(find.byType(MergePreviewPage), findsNothing);
    expect(find.byType(SyncFolderCard), findsNWidgets(2));

    await shut(tester);
  });
}
