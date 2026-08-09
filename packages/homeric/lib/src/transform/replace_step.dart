// ReplaceStep semantics ported from prosemirror-transform
// src/replace_step.ts @ 662b7a937bafde19b7e2a83241dbc8888e257c89; MIT
// (c) Marijn Haverbeke. The upstream source was read to learn the
// semantics; this implementation is original Dart and no source code was
// copied. The flat block model reduces PM's open-depth slice fitting to a
// one-level problem: a slice end is either open (merges runs into the
// adjacent block) or closed (complete blocks), and head/tail merges at
// block boundaries are the full extent of fitting.

import '../model/block.dart';
import '../model/document.dart';
import '../model/inline_run.dart';
import '../model/position.dart';
import 'change_list.dart';
import 'mapping.dart';
import 'run_ops.dart';
import 'step.dart';
import 'step_map.dart';

/// A piece of replacement content: zero or more blocks, each end either
/// open or closed.
///
/// An **open start** means the first block's runs merge into the block
/// containing the replace range's `from` (that block's identity — id, type,
/// attribute bag — wins; the first slice block's identity is ignored). An
/// **open end** means the last block's runs absorb the tail of the block
/// containing `to`, and the *slice* block's identity wins there — which is
/// how a join's inverse restores the trailing block's id and attributes,
/// and how a split hands the trailing half its fresh id.
///
/// A slice that is a single open-both block is plain inline content; when
/// applied inside one block it collapses entirely into that block.
final class Slice {
  /// Creates a slice over [content]. An empty slice must be closed.
  Slice(List<Block> content, {this.openStart = false, this.openEnd = false})
      : content = List<Block>.unmodifiable(content) {
    if (this.content.isEmpty && (openStart || openEnd)) {
      throw ArgumentError('an empty slice cannot be open');
    }
  }

  const Slice._empty()
      : content = const <Block>[],
        openStart = false,
        openEnd = false;

  /// The empty slice — pure deletion.
  static const Slice empty = Slice._empty();

  /// The slice's blocks (unmodifiable).
  final List<Block> content;

  /// Whether the first block merges into the block before the range.
  final bool openStart;

  /// Whether the last block absorbs the tail of the block after the range.
  final bool openEnd;

  /// Whether this slice inserts nothing.
  bool get isEmpty => content.isEmpty;

  /// Token size of the inserted content: block sizes minus one token per
  /// open end.
  int get size {
    var total = 0;
    for (final block in content) {
      total += block.size;
    }
    return total - (openStart ? 1 : 0) - (openEnd ? 1 : 0);
  }

  @override
  String toString() =>
      'Slice(${content.length} blocks, ${openStart ? 'open' : 'closed'}/'
      '${openEnd ? 'open' : 'closed'})';
}

/// Extracts the slice covering `[from, to)` of [doc] — the content a
/// `ReplaceStep(from, to, …)` would delete, in the shape its inverse needs
/// to restore it.
///
/// Blocks cut by an open end are carried with their identity (id, type,
/// attribute bag), so re-applying the slice restores block identity
/// exactly. Throws [PositionOutOfRangeError] / [ArgumentError] on invalid
/// ranges (this is a query, not a step application).
Slice sliceBetween(Document doc, int from, int to) {
  if (to < from) {
    throw ArgumentError('invalid slice range [$from, $to)');
  }
  final rFrom = doc.resolve(from);
  final rTo = to == from ? rFrom : doc.resolve(to);
  final inFrom = rFrom is InlinePosition ? rFrom : null;
  final inTo = rTo is InlinePosition ? rTo : null;
  if (inFrom != null && inTo != null && inFrom.blockIndex == inTo.blockIndex) {
    final block = inFrom.block;
    return Slice(
      [block.copyWith(runs: sliceRuns(block.runs, inFrom.offset, inTo.offset))],
      openStart: true,
      openEnd: true,
    );
  }
  final middleStart = inFrom != null
      ? inFrom.blockIndex + 1
      : (rFrom as BlockBoundaryPosition).insertionIndex;
  final middleEnd = inTo != null
      ? inTo.blockIndex
      : (rTo as BlockBoundaryPosition).insertionIndex;
  final blocks = <Block>[
    if (inFrom != null)
      inFrom.block.copyWith(
          runs: sliceRuns(
              inFrom.block.runs, inFrom.offset, inFrom.block.contentLength)),
    ...doc.blocks.getRange(middleStart, middleEnd),
    if (inTo != null)
      inTo.block.copyWith(runs: sliceRuns(inTo.block.runs, 0, inTo.offset)),
  ];
  if (blocks.isEmpty) return Slice.empty;
  return Slice(blocks, openStart: inFrom != null, openEnd: inTo != null);
}

/// Replaces the token range `[from, to)` with a [Slice] — the single
/// structural step: text edits, block insertion/removal, splits, joins,
/// and moves are all expressed through it.
final class ReplaceStep extends Step {
  /// Creates a replace step. [structure] marks the step as structural: it
  /// will refuse to apply if the replaced range contains any content
  /// characters (only open/close tokens may be consumed), so a rebased
  /// structural step cannot silently destroy concurrently inserted
  /// content.
  ReplaceStep(this.from, this.to, this.slice, {this.structure = false}) {
    if (from < 0 || to < from) {
      throw ArgumentError('invalid replace range [$from, $to)');
    }
  }

  /// Start of the replaced range (pre-step coordinates).
  final int from;

  /// End of the replaced range (pre-step coordinates).
  final int to;

  /// The content taking the range's place.
  final Slice slice;

  /// Whether this step may only consume open/close tokens (see the
  /// constructor).
  final bool structure;

  @override
  StepResult apply(Document doc) {
    if (to > doc.size) {
      return StepResult.fail(
          'replace range [$from, $to) exceeds document size ${doc.size}');
    }
    final rFrom = doc.resolve(from);
    final rTo = to == from ? rFrom : doc.resolve(to);
    final inFrom = rFrom is InlinePosition ? rFrom : null;
    final inTo = rTo is InlinePosition ? rTo : null;
    final leftOpen = inFrom != null;
    final rightOpen = inTo != null;
    if (slice.isEmpty) {
      if (leftOpen != rightOpen) {
        return StepResult.fail('deleting [$from, $to) would remove '
            'unbalanced block tokens');
      }
    } else if (slice.openStart != leftOpen || slice.openEnd != rightOpen) {
      return StepResult.fail('slice openness '
          '(${slice.openStart}/${slice.openEnd}) does not fit the range '
          'endpoints ($leftOpen/$rightOpen)');
    }
    final startIndex =
        inFrom?.blockIndex ?? (rFrom as BlockBoundaryPosition).insertionIndex;
    final endIndex = inTo != null
        ? inTo.blockIndex + 1
        : (rTo as BlockBoundaryPosition).insertionIndex;
    if (structure && _rangeHasContent(doc)) {
      return StepResult.fail('structural replace over [$from, $to) would '
          'destroy content');
    }

    final content = slice.content;
    final headRuns =
        inFrom == null ? null : sliceRuns(inFrom.block.runs, 0, inFrom.offset);
    final tailRuns = inTo == null
        ? null
        : sliceRuns(inTo.block.runs, inTo.offset, inTo.block.contentLength);
    final sameBlock =
        inFrom != null && inTo != null && inFrom.blockIndex == inTo.blockIndex;

    final result = <Block>[];
    final structural = <StructuralChange>[];
    if (content.isEmpty) {
      if (inFrom != null && inTo != null) {
        result.add(inFrom.block
            .copyWith(runs: normalizeRuns([...headRuns!, ...tailRuns!])));
        if (!sameBlock) {
          structural.add(BlockJoin(
            leadingId: inFrom.block.id,
            removedId: inTo.block.id,
            removedOffset: inTo.offset,
            leadingOffset: inFrom.offset,
          ));
        }
      }
      // Closed-closed empty slice: pure block removal, nothing to build.
    } else if (inFrom != null && inTo != null && content.length == 1) {
      // Single open-both block: everything collapses into the leading
      // block, which keeps its id, type, and attribute bag.
      result.add(inFrom.block.copyWith(
          runs: normalizeRuns(
              [...headRuns!, ...content.single.runs, ...tailRuns!])));
      if (!sameBlock) {
        structural.add(BlockJoin(
          leadingId: inFrom.block.id,
          removedId: inTo.block.id,
          removedOffset: inTo.offset,
          leadingOffset: inFrom.offset + content.single.contentLength,
        ));
      }
    } else {
      var middleStart = 0;
      var middleEnd = content.length;
      if (inFrom != null) {
        result.add(inFrom.block.copyWith(
            runs: normalizeRuns([...headRuns!, ...content.first.runs])));
        middleStart = 1;
      }
      Block? trailing;
      if (inTo != null) {
        final last = content.last;
        trailing =
            last.copyWith(runs: normalizeRuns([...last.runs, ...tailRuns!]));
        middleEnd = content.length - 1;
        if (sameBlock) {
          structural.add(BlockSplit(
            sourceId: inFrom.block.id,
            trailingId: last.id,
            sourceOffset: inTo.offset,
            trailingOffset: last.contentLength,
          ));
        } else {
          structural.add(BlockJoin(
            leadingId: last.id,
            removedId: inTo.block.id,
            removedOffset: inTo.offset,
            leadingOffset: last.contentLength,
          ));
        }
      }
      result.addAll(content.getRange(middleStart, middleEnd));
      if (trailing != null) result.add(trailing);
    }

    final failure = _checkIds(doc, result, startIndex, endIndex);
    if (failure != null) return StepResult.fail(failure);
    return StepResult.ok(
        doc.replaceBlockRange(startIndex, endIndex, result), structural);
  }

  /// Whether any content character lies inside `[from, to)`.
  bool _rangeHasContent(Document doc) {
    var hasContent = false;
    visitContentRanges(doc, from, to, (_, __, ___) => hasContent = true);
    return hasContent;
  }

  /// Rejects replacements that would duplicate a stable block id.
  ///
  /// An incoming id is first checked against the replaced range's own
  /// blocks — the common case (typing is a same-id single-block replace)
  /// never needs the document's global id → index map. Only ids the range
  /// does not account for fall back to the global lookup.
  static String? _checkIds(
      Document doc, List<Block> result, int startIndex, int endIndex) {
    final replacedIds = <String>{
      for (var i = startIndex; i < endIndex; i++) doc.blocks[i].id,
    };
    final seen = <String>{};
    for (final block in result) {
      if (!seen.add(block.id)) {
        return 'replacement repeats block id "${block.id}"';
      }
      if (replacedIds.contains(block.id)) continue;
      if (doc.indexOfBlockId(block.id) != null) {
        return 'block id "${block.id}" already exists in the document';
      }
    }
    return null;
  }

  @override
  StepMap getMap() => StepMap([from, to - from, slice.size]);

  @override
  Step invert(Document docBefore) =>
      ReplaceStep(from, from + slice.size, sliceBetween(docBefore, from, to));

  @override
  Step? map(Mappable mapping) {
    final span = mapSpan(mapping, from, to);
    if (span.from.deletedAcross && span.to.deletedAcross) return null;
    // Policy: keep the mapped `from`; an inverted span collapses onto it.
    return ReplaceStep(span.from.pos, span.end, slice, structure: structure);
  }

  @override
  Step? merge(Step other) {
    if (other is! ReplaceStep || structure || other.structure) return null;
    final thisRuns = _inlineRunsOf(slice);
    final otherRuns = _inlineRunsOf(other.slice);
    if (thisRuns == null || otherRuns == null) return null;
    if (from + slice.size == other.from) {
      // `other` acts directly after this step's inserted content: typing
      // forward or deleting forward.
      return ReplaceStep(from, to + (other.to - other.from),
          _mergeInline(slice, other.slice, thisRuns, otherRuns));
    }
    if (other.to == from) {
      // `other` acts directly before this step's range: backspacing.
      return ReplaceStep(other.from, to,
          _mergeInline(other.slice, slice, otherRuns, thisRuns));
    }
    return null;
  }

  /// The runs of an inline-compatible slice (empty, or one open-both
  /// block); `null` when the slice is structural.
  static List<InlineRun>? _inlineRunsOf(Slice slice) {
    if (slice.isEmpty) return const [];
    if (slice.content.length == 1 && slice.openStart && slice.openEnd) {
      return slice.content.single.runs;
    }
    return null;
  }

  static Slice _mergeInline(Slice first, Slice second,
      List<InlineRun> firstRuns, List<InlineRun> secondRuns) {
    final runs = normalizeRuns([...firstRuns, ...secondRuns]);
    if (runs.isEmpty) return Slice.empty;
    final template =
        first.isEmpty ? second.content.single : first.content.single;
    return Slice([template.copyWith(runs: runs)],
        openStart: true, openEnd: true);
  }

  @override
  String toString() =>
      'ReplaceStep($from, $to, $slice${structure ? ', structure' : ''})';
}
