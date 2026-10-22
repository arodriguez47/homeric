/// Nesting list lines from the keyboard alone, for phones without Tab.
///
/// - A space typed at the start of an item's words nests it one level
///   under the item above (`- ` then a space reads `  - `), when that item
///   is at least as deep. A phone keyboard has a space bar, not a Tab key.
/// - Backspace at the start of a nested item's words takes it out a level;
///   on a top-level item it takes the bullet or number away, leaving the
///   words as a plain line.
/// - Enter on an empty nested item takes it out a level instead of leaving
///   the list, so Enter twice from a nested item climbs back to the parent
///   list first.
///
/// [HomericListNesting.indent] is the same nest/outdent for a host's own
/// gesture (a swipe on the line, see `HomericListLine.onIndent`) or button.
/// To-do lines are left to their own rules.
///
/// With [HomericListNesting.hangingLists] (the host draws markers in a
/// gutter, see `HomericSyntax.hangingLists`), the caret never rests inside
/// a marker: a tap or Home at the line's start puts it at the start of the
/// words, and ← from there goes on to the line above.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../editing/editor_controller.dart';
import '../editing/markdown_list_indent.dart';
import '../model/block.dart';
import '../model/document.dart';
import '../model/position.dart';
import '../model/selection.dart';
import '../transform/builders.dart';
import '../transform/transaction.dart';
import 'checklists.dart';
import 'list_hang.dart';
import 'writing_feature.dart';

/// Keyboard-only nesting for list lines as a [HomericWritingFeature].
final class HomericListNesting extends HomericWritingFeature {
  /// Creates the feature; [isActive] is read before each rule, null is on.
  const HomericListNesting({this.isActive, this.hangingLists = false});

  /// Read before each rule; `false` leaves typing as typed.
  final ValueGetter<bool>? isActive;

  /// Whether the host hangs list lines, folding their markers out of view:
  /// then the caret is kept out of a marker it could not be seen in.
  final bool hangingLists;

  @override
  String get id => 'listNesting';

  @override
  VoidCallback installOn(HomericEditorController controller) {
    final stopIntercepting = controller.addCommandInterceptor((command) {
      if (command.controller != controller ||
          isActive?.call() == false ||
          controller.composing != null) {
        return HomericCommandInterception.ignored;
      }
      final prepared = prepare(command);
      if (prepared == null) return HomericCommandInterception.ignored;
      return controller.applyPreparedCommand(prepared)
          ? HomericCommandInterception.handled
          : HomericCommandInterception.ignored;
    });
    if (!hangingLists) return stopIntercepting;
    final keeper = _CaretKeeper(controller);
    controller.addListener(keeper.onChanged);
    return () {
      controller.removeListener(keeper.onChanged);
      stopIntercepting();
    };
  }

  /// The document position a caret at [offset] in [blockIndex] of
  /// [document] moves to when markers are hung, or null when it is fine
  /// where it is. [from] is the
  /// caret's offset in the same block just before, when it was there.
  @visibleForTesting
  static int? keptCaret(
    Document document,
    int blockIndex,
    int offset, {
    int? from,
  }) {
    final block = document.blocks[blockIndex];
    final match = _listLine(block);
    if (match == null || offset >= match.prefixEnd) return null;
    // ← from the start of the words: on to the end of the line above.
    if (from == match.prefixEnd &&
        offset == match.prefixEnd - 1 &&
        blockIndex > 0) {
      return document.positionAt(
        blockIndex - 1,
        document.blocks[blockIndex - 1].contentLength,
      );
    }
    return document.positionAt(blockIndex, match.prefixEnd);
  }

  /// The command a list rule makes of [command], or null when it goes ahead
  /// as typed.
  static HomericPreparedCommand? prepare(HomericEditorCommand command) {
    final selection = command.selection;
    if (selection == null || !selection.isCollapsed) return null;
    final document = command.controller.document;
    final caret = document.resolve(selection.head);
    if (caret is! InlinePosition ||
        (command.blockId != null && caret.block.id != command.blockId)) {
      return null;
    }
    final block = caret.block;
    final match = _listLine(block);
    if (match == null) return null;
    final atWords = caret.offset == match.prefixEnd;
    switch (command.kind) {
      case HomericCommandKind.preInsert:
        // A space at the start of the words, typed (one insertion at the
        // caret) rather than pasted.
        final edits = command.edits;
        if (!atWords ||
            command.text != ' ' ||
            command.replacementComposing != null ||
            (edits != null &&
                (edits.length != 1 ||
                    edits.single.start != caret.offset ||
                    edits.single.end != caret.offset))) {
          return null;
        }
        if (!_canNest(document, caret.blockIndex, match, block)) return null;
        return prepareIndent(document, block.id, selection: selection);
      case HomericCommandKind.preDelete:
        final edits = command.edits;
        // Enter on an empty item clears its marker to leave the list
        // (`insertParagraphBreak`); a nested one climbs a level instead.
        if (atWords &&
            match.indentLength > 0 &&
            block.text.length == match.prefixEnd &&
            edits != null &&
            edits.length == 1 &&
            edits.single.start == 0 &&
            edits.single.end == match.prefixEnd &&
            edits.single.text.isEmpty) {
          return prepareIndent(
            document,
            block.id,
            outdent: true,
            selection: selection,
          );
        }
        // Backspace: one character before the caret, at the words' start.
        if (!atWords ||
            edits == null ||
            edits.length != 1 ||
            edits.single.end != caret.offset ||
            edits.single.start != caret.offset - 1 ||
            edits.single.text.isNotEmpty) {
          return null;
        }
        if (match.indentLength > 0) {
          return prepareIndent(
            document,
            block.id,
            outdent: true,
            selection: selection,
          );
        }
        return _prepareUnlist(document, caret.blockIndex, match);
      case HomericCommandKind.preBreak:
        // Enter on an empty nested item.
        if (!atWords ||
            block.text.length != match.prefixEnd ||
            match.indentLength == 0) {
          return null;
        }
        return prepareIndent(
          document,
          block.id,
          outdent: true,
          selection: selection,
        );
      case HomericCommandKind.block:
        return null;
    }
  }

  /// Nests the list line [blockId] one level, or takes it out one with
  /// [outdent], as one undo step; the selection follows its text. False
  /// when it is not a list line, is a to-do, has no level to leave, or would
  /// nest deeper than one level under the item above.
  static bool indent(
    HomericEditorController controller,
    String blockId, {
    bool outdent = false,
  }) {
    if (controller.isReadOnly || controller.composing != null) return false;
    final document = controller.document;
    final index = document.indexOfBlockId(blockId);
    if (index == null) return false;
    final block = document.blocks[index];
    final match = _listLine(block);
    if (match == null) return false;
    if (!outdent && !_canNest(document, index, match, block)) return false;
    final prepared = prepareIndent(
      document,
      blockId,
      outdent: outdent,
      selection: controller.selection,
    );
    return prepared != null && controller.applyPreparedCommand(prepared);
  }

  /// The command that nests [blockId] one level (or takes it out one, with
  /// [outdent]), carrying [selection] along; null when [blockId] is not a
  /// list line or has no level to leave.
  static HomericPreparedCommand? prepareIndent(
    Document document,
    String blockId, {
    bool outdent = false,
    HomericSelection? selection,
  }) {
    final index = document.indexOfBlockId(blockId);
    if (index == null) return null;
    final text = document.blocks[index].text;
    final edit = outdent
        ? HomericMarkdownListIndent.outdent(text)
        : HomericMarkdownListIndent.nest(text);
    if (edit == null) return null;
    try {
      final transaction = Transaction(document);
      if (edit.end > edit.start) {
        transaction.deleteRange(
          document.positionAt(index, edit.start),
          document.positionAt(index, edit.end),
        );
      }
      if (edit.replacement.isNotEmpty) {
        transaction.insertText(
          transaction.doc.positionAt(index, edit.start),
          edit.replacement,
        );
      }
      return HomericPreparedCommand(
        stages: <Transaction>[transaction],
        selection: selection?.map(transaction.mapping),
      );
    } on ArgumentError {
      return null;
    }
  }

  /// Takes a top-level item's marker away; the caret stays at the words.
  static HomericPreparedCommand? _prepareUnlist(
    Document document,
    int index,
    HomericMarkdownListMatch match,
  ) {
    try {
      final transaction = Transaction(document)
        ..deleteRange(
          document.positionAt(index, 0),
          document.positionAt(index, match.prefixEnd),
        );
      return HomericPreparedCommand(
        stages: <Transaction>[transaction],
        selection: HomericSelection.collapsed(
          transaction.doc.positionAt(index, 0),
        ),
      );
    } on ArgumentError {
      return null;
    }
  }

  /// [block] as a list line, or null when it is not one or is a to-do.
  static HomericMarkdownListMatch? _listLine(Block block) {
    final match = HomericMarkdownListPrefix.match(block.text);
    if (match == null) return null;
    if (HomericChecklists.line.hasMatch(block.text.split('\n').first)) {
      return null;
    }
    return match;
  }

  /// Whether the list line at [index] may nest: the block above is a list
  /// line at least as deep, so the nested item has a parent.
  static bool _canNest(
    Document document,
    int index,
    HomericMarkdownListMatch match,
    Block block,
  ) {
    if (index == 0) return false;
    final above = document.blocks[index - 1];
    final aboveMatch = HomericMarkdownListPrefix.match(above.text);
    if (aboveMatch == null) return false;
    final depth =
        HomericListHang.depthOf(block.text.substring(0, match.indentLength));
    final aboveDepth = HomericListHang.depthOf(
      above.text.substring(0, aboveMatch.indentLength),
    );
    return aboveDepth >= depth;
  }
}

/// Moves a collapsed caret that lands inside a hung marker to where it can
/// be seen.
final class _CaretKeeper {
  _CaretKeeper(this.controller);

  final HomericEditorController controller;

  /// The caret's last resting place: block id and offset.
  (String, int)? _last;

  void onChanged() {
    final selection = controller.selection;
    final document = controller.document;
    final last = _last;
    _last = null;
    if (selection == null ||
        !selection.isCollapsed ||
        controller.composing != null) {
      return;
    }
    final caret = document.resolve(selection.head);
    if (caret is! InlinePosition) return;
    _last = (caret.block.id, caret.offset);
    final kept = HomericListNesting.keptCaret(
      document,
      caret.blockIndex,
      caret.offset,
      from: last != null && last.$1 == caret.block.id ? last.$2 : null,
    );
    if (kept == null) return;
    // After the change that put it there has settled.
    scheduleMicrotask(() {
      if (!identical(controller.document, document) ||
          controller.selection != selection) {
        return;
      }
      controller.setSelection(HomericSelection.collapsed(kept));
    });
  }
}
