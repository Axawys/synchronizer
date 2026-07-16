/// What happened to one line between two versions of a file.
enum DiffOp {
  /// Present in both, unchanged.
  equal,

  /// Only in the new version: it will be added.
  insert,

  /// Only in the old version: it will be removed.
  delete,
}

/// One line of a diff, carrying what happened to it.
class DiffLine {
  const DiffLine(this.op, this.text);

  final DiffOp op;
  final String text;

  @override
  String toString() => switch (op) {
        DiffOp.equal => '  $text',
        DiffOp.insert => '+ $text',
        DiffOp.delete => '- $text',
      };
}

/// Splits a file's text into lines for diffing.
///
/// A trailing newline shows up as a final empty line, which is what makes
/// joining the result back together give the original text again, and makes
/// "added a newline at the end" a visible change rather than a silent one.
List<String> splitLines(String text) => text.split('\n');

/// Joins lines produced by [splitLines] back into a file's text.
String joinLines(List<String> lines) => lines.join('\n');

/// The lines two versions share, in order: everything neither of them can be
/// said to have touched.
///
/// This stands in for the real ancestor when none was kept - a folder synced
/// for the first time, where both devices already had the file. Merging against
/// it combines the parts that differ instead of forcing a whole-file choice.
///
/// It is a guess, and it has one honest limitation: with no ancestor there is no
/// way to tell "this device added a line" from "the other device removed it", so
/// it reads every difference as an addition and a line deleted on one side comes
/// back. It errs towards keeping text, never towards losing it, and callers are
/// expected to say so rather than pass it off as a real merge.
List<String> commonBase(List<String> ours, List<String> theirs) => [
      for (final line in diffLines(ours, theirs))
        if (line.op == DiffOp.equal) line.text,
    ];

/// Above this many cells in the comparison table we stop looking for the
/// prettiest diff. Only reached by very large files with very large edits, and
/// only after the common head and tail have already been trimmed away.
const int _maxCells = 1000000;

/// Compares two versions of a file line by line.
///
/// Uses a longest-common-subsequence walk, the same shape of diff a person
/// expects from a version control tool: shared lines stay put and only what
/// really moved shows up as added or removed.
List<DiffLine> diffLines(List<String> a, List<String> b) {
  // Most edits touch a small part of a file, so trimming the identical head and
  // tail first keeps the expensive comparison down to the part that changed.
  var start = 0;
  while (start < a.length && start < b.length && a[start] == b[start]) {
    start++;
  }
  var endA = a.length;
  var endB = b.length;
  while (endA > start && endB > start && a[endA - 1] == b[endB - 1]) {
    endA--;
    endB--;
  }

  return [
    for (var i = 0; i < start; i++) DiffLine(DiffOp.equal, a[i]),
    ..._diffCore(a.sublist(start, endA), b.sublist(start, endB)),
    for (var i = endA; i < a.length; i++) DiffLine(DiffOp.equal, a[i]),
  ];
}

List<DiffLine> _diffCore(List<String> a, List<String> b) {
  if (a.isEmpty) return [for (final line in b) DiffLine(DiffOp.insert, line)];
  if (b.isEmpty) return [for (final line in a) DiffLine(DiffOp.delete, line)];

  if ((a.length + 1) * (b.length + 1) > _maxCells) {
    // Too big to align line by line: report it as a wholesale replacement,
    // which is still a truthful diff, just a blunt one.
    return [
      for (final line in a) DiffLine(DiffOp.delete, line),
      for (final line in b) DiffLine(DiffOp.insert, line),
    ];
  }

  final n = a.length;
  final m = b.length;

  // lcs[i][j] = length of the longest common subsequence of a[i:] and b[j:].
  final lcs = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      lcs[i][j] = a[i] == b[j]
          ? lcs[i + 1][j + 1] + 1
          : (lcs[i + 1][j] >= lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
    }
  }

  final out = <DiffLine>[];
  var i = 0;
  var j = 0;
  while (i < n && j < m) {
    if (a[i] == b[j]) {
      out.add(DiffLine(DiffOp.equal, a[i]));
      i++;
      j++;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
      out.add(DiffLine(DiffOp.delete, a[i]));
      i++;
    } else {
      out.add(DiffLine(DiffOp.insert, b[j]));
      j++;
    }
  }
  while (i < n) {
    out.add(DiffLine(DiffOp.delete, a[i++]));
  }
  while (j < m) {
    out.add(DiffLine(DiffOp.insert, b[j++]));
  }
  return out;
}
