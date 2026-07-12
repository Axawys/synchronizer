import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_net/sync_net.dart';

import 'package:synchronizer_mobile/main.dart';

void main() {
  // The multicast platform channel has no implementation in the test host, so
  // answer its calls with a no-op stub.
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('synchronizer/multicast'),
      (call) async => null,
    );
  });

  testWidgets('shows this device name and searches when no peers found',
      (tester) async {
    const self = DeviceInfo(
      id: 'self',
      name: 'test-phone',
      platform: DevicePlatform.android,
      port: 47800,
    );

    await tester.pumpWidget(const SynchronizerApp(self: self));
    await tester.pump();

    expect(find.text('This device: test-phone'), findsOneWidget);
    expect(find.text('Looking for devices...'), findsOneWidget);
  });
}
