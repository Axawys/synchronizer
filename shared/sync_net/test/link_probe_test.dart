import 'dart:io';

import 'package:sync_net/sync_net.dart';
import 'package:test/test.dart';

void main() {
  group('LinkKind', () {
    test('names the links a direct connection is made of', () {
      expect(linkKindOf('rndis0'), LinkKind.usb);
      expect(linkKindOf('usb0'), LinkKind.usb);
      expect(linkKindOf('enp0s20f0u2'), LinkKind.usb,
          reason: 'a tethered phone on a desktop looks like Ethernet');
      expect(linkKindOf('enx00e04c360033'), LinkKind.usb);
      expect(linkKindOf('ap0'), LinkKind.hotspot);
      expect(linkKindOf('swlan0'), LinkKind.hotspot);
      expect(linkKindOf('wlan0'), LinkKind.wifi);
      expect(linkKindOf('enp4s0'), LinkKind.wired);
      expect(linkKindOf('rmnet_data0'), LinkKind.mobile);
      expect(linkKindOf('tun0'), LinkKind.vpn);
      expect(linkKindOf('wg0'), LinkKind.vpn);
      expect(linkKindOf('nordlynx'), LinkKind.vpn);
    });

    test('reads the names Windows gives its adapters', () {
      expect(linkKindOf('Wi-Fi'), LinkKind.wifi);
      expect(linkKindOf('Wi-Fi 2'), LinkKind.wifi);
      expect(linkKindOf('Беспроводная сеть'), LinkKind.wifi);
      expect(linkKindOf('Ethernet 2'), LinkKind.wired);
      expect(linkKindOf('Local Area Connection* 10'), LinkKind.hotspot,
          reason: 'the virtual adapter Mobile hotspot runs on');
      expect(linkKindOf('Подключение по локальной сети* 2'), LinkKind.hotspot);
      expect(linkKindOf('vEthernet (WSL)'), LinkKind.other);
    });

    test('only a cable and a hotspot count as direct', () {
      expect(LinkKind.usb.isDirect, isTrue);
      expect(LinkKind.hotspot.isDirect, isTrue);
      expect(LinkKind.wifi.isDirect, isFalse);
      expect(LinkKind.wired.isDirect, isFalse);
      expect(LinkKind.mobile.isDirect, isFalse);
      expect(LinkKind.vpn.isDirect, isFalse);
    });
  });

  group('LinkProbe', () {
    test('refuses to sweep anything but a direct link', () {
      const wifi = LocalAddress(
          interfaceName: 'wlan0', address: '192.168.1.20', kind: LinkKind.wifi);
      // Knocking on 254 doors is fine when the link has one other device on it
      // and unacceptable on a network full of other people's machines.
      expect(() => const LinkProbe().sweep(wifi), throwsArgumentError);
    });

    test('finds what answers on the link and leaves out this device', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((socket) => socket.destroy());

      // Swept over loopback, where this device is .1 and the "peer" is the
      // listening socket, also on .1 - so the sweep must find it only when it
      // is not excluded as self.
      const self = LocalAddress(
          interfaceName: 'usb0', address: '127.0.0.2', kind: LinkKind.usb);
      final probe = LinkProbe(
          port: server.port, timeout: const Duration(milliseconds: 150));

      final found = await probe.sweep(self);

      expect(found, contains('127.0.0.1'));
      expect(found, isNot(contains('127.0.0.2')), reason: 'that is us');
    });

    test('an empty link answers with nothing', () async {
      // Port 1 is reserved and nothing on the loopback link listens there.
      const self = LocalAddress(
          interfaceName: 'usb0', address: '127.0.0.2', kind: LinkKind.usb);
      final probe =
          LinkProbe(port: 1, timeout: const Duration(milliseconds: 100));

      expect(await probe.sweep(self), isEmpty);
    });
  });
}
