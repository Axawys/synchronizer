import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sync_net/sync_net.dart';
import 'package:sync_ui/sync_ui.dart';

void main() {
  const self = DeviceInfo(
    id: 'self',
    name: 'test-desktop',
    platform: DevicePlatform.linux,
    port: 47800,
  );

  // resetStatic clears the instance a previous test cached, without which
  // mock values set here would never be read back.
  setUp(() {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('shows this device name and searches when no peers found',
      (tester) async {
    await tester.pumpWidget(
      const SynchronizerApp(self: self, autoStart: false),
    );
    await tester.pump();

    expect(find.text('This device: test-desktop'), findsOneWidget);
    expect(find.text('Looking for devices...'), findsOneWidget);
  });

  testWidgets('reports the painted brightness, so the window frame can match it',
      (tester) async {
    // GTK draws the frame, so it only follows the theme if we tell it to.
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues({'theme_mode': 'dark'});

    final reported = <Brightness>[];
    await tester.pumpWidget(SynchronizerApp(
      self: self,
      autoStart: false,
      applyWindowBrightness: (brightness) async => reported.add(brightness),
    ));
    // One frame to let the stored settings load, then past MaterialApp's theme
    // animation, which is what actually flips the painted brightness.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Starts light (nothing loaded yet), then follows the dark theme through.
    expect(reported.last, Brightness.dark);
  });

  testWidgets('the desktop rail navigates between the three destinations',
      (tester) async {
    await tester.pumpWidget(
      const SynchronizerApp(self: self, autoStart: false),
    );
    await tester.pump();

    int selected() =>
        tester.widget<NavigationRail>(find.byType(NavigationRail)).selectedIndex!;

    expect(find.text('Synchronizer'), findsOneWidget); // the rail's header
    expect(selected(), 0);

    await tester.tap(find.text('Folders'));
    await tester.pump();
    expect(selected(), 1);

    await tester.tap(find.byIcon(Icons.settings));
    await tester.pump();
    expect(selected(), 2);
  });
}
