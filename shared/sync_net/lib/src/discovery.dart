import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'device_info.dart';

/// Settings for [DiscoveryService]. The defaults are sensible for a real LAN;
/// tests dial the durations down.
class DiscoveryConfig {
  const DiscoveryConfig({
    this.multicastAddress = '239.255.42.99',
    this.port = 47811,
    this.announceInterval = const Duration(seconds: 3),
    this.staleAfter = const Duration(seconds: 10),
  });

  /// Administratively-scoped multicast group. Traffic to it stays on the local
  /// segment and does not route to the wider internet.
  final String multicastAddress;
  final int port;

  /// How often this device re-announces itself.
  final Duration announceInterval;

  /// A peer not heard from within this window is considered gone.
  final Duration staleAfter;
}

/// Discovers other Synchronizer devices on the local network and announces this
/// one, over UDP multicast.
///
/// The exchange is small: every device periodically multicasts an [DeviceInfo]
/// announcement, and a device joining the network multicasts a query so it does
/// not have to wait a full interval to learn who is already present. Peers that
/// go quiet for [DiscoveryConfig.staleAfter] drop off the list.
///
/// This deliberately avoids mDNS/Avahi: it needs no native plugin and the
/// packet format is ours, which keeps the desktop and phone behaving
/// identically. On Android the process must hold a multicast lock for inbound
/// packets to arrive; that is handled in the app layer.
class DiscoveryService {
  DiscoveryService(this.self, {this.config = const DiscoveryConfig()});

  final DeviceInfo self;
  final DiscoveryConfig config;

  static const _magic = 'synchronizer/1';

  RawDatagramSocket? _socket;
  InternetAddress? _group;
  Timer? _announceTimer;
  Timer? _pruneTimer;

  final _peers = <String, _SeenPeer>{};
  final _controller = StreamController<List<DeviceInfo>>.broadcast();

  /// Emits the full current peer list whenever it changes.
  Stream<List<DeviceInfo>> get peers => _controller.stream;

  /// Snapshot of the peers currently known, most recently seen first.
  List<DeviceInfo> get current {
    final list = _peers.values.toList()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return list.map((p) => p.info).toList(growable: false);
  }

  Future<void> start() async {
    if (_socket != null) return;

    final group = InternetAddress(config.multicastAddress);
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      config.port,
      reuseAddress: true,
      reusePort: true,
    );
    socket.multicastLoopback = true;
    socket.joinMulticast(group);

    _socket = socket;
    _group = group;
    socket.listen(_onEvent);

    _sendQuery();
    _announce();
    _announceTimer =
        Timer.periodic(config.announceInterval, (_) => _announce());
    _pruneTimer = Timer.periodic(config.announceInterval, (_) => _prune());
  }

  Future<void> stop() async {
    _announceTimer?.cancel();
    _pruneTimer?.cancel();
    final socket = _socket;
    final group = _group;
    if (socket != null && group != null) {
      try {
        socket.leaveMulticast(group);
      } on OSError {
        // The interface may already be gone; nothing to leave.
      }
      socket.close();
    }
    _socket = null;
    _group = null;
    await _controller.close();
  }

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final datagram = _socket?.receive();
    if (datagram == null) return;

    final Map<String, Object?> message;
    try {
      final decoded = jsonDecode(utf8.decode(datagram.data));
      if (decoded is! Map<String, Object?>) return;
      message = decoded;
    } on FormatException {
      return; // Not our packet, or corrupt. Ignore quietly.
    }

    if (message['magic'] != _magic) return;

    switch (message['type']) {
      case 'query':
        _announce();
      case 'announce':
        _onAnnounce(message, datagram.address.address);
    }
  }

  void _onAnnounce(Map<String, Object?> message, String sourceAddress) {
    final body = message['device'];
    if (body is! Map<String, Object?>) return;

    final DeviceInfo info;
    try {
      info = DeviceInfo.fromAnnouncement(body, address: sourceAddress);
    } catch (_) {
      return; // Malformed announcement.
    }

    if (info.id == self.id) return; // Never list ourselves.

    final existing = _peers[info.id];
    _peers[info.id] = _SeenPeer(info, DateTime.now());

    final changed = existing == null ||
        existing.info.name != info.name ||
        existing.info.address != info.address ||
        existing.info.port != info.port;
    if (changed) _emit();
  }

  void _announce() {
    _send({
      'magic': _magic,
      'type': 'announce',
      'device': self.toAnnouncement(),
    });
  }

  void _sendQuery() {
    _send({'magic': _magic, 'type': 'query'});
  }

  void _send(Map<String, Object?> message) {
    final socket = _socket;
    final group = _group;
    if (socket == null || group == null) return;
    socket.send(utf8.encode(jsonEncode(message)), group, config.port);
  }

  void _prune() {
    final now = DateTime.now();
    final gone = _peers.entries
        .where((e) => now.difference(e.value.lastSeen) > config.staleAfter)
        .map((e) => e.key)
        .toList();
    if (gone.isEmpty) return;
    for (final id in gone) {
      _peers.remove(id);
    }
    _emit();
  }

  void _emit() {
    if (!_controller.isClosed) _controller.add(current);
  }
}

class _SeenPeer {
  _SeenPeer(this.info, this.lastSeen);

  final DeviceInfo info;
  final DateTime lastSeen;
}
