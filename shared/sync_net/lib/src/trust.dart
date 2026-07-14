import 'device_info.dart';

/// A device this one has paired with. [secret] is the shared key both sides
/// derived during pairing; a later connection proves knowledge of it instead of
/// asking the user to confirm again.
class TrustedPeer {
  const TrustedPeer({
    required this.id,
    required this.name,
    required this.platform,
    required this.secret,
  });

  final String id;
  final String name;
  final DevicePlatform platform;
  final String secret;

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'platform': platform.name,
        'secret': secret,
      };

  factory TrustedPeer.fromJson(Map<String, Object?> json) => TrustedPeer(
        id: json['id']! as String,
        name: json['name']! as String,
        platform: devicePlatformFromString(json['platform']! as String),
        secret: json['secret']! as String,
      );
}

/// Where trusted pairs are kept. The interface is pure so the engine stays
/// platform-neutral; each app plugs in its own persistence (the apps back it
/// with shared_preferences).
abstract interface class TrustStore {
  Future<List<TrustedPeer>> all();
  Future<TrustedPeer?> get(String id);
  Future<void> add(TrustedPeer peer);
  Future<void> remove(String id);
}

/// A non-persistent [TrustStore], handy for tests and for a first run before an
/// app supplies its own.
class MemoryTrustStore implements TrustStore {
  final _peers = <String, TrustedPeer>{};

  @override
  Future<List<TrustedPeer>> all() async => _peers.values.toList();

  @override
  Future<TrustedPeer?> get(String id) async => _peers[id];

  @override
  Future<void> add(TrustedPeer peer) async => _peers[peer.id] = peer;

  @override
  Future<void> remove(String id) async => _peers.remove(id);
}
