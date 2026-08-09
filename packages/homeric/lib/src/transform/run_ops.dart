/// Internal run-list surgery shared by the transform steps.
///
/// The document model deliberately never merges or splits runs on its own;
/// this file is the edit-layer counterpart that does. All functions are pure
/// and share untouched [InlineRun] instances by reference.
library;

import '../model/inline_run.dart';

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
    if (runEnd <= start || runStart >= end) {
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
