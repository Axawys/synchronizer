import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:meta/meta.dart';

import 'device_info.dart';

/// Settings for [DiscoveryService]. The defaults are sensible for a real LAN;
/// tests dial the durations down.
class DiscoveryConfig {
  const DiscoveryConfig({
    this.multicastAddress = '239.255.42.99',
    this.port = 47811,
    this.announceInterval = const Duration(seconds: 2),
    this.staleAfter = const Duration(seconds: 6),
    this.interfaceScanInterval = const Duration(seconds: 8),
    this.useBroadcast = true,
    this.maxPeers = 64,
    this.verifyPeers = true,
    this.verifyTimeout = const Duration(milliseconds: 1500),
  });

  /// Administratively-scoped multicast group. Traffic to it stays on the local
  /// segment and does not route to the wider internet.
  final String multicastAddress;
  final int port;

  /// How often this device re-announces itself.
  final Duration announceInterval;

  /// A peer not heard from within this window is considered gone.
  final Duration staleAfter;

  /// How often the list of network interfaces is re-read, so that plugging in
  /// a cable, joining a Wi-Fi network or bringing up a VPN starts being
  /// announced on without restarting the app.
  final Duration interfaceScanInterval;

  /// Also send every packet as a limited broadcast (255.255.255.255) on each
  /// interface. Some access points and Android Wi-Fi drivers drop multicast
  /// while passing broadcast, and on those networks this is the difference
  /// between finding devices and finding none.
  final bool useBroadcast;

  /// Ceiling on how many peers are remembered at once. Discovery packets are
  /// unauthenticated, so anything on the network can invent devices; this
  /// bounds what that can cost us.
  final int maxPeers;

  /// Whether a device has to answer on its advertised port before it is listed.
  ///
  /// An announcement is a claim, and a UDP packet is a cheap thing to make.
  /// Networks produce them for reasons of their own - a router that reflects
  /// broadcast, a device that echoes a port, an app that closed a moment ago
  /// and whose last packet is still in flight - and every one of those was
  /// showing up in the list for a few seconds and then vanishing. Knocking on
  /// the door the packet claims is open settles it: what answers is a device
  /// with the app running and ready to pair, which is exactly what the list is
  /// for.
  final bool verifyPeers;

  /// How long that knock waits. On a local network an answer is immediate.
  final Duration verifyTimeout;
}

/// Whether something is listening at this address and port.
///
/// Injectable so tests can decide without a real socket, and so a platform that
/// needs a different kind of check can supply one.
typedef ReachabilityProbe = Future<bool> Function(String address, int port);

Future<bool> _connectProbe(String address, int port) async {
  try {
    final socket = await Socket.connect(
      address,
      port,
      timeout: const Duration(milliseconds: 1500),
    );
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

/// Discovers other Synchronizer devices on the local network and announces this
/// one, over UDP multicast (with a broadcast fallback).
///
/// The exchange is small: every device periodically multicasts a [DeviceInfo]
/// announcement, and a device joining the network multicasts a query so it does
/// not have to wait a full interval to learn who is already present. A device
/// that hears an announcement from a peer it did not know answers straight
/// away, so two apps opened at the same time see each other in well under a
/// second rather than at the next tick.
///
/// A device leaves the list two ways: it says goodbye when it shuts down
/// cleanly (immediate), or it simply goes quiet and is pruned after
/// [DiscoveryConfig.staleAfter] (the backstop for an app that was killed, lost
/// Wi-Fi, or crashed). So the list only ever shows devices actually reachable
/// right now, which is what makes tapping one meaningful.
///
/// Packets go out on every IPv4 interface, not just the default route. A
/// desktop with a docker bridge, a VPN, or both Ethernet and Wi-Fi up would
/// otherwise announce itself down whichever one the routing table happens to
/// prefer - which is regularly not the one the phone is on.
///
/// This deliberately avoids mDNS/Avahi: it needs no native plugin and the
/// packet format is ours, which keeps the desktop and phone behaving
/// identically. On Android the process must hold a multicast lock for inbound
/// packets to arrive; that is handled in the app layer.
class DiscoveryService {
  DiscoveryService(
    this.self, {
    this.config = const DiscoveryConfig(),
    ReachabilityProbe? probe,
  }) : _probe = probe ?? _connectProbe;

  /// What this device announces itself as. The name can change - the user can
  /// rename the device - and everyone else finds out from the next
  /// announcement, which is why [rename] sends one straight away.
  DeviceInfo self;
  final DiscoveryConfig config;

  /// How a device is checked for actually being there. Replaced in tests.
  final ReachabilityProbe _probe;

  /// Devices heard from but not yet shown to have the app open. They stay here
  /// until they answer, and cost nothing while they do not.
  final _unverified = <String, DateTime>{};

  static const _magic = 'synchronizer/1';

  /// A name longer than this is not a name, it is someone trying to see what
  /// the list does with it. Control characters go the same way.
  static const _maxNameLength = 64;
  static const _maxIdLength = 128;

  static final _broadcastAddress = InternetAddress('255.255.255.255');

  final _random = Random();

  /// Bound to the discovery port on every address, so it hears multicast and
  /// broadcast alike. Also the socket packets leave by when there is no usable
  /// interface to send from explicitly.
  RawDatagramSocket? _socket;
  InternetAddress? _group;

  /// One socket per interface address, used only for sending. Dart offers no
  /// way to set the outgoing multicast interface, but a socket bound to an
  /// interface's own address leaves by that interface - which is what makes
  /// announcing on all of them possible at all.
  final _senders = <String, RawDatagramSocket>{};

  /// Interfaces whose multicast membership we already hold, by name.
  final _joined = <String>{};

  Timer? _announceTimer;
  Timer? _pruneTimer;
  Timer? _interfaceTimer;
  Timer? _recoverTimer;

  static const _minRecoveryDelay = Duration(seconds: 1);
  static const _maxRecoveryDelay = Duration(seconds: 30);
  Duration _recoveryDelay = _minRecoveryDelay;

  /// Rounds of announcements where not one packet made it out. A network that
  /// briefly cannot be reached is ordinary; three in a row means the socket is
  /// no longer attached to anything and needs rebuilding.
  int _failedSends = 0;
  static const _failedSendsBeforeRecovery = 3;

  /// Query bursts and jittered replies, kept so stopping cancels them.
  final _pending = <Timer>[];

  /// When we last answered someone else's packet, so a burst of queries or a
  /// room full of devices coming online cannot turn into an announcement storm.
  DateTime? _lastReply;

  bool _running = false;

  final _peers = <String, _SeenPeer>{};
  final _controller = StreamController<List<DeviceInfo>>.broadcast();

  /// Emits the full current peer list whenever it changes.
  Stream<List<DeviceInfo>> get peers => _controller.stream;

  /// Whether discovery is currently listening and announcing.
  bool get isRunning => _running;

  /// Snapshot of the peers currently known, in a stable order.
  ///
  /// Sorted by name rather than by when each was last heard from: the list is
  /// something the user points at, and reordering it every time a packet
  /// arrives would move the row out from under the finger about to tap it.
  List<DeviceInfo> get current {
    final list = _peers.values.toList()
      ..sort((a, b) {
        final byName =
            a.info.name.toLowerCase().compareTo(b.info.name.toLowerCase());
        return byName != 0 ? byName : a.info.id.compareTo(b.info.id);
      });
    return list.map((p) => p.info).toList(growable: false);
  }

  /// When [id] was last heard from, or null if it is not on the list.
  DateTime? lastSeen(String id) => _peers[id]?.lastSeen;

  /// Changes the name this device goes by and tells the network at once, rather
  /// than leaving the old one on other people's screens until the next tick.
  void rename(String name) {
    if (name == self.name) return;
    self = DeviceInfo(
      id: self.id,
      name: name,
      platform: self.platform,
      port: self.port,
      address: self.address,
    );
    if (_running) _announce();
  }

  /// Pulls the listening socket out from under the service, the way the system
  /// does when an interface disappears or Android reclaims a background app's
  /// sockets. Only a test has any reason to do this deliberately; it is here
  /// because recovery from it is the behaviour worth testing.
  @visibleForTesting
  void dropSocketForTesting() => _socket?.close();

  Future<void> start() async {
    if (_running) return;
    _running = true;

    try {
      await _openSockets();
    } catch (_) {
      _running = false;
      rethrow; // The caller decides what to tell the user; see DevicesPage.
    }
    if (!_running) return; // stopped while binding

    _announce();
    _burstQueries();

    _announceTimer =
        Timer.periodic(config.announceInterval, (_) => _announce());
    _pruneTimer = Timer.periodic(_pruneInterval, (_) => _prune());
    _interfaceTimer =
        Timer.periodic(config.interfaceScanInterval, (_) => _scanInterfaces());
  }

  /// Look again, now: re-reads the interfaces and asks everyone to speak up.
  ///
  /// Cheap enough to call whenever the app comes back to the foreground or the
  /// user pulls the list down, and the fastest way back to a correct list after
  /// the device changed networks. If discovery is not running at all - it was
  /// paused, or the port was busy when it last tried - this starts it, because
  /// that is what a user asking to look again means by it.
  Future<void> refresh() async {
    if (!_running) {
      try {
        await start();
      } catch (_) {
        return; // Still not available. The screen already says so.
      }
      return;
    }
    await _scanInterfaces();
    if (!_running) return;
    _announce();
    _burstQueries();
    _prune();
  }

  /// Stops listening and announcing, and says goodbye. The service can be
  /// started again afterwards - [peers] stays open across a stop, so a screen
  /// that pauses discovery in the background keeps its subscription.
  Future<void> stop() async {
    if (!_running) return;
    _running = false;

    _announceTimer?.cancel();
    _pruneTimer?.cancel();
    _interfaceTimer?.cancel();
    _recoverTimer?.cancel();
    _announceTimer = null;
    _pruneTimer = null;
    _interfaceTimer = null;
    _recoverTimer = null;
    for (final timer in _pending) {
      timer.cancel();
    }
    _pending.clear();

    _closeSockets(sayGoodbye: true);
    _lastReply = null;
    _failedSends = 0;
    _recoveryDelay = _minRecoveryDelay;

    // Nothing is reachable through a service that is not running, and saying so
    // is better than leaving a stale list on screen.
    _unverified.clear();
    if (_peers.isNotEmpty) {
      _peers.clear();
      _emit();
    }
  }

  /// Stops for good and closes [peers]. Use this when the owner of the service
  /// is going away; use [stop] if it might start again.
  Future<void> dispose() async {
    await stop();
    if (!_controller.isClosed) await _controller.close();
  }

  /// Prune often enough that a device which vanished leaves the list promptly,
  /// without spinning a timer faster than the announcements it is checking.
  Duration get _pruneInterval =>
      config.announceInterval < const Duration(seconds: 1)
          ? config.announceInterval
          : const Duration(seconds: 1);

  // -------------------------------------------------------------- the sockets

  /// Binds the listening socket and everything hanging off it. Separate from
  /// [start] because recovery does exactly this again, without the app having
  /// asked for anything.
  Future<void> _openSockets() async {
    final group = InternetAddress(config.multicastAddress);
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      config.port,
      reuseAddress: true,
      reusePort: true,
    );

    socket.multicastLoopback = true;
    socket.broadcastEnabled = true;
    // Best effort on the default interface; _scanInterfaces joins the named
    // ones. Either may already cover the other, and a duplicate join throws.
    _tryJoin(socket, group, null);

    _socket = socket;
    _group = group;
    // Every callback checks the socket is still the current one: a socket being
    // torn down goes on delivering events, and they must not be mistaken for
    // news about its replacement.
    socket.listen(
      (event) => _onEvent(socket, event),
      onError: (Object _) => _onSocketLost(socket),
      onDone: () => _onSocketLost(socket),
    );

    await _scanInterfaces();
  }

  void _closeSockets({bool sayGoodbye = false}) {
    final socket = _socket;
    final group = _group;
    if (socket != null && group != null) {
      // Say goodbye so peers drop us at once instead of waiting out
      // [DiscoveryConfig.staleAfter]. A device that is killed outright cannot
      // send this, which is exactly what the staleness timeout is for. A
      // recovery says nothing: we are not leaving, the network moved.
      if (sayGoodbye) _sendBye();
      try {
        socket.leaveMulticast(group);
      } catch (_) {
        // The interface may already be gone, or the socket closed under us -
        // which is exactly the case recovery exists for. Either way there is
        // nothing left to leave.
      }
      socket.close();
    }
    for (final sender in _senders.values) {
      sender.close();
    }
    _senders.clear();
    _joined.clear();
    _socket = null;
    _group = null;
  }

  /// The listening socket died under us: the interface went away, or Android
  /// reclaimed it while the app was in the background. Nothing above here can
  /// do anything about that, so rebuild it.
  void _onSocketLost(RawDatagramSocket socket) {
    if (!_running || _socket != socket) return;
    _scheduleRecovery();
  }

  /// Rebinds after a delay that grows while it keeps failing, so a device with
  /// no network at all is not retrying in a tight loop in the user's pocket.
  void _scheduleRecovery() {
    if (!_running || _recoverTimer != null) return;
    _recoverTimer = Timer(_recoveryDelay, () async {
      _recoverTimer = null;
      if (!_running) return;

      _closeSockets();
      try {
        await _openSockets();
      } catch (_) {
        _recoveryDelay = _recoveryDelay * 2 < _maxRecoveryDelay
            ? _recoveryDelay * 2
            : _maxRecoveryDelay;
        _scheduleRecovery();
        return;
      }
      if (!_running) return;

      _recoveryDelay = _minRecoveryDelay;
      _failedSends = 0;
      // Back on the air. Everything we knew was learned on a network we may no
      // longer be on, so ask again rather than trusting the old list; whatever
      // does not answer is pruned on the usual timeout.
      _announce();
      _burstQueries();
    });
  }

  // ---------------------------------------------------------------- interfaces

  /// Brings the set of sending sockets and multicast memberships in line with
  /// the interfaces the machine actually has right now.
  Future<void> _scanInterfaces() async {
    final socket = _socket;
    final group = _group;
    if (!_running || socket == null || group == null) return;

    final List<NetworkInterface> interfaces;
    try {
      interfaces = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );
    } catch (_) {
      return; // Not something we can fix here; the next scan tries again.
    }
    if (!_running || _socket != socket) return; // stopped while enumerating

    // An interface that went away and came back has lost its membership, so
    // forget the ones no longer present and (re)join everything that is.
    final present = interfaces.map((i) => i.name).toSet();
    _joined.removeWhere((name) => !present.contains(name));

    final live = <String>{};
    var opened = false;
    for (final interface in interfaces) {
      if (_joined.add(interface.name)) _tryJoin(socket, group, interface);

      for (final address in interface.addresses) {
        live.add(address.address);
        if (_senders.containsKey(address.address)) continue;
        final sender = await _bindSender(address);
        if (sender == null) continue;
        if (!_running) {
          sender.close();
          return;
        }
        _senders[address.address] = sender;
        opened = true;
      }
    }

    for (final gone in _senders.keys.where((a) => !live.contains(a)).toList()) {
      _senders.remove(gone)?.close();
    }

    // A new interface means a network we have never announced on. Say hello on
    // it rather than waiting for the next tick.
    if (opened) {
      _announce();
      _burstQueries();
    }
  }

  Future<RawDatagramSocket?> _bindSender(InternetAddress address) async {
    try {
      final sender = await RawDatagramSocket.bind(address, 0);
      sender.multicastLoopback = true;
      sender.broadcastEnabled = true;
      // Replies land on the listening socket; anything arriving here is a copy
      // of our own traffic and reading it would only be to discard it.
      sender.listen((_) => sender.receive(), onError: (Object _) {});
      return sender;
    } catch (_) {
      return null; // Address disappeared between listing and binding, say.
    }
  }

  void _tryJoin(
    RawDatagramSocket socket,
    InternetAddress group,
    NetworkInterface? interface,
  ) {
    try {
      socket.joinMulticast(group, interface);
    } catch (_) {
      // Already a member (the default join often covers a named one), or the
      // interface does not do multicast. Neither is worth failing over.
    }
  }

  // ----------------------------------------------------------------- receiving

  void _onEvent(RawDatagramSocket socket, RawSocketEvent event) {
    if (_socket != socket) return; // an old socket, still draining
    if (event == RawSocketEvent.closed) return _onSocketLost(socket);
    if (event != RawSocketEvent.read) return;

    final Datagram? datagram;
    try {
      datagram = socket.receive();
    } catch (_) {
      // A read reported on a socket that has since been closed.
      return _onSocketLost(socket);
    }
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
        // Our own query, looped back or broadcast to ourselves.
        if (message['id'] == self.id) return;
        _replySoon();
      case 'announce':
        _onAnnounce(message, datagram.address.address);
      case 'bye':
        _onBye(message);
    }
  }

  /// A peer that is shutting down cleanly. Drop it now so it stops being
  /// offered for syncing the moment its app closes.
  void _onBye(Map<String, Object?> message) {
    final id = message['id'];
    if (id is! String || id == self.id) return;
    if (_peers.remove(id) != null) _emit();
  }

  void _onAnnounce(Map<String, Object?> message, String sourceAddress) {
    final body = message['device'];
    if (body is! Map<String, Object?>) return;

    final DeviceInfo announced;
    try {
      announced = DeviceInfo.fromAnnouncement(body, address: sourceAddress);
    } catch (_) {
      return; // Malformed announcement.
    }

    final info = _sanitise(announced);
    if (info == null) return;
    if (info.id == self.id) return; // Never list ourselves.

    final existing = _peers[info.id];
    // Room for the devices we already know; a flood of invented ids does not
    // get to push them out or grow without bound.
    if (existing == null && _peers.length >= config.maxPeers) return;

    // A device we have not shown to be listening does not go on the list yet.
    if (existing == null && config.verifyPeers) {
      _verify(info);
      return;
    }

    final now = DateTime.now();
    var chosen = info;
    var addressSeen = now;

    if (existing != null && existing.info.address != info.address) {
      // The same device reaching us down more than one path - it announces on
      // every interface it has, and a machine with a docker bridge or two
      // networks onto the same segment delivers several of them. Whichever
      // arrived last is not a decision: taking it would make the address flap,
      // the row rewrite itself every couple of seconds, and an open sync screen
      // reconnect over and over. So stay with the address already in use while
      // it is still answering, and only move when it has gone quiet - which is
      // what a device that genuinely changed address looks like.
      if (now.difference(existing.addressSeen) <= config.staleAfter) {
        chosen = info.copyWith(address: existing.info.address);
        addressSeen = existing.addressSeen;
      }
    }

    _peers[info.id] = _SeenPeer(chosen, now, addressSeen);

    final changed = existing == null ||
        existing.info.name != chosen.name ||
        existing.info.address != chosen.address ||
        existing.info.port != chosen.port;
    if (changed) _emit();

    // Someone we had not heard of. Answer directly rather than making them wait
    // for our next scheduled announcement - this is what makes two apps started
    // together appear on each other's screens at once.
    if (existing == null) _replySoon();
  }

  /// Knocks on a newly heard device's door, and lists it if it answers.
  ///
  /// One knock at a time per device, and not again while the last one is still
  /// in flight: announcements arrive every couple of seconds, and a device that
  /// is not listening would otherwise collect a connection attempt per packet.
  void _verify(DeviceInfo info) {
    final address = info.address;
    if (address == null) return;

    final now = DateTime.now();
    final tried = _unverified[info.id];
    if (tried != null && now.difference(tried) < config.verifyTimeout) return;
    _unverified[info.id] = now;

    _probe(address, info.port).then((reachable) {
      _unverified.remove(info.id);
      if (!_running || !reachable) return;
      if (_peers.containsKey(info.id) || _peers.length >= config.maxPeers) {
        return;
      }
      // It answered: the app is open over there and ready to pair. Only now is
      // it something worth putting in front of the user.
      _peers[info.id] = _SeenPeer(info, DateTime.now(), DateTime.now());
      _emit();
      _replySoon();
    }).catchError((Object _) {
      _unverified.remove(info.id);
    });
  }

  /// Rejects what cannot be a real device and tidies what merely looks awful,
  /// because every one of these fields ends up rendered in a list.
  DeviceInfo? _sanitise(DeviceInfo info) {
    if (info.id.isEmpty || info.id.length > _maxIdLength) return null;
    if (info.port < 1 || info.port > 65535) return null;

    final control = RegExp('[\\u0000-\\u001f\\u007f]');
    var name = info.name.replaceAll(control, ' ').trim();
    if (name.isEmpty) return null;
    if (name.length > _maxNameLength) {
      name = '${name.substring(0, _maxNameLength - 1)}…';
    }
    if (name == info.name) return info;

    return DeviceInfo(
      id: info.id,
      name: name,
      platform: info.platform,
      port: info.port,
      address: info.address,
    );
  }

  // ------------------------------------------------------------------- sending

  void _announce() {
    _send({
      'magic': _magic,
      'type': 'announce',
      'device': self.toAnnouncement(),
    });
  }

  void _sendQuery() {
    _send({'magic': _magic, 'type': 'query', 'id': self.id});
  }

  void _sendBye() {
    _send({'magic': _magic, 'type': 'bye', 'id': self.id});
  }

  /// Asks more than once, spread out. A single UDP query that happens to be
  /// dropped - routine on Wi-Fi - would otherwise cost a full announce interval
  /// of staring at an empty screen.
  void _burstQueries() {
    _sendQuery();
    final step = config.announceInterval.inMilliseconds;
    for (final fraction in const [0.25, 0.6, 1.2]) {
      _later(Duration(milliseconds: (step * fraction).round()), _sendQuery);
    }
  }

  /// Answers someone else's packet after a short random delay, at most once per
  /// window. The jitter keeps a roomful of devices from all replying in the
  /// same millisecond and losing each other's packets to a collision.
  void _replySoon() {
    final now = DateTime.now();
    final last = _lastReply;
    if (last != null && now.difference(last) < config.announceInterval ~/ 4) {
      return;
    }
    _lastReply = now;
    _later(_jitter, _announce);
  }

  Duration get _jitter {
    final ceiling =
        min(200, max(1, config.announceInterval.inMilliseconds ~/ 8));
    return Duration(milliseconds: _random.nextInt(ceiling));
  }

  void _later(Duration delay, void Function() action) {
    late final Timer timer;
    timer = Timer(delay, () {
      _pending.remove(timer);
      if (_running) action();
    });
    _pending.add(timer);
  }

  void _send(Map<String, Object?> message) {
    final socket = _socket;
    final group = _group;
    if (socket == null || group == null) return;

    final payload = utf8.encode(jsonEncode(message));
    var delivered = false;

    // Down the default route, which is also what reaches another app on this
    // same machine.
    delivered |= _sendFrom(socket, payload, group);

    for (final sender in _senders.values) {
      delivered |= _sendFrom(sender, payload, group);
      if (config.useBroadcast) {
        delivered |= _sendFrom(sender, payload, _broadcastAddress);
      }
    }
    if (config.useBroadcast && _senders.isEmpty) {
      delivered |= _sendFrom(socket, payload, _broadcastAddress);
    }

    // Not one path took it. Either the machine is off every network, or the
    // socket is a corpse; the second is the one we can do something about.
    if (delivered) {
      _failedSends = 0;
    } else if (++_failedSends >= _failedSendsBeforeRecovery) {
      _scheduleRecovery();
    }
  }

  /// Sends one packet, reporting whether it left. False is not a failure worth
  /// telling anyone about on its own: an interface that just went down or a
  /// network briefly unreachable is ordinary on a laptop, and the next
  /// announcement goes out over whatever is left.
  bool _sendFrom(
    RawDatagramSocket socket,
    List<int> payload,
    InternetAddress target,
  ) {
    try {
      return socket.send(payload, target, config.port) > 0;
    } catch (_) {
      return false;
    }
  }

  // --------------------------------------------------------------- bookkeeping

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
  _SeenPeer(this.info, this.lastSeen, this.addressSeen);

  final DeviceInfo info;

  /// Any packet from this device, whichever interface it came down.
  final DateTime lastSeen;

  /// A packet from the address actually being used for it. Once this goes
  /// stale the device is followed to whatever address it is announcing from.
  final DateTime addressSeen;
}
