import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:sync_net/sync_net.dart';

/// A [TrustStore] backed by shared_preferences, storing the trusted pairs as a
/// single JSON list. Small by nature — a handful of devices — so rewriting the
/// whole list on each change is fine.
class PrefsTrustStore implements TrustStore {
  static const _key = 'trusted_peers';

  Future<List<TrustedPeer>> _read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    final list = (jsonDecode(raw) as List).cast<Map<String, Object?>>();
    return list.map(TrustedPeer.fromJson).toList();
  }

  Future<void> _write(List<TrustedPeer> peers) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(peers.map((p) => p.toJson()).toList()),
    );
  }

  @override
  Future<List<TrustedPeer>> all() => _read();

  @override
  Future<TrustedPeer?> get(String id) async {
    final peers = await _read();
    for (final peer in peers) {
      if (peer.id == id) return peer;
    }
    return null;
  }

  @override
  Future<void> add(TrustedPeer peer) async {
    final peers = await _read()
      ..removeWhere((p) => p.id == peer.id)
      ..add(peer);
    await _write(peers);
  }

  @override
  Future<void> remove(String id) async {
    final peers = await _read()..removeWhere((p) => p.id == id);
    await _write(peers);
  }
}
