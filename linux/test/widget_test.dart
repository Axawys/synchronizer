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

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('shows this device name and searches when no peers found',
      (tester) async {
    await tester.pumpWidget(
      const SynchronizerApp(self: self, autoStart: false),
    );
    await tester.pump();

    expect(find.text('This device: test-desktop'), findsOneWidget);
    expect(find.text('Looking for devices...'), findsOneWidget);
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
