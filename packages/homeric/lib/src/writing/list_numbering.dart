/// Numbered lists that keep counting in order through every edit.
///
/// A numbered item's number is source text (`3. `), so an edit that adds,
/// removes, moves, nests or unlists an item would leave the numbers after
/// it stale: Enter after item 6 of 7 wrote a second `7. `. This feature
/// renumbers as part of the edit itself, through the controller's
/// [HomericEditorController.addDocumentNormalizer], so the numbers are
/// right in the source (and in every export), the change is one Undo, and
/// Undo and Redo bring back numbers that were already in order.
///
/// A run is the numbered items at one depth, in order, until a line that
/// is not inside the list: a plain paragraph, a bullet at that depth or
/// shallower, or a numbered item shallower than it. Nested lines and
/// paragraphs indented under an item stay inside the run. The run counts
/// up from its first item's number, so a list can start at 3. When the
/// first item leaves (deleted, moved, unlisted), the item that takes its
/// place starts where the list started, not at its own old number. An item
/// nested or outdented into a list of its own starts it at 1.
library;

import 'package:flutter/foundation.dart';

import '../editing/editor_controller.dart';
import '../editing/markdown_list_indent.dart';
import '../model/attributes.dart';
import '../model/block.dart';
import '../model/document.dart';
import '../model/inline_run.dart';
import '../transform/replace_step.dart';
import 'block_indent.dart';
import 'list_hang.dart';
import 'writing_feature.dart';

/// In-order numbering for numbered list lines as a [HomericWritingFeature].
final class HomericListNumbering extends HomericWritingFeature {
  /// Creates the feature; [isActive] is read before each edit, null is on.
  const HomericListNumbering({this.isActive, this.accepts});

  /// Read before each edit; `false` leaves numbers as typed.
  final ValueGetter<bool>? isActive;

  /// Lines the host numbers; a line it refuses (code in a fence) ends the
  /// lists above it and is never rewritten. Null numbers every line.
  final HomericIndentFilter? accepts;

  @override
  String get id => 'listNumbering';

  @override
  VoidCallback installOn(HomericEditorController controller) =>
      controller.addDocumentNormalizer((before, transaction) {
        if (isActive?.call() == false) return;
        final fixes = renumber(before, transaction.doc, accepts: accepts);
        // Back to front, so earlier offsets stay put.
        for (final fix in fixes.reversed) {
          final index = transaction.doc.indexOfBlockId(fix.blockId);
          if (index == null) continue;
          final block = transaction.doc.blocks[index];
          final from = transaction.doc.positionAt(index, fix.start);
          final to = transaction.doc.positionAt(index, fix.end);
          transaction.maybeStep(ReplaceStep(
            from,
            to,
            Slice(
              [
                Block(
                  id: block.id,
                  type: block.type,
                  runs: [
                    InlineRun(
                      fix.digits,
                      attributes: _attributesAt(block, fix.start),
                    ),
                  ],
                ),
              ],
              openStart: true,
              openEnd: true,
            ),
          ));
        }
      });

  /// The number rewrites that put every run in [after] in order, front to
  /// back. [before] is the document the edit started from: it says where a
  /// list started when its first item left.
  static List<HomericListNumberFix> renumber(
    Document before,
    Document after, {
    HomericIndentFilter? accepts,
  }) {
    final runs = _Runs.of(after, accepts).runs;
    if (runs.isEmpty) return const <HomericListNumberFix>[];
    _Runs? previous;
    Map<String, _Run>? runOf;
    final fixes = <HomericListNumberFix>[];
    for (final run in runs) {
      var start = run.items.first.number;
      final first = run.items.first.blockId;
      previous ??= _Runs.of(before, accepts);
      final old = previous.byBlock[first];
      if (old != null && old.items.first.blockId != first) {
        final was = old.items.firstWhere((item) => item.blockId == first);
        if (was.depth != run.items.first.depth) {
          // Nested or outdented out of its list into a new one.
          start = 1;
        } else {
          // It opens a list it was inside of before. If no item above it
          // there is in another list now (they left, or moved below it),
          // it takes that list's place and start; if some are, the list
          // was split and it keeps its own number.
          final listed = runOf ??= <String, _Run>{
            for (final r in runs)
              for (final item in r.items) item.blockId: r,
          };
          final above = old.items.takeWhile((item) => item.blockId != first);
          final split = above.any((item) {
            final now = listed[item.blockId];
            return now != null && !identical(now, run);
          });
          if (!split) {
            start = old.items.first.number;
          }
        }
      }
      for (var i = 0; i < run.items.length; i++) {
        final item = run.items[i];
        final want = start + i;
        if (item.number != want) {
          fixes.add(HomericListNumberFix(
            blockId: item.blockId,
            start: item.digitsStart,
            end: item.digitsEnd,
            digits: '$want',
          ));
        }
      }
    }
    fixes.sort((a, b) {
      final ai = after.indexOfBlockId(a.blockId)!;
      final bi = after.indexOfBlockId(b.blockId)!;
      return ai.compareTo(bi);
    });
    return fixes;
  }

  static Attributes _attributesAt(Block block, int offset) {
    var at = 0;
    for (final run in block.runs) {
      final next = at + run.length;
      if (!run.isEmpty && offset >= at && offset < next) return run.attributes;
      at = next;
    }
    return block.runs.isEmpty ? emptyAttributes : block.runs.first.attributes;
  }
}

/// One number to rewrite: [digits] in place of `[start, end)` of [blockId].
@immutable
final class HomericListNumberFix {
  /// A rewrite of the number at `[start, end)` in [blockId] to [digits].
  const HomericListNumberFix({
    required this.blockId,
    required this.start,
    required this.end,
    required this.digits,
  });

  /// The numbered line.
  final String blockId;

  /// Where its digits start in the line.
  final int start;

  /// Where its digits end.
  final int end;

  /// The number it should read.
  final String digits;

  @override
  bool operator ==(Object other) =>
      other is HomericListNumberFix &&
      other.blockId == blockId &&
      other.start == start &&
      other.end == end &&
      other.digits == digits;

  @override
  int get hashCode => Object.hash(blockId, start, end, digits);

  @override
  String toString() => 'HomericListNumberFix($blockId, $start-$end → $digits)';
}

final class _Item {
  _Item(
    this.blockId,
    this.depth,
    this.number,
    this.digitsStart,
    this.digitsEnd,
  );

  final String blockId;
  final int depth;
  final int number;
  final int digitsStart;
  final int digitsEnd;
}

final class _Run {
  final List<_Item> items = <_Item>[];
}

/// Every run in a document, and which run each numbered line is in.
final class _Runs {
  _Runs._(this.runs, this.byBlock);

  factory _Runs.of(Document doc, HomericIndentFilter? accepts) {
    final runs = <_Run>[];
    final byBlock = <String, _Run>{};
    // Open runs by depth: open[d] is the run counting at depth d, if any.
    final open = <_Run?>[];
    void closeFrom(int depth) {
      if (open.length > depth) open.length = depth;
    }

    for (final block in doc.blocks) {
      if (accepts != null && !accepts(block)) {
        closeFrom(0);
        continue;
      }
      final text = block.text;
      final match = HomericMarkdownListPrefix.match(text);
      if (match == null) {
        // A paragraph indented under an item (its words at that item's
        // words) stays inside the lists above it; anything else ends them.
        final trimmed = text.trimLeft();
        final level = trimmed.isEmpty
            ? 0
            : HomericListHang.depthOf(
                text.substring(0, text.length - trimmed.length));
        closeFrom(level);
        continue;
      }
      final depth =
          HomericListHang.depthOf(text.substring(0, match.indentLength));
      if (match.kind == HomericMarkdownListKind.bullet) {
        closeFrom(depth);
        continue;
      }
      closeFrom(depth + 1);
      while (open.length <= depth) {
        open.add(null);
      }
      var run = open[depth];
      if (run == null) {
        run = _Run();
        runs.add(run);
        open[depth] = run;
      }
      final digitsStart = match.indentLength;
      run.items.add(_Item(
        block.id,
        depth,
        int.tryParse(match.orderedDigits) ?? 1,
        digitsStart,
        digitsStart + match.orderedDigits.length,
      ));
      byBlock[block.id] = run;
    }
    return _Runs._(runs, byBlock);
  }

  final List<_Run> runs;
  final Map<String, _Run> byBlock;
}
