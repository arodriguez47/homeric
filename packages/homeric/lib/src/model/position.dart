/// Resolved positions and position errors.
///
/// Token-position provenance: positions are single integers counted the
/// ProseMirror way — each character costs 1, every block contributes an
/// opening and a closing token, and the gap between two adjacent blocks is
/// one position but two tokens. Design follows prosemirror-model's position
/// resolution (`src/resolvedpos.ts`,
/// https://github.com/ProseMirror/prosemirror-model, MIT; repository archived
/// April 2026). Design reference only — no source code was copied.
library;

import 'block.dart';

/// The result of resolving an integer position against a document.
///
/// Every position `p` in `[0, doc.size]` resolves to exactly one of:
///
/// - [BlockBoundaryPosition] — `p` sits between blocks (or at the document's
///   start/end). The single gap position between two adjacent blocks is a
///   boundary carrying both neighbors.
/// - [InlinePosition] — `p` sits inside a block's content span, with a text
///   offset in `[0, contentLength]`.
sealed class ResolvedPosition {
  const ResolvedPosition(this.position);

  /// The document position that was resolved.
  final int position;
}

/// A position at a document-level block boundary.
final class BlockBoundaryPosition extends ResolvedPosition {
  /// Creates a boundary resolution.
  const BlockBoundaryPosition(
    super.position, {
    required this.insertionIndex,
    required this.blockBefore,
    required this.blockAfter,
  });

  /// The block index at which an insertion at this position would land:
  /// [blockBefore] is `blocks[insertionIndex - 1]`, [blockAfter] is
  /// `blocks[insertionIndex]`.
  final int insertionIndex;

  /// The block ending at this position, or `null` at document start.
  final Block? blockBefore;

  /// The block starting at this position, or `null` at document end.
  final Block? blockAfter;

  @override
  String toString() =>
      'BlockBoundaryPosition($position, insertionIndex: $insertionIndex)';
}

/// A position inside a block's content span.
final class InlinePosition extends ResolvedPosition {
  /// Creates an inline resolution.
  const InlinePosition(
    super.position, {
    required this.blockIndex,
    required this.block,
    required this.blockStart,
    required this.offset,
  });

  /// Index of the containing block in the document's block list.
  final int blockIndex;

  /// The containing block.
  final Block block;

  /// Document position of the block's opening boundary; the block's first
  /// character sits at `blockStart + 1`.
  final int blockStart;

  /// Text offset within the block's content, in `[0, contentLength]`.
  final int offset;

  @override
  String toString() =>
      'InlinePosition($position, block: ${block.id}, offset: $offset)';
}

/// Typed error thrown when a position lies outside `[0, size]`.
final class PositionOutOfRangeError extends Error {
  /// Creates the error for [position] against a document of [size].
  PositionOutOfRangeError(this.position, this.size);

  /// The offending position.
  final int position;

  /// The document's token size at the time of the failed call.
  final int size;

  @override
  String toString() =>
      'PositionOutOfRangeError: position $position is outside the '
      'document range [0, $size]';
}
