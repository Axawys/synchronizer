import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_ui/sync_ui.dart';

/// The one moment in the app worth marking, and the rules it has to follow.
void main() {
  testWidgets('it plays, then takes itself off screen', (tester) async {
    var done = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Fireworks(onDone: () => done = true)),
    ));

    await tester.pump(const Duration(milliseconds: 400));
    expect(done, isFalse, reason: 'still going');

    await tester.pump(const Duration(seconds: 2));
    expect(done, isTrue, reason: 'a celebration that has to be dismissed is a chore');
  });

  testWidgets('it does not touch what is behind it', (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            Center(
              child: ElevatedButton(
                onPressed: () => taps++,
                child: const Text('under it'),
              ),
            ),
            const Positioned.fill(child: Fireworks()),
          ],
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.text('under it'));
    expect(taps, 1, reason: 'sparks are not a wall');

    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('asking for less motion skips it', (tester) async {
    var done = false;
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Scaffold(body: Fireworks(onDone: () => done = true)),
      ),
    ));
    await tester.pump();

    expect(done, isTrue, reason: 'over before it started, as asked');
  });
}
