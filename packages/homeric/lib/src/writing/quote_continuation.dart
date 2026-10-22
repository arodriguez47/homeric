/// Opt-in Enter behaviour for `> ` quotes: the next line carries the marker,
/// and Enter on an empty quote line ends the quote.
library;

import 'package:flutter/foundation.dart';

import '../editing/editor_controller.dart';
import '../model/position.dart';
import '../model/selection.dart';
import '../transform/builders.dart';
import '../transform/transaction.dart';
import 'syntax_decorations.dart';
import 'writing_feature.dart';

/// Continues a `> ` quote on Enter, the way a list item continues its list.
///
/// With the caret after the marker of the line it sits on, Enter starts the
/// next line with `> `; on a line holding only the marker, Enter clears it
/// instead, ending the quote. Enter before the marker, a selection, or a
/// pasted break goes ahead as the editor would.
final class HomericQuoteContinuation extends HomericWritingFeature {
  /// Creates the feature.
  const HomericQuoteContinuation();

  @override
  String get id => 'quoteContinuation';

  /// Command interceptor that handles [HomericCommandKind.preBreak].
  HomericCommandInterceptor get interceptor => _intercept;

  @override
  VoidCallback installOn(HomericEditorController controller) =>
      controller.addCommandInterceptor(interceptor);

  static HomericCommandInterception _intercept(HomericEditorCommand command) {
    final selection = command.selection;
    if (command.kind != HomericCommandKind.preBreak ||
        command.text != '\n' ||
        selection == null ||
        !selection.isCollapsed) {
      return HomericCommandInterception.ignored;
    }
    final controller = command.controller;
    final resolved = controller.document.resolve(selection.head);
    if (resolved is! InlinePosition) return HomericCommandInterception.ignored;
    final text = resolved.block.text;
    final offset = resolved.offset;
    // The line the caret is on: a soft-broken quote marks each line.
    final lineStart = offset == 0 ? 0 : text.lastIndexOf('\n', offset - 1) + 1;
    final next = text.indexOf('\n', offset);
    final lineEnd = next < 0 ? text.length : next;
    final line = text.substring(lineStart, lineEnd);
    final marker = HomericSyntax.quoteLine.firstMatch(line);
    if (marker == null || offset < lineStart + marker.end) {
      return HomericCommandInterception.ignored;
    }
    final handled = line.trim() == '>'
        ? _endQuote(controller, resolved.block.id, text, lineStart, lineEnd,
            trailingBlockId: command.trailingBlockId)
        : lineEnd < text.length
            // Inside a soft-broken quote, the next line joins it in place.
            ? _continueInside(controller, selection.head)
            : controller.replaceSelectionStructurally(
                '\n> ',
                firstTrailingBlockId: command.trailingBlockId,
              );
    return handled
        ? HomericCommandInterception.handled
        : HomericCommandInterception.ignored;
  }

  /// Opens a quoted line at [position] inside a soft-broken quote, keeping
  /// the lines after it in the same block.
  static bool _continueInside(
    HomericEditorController controller,
    int position,
  ) {
    try {
      final tx = Transaction(controller.document)..insertText(position, '\n> ');
      return controller.applyPreparedCommand(HomericPreparedCommand(
        stages: <Transaction>[tx],
        selection: HomericSelection.collapsed(position + 3),
      ));
    } on ArgumentError {
      return false;
    }
  }

  /// Ends the quote at the empty line [lineStart]..[lineEnd] of block
  /// [blockId]. A block that is only that line is cleared; in a soft-broken
  /// quote the line becomes an empty paragraph of its own, between the
  /// quote's halves, with the caret in it.
  static bool _endQuote(
    HomericEditorController controller,
    String blockId,
    String text,
    int lineStart,
    int lineEnd, {
    String? trailingBlockId,
  }) {
    final before = lineStart > 0;
    final after = lineEnd < text.length;
    if (!before && !after) {
      return controller.applyBlockEditBatch(
        blockId: blockId,
        edits: <CanonicalTextEdit>[CanonicalTextEdit(0, text.length, '')],
        selection: const BlockTextSelection.collapsed(0),
      );
    }
    final document = controller.document;
    final index = document.indexOfBlockId(blockId);
    if (index == null) return false;
    final from = before ? lineStart - 1 : 0;
    final to = after ? lineEnd + 1 : lineEnd;
    try {
      final tx = Transaction(document)
        ..deleteRange(
          document.positionAt(index, from),
          document.positionAt(index, to),
        );
      // Splitting where the line was leaves an empty paragraph there, with
      // the quote's other half (if any) on its far side.
      // The block right after the quote's first half takes [trailingBlockId].
      if (after) {
        tx.splitBlock(
          tx.doc.positionAt(index, from),
          trailingBlockId: before ? null : trailingBlockId,
        );
      }
      if (before) {
        tx.splitBlock(
          tx.doc.positionAt(index, from),
          trailingBlockId: trailingBlockId,
        );
      }
      return controller.applyPreparedCommand(HomericPreparedCommand(
        stages: <Transaction>[tx],
        selection: HomericSelection.collapsed(
          tx.doc.positionAt(index + (before ? 1 : 0), 0),
        ),
      ));
    } on ArgumentError {
      return false;
    }
  }
}
