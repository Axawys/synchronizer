import 'dart:math';

/// Which kind of machine a peer is. Kept deliberately small; it only drives
/// presentation (an icon, a label) and never behaviour.
enum DevicePlatform { linux, android, unknown }

DevicePlatform devicePlatformFromString(String value) {
  switch (value) {
    case 'linux':
      return DevicePlatform.linux;
    case 'android':
      return DevicePlatform.android;
    default:
      return DevicePlatform.unknown;
  }
}

/// Identity and reach of one device on the local network.
///
/// [id] is stable for the lifetime of an installation and is what
/// distinguishes a device from every other, including a renamed one. [name] is
/// the human-facing label. [address] and [port] are how the pairing/sync
/// transport connects back to it, and are populated from the network packet
/// rather than announced by the device itself.
class DeviceInfo {
  const DeviceInfo({
    required this.id,
    required this.name,
    required this.platform,
    required this.port,
    this.address,
  });

  final String id;
  final String name;
  final DevicePlatform platform;

  /// TCP port on which this device accepts pairing and sync connections.
  final int port;

  /// Source IP the announcement arrived from. Null before it is placed on the
  /// wire (for example the local device describing itself).
  final String? address;

  DeviceInfo copyWith({String? address}) => DeviceInfo(
        id: id,
        name: name,
        platform: platform,
        port: port,
        address: address ?? this.address,
      );

  /// The subset that travels in a discovery announcement. The address is
  /// intentionally excluded: a device does not get to assert its own IP, we
  /// read it from where the packet actually came from.
  Map<String, Object?> toAnnouncement() => {
        'id': id,
        'name': name,
        'platform': platform.name,
        'port': port,
      };

  factory DeviceInfo.fromAnnouncement(
    Map<String, Object?> json, {
    String? address,
  }) =>
      DeviceInfo(
        id: json['id']! as String,
        name: json['name']! as String,
        platform: devicePlatformFromString(json['platform']! as String),
        port: json['port']! as int,
        address: address,
      );

  /// Generates a fresh random device identifier (128 bits, hex encoded). The
  /// caller is expected to persist it so a device keeps the same id across
  /// restarts.
  static String generateId() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// A readable fallback name for when a device cannot report its real model,
  /// e.g. "Calm Otter". Memorable enough to pick out of a list, which a random
  /// id would not be. The caller persists it so the name stays put.
  static String randomFriendlyName() {
    final rng = Random.secure();
    final adjective = _adjectives[rng.nextInt(_adjectives.length)];
    final animal = _animals[rng.nextInt(_animals.length)];
    return '$adjective $animal';
  }

  static const _adjectives = [
    'Amber', 'Bold', 'Brave', 'Bright', 'Calm', 'Clever', 'Copper', 'Curious',
    'Eager', 'Gentle', 'Happy', 'Jolly', 'Keen', 'Lively', 'Lucky', 'Merry',
    'Mellow', 'Noble', 'Quick', 'Quiet', 'Silver', 'Snug', 'Sunny', 'Swift',
    'Tidy', 'Warm', 'Wise', 'Zesty',
  ];

  static const _animals = [
    'Badger', 'Beaver', 'Bison', 'Cricket', 'Dolphin', 'Falcon', 'Ferret',
    'Finch', 'Fox', 'Gecko', 'Heron', 'Ibex', 'Jackdaw', 'Lemur', 'Lynx',
    'Magpie', 'Marten', 'Moth', 'Newt', 'Otter', 'Owl', 'Panda', 'Puffin',
    'Raven', 'Robin', 'Seal', 'Sparrow', 'Stoat', 'Tapir', 'Walrus', 'Weasel',
    'Wombat',
  ];

  @override
  bool operator ==(Object other) => other is DeviceInfo && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'DeviceInfo($name, $id, ${address ?? '?'}:$port)';
}
