import 'package:sync_core/sync_core.dart';
import 'package:test/test.dart';

void main() {
  /// Renders a diff compactly so expectations read like a diff.
  List<String> render(List<DiffLine> diff) => [
        for (final line in diff)
          '${switch (line.op) {
            DiffOp.equal => ' ',
            DiffOp.insert => '+',
            DiffOp.delete => '-',
          }}${line.text}'
      ];

  group('diffLines', () {
    test('identical files show every line as unchanged', () {
      final diff = diffLines(['a', 'b'], ['a', 'b']);
      expect(render(diff), [' a', ' b']);
    });

    test('an inserted line in the middle', () {
      final diff = diffLines(['a', 'c'], ['a', 'b', 'c']);
      expect(render(diff), [' a', '+b', ' c']);
    });

    test('a removed line in the middle', () {
      final diff = diffLines(['a', 'b', 'c'], ['a', 'c']);
      expect(render(diff), [' a', '-b', ' c']);
    });

    test('a changed line reads as a removal and an addition', () {
      final diff = diffLines(['a', 'b', 'c'], ['a', 'B', 'c']);
      expect(render(diff), [' a', '-b', '+B', ' c']);
    });

    test('into an empty file everything is added', () {
      expect(render(diffLines([], ['a', 'b'])), ['+a', '+b']);
    });

    test('from a file to nothing everything is removed', () {
      expect(render(diffLines(['a', 'b'], [])), ['-a', '-b']);
    });

    test('shared lines are kept rather than rewritten wholesale', () {
      // The naive answer is to delete all of a and insert all of b; a proper
      // diff keeps the common lines in place.
      final diff = diffLines(
        ['one', 'two', 'three', 'four'],
        ['one', 'two', 'THREE', 'four'],
      );
      expect(render(diff), [' one', ' two', '-three', '+THREE', ' four']);
    });
  });

  group('splitLines and joinLines', () {
    test('round-trip preserves the text', () {
      const text = 'first\nsecond\nthird';
      expect(joinLines(splitLines(text)), text);
    });

    test('a trailing newline survives the round-trip', () {
      const text = 'first\n';
      expect(splitLines(text), ['first', '']);
      expect(joinLines(splitLines(text)), text);
    });

    test('adding a trailing newline is a visible change', () {
      final diff = diffLines(splitLines('a'), splitLines('a\n'));
      expect(diff.where((l) => l.op != DiffOp.equal), isNotEmpty);
    });
  });
}
