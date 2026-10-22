/// Opt-in Enter behaviour for `> ` quotes: the next line carries the marker,
/// and Enter on an empty quote line ends the quote.
library;

import 'package:flutter/foundation.dart';

import '../editing/editor_controller.dart';
import '../model/position.dart';
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
        ? controller.applyBlockEditBatch(
            blockId: resolved.block.id,
            edits: <CanonicalTextEdit>[
              CanonicalTextEdit(lineStart, lineEnd, ''),
            ],
            selection: BlockTextSelection.collapsed(lineStart),
          )
        : controller.replaceSelectionStructurally(
            '\n> ',
            firstTrailingBlockId: command.trailingBlockId,
          );
    return handled
        ? HomericCommandInterception.handled
        : HomericCommandInterception.ignored;
  }
}
