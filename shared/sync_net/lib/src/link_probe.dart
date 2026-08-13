import 'dart:async';
import 'dart:io';

import 'local_address.dart';

/// Looks for the other device on a link by knocking on every address on it.
///
/// Discovery should find a peer on a USB cable or a hotspot the same way it
/// finds one on a home network - but that is exactly where multicast is least
/// reliable: tethering interfaces on some Android builds do not carry it at
/// all, and a hotspot may pass it in one direction only. Meanwhile the link
/// itself is the smallest network there is: a /24 with two devices on it. So
/// when the packets do not come, knocking on all 254 doors is not a scan, it is
/// asking the one other machine present whether it is there - and it takes
/// about a second.
///
/// Deliberately limited to [LinkKind.isDirect] links. The same sweep on an
/// office or café network would be touching hundreds of strangers' machines,
/// which is not something this app has any business doing.
class LinkProbe {
  const LinkProbe({
    this.port = 47800,
    this.timeout = const Duration(milliseconds: 900),
    this.parallel = 48,
  });

  /// The port peers listen on. The default matches the one devices announce.
  final int port;

  /// How long one address gets to answer. A direct link is one hop, so an
  /// answer is immediate or not coming.
  final Duration timeout;

  /// How many addresses are tried at once. Bounded so a sweep cannot run the
  /// process out of file descriptors.
  final int parallel;

  /// Addresses on [link] that accept a connection on [port], self excluded.
  ///
  /// Throws [ArgumentError] for a link that is not direct - see the class
  /// comment for why that is a rule and not a preference.
  Future<List<String>> sweep(LocalAddress link) async {
    if (!link.kind.isDirect) {
      throw ArgumentError.value(
        link.interfaceName,
        'link',
        'only a USB or hotspot link may be swept',
      );
    }

    final subnet = _subnetOf(link.address);
    if (subnet == null) return const [];

    final candidates = [
      for (var host = 1; host < 255; host++)
        if ('$subnet.$host' != link.address) '$subnet.$host',
    ];

    final found = <String>[];
    for (var i = 0; i < candidates.length; i += parallel) {
      final batch = candidates.skip(i).take(parallel);
      final answers = await Future.wait(batch.map(_knock));
      found.addAll(answers.whereType<String>());
    }
    found.sort(_byHostNumber);
    return found;
  }

  Future<String?> _knock(String host) async {
    try {
      final socket = await Socket.connect(host, port, timeout: timeout);
      socket.destroy();
      return host;
    } catch (_) {
      return null; // Nothing there, or nothing listening on our port.
    }
  }

  /// The first three octets, or null if this is not a dotted quad.
  static String? _subnetOf(String address) {
    final parts = address.split('.');
    if (parts.length != 4) return null;
    if (parts.any((p) => int.tryParse(p) == null)) return null;
    return parts.take(3).join('.');
  }

  /// Numeric order, so .2 comes before .10 - the gateway of a tethered link is
  /// .1 and the first thing worth showing.
  static int _byHostNumber(String a, String b) {
    int last(String address) => int.parse(address.split('.').last);
    return last(a).compareTo(last(b));
  }
}
