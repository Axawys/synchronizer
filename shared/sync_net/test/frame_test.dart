import 'dart:async';
import 'dart:typed_data';

import 'package:sync_net/sync_net.dart';
import 'package:test/test.dart';

void main() {
  group('frame codec', () {
    test('round-trips a header and body', () async {
      final bytes = encodeFrame({'type': 'hello', 'n': 7}, [1, 2, 3, 4]);

      final frames = await readFrames(Stream.value(bytes)).toList();

      expect(frames, hasLength(1));
      expect(frames.single.type, 'hello');
      expect(frames.single.header['n'], 7);
      expect(frames.single.body, [1, 2, 3, 4]);
    });

    test('round-trips a header with no body', () async {
      final bytes = encodeFrame({'type': 'ping'});
      final frames = await readFrames(Stream.value(bytes)).toList();
      expect(frames.single.hasBody, isFalse);
    });

    test('reassembles a frame split across byte-by-byte reads', () async {
      final bytes = encodeFrame({'type': 'x'}, [9, 9, 9]);
      final drip = Stream.fromIterable(bytes.map((b) => Uint8List.fromList([b])));

      final frames = await readFrames(drip).toList();

      expect(frames.single.type, 'x');
      expect(frames.single.body, [9, 9, 9]);
    });

    test('splits several frames bundled into one read', () async {
      final a = encodeFrame({'type': 'a'});
      final b = encodeFrame({'type': 'b'}, [1]);
      final joined = Uint8List.fromList([...a, ...b]);

      final frames = await readFrames(Stream.value(joined)).toList();

      expect(frames.map((f) => f.type), ['a', 'b']);
    });

    test('rejects a body length over the limit', () {
      final bytes = encodeFrame({'type': 'big'}, [0, 0, 0]);
      expect(
        readFrames(Stream.value(bytes), maxBodyBytes: 2).toList(),
        throwsA(isA<FrameFormatException>()),
      );
    });

    test('rejects a non-JSON header', () {
      // headerLen=1, bodyLen=0, header byte '{' alone is invalid JSON.
      final bad = Uint8List.fromList([0, 0, 0, 1, 0, 0, 0, 0, 0x7b]);
      expect(
        readFrames(Stream.value(bad)).toList(),
        throwsA(isA<FrameFormatException>()),
      );
    });
  });
}
