import 'text_diff.dart';

/// A piece of a merged file.
sealed class MergeChunk {
  const MergeChunk();
}

/// A stretch both sides agree on: either untouched, or changed by only one of
/// them, or changed by both in exactly the same way.
final class MergedLines extends MergeChunk {
  const MergedLines(this.lines);
  final List<String> lines;
}

/// A stretch both sides changed differently. Nothing can decide this but the
/// user, so it is handed over with all three versions.
final class ConflictChunk extends MergeChunk {
  const ConflictChunk({
    required this.base,
    required this.ours,
    required this.theirs,
    this.ourStart = 1,
    this.theirStart = 1,
  });

  /// How the lines looked at the last sync.
  final List<String> base;

  /// How they look on this device.
  final List<String> ours;

  /// How they look on the other device.
  final List<String> theirs;

  /// Where [ours] begins in this device's file, counting from 1, and likewise
  /// [theirStart] in the other device's file.
  ///
  /// A merge rebuilds the file, so a chunk on its own has no idea where it came
  /// from. Tracking it while merging is the only way to tell the user which
  /// lines a conflict is about rather than showing them floating text.
  final int ourStart;
  final int theirStart;
}

/// The outcome of merging one file.
class TextMergeResult {
  const TextMergeResult(this.chunks);

  final List<MergeChunk> chunks;

  List<ConflictChunk> get conflicts => chunks.whereType<ConflictChunk>().toList();

  bool get hasConflicts => chunks.any((c) => c is ConflictChunk);

  /// The merged file, when nothing needed asking about. Null if there are
  /// conflicts, because then there is no single answer to give.
  List<String>? get clean => hasConflicts
      ? null
      : [for (final chunk in chunks) ...(chunk as MergedLines).lines];

  /// The merged file, with [choose] settling each conflict.
  List<String> resolve(List<String> Function(ConflictChunk) choose) => [
        for (final chunk in chunks)
          ...switch (chunk) {
            MergedLines(:final lines) => lines,
            ConflictChunk() => choose(chunk),
          },
      ];
}

/// Merges two edited versions of a file against the version they both started
/// from, the way a version control tool does.
///
/// Edits that touch different parts of the file are simply combined: if one
/// device added a line at the top and the other fixed a typo at the bottom,
/// both survive and nobody is asked anything. Only where the two changed the
/// same lines differently does a [ConflictChunk] come back, and even then an
/// identical edit made on both sides counts as agreement.
///
/// This is why the base version matters: without it there is no way to tell who
/// changed what, and every difference would look like a conflict.
TextMergeResult merge3(
  List<String> base,
  List<String> ours,
  List<String> theirs,
) {
  final ourRegions = _changedRegions(base, ours);
  final theirRegions = _changedRegions(base, theirs);

  final chunks = <MergeChunk>[];
  final stable = <String>[];
  void flushStable() {
    if (stable.isEmpty) return;
    chunks.add(MergedLines(List.of(stable)));
    stable.clear();
  }

  var baseIndex = 0;
  var oi = 0;
  var ti = 0;

  // Where we are in each side's own file, counting from 1, so a conflict can
  // say which of their lines it means.
  var ourLine = 1;
  var theirLine = 1;

  while (oi < ourRegions.length || ti < theirRegions.length) {
    final nextOur = oi < ourRegions.length ? ourRegions[oi].start : null;
    final nextTheir = ti < theirRegions.length ? theirRegions[ti].start : null;
    final start = [
      if (nextOur != null) nextOur,
      if (nextTheir != null) nextTheir,
    ].reduce((a, b) => a < b ? a : b);

    // Untouched base lines leading up to the next change. Neither side moved
    // them, so both files hold every one of them.
    while (baseIndex < start) {
      stable.add(base[baseIndex++]);
      ourLine++;
      theirLine++;
    }

    // Pull in every region either side has that overlaps this one, so two
    // changes that run into each other are judged together rather than
    // half-applied.
    var end = start;
    final ourGroup = <_Region>[];
    final theirGroup = <_Region>[];
    bool grew;
    do {
      grew = false;
      while (oi < ourRegions.length && ourRegions[oi].start <= end) {
        final region = ourRegions[oi++];
        ourGroup.add(region);
        if (region.end > end) end = region.end;
        grew = true;
      }
      while (ti < theirRegions.length && theirRegions[ti].start <= end) {
        final region = theirRegions[ti++];
        theirGroup.add(region);
        if (region.end > end) end = region.end;
        grew = true;
      }
    } while (grew);

    final ourLines = _sideLines(base, ourGroup, start, end);
    final theirLines = _sideLines(base, theirGroup, start, end);

    // A side that left the range alone still holds the base lines for it, so
    // its line count advances by the range, not by what the other side wrote.
    if (theirGroup.isEmpty) {
      stable.addAll(ourLines); // only we touched it
      ourLine += ourLines.length;
      theirLine += end - start;
    } else if (ourGroup.isEmpty) {
      stable.addAll(theirLines); // only they touched it
      ourLine += end - start;
      theirLine += theirLines.length;
    } else if (_sameLines(ourLines, theirLines)) {
      stable.addAll(ourLines); // both made the same edit
      ourLine += ourLines.length;
      theirLine += theirLines.length;
    } else {
      flushStable();
      chunks.add(ConflictChunk(
        base: base.sublist(start, end),
        ours: ourLines,
        theirs: theirLines,
        ourStart: ourLine,
        theirStart: theirLine,
      ));
      ourLine += ourLines.length;
      theirLine += theirLines.length;
    }

    baseIndex = end;
  }

  while (baseIndex < base.length) {
    stable.add(base[baseIndex++]);
  }
  flushStable();

  return TextMergeResult(chunks);
}

/// A stretch of the base file one side replaced with [lines]. A pure insertion
/// has [start] == [end].
class _Region {
  _Region(this.start, this.end, this.lines);
  final int start;
  int end;
  final List<String> lines;
}

/// Expresses one side's edits as replacements of base line ranges, which is
/// what lets both sides be lined up against each other by base position.
List<_Region> _changedRegions(List<String> base, List<String> side) {
  final regions = <_Region>[];
  var baseIndex = 0;
  _Region? open;

  for (final line in diffLines(base, side)) {
    switch (line.op) {
      case DiffOp.equal:
        open = null;
        baseIndex++;
      case DiffOp.delete:
        open ??= _addRegion(regions, baseIndex);
        baseIndex++;
        open.end = baseIndex;
      case DiffOp.insert:
        open ??= _addRegion(regions, baseIndex);
        open.lines.add(line.text);
    }
  }
  return regions;
}

_Region _addRegion(List<_Region> regions, int at) {
  final region = _Region(at, at, []);
  regions.add(region);
  return region;
}

/// Rebuilds how one side reads across the base range [start, end).
List<String> _sideLines(
  List<String> base,
  List<_Region> regions,
  int start,
  int end,
) {
  final out = <String>[];
  var index = start;
  for (final region in regions) {
    while (index < region.start) {
      out.add(base[index++]);
    }
    out.addAll(region.lines);
    index = region.end;
  }
  while (index < end) {
    out.add(base[index++]);
  }
  return out;
}

bool _sameLines(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
