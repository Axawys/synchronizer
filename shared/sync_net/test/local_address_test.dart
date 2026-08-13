import 'package:sync_net/sync_net.dart';
import 'package:test/test.dart';

void main() {
  test('this device can say where it is reachable', () async {
    final addresses = await localAddresses();

    // A machine with no network at all is a legitimate answer, so this checks
    // the shape of what comes back rather than that anything did.
    for (final address in addresses) {
      expect(address.address, matches(RegExp(r'^\d+\.\d+\.\d+\.\d+$')));
      expect(address.address, isNot(startsWith('127.')));
      expect(address.interfaceName, isNotEmpty);
    }
  });

  test('a carrier address never outranks one that can actually be dialled',
      () async {
    // Ranking is by interface name, so it can be checked against the real
    // list: whatever this machine has, mobile data must sort last.
    final addresses = await localAddresses();
    final mobile = addresses.indexWhere((a) =>
        a.interfaceName.startsWith('rmnet') ||
        a.interfaceName.startsWith('pdp'));
    if (mobile == -1) return;

    expect(mobile, addresses.length - 1,
        reason: 'mobile data is behind carrier NAT and cannot be connected to');
  });
}
