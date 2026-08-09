/// Internal run-list surgery shared by the transform steps.
///
/// The document model deliberately never merges or splits runs on its own;
/// this file is the edit-layer counterpart that does. All functions are pure
/// and share untouched [InlineRun] instances by reference.
library;

import '../model/document.dart';
import '../model/inline_run.dart';
import '../model/position.dart';

/// Calls [visit] for every block whose content intersects the global token
/// range `[from, to)`, with the intersection as local content offsets
/// (`localStart < localEnd`; blocks the range only touches at open/close
/// tokens are not visited).
///
/// This lives here (rather than on [Document]) because it is transform-
/// layer plumbing: the shared "walk the content of a token range" loop
/// behind mark application, mark segmentation, and content detection.
void visitContentRanges(
  Document doc,
  int from,
  int to,
  void Function(int blockIndex, int localStart, int localEnd) visit,
) {
  if (to <= from) return;
  final rFrom = doc.resolve(from);
  final rTo = doc.resolve(to);
  final firstIndex = rFrom is InlinePosition
      ? rFrom.blockIndex
      : (rFrom as BlockBoundaryPosition).insertionIndex;
  final endIndex = rTo is InlinePosition
      ? rTo.blockIndex + 1
      : (rTo as BlockBoundaryPosition).insertionIndex;
  for (var i = firstIndex; i < endIndex; i++) {
    final contentStart = doc.positionBeforeBlock(i) + 1;
    final contentLength = doc.blocks[i].contentLength;
    var localStart = from - contentStart;
    if (localStart < 0) localStart = 0;
    var localEnd = to - contentStart;
    if (localEnd > contentLength) localEnd = contentLength;
    if (localEnd > localStart) visit(i, localStart, localEnd);
  }
}

/// Returns the runs covering content offsets `[start, end)` of [runs].
///
/// Runs fully inside the range are shared by reference; runs cut by a range
/// edge are substring copies.
List<InlineRun> sliceRuns(List<InlineRun> runs, int start, int end) {
  final out = <InlineRun>[];
  var pos = 0;
  for (final run in runs) {
    final runStart = pos;
    final runEnd = pos + run.length;
    pos = runEnd;
    if (runEnd <= start) continue;
    if (runStart >= end) break;
    final localStart = (start > runStart ? start : runStart) - runStart;
    final localEnd = (end < runEnd ? end : runEnd) - runStart;
    out.add(localStart == 0 && localEnd == run.length
        ? run
        : run.copyWith(text: run.text.substring(localStart, localEnd)));
  }
  return out;
}

/// Drops empty runs and merges adjacent runs with deep-equal attribute sets.
List<InlineRun> normalizeRuns(Iterable<InlineRun> runs) {
  final out = <InlineRun>[];
  for (final run in runs) {
    if (run.isEmpty) continue;
    if (out.isNotEmpty && out.last.hasSameAttributesAs(run)) {
      out[out.length - 1] = out.last.copyWith(text: out.last.text + run.text);
    } else {
      out.add(run);
    }
  }
  return out;
}

/// Rewrites the run portions covering content offsets `[start, end)` with
/// [transform], leaving everything outside the range shared by reference.
///
/// Returns `null` (rejecting the whole operation) when [transform] returns
/// `null` for any portion. The result is not normalized.
List<InlineRun>? transformRunsInRange(
  List<InlineRun> runs,
  int start,
  int end,
  InlineRun? Function(InlineRun portion) transform,
) {
  final out = <InlineRun>[];
  var pos = 0;
  for (final run in runs) {
    final runStart = pos;
    final runEnd = pos + run.length;
    pos = runEnd;
    // An empty run carries no characters, so a character-range transform
    // must not see it — without this guard a strict mark step would fail
    // on an (entirely legal) empty run sitting inside the range.
    if (run.isEmpty || runEnd <= start || runStart >= end) {
      out.add(run);
      continue;
    }
    final localStart = (start > runStart ? start : runStart) - runStart;
    final localEnd = (end < runEnd ? end : runEnd) - runStart;
    if (localStart > 0) {
      out.add(run.copyWith(text: run.text.substring(0, localStart)));
    }
    final portion = localStart == 0 && localEnd == run.length
        ? run
        : run.copyWith(text: run.text.substring(localStart, localEnd));
    final mapped = transform(portion);
    if (mapped == null) return null;
    out.add(mapped);
    if (localEnd < run.length) {
      out.add(run.copyWith(text: run.text.substring(localEnd)));
    }
  }
  return out;
}
