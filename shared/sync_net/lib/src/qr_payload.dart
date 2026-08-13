import 'dart:convert';

import 'device_info.dart';

/// Everything one device needs to reach another and pair with it, small enough
/// to fit in a QR code.
///
/// This is the whole of the "show a code, scan it" flow: the device showing the
/// code puts on screen where it can be reached, the network to join to get
/// there if it made one, and a one-time pairing token. The device scanning it
/// then has no questions left to ask - and neither has the user, which is the
/// point. The six-digit comparison exists to prove the two people are looking
/// at the same two devices; a QR code proves it better, because reading it
/// requires being in front of the screen.
///
/// The token is the sensitive part, and it is why the code should be on screen
/// only while it is being scanned: anything that can photograph it can pair.
class QrPayload {
  const QrPayload({
    required this.name,
    required this.addresses,
    required this.port,
    required this.token,
    this.platform = DevicePlatform.unknown,
    this.wifiSsid,
    this.wifiPassphrase,
  });

  /// Format version, so a newer code shown to an older app fails clearly
  /// instead of being half-understood.
  static const int version = 1;

  /// What the device calls itself, so the other end can say who it paired with
  /// before the handshake has told it.
  final String name;
  final DevicePlatform platform;

  /// Where it can be reached, best candidate first. More than one because the
  /// device does not know which of its networks the scanner will end up on.
  final List<String> addresses;
  final int port;

  /// The one-time pairing secret. Proof of having read it replaces the code
  /// both users would otherwise compare.
  final String token;

  /// The network to join first, when the showing device raised one for this.
  final String? wifiSsid;
  final String? wifiPassphrase;

  bool get hasWifi => wifiSsid != null && wifiSsid!.isNotEmpty;

  /// Compact on purpose: every byte is a denser QR code, and a denser code is
  /// one a phone camera has to be closer to read.
  String encode() => jsonEncode({
        'v': version,
        'n': name,
        'f': platform.name,
        'a': addresses,
        'p': port,
        't': token,
        if (hasWifi) 'w': {'s': wifiSsid, 'k': wifiPassphrase ?? ''},
      });

  /// Reads a scanned string, or null if it is not one of ours - which is what
  /// most QR codes in the world are.
  static QrPayload? decode(String scanned) {
    final Object? parsed;
    try {
      parsed = jsonDecode(scanned);
    } catch (_) {
      return null;
    }
    if (parsed is! Map<String, Object?>) return null;
    if (parsed['v'] != version) return null;

    final name = parsed['n'];
    final addresses = parsed['a'];
    final port = parsed['p'];
    final token = parsed['t'];
    if (name is! String || token is! String || port is! int) return null;
    if (addresses is! List) return null;
    if (port < 1 || port > 65535) return null;

    final wifi = parsed['w'];
    return QrPayload(
      name: name,
      platform: devicePlatformFromString(parsed['f'] as String? ?? 'unknown'),
      addresses: [
        for (final address in addresses)
          if (address is String && address.isNotEmpty) address,
      ],
      port: port,
      token: token,
      wifiSsid: wifi is Map ? wifi['s'] as String? : null,
      wifiPassphrase: wifi is Map ? wifi['k'] as String? : null,
    );
  }
}
