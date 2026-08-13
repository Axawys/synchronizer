import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sync_net/sync_net.dart';
import 'package:sync_ui/sync_ui.dart';

/// The list is a list of things that can be done right now: every row is a
/// device on the network, and a device that is not there is not a row.
void main() {
  const self = DeviceInfo(
    id: 'self',
    name: 'This one',
    platform: DevicePlatform.linux,
    port: 47800,
  );

  Future<TrustStore> trustWith(String name) async {
    final trust = MemoryTrustStore();
    await trust.add(TrustedPeer(
      id: 'phone',
      name: name,
      platform: DevicePlatform.android,
      secret: 'sh',
    ));
    return trust;
  }

  Future<void> pumpDevices(WidgetTester tester, TrustStore trust) async {
    // The networking is built but never started: the point is what the screen
    // makes of what it knows, and a widget test has no business opening
    // sockets.
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: DevicesPage(
        self: self,
        trust: trust,
        folders: SharedFolders(),
        discovery: DiscoveryService(self),
        server: PeerServer(self, trust, port: self.port),
      ),
    ));
    // Twice: the first frame builds the screen, the second shows what reading
    // the trust store turned up.
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a paired device that is not on the network is not listed',
      (tester) async {
    await pumpDevices(tester, await trustWith('Calm Otter'));

    // Being paired is not being reachable, and a row that cannot be tapped to
    // any effect is worse than no row.
    expect(find.text('Calm Otter'), findsNothing);
    expect(find.byType(DeviceCard), findsNothing);
    expect(find.text('Looking for devices…'), findsOneWidget);
  });

  testWidgets('while it is still looking there is nothing to press',
      (tester) async {
    await pumpDevices(tester, MemoryTrustStore());

    expect(find.text('Looking for devices…'), findsOneWidget);
    // The answer is a second away; a button here would only invite pressing it.
    expect(find.text('Search again'), findsNothing);
    expect(find.text('No devices found.'), findsNothing);
  });

  testWidgets('when the wait runs out, the way to look again appears',
      (tester) async {
    await pumpDevices(tester, MemoryTrustStore());

    await tester.pump(const Duration(seconds: 13));

    expect(find.text('No devices found.'), findsOneWidget);
    expect(find.text('Looking for devices…'), findsNothing);
    expect(find.text('Search again'), findsOneWidget);
  });

  testWidgets('this device is on the list, with the folder it syncs',
      (tester) async {
    await pumpDevices(tester, MemoryTrustStore());

    // The device you are holding used to be the one thing the screen did not
    // show - and the folder it brings to every sync lived behind a tab.
    expect(find.text('This one'), findsOneWidget);
    expect(find.text('This device'), findsOneWidget);
    expect(find.text('No folder chosen yet'), findsOneWidget);
  });

  testWidgets('this device shows what its folder weighs, not just where it is',
      (tester) async {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues({});
    final vault = Directory.systemTemp.createTempSync('vault');
    addTearDown(() => vault.deleteSync(recursive: true));
    File('${vault.path}/note.md').writeAsStringSync('a' * 4200);

    final folders = SharedFolders();
    await folders.chooseAs('Obsidian', vault.path);

    // Walking a folder is real disk work, which a widget test's fake clock
    // does not carry on its own.
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: DevicesPage(
          self: self,
          trust: MemoryTrustStore(),
          folders: folders,
          discovery: DiscoveryService(self),
          server: PeerServer(self, MemoryTrustStore(), port: self.port),
        ),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();

    // The path says which folder is being synced; the weight says whether it
    // is the one with the vault in it.
    expect(find.text(' · 4.2 kB'), findsOneWidget);
  });

  testWidgets('this device can be renamed from its own card', (tester) async {
    String? renamedTo;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: DevicesPage(
        self: self,
        trust: MemoryTrustStore(),
        folders: SharedFolders(),
        discovery: DiscoveryService(self),
        server: PeerServer(self, MemoryTrustStore(), port: self.port),
        onRename: (name) async => renamedTo = name,
      ),
    ));
    await tester.pump();
    await tester.pump();

    await tester.longPress(find.text('This one'));
    await tester.pumpAndSettle();

    expect(find.text('Device name'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Study laptop');
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    // The name is what every other device shows for this one, so it is saved
    // rather than kept on screen.
    expect(renamedTo, 'Study laptop');
    expect(find.textContaining('Now called Study laptop'), findsOneWidget);
  });

  testWidgets('a VPN is named as the likely reason nothing is found',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SearchingPanel(
          timedOut: false,
          onRefresh: () async {},
          vpn: true,
          bypassed: true,
        ),
      ),
    ));
    await tester.pump();

    // It is the likeliest reason an empty screen stays empty, and the one
    // thing the user cannot see from anywhere else in the app.
    expect(find.textContaining('VPN'), findsOneWidget);
  });

  testWidgets('the device list is only the device list now', (tester) async {
    await pumpDevices(tester, MemoryTrustStore());

    // Direct used to be a switch on this screen. It is a tab of its own: a way
    // of reaching a device is not a mode of the list.
    expect(find.text('Local network'), findsNothing);
    expect(find.text('How to connect'), findsNothing);
  });
}
