import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sync_net/sync_net.dart';
import 'package:sync_ui/sync_ui.dart';

/// Tapping a paired device, from the list, with a real device answering at the
/// other end of a loopback socket.
///
/// The complaint this answers: a tap opened a screen with the device's name on
/// it, that screen played the animation and opened the answer on top of itself,
/// and coming back out of the answer landed in the named screen - which had
/// nothing in it and had to be left as well. The sync now happens on the list.
void main() {
  const self = DeviceInfo(
      id: 'self', name: 'This one', platform: DevicePlatform.linux, port: 0);
  const secret = 'shared';

  /// A port of our own, so a copy of the app running on this machine neither
  /// takes it nor turns up in the list.
  const discoveryPort = 48117;

  late Directory here;
  late Directory there;
  late Directory alsoThere;
  final servers = <PeerServer>[];
  late DiscoveryService discovery;
  RawDatagramSocket? announcer;

  setUp(() {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues({});
    here = Directory.systemTemp.createTempSync('here');
    there = Directory.systemTemp.createTempSync('there');
    alsoThere = Directory.systemTemp.createTempSync('also');
  });

  tearDown(() async {
    announcer?.close();
    announcer = null;
    await discovery.dispose();
    for (final server in servers) {
      await server.stop();
    }
    servers.clear();
    for (final dir in [here, there, alsoThere]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  /// Puts a device on the network the only way this screen believes in: an
  /// announcement it hears for itself. The port is the real one that device is
  /// listening on, so tapping its card reaches it.
  Future<void> announce(String id, String name, int port) async {
    announcer ??=
        await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    announcer!.send(
      utf8.encode(jsonEncode({
        'magic': 'synchronizer/1',
        'type': 'announce',
        'device': {
          'id': id,
          'name': name,
          'platform': 'android',
          'port': port,
        },
      })),
      InternetAddress.loopbackIPv4,
      discoveryPort,
    );
  }

  /// A device at the other end of a loopback socket, sharing [shared].
  Future<PeerServer> startPeer(
      String id, String name, Map<String, String> shared) async {
    final theirTrust = MemoryTrustStore();
    await theirTrust.add(const TrustedPeer(
        id: 'self',
        name: 'This one',
        platform: DevicePlatform.linux,
        secret: secret));
    final server = PeerServer(
      DeviceInfo(
          id: id, name: name, platform: DevicePlatform.android, port: 0),
      theirTrust,
      port: 0,
      directories: MapDirectorySource(shared),
    );
    await server.start();
    servers.add(server);
    return server;
  }

  /// The device list, with every [peers] entry paired, announced and answering.
  Future<void> openList(
    WidgetTester tester,
    Map<String, Map<String, String>> peers,
  ) async {
    final trust = MemoryTrustStore();
    final ports = <String, int>{};
    for (final entry in peers.entries) {
      final server = await startPeer(entry.key, entry.key, entry.value);
      ports[entry.key] = server.boundPort;
      await trust.add(TrustedPeer(
          id: entry.key,
          name: entry.key,
          platform: DevicePlatform.android,
          secret: secret));
    }

    discovery = DiscoveryService(
      self,
      config: const DiscoveryConfig(
        port: discoveryPort,
        announceInterval: Duration(milliseconds: 400),
        staleAfter: Duration(seconds: 30),
      ),
      // They are answering on real sockets; the knock is not what these are
      // about.
      probe: (_, _) async => true,
    );
    await discovery.start();

    final folders = SharedFolders();
    await folders.chooseAs('Obsidian', here.path);

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: DevicesPage(
        self: self,
        trust: trust,
        folders: folders,
        discovery: discovery,
        server: PeerServer(self, trust, port: 0),
      ),
    ));

    // Real sockets and a real disk, neither of which a widget test's clock
    // carries on its own.
    for (var i = 0; i < 30; i++) {
      for (final id in peers.keys) {
        await announce(id, id, ports[id]!);
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
      await tester.pump();
      if (peers.keys.every((id) => find.text(id).evaluate().isNotEmpty)) break;
    }
  }

  /// Lets the real work run while the animation's clock keeps ticking.
  Future<void> settle(WidgetTester tester, {int rounds = 40}) async {
    for (var i = 0; i < rounds; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      await tester.pump(const Duration(milliseconds: 25));
    }
  }

  testWidgets('the sync happens on the list, not on a screen of its own',
      (tester) async {
    await tester.runAsync(() async {
      await openList(tester, {'Tablet': {'Obsidian': there.path}});
      expect(find.text('Tablet'), findsOneWidget);

      await tester.tap(find.text('Tablet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // The waiting is here, on the screen the tap happened on: the title is
      // still the list's, and no room with the device's name on it opened.
      expect(find.byType(SyncingDevices), findsOneWidget);
      expect(find.text('Devices on this network'), findsOneWidget);
      expect(find.byType(DeviceCard), findsNothing);

      // Both sides hold the same nothing, so there is nothing to decide and
      // nothing to show for it: the squares unfold back into the two devices
      // and the list comes back on its own.
      await settle(tester);

      expect(find.byType(SyncingDevices), findsNothing);
      expect(find.byType(SyncFolderCard), findsNothing);
      expect(find.byType(DeviceCard), findsOneWidget);
      expect(find.textContaining('already in sync'), findsOneWidget);
    });
  });

  testWidgets('the device tapped is told about the sync, and about its end',
      (tester) async {
    await tester.runAsync(() async {
      await openList(tester, {'Tablet': {'Obsidian': there.path}});
      final heard = <RemoteSync>[];
      final sub = servers.single.remoteSyncs.listen(heard.add);
      addTearDown(sub.cancel);

      await tester.tap(find.text('Tablet'));
      await tester.pump();
      for (var i = 0; i < 20 && heard.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        await tester.pump(const Duration(milliseconds: 25));
      }

      // So it can play the same two squares, with the same two devices in it.
      expect(heard, hasLength(1));
      expect(heard.single.from.id, 'self');
      expect(heard.single.participants.map((d) => d.id), ['self', 'Tablet']);

      // Nothing to do, so it is over here - and there, at the same time.
      await settle(tester);
      expect(find.byType(DeviceCard), findsOneWidget);
      await heard.single.ended.timeout(const Duration(seconds: 5));
    });
  });

  testWidgets('every device in a levelling run is told it is in it',
      (tester) async {
    await tester.runAsync(() async {
      await openList(tester, {
        'Tablet': {'Obsidian': there.path},
        'Laptop': {'Obsidian': alsoThere.path},
      });
      final heard = <String, RemoteSync>{};
      for (final server in servers) {
        server.remoteSyncs.listen((sync) => heard[server.self.id] = sync);
      }

      await tester.tap(find.text('Tablet'));
      await settle(tester, rounds: 60);

      // Each of them sees all three: the run is one circuit, not two pairs.
      expect(heard.keys, unorderedEquals(['Tablet', 'Laptop']));
      for (final sync in heard.values) {
        expect(sync.participants.map((d) => d.id),
            unorderedEquals(['self', 'Tablet', 'Laptop']));
        await sync.ended.timeout(const Duration(seconds: 5));
      }
    });
  });

  testWidgets('backing out of the changes lands on the list', (tester) async {
    File('${there.path}/note.md').writeAsStringSync('written on the tablet\n');

    await tester.runAsync(() async {
      await openList(tester, {'Tablet': {'Obsidian': there.path}});
      await tester.tap(find.text('Tablet'));
      await settle(tester);

      // The one thing that opens is the answer: what would come across.
      expect(find.byType(MergePreviewPage), findsOneWidget);
      expect(find.textContaining('note.md'), findsWidgets);

      await tester.pageBack();
      await settle(tester);

      // And backing out of it is back to where the device was tapped, in one
      // step. It used to land in the screen the device's name was on.
      expect(find.byType(MergePreviewPage), findsNothing);
      expect(find.byType(SyncingDevices), findsNothing);
      expect(find.byType(DeviceCard), findsOneWidget);
    });
  });

  testWidgets('three devices level themselves on the list too', (tester) async {
    await tester.runAsync(() async {
      await openList(tester, {
        'Tablet': {'Obsidian': there.path},
        'Laptop': {'Obsidian': alsoThere.path},
      });
      expect(find.byType(DeviceCard), findsNWidgets(2));

      // Tapping any one of them is asking for all of them: the folder is the
      // same folder everywhere, and what matters is where each copy stands.
      await tester.tap(find.text('Tablet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Same wait, same picture, still on the list - three of them this time,
      // this device on the left and the other two rolling at it.
      expect(find.byType(SyncingDevices), findsOneWidget);
      expect(find.text('All paired devices'), findsOneWidget);
      expect(find.text('Tablet'), findsOneWidget);
      expect(find.text('Laptop'), findsOneWidget);
      // And no step in between: nothing was pressed to start the working-out.
      expect(find.text('See what will change'), findsNothing);

      await settle(tester, rounds: 60);

      // All three hold the same nothing, so it folds back into the list.
      expect(find.byType(SyncingDevices), findsNothing);
      expect(find.byType(DeviceCard), findsNWidgets(2));
      expect(find.textContaining('already holds the same copy'),
          findsOneWidget);
    });
  });

  testWidgets('with something to level, the answer is on the list as well',
      (tester) async {
    File('${there.path}/note.md').writeAsStringSync('written on the tablet\n');

    await tester.runAsync(() async {
      await openList(tester, {
        'Tablet': {'Obsidian': there.path},
        'Laptop': {'Obsidian': alsoThere.path},
      });
      await tester.tap(find.text('Laptop'));
      await settle(tester, rounds: 60);

      // The working-out happened by itself and what it found is here, on the
      // screen the tap happened on, with the way back in the bar above it.
      expect(find.byType(SyncingDevices), findsNothing);
      expect(find.byType(FolderAcrossDevices), findsWidgets);
      expect(find.byType(BackButton), findsOneWidget);

      // Everything the levelling screen had is here, down to the button that
      // starts the run.
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pump();
      expect(find.byType(DeviceChanges), findsWidgets);
      expect(find.text('Bring into line'), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await settle(tester, rounds: 20);

      expect(find.byType(DeviceCard), findsNWidgets(2));
      expect(find.byType(FolderAcrossDevices), findsNothing);
    });
  });

  testWidgets('a sync that carried something ends in fireworks',
      (tester) async {
    File('${there.path}/note.md').writeAsStringSync('written on the tablet\n');

    await tester.runAsync(() async {
      await openList(tester, {'Tablet': {'Obsidian': there.path}});
      final heard = <RemoteSync>[];
      final sub = servers.single.remoteSyncs.listen(heard.add);
      addTearDown(sub.cancel);

      await tester.tap(find.text('Tablet'));
      await settle(tester);

      expect(find.byType(MergePreviewPage), findsOneWidget);
      await tester.tap(find.byType(FloatingActionButton));
      await settle(tester, rounds: 30);

      // The tablet is told it went through, so it has its fireworks too.
      expect(heard, hasLength(1));
      await heard.single.ended.timeout(const Duration(seconds: 5));
      expect(heard.single.succeeded, isTrue);

      // Two devices that disagreed now hold the same thing, and somebody
      // waited through a network round of it. Three devices get fireworks for
      // exactly that, and two are not less of an occasion.
      expect(find.byType(Fireworks), findsOneWidget);
      expect(File('${here.path}/note.md').existsSync(), isTrue);

      // They see themselves out, and the screen waits for them before it goes.
      await settle(tester, rounds: 100);
      expect(find.byType(Fireworks), findsNothing);
      expect(find.byType(DeviceCard), findsOneWidget);
    });
  });

  testWidgets('a file changed in two places is laid out, text against text',
      (tester) async {
    File('${here.path}/note.md').writeAsStringSync('the desk version\n');
    File('${there.path}/note.md').writeAsStringSync('the train version\n');
    // An hour between them, so which one is "newest" is not down to the
    // second the test happened to run in.
    File('${here.path}/note.md').setLastModifiedSync(
        DateTime.now().subtract(const Duration(hours: 1)));

    await tester.runAsync(() async {
      await openList(tester, {
        'Tablet': {'Obsidian': there.path},
        'Laptop': {'Obsidian': alsoThere.path},
      });
      await tester.tap(find.text('Tablet'));
      await settle(tester, rounds: 80);

      // Down to the conflicts, which is where the run cannot decide alone.
      for (var i = 0; i < 6; i++) {
        if (find.textContaining('the train version').evaluate().isNotEmpty) {
          break;
        }
        await tester.drag(find.byType(ListView), const Offset(0, -240));
        await tester.pump();
      }

      // Both copies, as text: the question is which of these two is the
      // paragraph you wrote, and only the text answers it.
      expect(find.textContaining('the desk version'), findsOneWidget);
      expect(find.textContaining('the train version'), findsOneWidget);

      // One copy is already the starting point and says so; the other offers
      // to take its place, right under the text it stands for. The newest is
      // where it starts, which is the train.
      expect(find.text('Chosen'), findsOneWidget);
      expect(find.text('Apply this one'), findsOneWidget);
      double distance(Finder a, Finder b) =>
          (tester.getRect(a).center - tester.getRect(b).center).distance;
      final desk = find.textContaining('the desk version');
      final train = find.textContaining('the train version');
      expect(distance(find.text('Chosen'), train),
          lessThan(distance(find.text('Chosen'), desk)));

      await tester.ensureVisible(find.text('Apply this one'));
      await tester.pump();
      await tester.tap(find.text('Apply this one'));
      await tester.pump();

      // Pressed under the desk copy, it is the desk copy that is now kept.
      expect(distance(find.text('Chosen'), desk),
          lessThan(distance(find.text('Chosen'), train)));
    });
  });

  testWidgets('there is no list of devices to tick', (tester) async {
    await tester.runAsync(() async {
      await openList(tester, {
        'Tablet': {'Obsidian': there.path},
        'Laptop': {'Obsidian': alsoThere.path},
      });
      await tester.tap(find.text('Tablet'));
      await settle(tester, rounds: 60);

      // Every paired device present is in the run. A run that leaves one out
      // puts it a version behind without saying so, and the checkboxes only
      // ever offered that.
      expect(find.byType(CheckboxListTile), findsNothing);
    });
  });

  testWidgets('the copy picked in a conflict is the one all three end up with',
      (tester) async {
    await tester.runAsync(() async {
      // A line all three of them agreed on once, so what follows is a real
      // three-way conflict rather than three unrelated files.
      for (final dir in [here, there, alsoThere]) {
        File('${dir.path}/note.md').writeAsStringSync('the first line\n');
      }
      final base = await Manifest.scan(here);
      await BaseManifests.save('Tablet', 'Obsidian', base);
      await BaseManifests.save('Laptop', 'Obsidian', base);

      // Then the same line, changed differently on each of them.
      File('${here.path}/note.md').writeAsStringSync('the desk line\n');
      File('${there.path}/note.md').writeAsStringSync('the train line\n');
      File('${alsoThere.path}/note.md').writeAsStringSync('the bus line\n');
      // The newest is this device's own copy, so the one picked below is
      // deliberately not the one the screen starts on.
      final now = DateTime.now();
      File('${there.path}/note.md')
          .setLastModifiedSync(now.subtract(const Duration(hours: 2)));
      File('${alsoThere.path}/note.md')
          .setLastModifiedSync(now.subtract(const Duration(hours: 1)));

      await openList(tester, {
        'Tablet': {'Obsidian': there.path},
        'Laptop': {'Obsidian': alsoThere.path},
      });
      await tester.tap(find.text('Tablet'));
      await settle(tester, rounds: 80);

      // Down to the conflict, and keep the copy from the bus.
      for (var i = 0; i < 8; i++) {
        if (find.textContaining('the bus line').evaluate().isNotEmpty) break;
        await tester.drag(find.byType(ListView), const Offset(0, -240));
        await tester.pump();
      }
      expect(find.textContaining('the bus line'), findsOneWidget);

      final bus = tester.getRect(find.textContaining('the bus line')).center;
      final buttons = find.text('Apply this one');
      var nearest = 0;
      var best = double.infinity;
      for (var i = 0; i < buttons.evaluate().length; i++) {
        final away = (tester.getRect(buttons.at(i)).center - bus).distance;
        if (away < best) {
          best = away;
          nearest = i;
        }
      }
      await tester.ensureVisible(buttons.at(nearest));
      await tester.pump();
      await tester.tap(buttons.at(nearest));
      await tester.pump();

      // And run it.
      for (var i = 0; i < 8; i++) {
        if (find.text('Bring into line').evaluate().isNotEmpty) break;
        await tester.drag(find.byType(ListView), const Offset(0, -240));
        await tester.pump();
      }
      await tester.ensureVisible(find.text('Bring into line'));
      await tester.pump();
      await tester.tap(find.text('Bring into line'));
      await settle(tester, rounds: 160);

      // All three hold the line that was picked. The one that was chosen is
      // the whole of what the screen was for.
      expect(File('${here.path}/note.md').readAsStringSync(),
          contains('the bus line'));
      expect(File('${there.path}/note.md').readAsStringSync(),
          contains('the bus line'));
      expect(File('${alsoThere.path}/note.md').readAsStringSync(),
          contains('the bus line'));
    });
  });

  testWidgets('edits in different places are combined, not put to a vote',
      (tester) async {
    await tester.runAsync(() async {
      // One file, three lines, agreed on by everybody.
      const start = 'first line\nsecond line\nthird line\n';
      for (final dir in [here, there, alsoThere]) {
        File('${dir.path}/note.md').writeAsStringSync(start);
      }
      final base = await Manifest.scan(here);
      await BaseManifests.save('Tablet', 'Obsidian', base);
      await BaseManifests.save('Laptop', 'Obsidian', base);
      // The text of that agreement too, which is what a merge needs to tell
      // "one side changed this" from "both did". A real sync leaves it behind;
      // a test has to put it there.
      await refreshBaseStore(here, base);

      // Two devices, two different lines: nobody disagreed about anything.
      File('${here.path}/note.md')
          .writeAsStringSync('first line\nsecond line\nthird line, longer\n');
      File('${there.path}/note.md')
          .writeAsStringSync('first line, longer\nsecond line\nthird line\n');

      await openList(tester, {
        'Tablet': {'Obsidian': there.path},
        'Laptop': {'Obsidian': alsoThere.path},
      });
      await tester.tap(find.text('Tablet'));
      await settle(tester, rounds: 80);

      // Not a question, so it is not asked: there is nothing to pick between.
      for (var i = 0; i < 8; i++) {
        if (find.text('Bring into line').evaluate().isNotEmpty) break;
        await tester.drag(find.byType(ListView), const Offset(0, -240));
        await tester.pump();
      }
      expect(find.byType(ConflictAcrossDevices), findsNothing);
      expect(find.text('Apply this one'), findsNothing);

      await tester.ensureVisible(find.text('Bring into line'));
      await tester.pump();
      await tester.tap(find.text('Bring into line'));
      await settle(tester, rounds: 160);

      // Both edits survive, everywhere.
      for (final dir in [here, there, alsoThere]) {
        final text = File('${dir.path}/note.md').readAsStringSync();
        expect(text, contains('first line, longer'), reason: dir.path);
        expect(text, contains('third line, longer'), reason: dir.path);
      }
    });
  });
}
