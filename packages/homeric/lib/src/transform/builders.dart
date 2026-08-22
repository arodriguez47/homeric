// Builder semantics follow prosemirror-transform src/transform.ts (the
// replace/split/join/mark convenience layer)
// @ 662b7a937bafde19b7e2a83241dbc8888e257c89; MIT (c) Marijn Haverbeke.
// The upstream source was read to learn the semantics; this implementation
// is original Dart and no source code was copied.

import '../model/attributes.dart';
import '../model/block.dart';
import '../model/document.dart';
import '../model/inline_run.dart';
import '../model/position.dart';
import 'attr_step.dart';
import 'change_list.dart';
import 'replace_step.dart';
import 'run_ops.dart';
import 'transaction.dart';

/// Edit intents expressed as steps on a [Transaction].
///
/// Builders validate their inputs against the transaction's current
/// document and throw [ArgumentError] on positions that cannot express the
/// intent; the steps they emit still fail as values if misapplied
/// elsewhere.
extension TransactionBuilders on Transaction {
  /// Inserts [text] (with inline [attributes]) at an inline [position].
  void insertText(int position, String text,
      {Attributes attributes = emptyAttributes}) {
    if (text.isEmpty) return;
    final resolved = doc.resolve(position);
    if (resolved is! InlinePosition) {
      throw ArgumentError.value(
          position, 'position', 'insertText requires an inline position');
    }
    final host = resolved.block;
    step(ReplaceStep(
      position,
      position,
      Slice(
        [
          Block(id: host.id, type: host.type, runs: [
            InlineRun(text, attributes: attributes),
          ]),
        ],
        openStart: true,
        openEnd: true,
      ),
    ));
  }

  /// Deletes `[from, to)`. Mixed inline/boundary endpoints are normalized
  /// to the nearest balanced range (a boundary endpoint facing an inline
  /// one steps one position inward), so the deletion never strands an
  /// unmatched block token.
  void deleteRange(int from, int to) {
    var start = from;
    var end = to;
    final leftInline = doc.resolve(start) is InlinePosition;
    final rightInline = doc.resolve(end) is InlinePosition;
    if (leftInline && !rightInline) end -= 1;
    if (!leftInline && rightInline) start += 1;
    if (end <= start) return;
    step(ReplaceStep(start, end, Slice.empty));
  }

  /// Splits the block containing inline [position] in two. The leading
  /// half keeps the block's id and attribute-bag reference; the trailing
  /// half gets [trailingBlockId] (or a fresh id), the same type, and
  /// shares the same bag reference. Returns the trailing block's id.
  String splitBlock(int position, {String? trailingBlockId}) {
    final resolved = doc.resolve(position);
    if (resolved is! InlinePosition) {
      throw ArgumentError.value(
          position, 'position', 'splitBlock requires an inline position');
    }
    final host = resolved.block;
    final trailingId = trailingBlockId ?? allocateBlockId();
    step(ReplaceStep(
      position,
      position,
      Slice(
        [
          Block(id: host.id, type: host.type),
          Block(id: trailingId, type: host.type, attributes: host.attributes),
        ],
        openStart: true,
        openEnd: true,
      ),
      structure: true,
    ));
    return trailingId;
  }

  /// Joins the two blocks around [boundary] (a position between blocks).
  /// The leading block's id, type, and attribute bag survive; the trailing
  /// block's id disappears.
  void joinBlocks(int boundary) {
    final resolved = doc.resolve(boundary);
    if (resolved is! BlockBoundaryPosition ||
        resolved.blockBefore == null ||
        resolved.blockAfter == null) {
      throw ArgumentError.value(boundary, 'boundary',
          'joinBlocks requires a boundary between two blocks');
    }
    step(ReplaceStep(boundary - 1, boundary + 1, Slice.empty, structure: true));
  }

  /// Moves the block with [blockId] so it ends up at [targetIndex] in the
  /// resulting document, preserving its id, attribute bag, and content
  /// (the block instance itself is carried over).
  ///
  /// The delete and insert maps are registered as a mirror pair in
  /// [Transaction.mapping], so positions inside the moved block recover
  /// into the destination instead of reporting `deletedAcross`.
  void moveBlock(String blockId, int targetIndex) {
    final sourceIndex = doc.indexOfBlockId(blockId);
    if (sourceIndex == null) {
      throw ArgumentError.value(blockId, 'blockId', 'no block with this id');
    }
    RangeError.checkValueInInterval(
        targetIndex, 0, doc.blockCount - 1, 'targetIndex');
    if (targetIndex == sourceIndex) return;
    final block = doc.blocks[sourceIndex];
    stepPairMirrored(
      ReplaceStep(doc.positionBeforeBlock(sourceIndex),
          doc.positionAfterBlock(sourceIndex), Slice.empty),
      (doc) {
        final insertPos = targetIndex == doc.blockCount
            ? doc.size
            : doc.positionBeforeBlock(targetIndex);
        return ReplaceStep(insertPos, insertPos, Slice([block]));
      },
      record: BlockMove(
          blockId: blockId, fromIndex: sourceIndex, toIndex: targetIndex),
    );
  }

  /// Changes the type of the block with [blockId], keeping its attributes.
  void setBlockType(String blockId, String type) {
    step(BlockAttrStep(blockId, type: type));
  }

  /// Replaces the attribute bag of the block with [blockId], keeping its
  /// type.
  void setBlockAttributes(String blockId, Attributes attributes) {
    step(BlockAttrStep(blockId, attributes: attributes));
  }

  /// Toggles inline attribute [key] = [value] over `[from, to)`: when
  /// every character in the range already carries the value, it is
  /// removed; otherwise the whole range becomes marked, replacing
  /// conflicting values via paired remove/add steps so each emitted step
  /// inverts losslessly.
  void toggleMark(int from, int to, String key, Object? value) {
    if (from < 0 || to < from || to > doc.size) {
      throw ArgumentError('invalid mark range [$from, $to)');
    }
    final frozen = freezeAttributeValue(value);
    final segments = _markSegments(doc, from, to, key);
    if (segments.isEmpty) return;
    final allMarked =
        segments.every((s) => s.present && attributesEqual(s.value, frozen));
    if (allMarked) {
      step(RemoveMarkStep(from, to, key, frozen));
      return;
    }
    for (final segment in segments) {
      if (segment.present && attributesEqual(segment.value, frozen)) {
        continue;
      }
      if (segment.present) {
        step(RemoveMarkStep(segment.start, segment.end, key, segment.value));
      }
      step(AddMarkStep(segment.start, segment.end, key, frozen));
    }
  }
}

final class _MarkSegment {
  _MarkSegment(this.start, this.end, this.present, this.value);

  final int start;
  int end;
  final bool present;
  final Object? value;
}

/// Splits the characters of `[from, to)` into maximal segments with a
/// uniform state for [key] (present with a deep-equal value, or absent).
/// Segment ranges are global positions; adjacent same-state segments merge
/// across block boundaries (the intervening tokens carry no marks).
List<_MarkSegment> _markSegments(Document doc, int from, int to, String key) {
  final segments = <_MarkSegment>[];
  visitContentRanges(doc, from, to, (blockIndex, localStart, localEnd) {
    final block = doc.blocks[blockIndex];
    var pos = doc.positionBeforeBlock(blockIndex) + 1 + localStart;
    for (final run in sliceRuns(block.runs, localStart, localEnd)) {
      if (run.isEmpty) continue;
      final end = pos + run.length;
      final present = run.attributes.containsKey(key);
      final value = run.attributes[key];
      final last = segments.isEmpty ? null : segments.last;
      if (last != null &&
          last.present == present &&
          attributesEqual(last.value, value)) {
        last.end = end;
      } else {
        segments.add(_MarkSegment(pos, end, present, value));
      }
      pos = end;
    }
  });
  return segments;
}
