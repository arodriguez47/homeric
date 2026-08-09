/// What a transaction changed, in block-identity terms.
///
/// A [ChangeList] is the bridge between position mapping (which only knows
/// integers) and the block-sharded consumers downstream: `DecorationSet.map`
/// takes `(Mapping, ChangeList)` so it can re-localize block-local offsets
/// and re-key shards across splits, joins, and moves.
library;

import '../model/document.dart';

/// A global token range `[start, end)` covering a block, including its
/// opening and closing tokens.
final class BlockSpan {
  /// Creates a span.
  const BlockSpan(this.start, this.end);

  /// Position of the block's opening boundary.
  final int start;

  /// Position just after the block's closing token.
  final int end;

  @override
  bool operator ==(Object other) =>
      other is BlockSpan && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => '[$start, $end)';
}

/// One touched block: its stable id and its global ranges before and after
/// the transaction.
final class BlockChange {
  /// Creates a change record.
  const BlockChange(this.blockId, {this.before, this.after});

  /// The block's stable id.
  final String blockId;

  /// The block's span in the pre-transaction document, or `null` when the
  /// block was created by the transaction.
  final BlockSpan? before;

  /// The block's span in the post-transaction document, or `null` when the
  /// block was removed by the transaction.
  final BlockSpan? after;

  /// Whether the transaction created this block.
  bool get isCreated => before == null;

  /// Whether the transaction removed this block (its id no longer exists).
  bool get isRemoved => after == null;

  @override
  String toString() => 'BlockChange($blockId, $before -> $after)';
}

/// A block-identity outcome of a structural edit: which id received which
/// text across a split, join, or move.
sealed class StructuralChange {
  const StructuralChange();
}

/// A block split: content of [sourceId] at or past [sourceOffset] moved
/// into the new [trailingId] block, starting at local offset
/// [trailingOffset]. Offsets are in the coordinates of the step that split
/// the block.
final class BlockSplit extends StructuralChange {
  /// Creates a split record.
  const BlockSplit({
    required this.sourceId,
    required this.trailingId,
    required this.sourceOffset,
    required this.trailingOffset,
  });

  /// The block that was split; it keeps its id for the leading half.
  final String sourceId;

  /// The block that received the content past the split point.
  final String trailingId;

  /// Content offset in the source block where the moved-away text began.
  final int sourceOffset;

  /// Content offset in the trailing block where that text now starts.
  final int trailingOffset;

  @override
  String toString() =>
      'BlockSplit($sourceId@$sourceOffset -> $trailingId@$trailingOffset)';
}

/// A block join: [removedId]'s id disappeared and its surviving content (at
/// or past [removedOffset]) now lives in [leadingId], starting at local
/// offset [leadingOffset]. Offsets are in the coordinates of the joining
/// step.
final class BlockJoin extends StructuralChange {
  /// Creates a join record.
  const BlockJoin({
    required this.leadingId,
    required this.removedId,
    required this.removedOffset,
    required this.leadingOffset,
  });

  /// The surviving block; it keeps its id, type, and attribute bag.
  final String leadingId;

  /// The block whose id disappeared.
  final String removedId;

  /// Content offset in the removed block where the surviving text began.
  final int removedOffset;

  /// Content offset in the leading block where that text now starts.
  final int leadingOffset;

  @override
  String toString() =>
      'BlockJoin($removedId@$removedOffset -> $leadingId@$leadingOffset)';
}

/// A whole-block move: [blockId] kept its identity and content and now sits
/// at a different index. The transaction's mapping carries the delete and
/// insert maps as a mirror pair, so positions inside the block recover into
/// the destination.
final class BlockMove extends StructuralChange {
  /// Creates a move record.
  const BlockMove({
    required this.blockId,
    required this.fromIndex,
    required this.toIndex,
  });

  /// The moved block's stable id (unchanged by the move).
  final String blockId;

  /// The block's index before the move.
  final int fromIndex;

  /// The block's index after the move.
  final int toIndex;

  @override
  String toString() => 'BlockMove($blockId, $fromIndex -> $toIndex)';
}

/// The set of blocks a transaction touched, with old/new global ranges,
/// plus the structural block-identity outcomes.
final class ChangeList {
  ChangeList._(this.changes, this.structural, this._byId);

  /// Diffs [before] against [after].
  ///
  /// Untouched blocks are recognized by reference identity (the structural-
  /// sharing invariant guarantees an unedited block is the same instance),
  /// so blocks merely shifted by earlier or later edits are not reported.
  /// Blocks in the differing middle are matched by stable id: present in
  /// both means changed (or moved), before-only means removed, after-only
  /// means created.
  factory ChangeList.compute(
    Document before,
    Document after,
    List<StructuralChange> structural,
  ) {
    final b = before.blocks;
    final a = after.blocks;
    final maxShared = b.length < a.length ? b.length : a.length;
    var prefix = 0;
    while (prefix < maxShared && identical(b[prefix], a[prefix])) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < b.length - prefix &&
        suffix < a.length - prefix &&
        identical(b[b.length - 1 - suffix], a[a.length - 1 - suffix])) {
      suffix++;
    }
    BlockSpan spanOf(Document doc, int index) => BlockSpan(
        doc.positionBeforeBlock(index), doc.positionAfterBlock(index));

    final afterIndexById = <String, int>{
      for (var i = prefix; i < a.length - suffix; i++) a[i].id: i,
    };
    final changes = <BlockChange>[];
    for (var i = prefix; i < b.length - suffix; i++) {
      final id = b[i].id;
      final afterIndex = afterIndexById.remove(id);
      changes.add(BlockChange(
        id,
        before: spanOf(before, i),
        after: afterIndex == null ? null : spanOf(after, afterIndex),
      ));
    }
    final createdIndices = afterIndexById.values.toList()..sort();
    for (final index in createdIndices) {
      changes.add(BlockChange(a[index].id, after: spanOf(after, index)));
    }
    return ChangeList._(
      List<BlockChange>.unmodifiable(changes),
      List<StructuralChange>.unmodifiable(structural),
      {for (final change in changes) change.blockId: change},
    );
  }

  /// Touched blocks in pre-transaction document order (created blocks
  /// last, in post-transaction order).
  final List<BlockChange> changes;

  /// Split/join/move block-identity outcomes, in step order.
  final List<StructuralChange> structural;

  final Map<String, BlockChange> _byId;

  /// The change for [blockId], or `null` when the block was not touched.
  BlockChange? changeFor(String blockId) => _byId[blockId];

  /// Ids of every touched block.
  Iterable<String> get touchedBlockIds => changes.map((c) => c.blockId);

  @override
  String toString() => 'ChangeList(${changes.length} blocks, '
      '${structural.length} structural)';
}
