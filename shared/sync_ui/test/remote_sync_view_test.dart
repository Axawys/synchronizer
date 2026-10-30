import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sync_net/sync_net.dart';
import 'package:sync_ui/sync_ui.dart';

/// A sync started on another device plays here too: this device's folder is
/// being read and written, and its screen should not sit there as a list as if
/// nothing were happening.
void main() {
  const self = DeviceInfo(
      id: 'self', name: 'This one', platform: DevicePlatform.linux, port: 0);
  const phone = DeviceInfo(
      id: 'phone', name: 'Phone', platform: DevicePlatform.android, port: 0);
  const tablet = DeviceInfo(
      id: 'tablet', name: 'Tablet', platform: DevicePlatform.android, port: 0);
  const secret = 'shared';

  late PeerServer server;

  setUp(() {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() => server.stop());

  /// The device list, listening for real on a loopback port.
  Future<void> openList(WidgetTester tester) async {
    final trust = MemoryTrustStore();
    await trust.add(const TrustedPeer(
        id: 'phone',
        name: 'Phone',
        platform: DevicePlatform.android,
        secret: secret));
    server = PeerServer(self, trust, port: 0);
    await server.start();

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: DevicesPage(
        self: self,
        trust: trust,
        folders: SharedFolders(),
        discovery: DiscoveryService(self),
        server: server,
      ),
    ));
    await tester.pump();
  }

  /// The phone, starting a sync that has this device in it.
  Future<SyncAnnouncement?> phoneAnnounces(List<DeviceInfo> participants) =>
      SyncAnnouncement.open(
        '127.0.0.1',
        server.boundPort,
        self: phone,
        trusted: const TrustedPeer(
            id: 'self',
            name: 'This one',
            platform: DevicePlatform.linux,
            secret: secret),
        participants: participants,
      );

  Future<void> settle(WidgetTester tester, {int rounds = 40}) async {
    for (var i = 0; i < rounds; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      await tester.pump(const Duration(milliseconds: 25));
    }
  }

  testWidgets('a sync started on the other device plays here, and ends here',
      (tester) async {
    await tester.runAsync(() async {
      await openList(tester);
      expect(find.byType(SyncingDevices), findsNothing);

      final announcement = await phoneAnnounces([phone, self]);
      expect(announcement, isNotNull);
      await settle(tester, rounds: 10);

      // The same two squares the phone is showing, with the phone in them.
      expect(find.byType(SyncingDevices), findsOneWidget);
      expect(find.text('Phone'), findsOneWidget);
      expect(find.text('Syncing with Phone…'), findsOneWidget);

      // The phone is done: the squares unfold, and the list is back.
      await announcement!.close();
      await settle(tester);
      expect(find.byType(Fireworks), findsNothing);
      expect(find.byType(SyncingDevices), findsNothing);
      expect(find.byType(SelfCard), findsOneWidget);
    });
  });

  testWidgets('a sync that went through there ends in fireworks here too',
      (tester) async {
    await tester.runAsync(() async {
      await openList(tester);
      final announcement = await phoneAnnounces([phone, self]);
      await settle(tester, rounds: 10);

      await announcement!.close(succeeded: true);
      await settle(tester, rounds: 10);
      expect(find.byType(Fireworks), findsOneWidget);

      // The list waits for the last spark, as it does on the phone.
      await settle(tester, rounds: 100);
      expect(find.byType(Fireworks), findsNothing);
      expect(find.byType(SyncingDevices), findsNothing);
      expect(find.byType(SelfCard), findsOneWidget);
    });
  });

  testWidgets('a levelling run shows everyone in it', (tester) async {
    await tester.runAsync(() async {
      await openList(tester);

      final announcement = await phoneAnnounces([phone, self, tablet]);
      addTearDown(() => announcement?.close());
      await settle(tester, rounds: 10);

      expect(find.byType(SyncingDevices), findsOneWidget);
      expect(find.text('Phone'), findsOneWidget);
      expect(find.text('Tablet'), findsOneWidget);
      expect(find.text('Phone is bringing the devices into line…'),
          findsOneWidget);
      await announcement!.close();
      await settle(tester);
    });
  });
}
