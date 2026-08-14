import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_net/sync_net.dart';
import 'package:sync_ui/sync_ui.dart';

/// What the screen does between a tap on a device and an answer: the two of
/// them fold down into squares and roll at each other.
///
/// The order is the point. It went off all at once to begin with - text
/// fading while cards shrank while squares slid - which reads as a glitch, not
/// as a transition. So these check the steps happen one after another, and that
/// the last one hands over to the rolling square without a jump.
void main() {
  const self = DeviceInfo(
      id: 'self',
      name: 'This one',
      platform: DevicePlatform.linux,
      port: 47800);
  const peer = DeviceInfo(
      id: 'phone',
      name: 'Calm Otter',
      platform: DevicePlatform.android,
      port: 47800,
      address: '192.168.1.5');

  Future<void> pump(
    WidgetTester tester, {
    VoidCallback? onCancel,
    bool reduceMotion = false,
    bool unfold = false,
    VoidCallback? onUnfolded,
  }) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Scaffold(
          body: SyncingDevices(
            self: self,
            peers: const [peer],
            caption: 'Working out the changes…',
            onCancel: onCancel,
            unfold: unfold,
            onUnfolded: onUnfolded,
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  Rect shape(WidgetTester tester, Key key) => tester.getRect(find.byKey(key));

  testWidgets('it opens as the two devices, as the list had them',
      (tester) async {
    await pump(tester);

    // Whatever was tapped a moment ago is still on screen: same cards, same
    // names, same second lines. Nothing has moved yet.
    expect(find.text('This one'), findsOneWidget);
    expect(find.text('Calm Otter'), findsOneWidget);
    expect(find.text('This device'), findsOneWidget);
    expect(find.text('Paired'), findsOneWidget);
    expect(find.byType(RollingSquare), findsNothing);
    expect(shape(tester, SyncingDevices.selfShape).width, greaterThan(300));
  });

  testWidgets('the writing goes first, while the cards are still cards',
      (tester) async {
    await pump(tester);
    await tester.pump(const Duration(milliseconds: 170));

    // Everything but the names has faded, and only then does anything move.
    final faded = tester.widget<Opacity>(find
        .ancestor(of: find.text('Paired'), matching: find.byType(Opacity))
        .first);
    expect(faded.opacity, lessThan(0.05));
    expect(shape(tester, SyncingDevices.peerShape).width, greaterThan(300));
    expect(find.text('Calm Otter'), findsOneWidget);
  });

  testWidgets('then the cards close down onto squares', (tester) async {
    await pump(tester);
    await tester.pump(const Duration(milliseconds: 600));

    for (final key in [SyncingDevices.selfShape, SyncingDevices.peerShape]) {
      final square = shape(tester, key);
      expect(square.width, closeTo(RollingSquare.side, 0.5));
      expect(square.height, closeTo(RollingSquare.side, 0.5));
    }
    // Still nothing rolling: that is the last step, not this one.
    expect(find.byType(RollingSquare), findsNothing);
  });

  testWidgets('the names end up in a list above the squares', (tester) async {
    await pump(tester);
    final startedAt = tester.getRect(find.text('Calm Otter'));

    await tester.pump(const Duration(milliseconds: 1000));

    final names = [
      tester.getRect(find.text('This one')),
      tester.getRect(find.text('Calm Otter')),
    ];
    final squares = [
      shape(tester, SyncingDevices.selfShape),
      shape(tester, SyncingDevices.peerShape),
    ];

    // Two lines, one under the other, close enough together to read as a list
    // rather than as two cards.
    expect(names[1].top - names[0].top, closeTo(26, 1));
    // Above the squares, not beside them: beside them they were labels stuck
    // to two moving objects.
    for (final name in names) {
      expect(name.bottom, lessThanOrEqualTo(squares[0].top));
    }
    // And they came out of the cards to get there.
    expect(names[1].top, lessThan(startedAt.top));
    // The squares finish on one line, which is what they roll along.
    expect(squares[0].top, closeTo(squares[1].top, 0.01));
    expect(squares[0].left, lessThan(squares[1].left));
  });

  testWidgets('only once they are lined up does anything start rolling',
      (tester) async {
    await pump(tester);

    await tester.pump(const Duration(milliseconds: 900));
    expect(find.byType(RollingSquare), findsNothing);

    // Lined up, and still not rolling: the caption is only just arriving.
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byType(RollingSquare), findsNothing);
    final parked = [
      shape(tester, SyncingDevices.selfShape),
      shape(tester, SyncingDevices.peerShape),
    ];

    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(RollingSquare), findsNWidgets(2));

    // The roll begins on the spot the square was left on - its track starts at
    // that very corner - so the hand-over cannot be seen.
    final left = shape(tester, SyncingDevices.selfShape);
    final right = shape(tester, SyncingDevices.peerShape);
    expect(left.left, closeTo(parked[0].left, 0.01));
    expect(left.bottom, closeTo(parked[0].bottom, 0.01));
    expect(right.right, closeTo(parked[1].right, 0.01));
    expect(right.bottom, closeTo(parked[1].bottom, 0.01));
  });

  testWidgets('they roll towards each other', (tester) async {
    await pump(tester);
    await tester.pump(const Duration(milliseconds: 1150));

    final start = [
      tester.getRect(find.descendant(
          of: find.byKey(SyncingDevices.selfShape),
          matching: find.byType(Container))),
      tester.getRect(find.descendant(
          of: find.byKey(SyncingDevices.peerShape),
          matching: find.byType(Container))),
    ];
    await tester.pump(const Duration(milliseconds: 380));

    // One from each end, meeting in the middle: the screen is about these two
    // working with each other, not about one of them waiting.
    expect(
        tester
            .getRect(find.descendant(
                of: find.byKey(SyncingDevices.selfShape),
                matching: find.byType(Container)))
            .left,
        greaterThan(start[0].left));
    expect(
        tester
            .getRect(find.descendant(
                of: find.byKey(SyncingDevices.peerShape),
                matching: find.byType(Container)))
            .right,
        lessThan(start[1].right));
  });

  testWidgets('less motion means a still square, not a livelier spinner',
      (tester) async {
    await pump(tester, reduceMotion: true);

    // Straight to squares, and they stay where they are.
    expect(find.byType(RollingSquare), findsNWidgets(2));
    final start = shape(tester, SyncingDevices.selfShape);
    await tester.pump(const Duration(milliseconds: 600));
    expect(shape(tester, SyncingDevices.selfShape), start);
  });

  testWidgets('two long names on a phone screen still fit', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(
        body: SyncingDevices(
          self: DeviceInfo(
              id: 'a',
              name: 'axawys-desktop-machine-in-the-study',
              platform: DevicePlatform.linux,
              port: 1),
          peers: [
            DeviceInfo(
                id: 'b',
                name: 'Xiaomi Redmi Note 12 Pro Max',
                platform: DevicePlatform.android,
                port: 1),
          ],
          caption: 'Working out the changes…',
        ),
      ),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a wait that can be called off says so', (tester) async {
    var cancelled = 0;
    await pump(tester, onCancel: () => cancelled++);
    await tester.pump(const Duration(milliseconds: 1200));

    await tester.tap(find.text('Cancel'));
    expect(cancelled, 1);
  });

  testWidgets('and one that cannot offers nothing to press', (tester) async {
    await pump(tester);
    await tester.pump(const Duration(milliseconds: 1200));
    expect(find.text('Cancel'), findsNothing);
  });

  testWidgets('nothing to do runs the whole thing backwards', (tester) async {
    var unfolded = 0;
    await pump(tester);
    await tester.pump(const Duration(milliseconds: 1200));
    expect(find.byType(RollingSquare), findsNWidgets(2));

    await pump(tester, unfold: true, onUnfolded: () => unfolded++);
    await tester.pump(const Duration(milliseconds: 400));

    // On the way back the squares are squares again, growing.
    expect(find.byType(RollingSquare), findsNothing);
    expect(unfolded, 0);

    await tester.pump(const Duration(milliseconds: 500));

    // And they end up as the two devices they came from, at which point the
    // screen is told it can go.
    expect(find.text('Paired'), findsOneWidget);
    expect(shape(tester, SyncingDevices.selfShape).width, greaterThan(300));
    expect(unfolded, 1);
  });

  testWidgets('three devices roll round a triangle, this one at the apex',
      (tester) async {
    const other = DeviceInfo(
        id: 'laptop',
        name: 'Study laptop',
        platform: DevicePlatform.linux,
        port: 47800);

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(
        body: SyncingDevices(
          self: self,
          peers: [peer, other],
          caption: 'Working out what will change…',
        ),
      ),
    ));
    await tester.pump();

    // Three cards to begin with, and three names.
    expect(find.text('This one'), findsOneWidget);
    expect(find.text('Calm Otter'), findsOneWidget);
    expect(find.text('Study laptop'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1200));

    final squares = [
      for (var i = 0; i < 3; i++)
        tester.getRect(find.byKey(SyncingDevices.shapeOf(i))).center,
    ];

    // A corner each, not a line: a sync between two is one meeting the other,
    // and three is a round. This device takes the apex, as it takes the top of
    // the list of names.
    expect(squares[0].dy, lessThan(squares[1].dy));
    expect(squares[0].dy, lessThan(squares[2].dy));
    // Round the shape in the order they are named: the first peer to the
    // right of the apex, the second to the left of it.
    expect(squares[1].dx, greaterThan(squares[0].dx));
    expect(squares[2].dx, lessThan(squares[0].dx));

    // Equally spaced round it: the sides of the triangle they roll along.
    final sides = [
      (squares[0] - squares[1]).distance,
      (squares[1] - squares[2]).distance,
      (squares[2] - squares[0]).distance,
    ];
    for (final side in sides) {
      expect(side, closeTo(sides[0], 2));
    }

    // And three names, in a list, above the shape.
    final names = [
      tester.getRect(find.text('This one')),
      tester.getRect(find.text('Calm Otter')),
      tester.getRect(find.text('Study laptop')),
    ];
    expect(names[1].top - names[0].top, closeTo(26, 1));
    expect(names[2].top - names[1].top, closeTo(26, 1));
    expect(names[2].bottom, lessThanOrEqualTo(squares[0].dy));
  });

  testWidgets('and they go round it, all the same way', (tester) async {
    const other = DeviceInfo(
        id: 'laptop',
        name: 'Study laptop',
        platform: DevicePlatform.linux,
        port: 47800);

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(
        body: SyncingDevices(
          self: self,
          peers: [peer, other],
          caption: 'Working out what will change…',
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1200));

    final circuit = const Circuit(3);
    final started = [
      for (var i = 0; i < 3; i++)
        tester.getRect(find.byKey(SyncingDevices.shapeOf(i))).center,
    ];

    // A third of a lap on, each square stands where the next one started: they
    // are going round together, not each on a spot of its own.
    await tester.pump(Duration(
        milliseconds: (circuit.lap.inMilliseconds / 3).round()));

    for (var i = 0; i < 3; i++) {
      final now = tester.getRect(find.byKey(SyncingDevices.shapeOf(i))).center;
      expect((now - started[(i + 1) % 3]).distance, lessThan(3));
    }
  });

  testWidgets('four devices get a square, and more than four a circle',
      (tester) async {
    Future<void> pumpWith(int peers) async {
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SyncingDevices(
            self: self,
            peers: [
              for (var i = 0; i < peers; i++)
                DeviceInfo(
                    id: 'peer$i',
                    name: 'Peer $i',
                    platform: DevicePlatform.android,
                    port: 1),
            ],
            caption: 'Working out what will change…',
          ),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1200));
    }

    await pumpWith(3);
    final corners = [
      for (var i = 0; i < 4; i++)
        tester.getRect(find.byKey(SyncingDevices.shapeOf(i))).center,
    ];
    // Four corners: two across from each other on both diagonals.
    expect((corners[0] - corners[2]).distance,
        closeTo((corners[1] - corners[3]).distance, 2));
    // A square, so the diagonal is the side times root two.
    final side = (corners[0] - corners[1]).distance;
    expect((corners[0] - corners[2]).distance, closeTo(side * 1.414, 3));

    // Five and up stop having countable corners, so they get the shape that
    // does not claim a number: a circle. Every one of them the same distance
    // out from the middle, and no two of them a straight edge apart.
    await pumpWith(4);
    final round = [
      for (var i = 0; i < 5; i++)
        tester.getRect(find.byKey(SyncingDevices.shapeOf(i))).center,
    ];
    var middle = Offset.zero;
    for (final spot in round) {
      middle += spot;
    }
    middle = middle / 5;
    final out = (round[0] - middle).distance;
    for (final spot in round) {
      expect((spot - middle).distance, closeTo(out, 2));
    }
  });
}
