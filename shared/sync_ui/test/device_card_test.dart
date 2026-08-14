import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_net/sync_net.dart';
import 'package:sync_ui/sync_ui.dart';

/// The devices screen is the first thing the app shows, and a card is the whole
/// of it: if it does not say which device it is and where, there is nothing to
/// choose between them.
void main() {
  const phone = DeviceInfo(
    id: 'abc',
    name: 'Calm Otter',
    platform: DevicePlatform.android,
    port: 47800,
    address: '192.168.1.24',
  );

  Widget host(Widget child) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: Center(child: SizedBox(width: 360, child: child))),
      );

  testWidgets('a card carries the name and the address', (tester) async {
    await tester
        .pumpWidget(host(const DeviceCard(device: phone, paired: false)));

    expect(find.text('Calm Otter'), findsOneWidget);
    expect(find.text('192.168.1.24:47800'), findsOneWidget);
  });

  testWidgets('a card is a rounded rectangle', (tester) async {
    await tester
        .pumpWidget(host(const DeviceCard(device: phone, paired: false)));

    final material = tester.widget<Material>(
      find
          .ancestor(of: find.text('Calm Otter'), matching: find.byType(Material))
          .first,
    );
    final shape = material.shape! as RoundedRectangleBorder;
    expect(shape.borderRadius, const BorderRadius.all(Radius.circular(18)));
  });

  testWidgets('a card says whether the device is paired', (tester) async {
    await tester
        .pumpWidget(host(const DeviceCard(device: phone, paired: false)));
    expect(find.text('Not paired'), findsOneWidget);

    await tester.pumpWidget(host(const DeviceCard(device: phone, paired: true)));
    expect(find.text('Paired'), findsOneWidget);
  });

  testWidgets('a device with no address says so rather than showing nothing',
      (tester) async {
    const unreachable = DeviceInfo(
        id: 'x', name: 'Lost', platform: DevicePlatform.unknown, port: 1);
    await tester
        .pumpWidget(host(const DeviceCard(device: unreachable, paired: false)));

    expect(find.text('unknown:1'), findsOneWidget);
  });

  testWidgets('tapping a card opens the device', (tester) async {
    var taps = 0;
    await tester.pumpWidget(host(
      DeviceCard(device: phone, paired: true, onTap: () => taps++),
    ));

    await tester.tap(find.byType(DeviceCard));
    expect(taps, 1);
  });

  testWidgets('holding a paired card offers to forget it', (tester) async {
    var forgets = 0;
    await tester.pumpWidget(host(
      DeviceCard(device: phone, paired: true, onForget: () => forgets++),
    ));

    await tester.longPress(find.byType(DeviceCard));
    expect(forgets, 1);
  });

  testWidgets('a paired device shows its folder instead of its address',
      (tester) async {
    await tester.pumpWidget(host(const DeviceCard(
      device: phone,
      paired: true,
      folders: [SharedDir('Obsidian', files: 120, bytes: 24500000)],
    )));

    // The address is how the app finds it, not how a person recognises it -
    // and the weight is what says whether that folder holds the vault. Where
    // that device keeps it is its own business.
    expect(find.text('192.168.1.24:47800'), findsNothing);
    expect(find.text('Obsidian'), findsOneWidget);
    expect(find.textContaining('/'), findsNothing);
    expect(find.text(' · 24500 kB'), findsOneWidget);
  });

  testWidgets('"paired" sits by the name and leaves the folder line the row',
      (tester) async {
    await tester.pumpWidget(host(const DeviceCard(
      device: phone,
      paired: true,
      folders: [SharedDir('Obsidian', bytes: 24500000)],
    )));

    // It says something about the device, so it belongs against the name.
    expect(
      find.descendant(
        of: find.ancestor(
            of: find.text('Calm Otter'), matching: find.byType(Row)).first,
        matching: find.byType(Tag),
      ),
      findsOneWidget,
    );
    // And the path and size get the whole width instead of stopping short of
    // a pill on the right.
    final tag = tester.getRect(find.byType(Tag));
    final line = tester.getRect(find.byType(FolderLine));
    expect(line.right, greaterThan(tag.left));
  });

  testWidgets('a paired device sharing nothing says so', (tester) async {
    await tester.pumpWidget(
        host(const DeviceCard(device: phone, paired: true, folders: [])));

    // Worth knowing before the tap: a sync with it would have nothing to do.
    expect(find.text('No folder chosen yet'), findsOneWidget);
  });

  testWidgets('a folder that is gone over there is said in red',
      (tester) async {
    await tester.pumpWidget(host(const DeviceCard(
      device: phone,
      paired: true,
      folders: [SharedDir('Obsidian', missing: true)],
    )));

    final found = find.text('Not there any more on that device');
    final colors = Theme.of(tester.element(found)).colorScheme;
    expect(tester.widget<Text>(found).style?.color, colors.error,
        reason: 'a folder that is gone is a warning and has to read as one');
  });

  testWidgets('a device that has not answered yet still says where it is',
      (tester) async {
    // Until the answer comes back there is nothing to say about its folder,
    // and an empty line would be worse than the address it replaces.
    await tester
        .pumpWidget(host(const DeviceCard(device: phone, paired: true)));

    expect(find.text('192.168.1.24:47800'), findsOneWidget);
  });

  testWidgets('a name too long to fit is cut, not spilled', (tester) async {
    const wordy = DeviceInfo(
      id: 'y',
      name: 'A device with a name far longer than any card is ever going to be',
      platform: DevicePlatform.linux,
      port: 47800,
      address: '10.0.0.2',
    );
    await tester
        .pumpWidget(host(const DeviceCard(device: wordy, paired: false)));

    expect(tester.takeException(), isNull);
    final name = tester.widget<Text>(find.text(wordy.name));
    expect(name.overflow, TextOverflow.ellipsis);
    expect(name.maxLines, 1);
  });
}
