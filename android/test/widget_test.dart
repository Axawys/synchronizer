import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sync_net/sync_net.dart';
import 'package:sync_ui/sync_ui.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('shows this device name and searches when no peers found',
      (tester) async {
    const self = DeviceInfo(
      id: 'self',
      name: 'test-phone',
      platform: DevicePlatform.android,
      port: 47800,
    );

    await tester.pumpWidget(
      const SynchronizerApp(self: self, autoStart: false),
    );
    await tester.pump();

    // The name and what it is are two things on the card now, not one line.
    expect(find.text('test-phone'), findsOneWidget);
    expect(find.text('This device'), findsOneWidget);
    expect(find.text('Looking for devices…'), findsOneWidget);
  });
}
