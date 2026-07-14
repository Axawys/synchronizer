import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sync_core/sync_core.dart';

import 'connection.dart';
import 'device_info.dart';
import 'frame.dart';
import 'pairing.dart' show generateNonce;
import 'trust.dart';

/// Message types for an established sync session (after pairing).
abstract final class SessionType {
  static const hello = 'session.hello';
  static const challenge = 'session.challenge';
  static const auth = 'session.auth';
  static const ok = 'session.ok';
  static const denied = 'session.denied';

  static const listDirs = 'dirs.list';
  static const dirs = 'dirs';
  static const getManifest = 'manifest.get';
  static const manifest = 'manifest';
  static const getFile = 'file.get';
  static const file = 'file';
  static const error = 'error';
}

/// A directory this device offers to a peer, addressed by [name]. The path is
/// local and never leaves the device.
class SharedDir {
  const SharedDir(this.name);
  final String name;
}

/// Supplies the directories the session server will serve, and resolves a name
/// to its local path. Apps implement this over their own settings.
abstract interface class DirectorySource {
  List<SharedDir> list();

  /// Absolute local path for [name], or null if it is not shared.
  String? pathOf(String name);
}

/// A fixed name-to-path map, the common case and what tests use.
class MapDirectorySource implements DirectorySource {
  MapDirectorySource(this._paths);
  final Map<String, String> _paths;

  @override
  List<SharedDir> list() =>
      _paths.keys.map(SharedDir.new).toList(growable: false);

  @override
  String? pathOf(String name) => _paths[name];
}

/// Raised on any session-level failure (authentication refused, a protocol
/// violation, a request the server rejected).
class SessionException implements Exception {
  const SessionException(this.message);
  final String message;
  @override
  String toString() => 'SessionException: $message';
}

String _mac(String secret, String data) =>
    Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(data)).toString();

/// Client side of a sync session: authenticate against a paired device, then
/// browse and pull its shared directories.
class SyncClient {
  SyncClient._(this._conn, this._frames, this.peer);

  final PeerConnection _conn;
  final StreamIterator<Frame> _frames;
  final DeviceInfo peer;

  /// Connects to [host]:[port], authenticates as [self] using the shared secret
  /// from [trusted], and verifies the server proves the same secret back.
  static Future<SyncClient> connect(
    String host,
    int port, {
    required DeviceInfo self,
    required TrustedPeer trusted,
  }) async {
    final conn = await PeerConnection.connect(host, port);
    final frames = StreamIterator(conn.frames);
    try {
      conn.send({'type': SessionType.hello, 'deviceId': self.id});

      final challenge = await _expect(frames, SessionType.challenge);
      final serverNonce = challenge.header['nonce']! as String;

      final clientNonce = _nonce();
      conn.send({
        'type': SessionType.auth,
        'nonce': clientNonce,
        'mac': _mac(trusted.secret, 'client:$serverNonce'),
      });

      final reply = await _next(frames);
      if (reply.type == SessionType.denied) {
        throw SessionException(
            'authentication refused: ${reply.header['reason'] ?? 'unknown'}');
      }
      if (reply.type != SessionType.ok) {
        throw const SessionException('unexpected reply during authentication');
      }
      final serverMac = reply.header['mac'];
      if (serverMac != _mac(trusted.secret, 'server:$clientNonce')) {
        throw const SessionException('server failed to prove the shared secret');
      }

      return SyncClient._(
        conn,
        frames,
        DeviceInfo(
          id: trusted.id,
          name: trusted.name,
          platform: trusted.platform,
          port: port,
          address: host,
        ),
      );
    } catch (_) {
      await frames.cancel();
      await conn.close();
      rethrow;
    }
  }

  Future<List<SharedDir>> listDirectories() async {
    _conn.send({'type': SessionType.listDirs});
    final reply = await _expect(_frames, SessionType.dirs);
    final list = (reply.header['dirs']! as List).cast<Map<String, Object?>>();
    return list.map((d) => SharedDir(d['name']! as String)).toList();
  }

  /// Fetches the peer's current manifest for [name].
  Future<Manifest> fetchManifest(String name) async {
    _conn.send({'type': SessionType.getManifest, 'name': name});
    final reply = await _next(_frames);
    if (reply.type == SessionType.error) {
      throw SessionException(reply.header['message']?.toString() ?? 'error');
    }
    if (reply.type != SessionType.manifest) {
      throw const SessionException('unexpected reply to manifest request');
    }
    return Manifest.decode(utf8.decode(reply.body));
  }

  /// Fetches the raw bytes of one file inside [name].
  Future<Uint8List> fetchFile(String name, String path) async {
    _conn.send({'type': SessionType.getFile, 'name': name, 'path': path});
    final reply = await _next(_frames);
    if (reply.type == SessionType.error) {
      throw SessionException(reply.header['message']?.toString() ?? 'error');
    }
    if (reply.type != SessionType.file) {
      throw const SessionException('unexpected reply to file request');
    }
    return reply.body;
  }

  Future<void> close() async {
    await _frames.cancel();
    await _conn.close();
  }
}

/// Server side for one connection whose first frame is a [SessionType.hello].
/// Authenticates the caller against the trust store, then answers directory,
/// manifest and file requests until the peer disconnects.
///
/// Driven by [PeerServer].
Future<void> handleSession(
  PeerConnection conn,
  StreamIterator<Frame> frames,
  Frame hello, {
  required DeviceInfo self,
  required TrustStore trust,
  required DirectorySource directories,
}) async {
  final peerId = hello.header['deviceId'];
  final trusted = peerId is String ? await trust.get(peerId) : null;
  if (trusted == null) {
    conn.send({'type': SessionType.denied, 'reason': 'not paired'});
    await conn.close();
    return;
  }

  final serverNonce = _nonce();
  conn.send({'type': SessionType.challenge, 'nonce': serverNonce});

  if (!await frames.moveNext()) {
    await conn.close();
    return;
  }
  final auth = frames.current;
  if (auth.type != SessionType.auth ||
      auth.header['mac'] != _mac(trusted.secret, 'client:$serverNonce')) {
    conn.send({'type': SessionType.denied, 'reason': 'bad credentials'});
    await conn.close();
    return;
  }
  final clientNonce = auth.header['nonce']! as String;
  conn.send({
    'type': SessionType.ok,
    'mac': _mac(trusted.secret, 'server:$clientNonce'),
  });

  while (await frames.moveNext()) {
    final request = frames.current;
    switch (request.type) {
      case SessionType.listDirs:
        conn.send({
          'type': SessionType.dirs,
          'dirs': directories.list().map((d) => {'name': d.name}).toList(),
        });
      case SessionType.getManifest:
        await _serveManifest(conn, directories, request);
      case SessionType.getFile:
        await _serveFile(conn, directories, request);
      default:
        conn.send({'type': SessionType.error, 'message': 'unknown request'});
    }
  }
  await conn.close();
}

Future<void> _serveManifest(
  PeerConnection conn,
  DirectorySource directories,
  Frame request,
) async {
  final path = directories.pathOf(request.header['name']?.toString() ?? '');
  if (path == null) {
    conn.send({'type': SessionType.error, 'message': 'no such directory'});
    return;
  }
  final manifest = await Manifest.scan(Directory(path));
  conn.send({'type': SessionType.manifest}, utf8.encode(manifest.encode()));
}

Future<void> _serveFile(
  PeerConnection conn,
  DirectorySource directories,
  Frame request,
) async {
  final root = directories.pathOf(request.header['name']?.toString() ?? '');
  final rel = request.header['path']?.toString() ?? '';
  if (root == null) {
    conn.send({'type': SessionType.error, 'message': 'no such directory'});
    return;
  }

  final resolved = _resolveWithin(root, rel);
  if (resolved == null) {
    conn.send({'type': SessionType.error, 'message': 'invalid path'});
    return;
  }

  final file = File(resolved);
  if (!file.existsSync()) {
    conn.send({'type': SessionType.error, 'message': 'not found'});
    return;
  }
  conn.send(
    {'type': SessionType.file, 'path': rel},
    await file.readAsBytes(),
  );
}

/// Joins [rel] onto [root], refusing anything that escapes [root] (a `..` or an
/// absolute path). Returns null if the result would leave the shared directory.
String? _resolveWithin(String root, String rel) {
  if (rel.isEmpty || p.posix.isAbsolute(rel) || p.isAbsolute(rel)) return null;
  final rootNorm = p.normalize(p.absolute(root));
  final joined = p.normalize(p.join(rootNorm, rel));
  if (joined != rootNorm && !p.isWithin(rootNorm, joined)) return null;
  return joined;
}

String _nonce() {
  // Reuse the pairing nonce generator's shape: 16 random bytes, hex.
  return generateNonce();
}

Future<Frame> _next(StreamIterator<Frame> frames) async {
  if (!await frames.moveNext()) {
    throw const SessionException('connection closed');
  }
  return frames.current;
}

Future<Frame> _expect(StreamIterator<Frame> frames, String type) async {
  final frame = await _next(frames);
  if (frame.type != type) {
    throw SessionException('expected $type but got ${frame.type}');
  }
  return frame;
}
