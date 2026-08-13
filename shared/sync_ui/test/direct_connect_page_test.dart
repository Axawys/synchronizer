import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_net/sync_net.dart';
import 'package:sync_ui/sync_ui.dart';

/// The screen for when discovery cannot help. It has to be understandable
/// without any of it working: the person reading it is already stuck.
void main() {
  const self = DeviceInfo(
    id: 'self',
    name: 'This one',
    platform: DevicePlatform.linux,
    port: 47800,
  );

  Future<void> pump(
    WidgetTester tester, {
    DirectRole? role,
    DirectLinkControls? links,
    QrScanner? scanner,
    PeerServer? server,
    bool autoLoad = false,
  }) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
          body: DirectConnectPanel(
        self: self,
        trust: MemoryTrustStore(),
        links: links,
        scanner: scanner,
        server: server,
        initialRole: role ?? DirectRole.receive,
        // Reading real interfaces would make this test depend on the machine
        // it runs on.
        autoLoad: autoLoad,
      )),
    ));
    await tester.pump();
    await tester.pump();
  }

  /// The address field and the two roles now live behind the "by hand" tile:
  /// the camera is the way in, and typing is the fallback under it.
  Future<void> expandManual(WidgetTester tester) async {
    await tester.tap(find.text('By hand, without a camera'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('the waiting end explains itself and says it is waiting',
      (tester) async {
    await pump(tester);
    await expandManual(tester);

    expect(find.text("This device's addresses"), findsOneWidget);
    expect(find.text('Waiting for the other device to connect…'), findsOneWidget);
  });

  testWidgets('either end can be chosen', (tester) async {
    await pump(tester);
    await expandManual(tester);
    expect(find.text('Address'), findsNothing);

    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    expect(find.text('Address'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
  });

  testWidgets('what to do with no shared network is on the screen',
      (tester) async {
    await pump(tester);

    // The whole reason someone opens this screen, so it is not hidden behind
    // the mode that happens to be selected: what to do to make a link, and the
    // one thing no button here can fix.
    expect(find.textContaining('turn on USB tethering'), findsOneWidget);
    expect(
        find.textContaining('Mobile data on its own is not enough'),
        findsOneWidget);
  });

  testWidgets('nonsense in the address field is refused before dialling',
      (tester) async {
    await pump(tester, role: DirectRole.send);
    await expandManual(tester);

    await tester.enterText(find.byType(TextField), '10.0.0.4:not-a-port');
    await tester.tap(find.text('Connect'));
    await tester.pump();

    expect(
        find.textContaining('Expected something like 192.168.43.1:47800'),
        findsOneWidget);
  });

  testWidgets('an empty address is refused too', (tester) async {
    await pump(tester, role: DirectRole.send);
    await expandManual(tester);

    await tester.tap(find.text('Connect'));
    await tester.pump();

    expect(find.textContaining('That is not an address'), findsOneWidget);
  });

  testWidgets('a platform that can host one offers to become a hotspot',
      (tester) async {
    final links = _FakeLinks();
    await pump(tester, links: links, autoLoad: true);

    expect(find.text('Become a hotspot'), findsOneWidget);

    await tester.tap(find.text('Become a hotspot'));
    await tester.pump();
    await tester.pump();

    // The name and password are the system's to choose; the screen's job is to
    // put them where they can be read out to the other device.
    expect(find.textContaining('Join this network'), findsOneWidget);
    expect(find.text('SyncSpot-42'), findsOneWidget);
    expect(find.text('Password: hunter2hunter'), findsOneWidget);
    expect(find.text('Stop the hotspot'), findsOneWidget);
  });

  testWidgets('a hotspot the system refuses is said so, not hidden',
      (tester) async {
    final links = _FakeLinks(hotspot: null);
    await pump(tester, links: links, autoLoad: true);

    await tester.tap(find.text('Become a hotspot'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('Could not start a hotspot'), findsOneWidget);
  });

  testWidgets('the system screens for tethering and Wi-Fi can be opened',
      (tester) async {
    final links = _FakeLinks();
    await pump(tester, links: links, autoLoad: true);

    await tester.tap(find.text('Tethering settings'));
    await tester.pump();
    expect(links.openedTethering, 1);

    await tester.tap(find.text('Join a Wi-Fi network'));
    await tester.pump();
    expect(links.openedWifi, 1);
  });

  testWidgets('showing a code puts one on screen with a token the server takes',
      (tester) async {
    final server = PeerServer(self, MemoryTrustStore(), port: 0);
    await server.start();
    addTearDown(server.stop);

    await pump(tester, links: _FakeLinks(), server: server, autoLoad: true);
    expect(find.text('Show a code'), findsOneWidget);

    // Reading this device's interfaces is real I/O, which only turns under
    // runAsync; the fake clock a widget test runs on will not deliver it.
    await tester.runAsync(() async {
      await tester.tap(find.text('Show a code'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    // Wherever it lands on a test-sized window, bring it into view the way a
    // user scrolling would.
    await tester.ensureVisible(find.byType(PairingQrCode, skipOffstage: false));
    await tester.pump();

    expect(find.byType(PairingQrCode), findsOneWidget);
    expect(server.qrToken, isNotNull, reason: 'the code is worth nothing '
        'unless the server will honour it');
    // The hotspot it raised is named on screen - twice over, in fact: once by
    // the panel that started it and once under the code, for the device whose
    // camera cannot read it.
    expect(find.text('SyncSpot-42'), findsWidgets);

    await tester.ensureVisible(find.text('Hide the code', skipOffstage: false));
    await tester.pump();
    await tester.tap(find.text('Hide the code'));
    await tester.pump();

    expect(find.byType(PairingQrCode), findsNothing);
    expect(server.qrToken, isNull,
        reason: 'a token nobody is watching for is a way in');
  });

  testWidgets('a code that is not ours is refused rather than dialled',
      (tester) async {
    final scanner = _FakeScanner('https://example.com/not-a-pairing');
    await pump(tester, scanner: scanner, autoLoad: true);

    await tester.tap(find.text('Scan a code'));
    await tester.pump();
    await tester.pump();

    expect(scanner.scans, 1);
    expect(find.text('That is not a Synchronizer code.'), findsOneWidget);
  });

  testWidgets('a scanned code joins the network it names', (tester) async {
    final links = _FakeLinks();
    const payload = QrPayload(
      name: 'Pixel 7',
      addresses: ['192.168.49.1'],
      port: 47800,
      token: 'deadbeef',
      wifiSsid: 'SyncSpot-42',
      wifiPassphrase: 'hunter2hunter',
    );
    final scanner = _FakeScanner(payload.encode());

    await pump(tester, links: links, scanner: scanner, autoLoad: true);
    await tester.tap(find.text('Scan a code'));
    await tester.pump();
    await tester.pump();

    // Joining comes first: the address in the code is on a network this device
    // is not on yet.
    expect(links.joined, 'SyncSpot-42');

    // Nothing is listening at that address in a test, so it ends where it
    // should: saying so, rather than sitting there.
    await tester.pump(const Duration(seconds: 7));
    await tester.pump();
    expect(find.textContaining('could not be reached'), findsOneWidget);
  });

  testWidgets('without a camera only showing a code is offered', (tester) async {
    final server = PeerServer(self, MemoryTrustStore(), port: 0);
    await server.start();
    addTearDown(server.stop);

    await pump(tester, server: server, autoLoad: true);

    expect(find.text('Show a code'), findsOneWidget);
    expect(find.text('Scan a code'), findsNothing);
  });

  testWidgets('a connection that is still being made can be called off',
      (tester) async {
    await pump(tester, role: DirectRole.send);
    await expandManual(tester);

    await tester.enterText(find.byType(TextField), '203.0.113.1:47800');
    await tester.tap(find.text('Connect'));
    await tester.pump();

    // Nothing answers at that address, and the attempt would otherwise sit out
    // its timeout with the screen locked.
    expect(find.text('Connecting…'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Connect'), findsOneWidget, reason: 'back to where it was');
  });

  testWidgets('with no link there is nothing to sweep', (tester) async {
    // Finding the device on the link is only offered where there is a link
    // that is two devices; sweeping an office network is not on the table.
    await pump(tester, role: DirectRole.send);
    await expandManual(tester);

    expect(find.text('Find the device on this link'), findsNothing);
    expect(find.text('Address'), findsOneWidget);
  });
}

/// Stands in for the platform: says yes to everything and remembers being
/// asked.
class _FakeLinks implements DirectLinkControls {
  _FakeLinks({
    this.hotspot = const HotspotCredentials(
      ssid: 'SyncSpot-42',
      passphrase: 'hunter2hunter',
    ),
  });

  final HotspotCredentials? hotspot;
  int openedTethering = 0;
  int openedWifi = 0;
  bool stopped = false;
  String? joined;
  String? boundTo;
  bool vpn = false;

  @override
  Future<bool> canHostHotspot() async => true;

  @override
  Future<HotspotCredentials?> startHotspot() async => hotspot;

  @override
  Future<void> stopHotspot() async => stopped = true;

  @override
  Future<bool> openTetheringSettings() async {
    openedTethering++;
    return true;
  }

  @override
  Future<bool> openWifiSettings() async {
    openedWifi++;
    return true;
  }

  @override
  Future<bool> joinWifi(String ssid, String passphrase) async {
    joined = ssid;
    return true;
  }

  @override
  Future<void> leaveWifi() async => joined = null;

  @override
  Future<String?> bindToLocalNetwork() async => boundTo = 'wifi';

  @override
  Future<void> releaseNetwork() async => boundTo = null;

  @override
  Future<bool> vpnActive() async => vpn;
}

/// A camera that always reads the same code, so the flow after a scan can be
/// tested without one.
class _FakeScanner implements QrScanner {
  _FakeScanner(this.code);

  final String? code;
  int scans = 0;

  @override
  Future<String?> scan(BuildContext context) async {
    scans++;
    return code;
  }
}
