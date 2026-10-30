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
  static const prepareDir = 'dir.prepare';
  static const dirReady = 'dir.ready';
  static const getManifest = 'manifest.get';
  static const manifest = 'manifest';
  static const getFile = 'file.get';
  static const file = 'file';

  // Push (writing into the peer's shared directory).
  static const putFile = 'file.put';
  static const deleteFile = 'file.delete';
  static const ack = 'ok';

  static const error = 'error';
}

/// A directory this device offers to a peer, addressed by [name].
class SharedDir {
  const SharedDir(this.name, {this.files, this.bytes, this.missing = false});

  final String name;

  /// How many files it holds, and what they weigh, when the far end said. Null
  /// from a device too old to say, which is not the same as zero and must not
  /// be shown as one.
  final int? files;
  final int? bytes;

  /// The folder is shared but no longer there. Worth saying out loud: a folder
  /// that has moved or is on an unmounted drive otherwise reads as an empty
  /// one, and an empty folder is a legitimate thing to sync.
  final bool missing;
}

/// Which folders are being synced right now, so two devices cannot work on the
/// same one at once.
///
/// Every write already refuses to go over something it did not expect, which is
/// what keeps data safe. This is the other half: two devices syncing the same
/// folder at the same moment would otherwise both do half a sync and report a
/// pile of failures each. One at a time, and the second is told why.
class FolderLocks {
  final _held = <String, Object>{};

  /// Takes the folder for one session, or returns false if a different device
  /// has it.
  ///
  /// The same device syncing again takes over from itself: a session that just
  /// ended may not have been noticed yet - a socket closing is not instant -
  /// and telling a device it is competing with itself would make every second
  /// sync fail.
  bool take(String folder, Object holder) {
    final current = _held[folder];
    if (current != null && current != holder) return false;
    _held[folder] = holder;
    return true;
  }

  /// Gives the folder back, unless someone else has since taken it - which is
  /// what a slow disconnect looks like from here.
  void release(String folder, Object holder) {
    if (_held[folder] == holder) _held.remove(folder);
  }

  bool isBusy(String folder) => _held.containsKey(folder);
}

/// A paired device asking this one to make a folder available under [folder].
///
/// It arrives when the other device wants to sync something this one does not
/// offer yet - most of the time because nobody has said where it should live
/// here. Only the person holding this device can answer that, so the app puts a
/// folder chooser in front of them; the device that asked is told to wait and
/// watch for the folder appearing.
class FolderRequest {
  const FolderRequest({required this.folder, required this.peerId});

  final String folder;
  final String peerId;
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
  SyncClient._(this._conn, this._frames, this.peer,
      {this.peerKeepsWindowsNames = false});

  final PeerConnection _conn;
  final StreamIterator<Frame> _frames;
  final DeviceInfo peer;

  /// The peer keeps its files on Windows and cannot hold every name this
  /// device can. Said by the peer itself when the session opens, so it holds
  /// whatever the trust store remembers about its platform; a sync with it
  /// leaves those names out on both sides (see [windowsUnsafePaths]).
  final bool peerKeepsWindowsNames;

  /// Connects to [host]:[port], authenticates as [self] using the shared secret
  /// from [trusted], and verifies the server proves the same secret back.
  /// [cancel] gives up on a device that is not answering: the attempt is
  /// dropped where it stands rather than run to its timeout.
  static Future<SyncClient> connect(
    String host,
    int port, {
    required DeviceInfo self,
    required TrustedPeer trusted,
    Future<void>? cancel,
  }) async {
    final conn = await PeerConnection.connect(host, port, cancel: cancel);
    final frames = StreamIterator(conn.frames);
    try {
      conn.send({'type': SessionType.hello, 'deviceId': self.id});

      final challenge = await _expect(frames, SessionType.challenge, conn);
      final serverNonce = challenge.header['nonce']! as String;

      final clientNonce = _nonce();
      conn.send({
        'type': SessionType.auth,
        'nonce': clientNonce,
        'mac': _mac(trusted.secret, 'client:$serverNonce'),
      });

      final reply = await _next(frames, conn);
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
        peerKeepsWindowsNames: reply.header['names'] == 'windows',
      );
    } catch (_) {
      await closeConnection(conn, frames);
      rethrow;
    }
  }

  Future<List<SharedDir>> listDirectories() async {
    _conn.send({'type': SessionType.listDirs});
    final reply = await _expect(_frames, SessionType.dirs, _conn);
    final list = (reply.header['dirs']! as List).cast<Map<String, Object?>>();
    return list
        .map((d) => SharedDir(
              d['name']! as String,
              files: d['files'] as int?,
              bytes: d['bytes'] as int?,
              missing: d['missing'] == true,
            ))
        .toList();
  }

  /// Asks the peer whether it has a place for [name], and to choose one if it
  /// has not. False means the question has been put to the person holding that
  /// device; the folder appears in its listing once they answer.
  Future<bool> prepareDirectory(String name) async {
    _conn.send({'type': SessionType.prepareDir, 'name': name});
    final reply = await _expect(_frames, SessionType.dirReady, _conn);
    return reply.header['ready'] == true;
  }

  /// Fetches the peer's current manifest for [name].
  Future<Manifest> fetchManifest(String name) async {
    _conn.send({'type': SessionType.getManifest, 'name': name});
    final reply = await _next(_frames, _conn);
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
    final reply = await _next(_frames, _conn);
    if (reply.type == SessionType.error) {
      throw SessionException(reply.header['message']?.toString() ?? 'error');
    }
    if (reply.type != SessionType.file) {
      throw const SessionException('unexpected reply to file request');
    }
    return reply.body;
  }

  /// Writes [bytes] to [path] inside the peer's shared directory [name],
  /// creating or overwriting it. Waits for the peer to acknowledge the write.
  ///
  /// The content hash travels with the request so the peer can reject a body
  /// that arrived corrupted instead of writing it into the vault.
  /// Writes [bytes] into the peer's [name] at [path].
  ///
  /// [expect] is the hash of what this device believed was there when it worked
  /// out that this write was the right thing to do - null meaning "nothing was
  /// there". The peer checks it and refuses if reality has moved on, which is
  /// the difference between two devices syncing at once and one of them quietly
  /// undoing the other's work.
  Future<void> putFile(
    String name,
    String path,
    List<int> bytes, {
    String? expect,
    bool expectAbsent = false,
  }) async {
    _conn.send({
      'type': SessionType.putFile,
      'name': name,
      'path': path,
      'hash': sha256.convert(bytes).toString(),
      if (expect != null) 'expect': expect,
      if (expectAbsent) 'expectAbsent': true,
    }, bytes);
    await _expectAck('file put');
  }

  /// Deletes [path] inside the peer's shared directory [name], if it is still
  /// the file this device decided to delete - see [putFile] for why.
  Future<void> deleteFile(String name, String path, {String? expect}) async {
    _conn.send({
      'type': SessionType.deleteFile,
      'name': name,
      'path': path,
      if (expect != null) 'expect': expect,
    });
    await _expectAck('file delete');
  }

  Future<void> _expectAck(String what) async {
    final reply = await _next(_frames, _conn);
    if (reply.type == SessionType.error) {
      throw SessionException(reply.header['message']?.toString() ?? 'error');
    }
    if (reply.type != SessionType.ack) {
      throw SessionException('unexpected reply to $what');
    }
  }

  Future<void> close() => closeConnection(_conn, _frames);
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
  void Function(FolderRequest)? onFolderRequest,
  FolderLocks? locks,
  bool windowsNames = false,
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
    // Tells the other device to leave out what this one cannot hold. A device
    // too old to know the field ignores it, and the writes below refuse those
    // names anyway.
    if (windowsNames) 'names': 'windows',
  });

  // Folders this session took, so they are given back however it ends.
  final held = <String>{};

  try {
    while (await frames.moveNext()) {
      final request = frames.current;

      // Anything that names a folder claims it for this session: a sync is a
      // conversation about one folder, and two at once are two half-syncs.
      final folder = request.header['name'];
      if (folder is String && folder.isNotEmpty && !held.contains(folder)) {
        if (locks != null && !locks.take(folder, trusted.id)) {
          conn.send({
            'type': SessionType.error,
            'message': 'that folder is syncing with another device right now',
          });
          continue;
        }
        held.add(folder);
      }

      switch (request.type) {
        case SessionType.listDirs:
          await _serveDirs(conn, directories);
        case SessionType.prepareDir:
          _servePrepare(
              conn, directories, request, trusted.id, onFolderRequest);
        case SessionType.getManifest:
          await _serveManifest(conn, directories, request);
        case SessionType.getFile:
          await _serveFile(conn, directories, request);
        case SessionType.putFile:
          await _servePut(conn, directories, request, windowsNames);
        case SessionType.deleteFile:
          await _serveDelete(conn, directories, request, windowsNames);
        default:
          conn.send({'type': SessionType.error, 'message': 'unknown request'});
      }
    }
  } finally {
    for (final folder in held) {
      locks?.release(folder, trusted.id);
    }
  }
  await conn.close();
}

/// The folders this device offers, each with how much is in it.
///
/// Where a folder lives is not part of the answer: it is the offering device's
/// business, nothing on the other end shows it, and a path is a small thing to
/// hand over for nothing in return.
///
/// The measurement costs a walk of the directory, which is worth it: it is what
/// lets the other device show "1.2 GB there, nothing here" before anything is
/// tapped, and it is the difference between a sync that explains itself and one
/// that says "nothing to do" over an empty folder nobody meant to share.
Future<void> _serveDirs(
  PeerConnection conn,
  DirectorySource directories,
) async {
  final dirs = <Map<String, Object?>>[];
  for (final dir in directories.list()) {
    final path = directories.pathOf(dir.name);
    final root = path == null ? null : Directory(path);
    final exists = root?.existsSync() ?? false;
    final size = exists ? await Manifest.measure(root!) : null;
    dirs.add({
      'name': dir.name,
      'missing': !exists,
      if (size != null) 'files': size.files,
      if (size != null) 'bytes': size.bytes,
    });
  }
  conn.send({'type': SessionType.dirs, 'dirs': dirs});
}

/// Answers whether this device has somewhere to keep [name], and asks its user
/// if it does not.
///
/// The answer comes back at once either way. Choosing a folder takes as long as
/// a person takes, and holding a connection open across that is a connection
/// that will time out; the asking device is told "not yet" and looks again.
void _servePrepare(
  PeerConnection conn,
  DirectorySource directories,
  Frame request,
  String peerId,
  void Function(FolderRequest)? onFolderRequest,
) {
  final name = request.header['name']?.toString() ?? '';
  final ready = name.isNotEmpty && directories.pathOf(name) != null;
  conn.send({'type': SessionType.dirReady, 'ready': ready});

  if (!ready && name.isNotEmpty) {
    onFolderRequest?.call(FolderRequest(folder: name, peerId: peerId));
  }
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

  // A folder that is shared but not there is not an empty folder. Scanning it
  // would answer "no files", the other device would take that for the truth,
  // and a sync in that state deletes a vault. The local side already refuses
  // this (MissingRootException); the serving side has to refuse it too.
  final root = Directory(path);
  if (!root.existsSync()) {
    conn.send({
      'type': SessionType.error,
      'message': 'the shared folder is missing on that device',
    });
    return;
  }

  final manifest = await Manifest.scan(root);
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

Future<void> _servePut(
  PeerConnection conn,
  DirectorySource directories,
  Frame request,
  bool windowsNames,
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

  final misnamed = windowsNames ? _windowsRefusal(root, rel, resolved) : null;
  if (misnamed != null) {
    conn.send({'type': SessionType.error, 'message': misnamed});
    return;
  }

  // Reject a body that did not survive the trip intact, rather than writing
  // corrupted content into the vault.
  final expected = request.header['hash'];
  if (expected is String &&
      sha256.convert(request.body).toString() != expected) {
    conn.send({'type': SessionType.error, 'message': 'hash mismatch'});
    return;
  }

  final target = File(resolved);
  final stale = await _movedOn(target, request);
  if (stale != null) {
    conn.send({'type': SessionType.error, 'message': stale});
    return;
  }

  // Same atomic write as applyChanges: temp file then rename, so an interrupted
  // push never leaves a half-written file in the peer's vault.
  await target.parent.create(recursive: true);
  final temp = File('$resolved.synctmp');
  await temp.writeAsBytes(request.body, flush: true);
  await temp.rename(resolved);

  conn.send({'type': SessionType.ack, 'path': rel});
}

/// Whether the file is no longer what the other device thought it was.
///
/// A sync is worked out against a snapshot and applied a moment later. In
/// between, the file can be edited here or written by a third device syncing at
/// the same time - and carrying out the old plan would then throw away work
/// nobody chose to lose. The writer says what it expected to find; if it is not
/// there any more, the write is refused and the sync reports a failure, which
/// leaves the agreed ancestor where it was so the next run sees a real
/// conflict instead of a silent deletion.
///
/// Returns why it was refused, or null to go ahead.
Future<String?> _movedOn(File target, Frame request) async {
  final expected = request.header['expect'];
  final expectAbsent = request.header['expectAbsent'] == true;
  if (expected is! String && !expectAbsent) return null; // nothing claimed

  final exists = target.existsSync();
  if (expectAbsent) {
    return exists
        ? 'a file appeared there since this sync was worked out'
        : null;
  }
  if (!exists) return 'the file was removed since this sync was worked out';

  final actual = sha256.convert(await target.readAsBytes()).toString();
  return actual == expected
      ? null
      : 'the file changed since this sync was worked out';
}

Future<void> _serveDelete(
  PeerConnection conn,
  DirectorySource directories,
  Frame request,
  bool windowsNames,
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

  final misnamed = windowsNames ? _windowsRefusal(root, rel, resolved) : null;
  if (misnamed != null) {
    conn.send({'type': SessionType.error, 'message': misnamed});
    return;
  }

  final file = File(resolved);
  final stale = await _movedOn(file, request);
  if (stale != null) {
    conn.send({'type': SessionType.error, 'message': stale});
    return;
  }

  if (file.existsSync()) await file.delete();
  // A folder deleted on the peer arrives as deletions of the files inside it;
  // clear out the directories that are now empty so the folder really goes.
  await removeEmptyParents(resolved, root);
  conn.send({'type': SessionType.ack, 'path': rel});
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

/// Why this device, keeping its files on Windows, will not write or delete
/// [rel], or null to go ahead.
///
/// A device that knows the rules never asks: it was told about them when the
/// session opened and left these names out. This is for one that does not - an
/// older version - and for whatever slips past it, because Windows itself
/// refuses almost none of this and does something else instead.
String? _windowsRefusal(String root, String rel, String resolved) {
  if (!isWindowsSafe(rel)) return 'that name cannot be kept on Windows';
  if (_spelledDifferently(root, resolved)) {
    return 'a file or folder differing only in letter case is already there';
  }
  return null;
}

/// Whether the part of [resolved] that already exists is spelled differently
/// on disk. `note.md` written where `Note.md` is lands in `Note.md`, and so does
/// `notes/a.md` under `Notes`: a case-insensitive file system answers to either
/// spelling and keeps the first.
bool _spelledDifferently(String root, String resolved) {
  final rootNorm = p.normalize(p.absolute(root));
  var existing = resolved;
  while (FileSystemEntity.typeSync(existing, followLinks: false) ==
      FileSystemEntityType.notFound) {
    existing = p.dirname(existing);
    if (!p.isWithin(rootNorm, existing)) return false; // nothing below root yet
  }
  try {
    // Resolving goes through the file system, which answers with the spelling
    // it actually holds. Only the part below the root is compared, so a root
    // reached through a link or typed in another case does not count.
    final actual = p.relative(File(existing).resolveSymbolicLinksSync(),
        from: Directory(rootNorm).resolveSymbolicLinksSync());
    return actual != p.relative(existing, from: rootNorm);
  } on FileSystemException {
    return false;
  }
}

String _nonce() {
  // Reuse the pairing nonce generator's shape: 16 random bytes, hex.
  return generateNonce();
}

/// The next frame, waiting only as long as the link shows signs of life when
/// [conn] is given. Requests pass it; the server's idle wait for the next
/// request does not, since a session with nobody typing into it is not broken.
Future<Frame> _next(StreamIterator<Frame> frames, [PeerConnection? conn]) async {
  final moved = conn == null
      ? frames.moveNext()
      : conn.awaitReply(frames.moveNext());
  if (!await moved) {
    throw const SessionException('connection closed');
  }
  return frames.current;
}

Future<Frame> _expect(StreamIterator<Frame> frames, String type,
    [PeerConnection? conn]) async {
  final frame = await _next(frames, conn);
  if (frame.type != type) {
    throw SessionException('expected $type but got ${frame.type}');
  }
  return frame;
}
