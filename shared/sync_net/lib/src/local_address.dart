import 'dart:io';

/// What kind of link an address sits on, as far as the interface name gives it
/// away. It decides what the app can say about an address and what it may do
/// with it - a cable and a hotspot are two devices and nothing else, which is
/// what makes sweeping them for the other device reasonable, where doing the
/// same to an office network would not be.
enum LinkKind {
  /// USB tethering: `usb0`, `rndis0`, `enp0s20u1`. Two devices, one cable.
  usb,

  /// A hotspot this device is hosting: `ap0`, `swlan0`, `wlan1`.
  hotspot,

  /// An ordinary Wi-Fi network.
  wifi,

  /// Ethernet and everything else with a cable to a switch.
  wired,

  /// Mobile data. Behind carrier NAT, so nothing can dial it.
  mobile,

  /// A VPN tunnel. Not a way to reach the other device - and, on a phone, the
  /// thing that quietly takes the app's traffic away from the network the other
  /// device is on.
  vpn,

  other;

  /// Whether a link is short enough that the only thing on it is the other
  /// device.
  bool get isDirect => this == LinkKind.usb || this == LinkKind.hotspot;
}

/// One address this device can be reached at, and the link it belongs to.
class LocalAddress {
  const LocalAddress({
    required this.interfaceName,
    required this.address,
    required this.kind,
  });

  final String interfaceName;
  final String address;
  final LinkKind kind;

  @override
  String toString() => '$address ($interfaceName, ${kind.name})';
}

/// Every IPv4 address this device currently answers on, best candidate first.
///
/// This is what a direct connection needs: when the two devices are not on a
/// network that can carry discovery - a phone sharing its own hotspot, a USB
/// cable, a guest Wi-Fi that isolates its clients - the only way in is for one
/// side to read out an address and the other to dial it. So the order matters
/// more than the completeness: the address most likely to be the one the other
/// device can reach goes first, because that is the one the user will use.
///
/// The ranking follows [LinkKind]: a cable first, then a hotspot this device is
/// hosting, then ordinary networks, and mobile data last - a carrier address is
/// behind carrier NAT and effectively never reachable from another device,
/// however real it looks in this list.
Future<List<LocalAddress>> localAddresses() async {
  final List<NetworkInterface> interfaces;
  try {
    interfaces = await NetworkInterface.list(
      includeLoopback: false,
      includeLinkLocal: false,
      type: InternetAddressType.IPv4,
    );
  } catch (_) {
    return const [];
  }

  final found = [
    for (final interface in interfaces)
      for (final address in interface.addresses)
        LocalAddress(
          interfaceName: interface.name,
          address: address.address,
          kind: linkKindOf(interface.name),
        ),
  ]..sort((a, b) {
      final byKind = _rank(a.kind).compareTo(_rank(b.kind));
      if (byKind != 0) return byKind;
      final byInterface = a.interfaceName.compareTo(b.interfaceName);
      return byInterface != 0 ? byInterface : a.address.compareTo(b.address);
    });

  return List.unmodifiable(found);
}

/// Whether a VPN tunnel is up on this device.
///
/// Worth knowing because of what it does to finding devices: on Android a VPN
/// takes the app's traffic into the tunnel, so announcements never reach the
/// local network and the device on the other side of the room becomes
/// unreachable. The app cannot fix that by itself everywhere, but it can say
/// so instead of leaving the user to wonder.
Future<bool> vpnIsUp() async {
  for (final address in await localAddresses()) {
    if (address.kind == LinkKind.vpn) return true;
  }
  return false;
}

/// Classifies an interface by its name, which is as much as the OS gives us
/// without native code. The names are the ones Linux and Android use:
/// `rndis0`/`usb0`/`enp0s20u2` for tethering, `ap0`/`swlan0`/`wlan1` for a
/// hosted hotspot, `rmnet_data0`/`ccmni0` for mobile data.
///
/// Windows names its adapters for people instead - `Wi-Fi`, `Ethernet 2`,
/// `Local Area Connection* 10` - and in the language of the system. Those say
/// less: a phone tethered by cable is just another `Ethernet`, so on Windows a
/// cable ranks as a wired network.
LinkKind linkKindOf(String interfaceName) {
  final name = interfaceName.toLowerCase();
  bool named(List<String> prefixes) => prefixes.any(name.startsWith);

  // The asterisk is how Windows marks a virtual adapter, and the virtual one
  // with this name is the one its Mobile hotspot runs on.
  if (named(const ['local area connection*', 'подключение по локальной сети*'])) {
    return LinkKind.hotspot;
  }
  if (named(const ['wi-fi', 'wireless', 'беспроводная сеть'])) {
    return LinkKind.wifi;
  }
  // Hyper-V and WSL switches: a network inside this machine, not a way out.
  if (name.startsWith('vethernet')) return LinkKind.other;

  if (named(const ['usb', 'rndis'])) return LinkKind.usb;
  // A wired name ending in a `u<n>` segment, or starting `enx`, is a USB
  // device pretending to be Ethernet - which is exactly what a tethered phone
  // looks like on a Linux desktop (`enp0s20f0u2`, `enx00e04c360033`).
  if (RegExp(r'^en.*u\d+$').hasMatch(name)) return LinkKind.usb;
  if (name.startsWith('enx')) return LinkKind.usb;
  if (named(const ['ap', 'swlan', 'softap', 'wlan1'])) return LinkKind.hotspot;
  if (named(const ['tun', 'tap', 'wg', 'ppp', 'ipsec', 'utun', 'nordlynx'])) {
    return LinkKind.vpn;
  }
  if (named(const ['rmnet', 'ccmni', 'pdp', 'seth'])) return LinkKind.mobile;
  if (named(const ['wlan', 'wl', 'wifi'])) return LinkKind.wifi;
  if (named(const ['eth', 'en', 'br', 'docker'])) return LinkKind.wired;
  return LinkKind.other;
}

int _rank(LinkKind kind) => switch (kind) {
      LinkKind.usb => 0,
      LinkKind.hotspot => 1,
      LinkKind.wifi => 2,
      LinkKind.wired => 3,
      LinkKind.other => 4,
      LinkKind.mobile => 5,
      // Never the address to hand out: a tunnel goes somewhere else entirely.
      LinkKind.vpn => 6,
    };
