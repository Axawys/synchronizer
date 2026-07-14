import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// One message on the wire: a small JSON [header] and an optional binary
/// [body]. The header says what the message is and carries its metadata; the
/// body carries bulk bytes (a file's contents, a serialized manifest) that
/// would be wasteful to squeeze through JSON.
class Frame {
  Frame(this.header, this.body);

  final Map<String, Object?> header;
  final Uint8List body;

  /// Convenience accessor for the `type` discriminator every message sets.
  String get type => header['type'] as String? ?? '';

  bool get hasBody => body.isNotEmpty;
}

/// Upper bound on a header, to reject a garbled or hostile length prefix before
/// allocating for it. Headers are metadata and stay tiny.
const int kMaxHeaderBytes = 1 << 20; // 1 MiB

/// Default upper bound on a body. File transfer is chunked above this, so a
/// single frame never needs to be enormous.
const int kDefaultMaxBodyBytes = 64 << 20; // 64 MiB

/// Serializes a frame: `[headerLen u32][bodyLen u32][header][body]`, lengths
/// big-endian.
Uint8List encodeFrame(Map<String, Object?> header, [List<int>? body]) {
  final headerBytes = utf8.encode(jsonEncode(header));
  final bodyBytes = body ?? const <int>[];

  final prefix = ByteData(8)
    ..setUint32(0, headerBytes.length)
    ..setUint32(4, bodyBytes.length);

  final bodyStart = 8 + headerBytes.length;
  final out = Uint8List(bodyStart + bodyBytes.length)
    ..setRange(0, 8, prefix.buffer.asUint8List())
    ..setRange(8, bodyStart, headerBytes)
    ..setRange(bodyStart, bodyStart + bodyBytes.length, bodyBytes);
  return out;
}

/// Turns a byte stream (typically a socket) into a stream of [Frame]s,
/// reassembling frames that arrive split across several reads or several frames
/// bundled into one read.
Stream<Frame> readFrames(
  Stream<List<int>> source, {
  int maxBodyBytes = kDefaultMaxBodyBytes,
}) async* {
  final chunks = <Uint8List>[];
  var buffered = 0;

  await for (final chunk in source) {
    if (chunk.isEmpty) continue;
    chunks.add(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
    buffered += chunk.length;

    while (buffered >= 8) {
      final head = _peek(chunks, 8);
      final lengths = ByteData.sublistView(head);
      final headerLen = lengths.getUint32(0);
      final bodyLen = lengths.getUint32(4);

      if (headerLen > kMaxHeaderBytes) {
        throw const FrameFormatException('header length exceeds limit');
      }
      if (bodyLen > maxBodyBytes) {
        throw const FrameFormatException('body length exceeds limit');
      }

      final total = 8 + headerLen + bodyLen;
      if (buffered < total) break;

      final full = _take(chunks, total);
      buffered -= total;

      final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(
          Uint8List.sublistView(full, 8, 8 + headerLen),
        ));
      } on FormatException catch (e) {
        throw FrameFormatException('header is not valid JSON: ${e.message}');
      }
      if (decoded is! Map<String, Object?>) {
        throw const FrameFormatException('header is not a JSON object');
      }

      yield Frame(decoded, Uint8List.sublistView(full, 8 + headerLen, total));
    }
  }
}

/// Raised when the byte stream does not conform to the frame format. It means
/// the peer is not speaking our protocol (or the stream is corrupt), so the
/// connection should be dropped.
class FrameFormatException implements Exception {
  const FrameFormatException(this.message);
  final String message;
  @override
  String toString() => 'FrameFormatException: $message';
}

/// Copies the first [n] bytes spread across [chunks] without consuming them.
Uint8List _peek(List<Uint8List> chunks, int n) {
  final out = Uint8List(n);
  var offset = 0;
  for (final chunk in chunks) {
    if (offset >= n) break;
    final take = min(chunk.length, n - offset);
    out.setRange(offset, offset + take, chunk);
    offset += take;
  }
  return out;
}

/// Removes and returns the first [n] bytes from [chunks]. The caller must have
/// checked at least [n] bytes are buffered.
Uint8List _take(List<Uint8List> chunks, int n) {
  final out = Uint8List(n);
  var offset = 0;
  while (offset < n) {
    final chunk = chunks.first;
    final need = n - offset;
    if (chunk.length <= need) {
      out.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
      chunks.removeAt(0);
    } else {
      out.setRange(offset, offset + need, chunk);
      chunks[0] = Uint8List.sublistView(chunk, need);
      offset += need;
    }
  }
  return out;
}
