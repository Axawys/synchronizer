import 'package:flutter_test/flutter_test.dart';
import 'package:sync_net/sync_net.dart';
import 'package:sync_ui/sync_ui.dart';

void main() {
  testWidgets('shows this device name and searches when no peers found',
      (tester) async {
    const self = DeviceInfo(
      id: 'self',
      name: 'test-desktop',
      platform: DevicePlatform.linux,
      port: 47800,
    );

    await tester.pumpWidget(
      const SynchronizerApp(self: self, autoStart: false),
    );
    await tester.pump();

    expect(find.text('This device: test-desktop'), findsOneWidget);
    expect(find.text('Looking for devices...'), findsOneWidget);
  });
}
