/// A line and the deeper lines under it, moved as one.
///
/// Indentation is leading whitespace (see [HomericBlockIndent]), so the
/// lines "under" a line are simply the ones after it that start further
/// in: a bullet's nested bullets and the paragraphs indented to its words.
/// [HomericBlockFamily] finds that run and builds the moves that carry it,
/// for a grip drag, a menu's Move up/down or ⌘⇧↑/↓.
///
/// Where a line starts: a list line at its marker (its depth), a paragraph
/// at its indent level; headings, quotes, fences and other non-prose lines
/// at the margin. A line's children are the lines after it that start
/// further in, up to the first that doesn't. Blank lines inside the run go
/// with it; blank lines after its last child stay.
library;

import 'package:flutter/services.dart' show HardwareKeyboard;

import '../editing/editable_document.dart';
import '../editing/editor_controller.dart';
import '../editing/markdown_list_indent.dart';
import '../model/block.dart';
import '../model/document.dart';
import '../transform/builders.dart';
import '../transform/transaction.dart';
import 'block_indent.dart';
import 'list_hang.dart';

/// Finds and moves a line together with the lines indented under it.
abstract final class HomericBlockFamily {
  /// Where [block] starts, in indent steps: a list line's depth, a
  /// paragraph's indent level, 0 for anything else.
  static int startOf(
    Block block, {
    Set<String> types = HomericBlockIndent.defaultTypes,
    HomericIndentFilter? accepts,
  }) {
    if (!types.contains(block.type)) return 0;
    if (accepts != null && !accepts(block)) return 0;
    final list = HomericMarkdownListPrefix.match(block.text);
    if (list != null) {
      return HomericListHang.depthOf(
        block.text.substring(0, list.indentLength),
      );
    }
    return HomericBlockIndent.paragraphIndentOf(
          block,
          types: types,
          accepts: accepts,
        )?.level ??
        0;
  }

  /// An empty text line, skipped inside a family. A block of another
  /// type, or one [accepts] excludes, is never blank: an empty rule or
  /// image ends the family even though it has no text.
  static bool _blank(
    Block block,
    Set<String> types,
    HomericIndentFilter? accepts,
  ) =>
      types.contains(block.type) &&
      (accepts == null || accepts(block)) &&
      block.text.trim().isEmpty;

  /// One past the last line of the family that starts at [index]: [index]
  /// + 1 when the line has nothing under it.
  static int endOf(
    Document document,
    int index, {
    Set<String> types = HomericBlockIndent.defaultTypes,
    HomericIndentFilter? accepts,
  }) {
    final blocks = document.blocks;
    if (index < 0 || index >= blocks.length) return index + 1;
    final start = startOf(blocks[index], types: types, accepts: accepts);
    var end = index + 1;
    var probe = index + 1;
    while (probe < blocks.length) {
      final block = blocks[probe];
      if (_blank(block, types, accepts)) {
        probe++;
        continue;
      }
      if (startOf(block, types: types, accepts: accepts) <= start) break;
      probe++;
      end = probe;
    }
    return end;
  }

  /// The ids of [blockId]'s family, in document order, the line first.
  /// Empty when [blockId] isn't in [document].
  static List<String> idsOf(
    Document document,
    String blockId, {
    Set<String> types = HomericBlockIndent.defaultTypes,
    HomericIndentFilter? accepts,
  }) {
    final index = document.indexOfBlockId(blockId);
    if (index == null) return const <String>[];
    final end = endOf(document, index, types: types, accepts: accepts);
    return <String>[
      for (var i = index; i < end; i++) document.blocks[i].id,
    ];
  }

  /// Whether [blockId] has lines under it.
  static bool hasChildren(
    Document document,
    String blockId, {
    Set<String> types = HomericBlockIndent.defaultTypes,
    HomericIndentFilter? accepts,
  }) =>
      idsOf(document, blockId, types: types, accepts: accepts).length > 1;

  /// The move of [blockId]'s family one step, up ([by] -1) or down ([by]
  /// 1), as one transaction; null when it can't go.
  ///
  /// A step is past the neighbouring family, not one line: up goes above
  /// the nearest line before it that starts no further in (a sibling, or
  /// its parent), down goes below the next family. So a bullet steps over
  /// its sibling with all the sibling's children, and never lands among
  /// them.
  static Transaction? step(
    Document document,
    String blockId,
    int by, {
    Set<String> types = HomericBlockIndent.defaultTypes,
    HomericIndentFilter? accepts,
  }) {
    final index = document.indexOfBlockId(blockId);
    if (index == null || by == 0) return null;
    final blocks = document.blocks;
    final start = startOf(blocks[index], types: types, accepts: accepts);
    final end = endOf(document, index, types: types, accepts: accepts);
    if (by < 0) {
      if (index == 0) return null;
      var above = index - 1;
      while (above > 0 &&
          (_blank(blocks[above], types, accepts) ||
              startOf(blocks[above], types: types, accepts: accepts) > start)) {
        above--;
      }
      return _moveRun(document, index, end, before: above);
    }
    if (end >= blocks.length) return null;
    var next = end;
    while (next < blocks.length - 1 && _blank(blocks[next], types, accepts)) {
      next++;
    }
    final nextEnd = endOf(document, next, types: types, accepts: accepts);
    return _moveRun(document, index, end, after: nextEnd - 1);
  }

  /// The move of [blockId]'s family to where a single-line move to
  /// [targetIndex] would put [blockId] (Homeric's reorder and
  /// [BlockMoveRequest] index): above the line now at [targetIndex] when
  /// it moves up, below it when it moves down. Null when that is inside
  /// the family itself, or no move.
  static Transaction? toIndex(
    Document document,
    String blockId,
    int targetIndex, {
    Set<String> types = HomericBlockIndent.defaultTypes,
    HomericIndentFilter? accepts,
  }) {
    final index = document.indexOfBlockId(blockId);
    if (index == null ||
        targetIndex < 0 ||
        targetIndex >= document.blockCount) {
      return null;
    }
    final end = endOf(document, index, types: types, accepts: accepts);
    if (targetIndex < index) {
      return _moveRun(document, index, end, before: targetIndex);
    }
    if (targetIndex < end) return null;
    return _moveRun(document, index, end, after: targetIndex);
  }

  /// A family's move for `HomericEditableDocument(onMoveBlock:)`: a line
  /// with nothing under it is left to Homeric's own move; a family moves
  /// whole, by [step] for a one-line request (⌘⇧↑/↓,
  /// [HomericBlockMoveContext.isStep]) and by [toIndex] for a drop, which
  /// keeps the place it was dropped. With ⌥ held the line moves alone.
  static HomericDocumentCommandResult onMoveBlock(
    HomericBlockMoveContext context, {
    Set<String> types = HomericBlockIndent.defaultTypes,
    HomericIndentFilter? accepts,
  }) {
    final document = context.document;
    // ⌥ held (⌥⌘⇧↑/↓, or a drag dropped with ⌥): this line alone.
    if (HardwareKeyboard.instance.isAltPressed) {
      return HomericDocumentCommandResult.ignored;
    }
    if (!hasChildren(document, context.blockId,
        types: types, accepts: accepts)) {
      return HomericDocumentCommandResult.ignored;
    }
    final index = document.indexOfBlockId(context.blockId)!;
    final delta = context.targetIndex - index;
    final transaction = context.isStep
        ? step(document, context.blockId, delta.sign,
            types: types, accepts: accepts)
        : toIndex(
            document,
            context.blockId,
            context.targetIndex,
            types: types,
            accepts: accepts,
          );
    if (transaction == null) {
      return HomericDocumentCommandResult.handled;
    }
    return HomericDocumentCommandResult.prepared(HomericPreparedCommand(
      stages: <Transaction>[transaction],
      selection: context.selection?.map(transaction.mapping),
    ));
  }

  /// Moves blocks [from]..[end) to just above the block now at [before],
  /// or just below the block now at [after], keeping their order.
  static Transaction? _moveRun(
    Document document,
    int from,
    int end, {
    int? before,
    int? after,
  }) {
    final ids = <String>[
      for (var i = from; i < end; i++) document.blocks[i].id,
    ];
    final tx = Transaction(document);
    if (before != null) {
      if (before >= from) return null;
      final anchor = document.blocks[before].id;
      for (final id in ids) {
        final at = tx.doc.indexOfBlockId(id)!;
        final j = tx.doc.indexOfBlockId(anchor)!;
        tx.moveBlock(id, at < j ? j - 1 : j);
      }
    } else if (after != null) {
      if (after < end) return null;
      final anchor = document.blocks[after].id;
      for (final id in ids.reversed) {
        final at = tx.doc.indexOfBlockId(id)!;
        final j = tx.doc.indexOfBlockId(anchor)!;
        tx.moveBlock(id, at < j ? j : j + 1);
      }
    } else {
      return null;
    }
    return tx.docChanged ? tx : null;
  }
}
