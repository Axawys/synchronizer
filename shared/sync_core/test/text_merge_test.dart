import 'package:sync_core/sync_core.dart';
import 'package:test/test.dart';

void main() {
  group('merge3 combines edits that do not overlap', () {
    test('each side edits a different end of the file', () {
      final base = ['title', 'one', 'two', 'three'];
      final ours = ['TITLE', 'one', 'two', 'three']; // we changed the top
      final theirs = ['title', 'one', 'two', 'THREE']; // they changed the bottom

      final result = merge3(base, ours, theirs);

      expect(result.hasConflicts, isFalse);
      // Both edits survive, which is the whole point of merging.
      expect(result.clean, ['TITLE', 'one', 'two', 'THREE']);
    });

    test('one side adds a line, the other removes a different one', () {
      final base = ['a', 'b', 'c'];
      final ours = ['a', 'b', 'c', 'd']; // added at the end
      final theirs = ['a', 'c']; // removed b

      final result = merge3(base, ours, theirs);

      expect(result.hasConflicts, isFalse);
      expect(result.clean, ['a', 'c', 'd']);
    });

    test('only one side changed anything', () {
      final base = ['a', 'b'];
      final result = merge3(base, base, ['a', 'b', 'c']);

      expect(result.hasConflicts, isFalse);
      expect(result.clean, ['a', 'b', 'c']);
    });

    test('nobody changed anything', () {
      final base = ['a', 'b'];
      final result = merge3(base, base, base);

      expect(result.hasConflicts, isFalse);
      expect(result.clean, base);
    });

    test('both sides made the identical edit', () {
      final base = ['a', 'b'];
      final same = ['a', 'B'];
      final result = merge3(base, same, same);

      expect(result.hasConflicts, isFalse, reason: 'agreement is not a conflict');
      expect(result.clean, same);
    });

    test('insertions far apart both land', () {
      final base = ['1', '2', '3', '4', '5', '6'];
      final ours = ['1', 'ours', '2', '3', '4', '5', '6'];
      final theirs = ['1', '2', '3', '4', '5', 'theirs', '6'];

      final result = merge3(base, ours, theirs);

      expect(result.hasConflicts, isFalse);
      expect(result.clean, ['1', 'ours', '2', '3', '4', '5', 'theirs', '6']);
    });
  });

  group('merge3 reports genuine conflicts', () {
    test('both sides changed the same line differently', () {
      final base = ['a', 'b', 'c'];
      final ours = ['a', 'OURS', 'c'];
      final theirs = ['a', 'THEIRS', 'c'];

      final result = merge3(base, ours, theirs);

      expect(result.hasConflicts, isTrue);
      expect(result.clean, isNull);

      final conflict = result.conflicts.single;
      expect(conflict.base, ['b']);
      expect(conflict.ours, ['OURS']);
      expect(conflict.theirs, ['THEIRS']);
    });

    test('one side edits a line the other deletes', () {
      final base = ['a', 'b', 'c'];
      final ours = ['a', 'b changed', 'c'];
      final theirs = ['a', 'c'];

      final result = merge3(base, ours, theirs);

      expect(result.hasConflicts, isTrue);
      expect(result.conflicts.single.ours, ['b changed']);
      expect(result.conflicts.single.theirs, isEmpty);
    });

    test('unaffected lines around a conflict stay merged', () {
      final base = ['keep', 'x', 'tail'];
      final ours = ['keep', 'ours', 'tail'];
      final theirs = ['keep', 'theirs', 'tail'];

      final result = merge3(base, ours, theirs);

      expect(result.chunks.length, 3);
      expect((result.chunks.first as MergedLines).lines, ['keep']);
      expect(result.chunks[1], isA<ConflictChunk>());
      expect((result.chunks.last as MergedLines).lines, ['tail']);
    });

    test('resolve picks a side per conflict and keeps the merged rest', () {
      // Untouched lines separate the edits, so only the middle is in dispute:
      // our change to the top and their change to the bottom both stand.
      final base = ['top', 'keep', 'x', 'keep too', 'bottom'];
      final ours = ['TOP', 'keep', 'ours', 'keep too', 'bottom'];
      final theirs = ['top', 'keep', 'theirs', 'keep too', 'BOTTOM'];

      final result = merge3(base, ours, theirs);
      expect(result.conflicts.single.base, ['x']);

      expect(result.resolve((c) => c.theirs),
          ['TOP', 'keep', 'theirs', 'keep too', 'BOTTOM']);
      expect(result.resolve((c) => c.ours),
          ['TOP', 'keep', 'ours', 'keep too', 'BOTTOM']);
    });

    test('edits with no untouched line between them conflict as one region', () {
      // Each side's changed region reaches the middle line, so the regions
      // overlap and the whole span is disputed - the same call git makes.
      final base = ['top', 'x', 'bottom'];
      final ours = ['TOP', 'ours', 'bottom'];
      final theirs = ['top', 'theirs', 'BOTTOM'];

      final result = merge3(base, ours, theirs);

      final conflict = result.conflicts.single;
      expect(conflict.ours, ['TOP', 'ours', 'bottom']);
      expect(conflict.theirs, ['top', 'theirs', 'BOTTOM']);
    });
  });

  group('merge3 on real-ish notes', () {
    test('two devices editing one markdown note in different places', () {
      final base = splitLines('# Notes\n\n- milk\n- bread\n');
      final ours = splitLines('# Notes\n\n- milk\n- bread\n- cheese\n');
      final theirs = splitLines('# Shopping\n\n- milk\n- bread\n');

      final result = merge3(base, ours, theirs);

      expect(result.hasConflicts, isFalse);
      expect(joinLines(result.clean!), '# Shopping\n\n- milk\n- bread\n- cheese\n');
    });
  });
}
