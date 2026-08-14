import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_net/sync_net.dart';
import 'package:sync_ui/sync_ui.dart';

/// The screen for when discovery cannot help. It is two buttons and a code:
/// the person reading it is already stuck, and the parts a code is made of -
/// networks, addresses, passwords - are not theirs to assemble.
void main() {
  const self = DeviceInfo(
    id: 'self',
    name: 'This one',
    platform: DevicePlatform.linux,
    port: 47800,
  );

  Future<void> pump(
    WidgetTester tester, {
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
        // Reading real interfaces would make this test depend on the machine
        // it runs on.
        autoLoad: autoLoad,
      )),
    ));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('there is nothing to assemble by hand', (tester) async {
    await pump(tester, links: _FakeLinks(), server: null, autoLoad: true);

    // Every one of these was a control on this screen once, and every one of
    // them asks the user to understand how the connection is made.
    expect(find.text('By hand, without a camera'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Become a hotspot'), findsNothing);
    expect(find.text('Tethering settings'), findsNothing);
    expect(find.text('Join a Wi-Fi network'), findsNothing);
    expect(find.text("This device's addresses"), findsNothing);
  });

  testWidgets('the one thing no button can fix is still said', (tester) async {
    await pump(tester);

    // Mobile data alone cannot carry this, however many bars it shows. It is
    // the assumption people arrive with, and nothing on screen would tell them
    // otherwise.
    expect(
        find.textContaining('Mobile data on its own is not enough'),
        findsOneWidget);
  });

  testWidgets('showing a code puts one on screen with a token the server takes',
      (tester) async {
    final server = PeerServer(self, MemoryTrustStore(), port: 0);
    await server.start();
    addTearDown(server.stop);

    final links = _FakeLinks();
    await pump(tester, links: links, server: server, autoLoad: true);
    expect(find.text('Show a code'), findsOneWidget);

    // Reading this device's interfaces is real I/O, which only turns under
    // runAsync; the fake clock a widget test runs on will not deliver it.
    await tester.runAsync(() async {
      await tester.tap(find.text('Show a code'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    await tester.ensureVisible(find.byType(PairingQrCode, skipOffstage: false));
    await tester.pump();

    expect(find.byType(PairingQrCode), findsOneWidget);
    expect(server.qrToken, isNotNull, reason: 'the code is worth nothing '
        'unless the server will honour it');
    // The hotspot it raised is between the two devices: the code carries the
    // network and the key, and neither is anybody's to read or type.
    expect(links.started, 1);
    expect(find.text('SyncSpot-42'), findsNothing);
    expect(find.textContaining('hunter2hunter'), findsNothing);
    expect(find.textContaining(':47800'), findsNothing);
  });

  testWidgets('hiding the code takes the hotspot down with it', (tester) async {
    final server = PeerServer(self, MemoryTrustStore(), port: 0);
    await server.start();
    addTearDown(server.stop);

    final links = _FakeLinks();
    await pump(tester, links: links, server: server, autoLoad: true);
    await tester.runAsync(() async {
      await tester.tap(find.text('Show a code'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    await tester.ensureVisible(find.text('Hide the code', skipOffstage: false));
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.text('Hide the code'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();

    expect(find.byType(PairingQrCode), findsNothing);
    expect(server.qrToken, isNull,
        reason: 'a token nobody is watching for is a way in');
    // Nobody is coming to scan a code that is off screen, and the network was
    // only ever there to carry it.
    expect(links.stopped, isTrue);
  });

  testWidgets('a hotspot the system refuses is said, and the code goes up '
      'anyway', (tester) async {
    final server = PeerServer(self, MemoryTrustStore(), port: 0);
    await server.start();
    addTearDown(server.stop);

    await pump(tester,
        links: _FakeLinks(hotspot: null), server: server, autoLoad: true);
    await tester.runAsync(() async {
      await tester.tap(find.text('Show a code'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    expect(find.textContaining('Could not start a hotspot'), findsOneWidget);
    // Whatever network this device is already on may well be the one the other
    // device is on too.
    expect(find.byType(PairingQrCode, skipOffstage: false), findsOneWidget);
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

  testWidgets('a scan that is still going can be called off', (tester) async {
    const payload = QrPayload(
      name: 'Pixel 7',
      addresses: ['203.0.113.1'],
      port: 47800,
      token: 'deadbeef',
    );
    await pump(tester, scanner: _FakeScanner(payload.encode()), autoLoad: true);

    await tester.tap(find.text('Scan a code'));
    await tester.pump();
    await tester.pump();

    // Nothing answers at that address, and the attempt would otherwise sit out
    // its timeout with the buttons disabled.
    expect(find.text('Connecting…'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Connecting…'), findsNothing);
    expect(find.text('Scan a code'), findsOneWidget,
        reason: 'back to where it was');
  });

  testWidgets('without a camera only showing a code is offered',
      (tester) async {
    final server = PeerServer(self, MemoryTrustStore(), port: 0);
    await server.start();
    addTearDown(server.stop);

    await pump(tester, server: server, autoLoad: true);

    expect(find.text('Show a code'), findsOneWidget);
    expect(find.text('Scan a code'), findsNothing);
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
  int started = 0;
  bool stopped = false;
  String? joined;
  String? boundTo;
  bool vpn = false;

  @override
  Future<bool> canHostHotspot() async => true;

  @override
  Future<HotspotCredentials?> startHotspot() async {
    started++;
    return hotspot;
  }

  @override
  Future<void> stopHotspot() async => stopped = true;

  @override
  Future<bool> openTetheringSettings() async => true;

  @override
  Future<bool> openWifiSettings() async => true;

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
