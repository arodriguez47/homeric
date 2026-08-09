/// The immutable block document.
///
/// Token-position provenance: document size and cumulative block-size caching
/// follow prosemirror-model's design (`src/node.ts` / `Fragment` cached
/// sizes, `src/resolvedpos.ts` resolution;
/// https://github.com/ProseMirror/prosemirror-model, MIT; repository archived
/// April 2026). Design reference only — no source code was copied.
///
/// Structural sharing: every edit helper shallow-copies the block list only;
/// untouched [Block] instances (and their run lists and attribute bags) are
/// shared by reference between document versions. The cumulative-size cache
/// of the source document is carried over so sizes are recomputed only for
/// blocks at or after the edit point.
library;

import 'block.dart';
import 'position.dart';

/// An immutable, flat sequence of [Block]s with ProseMirror token positions.
final class Document {
  /// Creates a document over [blocks] (copied into an unmodifiable list).
  Document([List<Block> blocks = const <Block>[]])
      : this._(List<Block>.unmodifiable(blocks), null, 0);

  Document._(this.blocks, this._inheritedSizes, this._inheritedSizeCount);

  /// The ordered block sequence (unmodifiable list).
  final List<Block> blocks;

  /// Cumulative sizes inherited from the document this one was derived from;
  /// entries `0.._inheritedSizeCount` are still valid for this document.
  final List<int>? _inheritedSizes;
  final int _inheritedSizeCount;

  /// Lazily computed cumulative sizes: `_cumulative[i]` is the document
  /// position of block `i`'s opening boundary; `_cumulative[length]` is the
  /// document size.
  List<int>? _cumulativeCache;

  List<int> get _cumulative {
    final cached = _cumulativeCache;
    if (cached != null) return cached;
    final sizes = List<int>.filled(blocks.length + 1, 0);
    var next = 1;
    final inherited = _inheritedSizes;
    if (inherited != null) {
      final reusable = _inheritedSizeCount < blocks.length
          ? _inheritedSizeCount
          : blocks.length;
      for (var i = 1; i <= reusable; i++) {
        sizes[i] = inherited[i];
      }
      next = reusable + 1;
    }
    for (var i = next; i <= blocks.length; i++) {
      sizes[i] = sizes[i - 1] + blocks[i - 1].size;
    }
    return _cumulativeCache = sizes;
  }

  /// Lazily built id → index lookup. Detects duplicate ids on first use.
  Map<String, int>? _indexByIdCache;

  Map<String, int> get _indexById {
    final cached = _indexByIdCache;
    if (cached != null) return cached;
    final index = <String, int>{};
    for (var i = 0; i < blocks.length; i++) {
      final id = blocks[i].id;
      if (index.containsKey(id)) {
        throw StateError('Duplicate block id "$id" at indices '
            '${index[id]} and $i');
      }
      index[id] = i;
    }
    return _indexByIdCache = Map<String, int>.unmodifiable(index);
  }

  /// Number of blocks.
  int get blockCount => blocks.length;

  /// Whether the document holds no blocks (token size 0).
  bool get isEmpty => blocks.isEmpty;

  /// Total token size: the sum of every block's size (content length + 2).
  int get size => _cumulative[blocks.length];

  /// Document position of block [index]'s opening boundary.
  int positionBeforeBlock(int index) {
    RangeError.checkValueInInterval(index, 0, blocks.length - 1, 'index');
    return _cumulative[index];
  }

  /// Document position just after block [index]'s closing token.
  int positionAfterBlock(int index) {
    RangeError.checkValueInInterval(index, 0, blocks.length - 1, 'index');
    return _cumulative[index + 1];
  }

  /// Document position of text [offset] inside block [blockIndex]'s content
  /// (`offset` in `[0, contentLength]`).
  int positionAt(int blockIndex, int offset) {
    RangeError.checkValueInInterval(
        blockIndex, 0, blocks.length - 1, 'blockIndex');
    RangeError.checkValueInInterval(
        offset, 0, blocks[blockIndex].contentLength, 'offset');
    return _cumulative[blockIndex] + 1 + offset;
  }

  /// The block with the given stable [id], or `null` if absent.
  Block? blockById(String id) {
    final index = _indexById[id];
    return index == null ? null : blocks[index];
  }

  /// Index of the block with the given stable [id], or `null` if absent.
  int? indexOfBlockId(String id) => _indexById[id];

  /// Resolves [position] to a block boundary or an inline text position.
  ///
  /// Throws [PositionOutOfRangeError] for positions outside `[0, size]`.
  ResolvedPosition resolve(int position) {
    final sizes = _cumulative;
    final docSize = sizes[blocks.length];
    if (position < 0 || position > docSize) {
      throw PositionOutOfRangeError(position, docSize);
    }
    // Greatest index with sizes[index] <= position, by binary search.
    var low = 0;
    var high = blocks.length;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (sizes[mid] <= position) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    if (sizes[low] == position) {
      return BlockBoundaryPosition(
        position,
        insertionIndex: low,
        blockBefore: low > 0 ? blocks[low - 1] : null,
        blockAfter: low < blocks.length ? blocks[low] : null,
      );
    }
    // Strictly between sizes[low] and sizes[low + 1]: inside block `low`,
    // past its opening token.
    return InlinePosition(
      position,
      blockIndex: low,
      block: blocks[low],
      blockStart: sizes[low],
      offset: position - sizes[low] - 1,
    );
  }

  /// Replaces blocks `[start, end)` with [replacement].
  ///
  /// This is the single structural edit primitive: it shallow-copies the
  /// block list, shares every untouched block by reference, and hands the
  /// current cumulative-size cache to the new document so only positions at
  /// or after [start] are recomputed.
  Document replaceBlockRange(int start, int end, Iterable<Block> replacement) {
    RangeError.checkValidRange(start, end, blocks.length);
    final next = List<Block>.unmodifiable(<Block>[
      ...blocks.getRange(0, start),
      ...replacement,
      ...blocks.getRange(end, blocks.length),
    ]);
    return Document._(next, _cumulativeCache, start);
  }

  /// Replaces the block at [index] with [block].
  Document updateBlock(int index, Block block) {
    RangeError.checkValueInInterval(index, 0, blocks.length - 1, 'index');
    return replaceBlockRange(index, index + 1, <Block>[block]);
  }

  /// Inserts [block] so that it becomes `blocks[index]`.
  Document insertBlock(int index, Block block) {
    RangeError.checkValueInInterval(index, 0, blocks.length, 'index');
    return replaceBlockRange(index, index, <Block>[block]);
  }

  /// Removes the block at [index].
  Document removeBlock(int index) {
    RangeError.checkValueInInterval(index, 0, blocks.length - 1, 'index');
    return replaceBlockRange(index, index + 1, const <Block>[]);
  }

  @override
  String toString() => 'Document(${blocks.length} blocks, size $size)';
}
