/// Indenting whole blocks: a paragraph and a list line move on one ruler.
///
/// A block's indent is its first line's leading whitespace, two spaces (or
/// a tab) per level, as a nested list line's already is. So one model
/// covers both: a list line at depth `d` has its words `d + 1` steps in
/// (its marker hangs in the step before them), and a paragraph indented
/// `n` levels has its words `n` steps in. A paragraph indented once under
/// a top-level item lines up with the item's words, as a continuation
/// paragraph does in a typeset list.
///
/// The indent is folded out of view with the list markers
/// (`HomericSyntax.hangingIndents`) and the host lays the paragraph out
/// with `HomericListLine`, so wrapped lines keep to the indent. Markdown
/// readers see an ordinary paragraph (up to three leading spaces) or a
/// nested list.
///
/// [HomericBlockIndent] is the writing feature:
///
/// - Tab and Shift-Tab indent and outdent every block the selection
///   touches, list lines and paragraphs alike, as one undo step.
/// - A space typed at the start of a paragraph's words indents it, as it
///   nests a list line ([HomericListNesting]); Backspace there takes it
///   out a level. A phone keyboard has a space bar, not a Tab key.
/// - Enter in an indented paragraph starts the next one at the same
///   indent; Enter on an empty indented paragraph takes it out a level.
/// - The caret never rests inside a folded indent.
///
/// A block moves at most one step right of the block above it, so an
/// indent always reads as belonging to the line above.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter/widgets.dart' show SingleActivator;

import '../editing/editable_document.dart';
import '../editing/editor_controller.dart';
import '../editing/markdown_list_indent.dart';
import '../model/block.dart';
import '../model/document.dart';
import '../model/position.dart';
import '../model/selection.dart';
import '../transform/builders.dart';
import '../transform/transaction.dart';
import 'list_hang.dart';
import 'writing_feature.dart';

/// An indented paragraph's folded indent.
@immutable
final class HomericParagraphIndent {
  /// [level] steps in, its leading whitespace ending at [prefixEnd].
  const HomericParagraphIndent({required this.level, required this.prefixEnd});

  /// Levels of indent: a tab, or two spaces, each.
  final int level;

  /// End of the leading whitespace, where the words start.
  final int prefixEnd;

  @override
  bool operator ==(Object other) =>
      other is HomericParagraphIndent &&
      other.level == level &&
      other.prefixEnd == prefixEnd;

  @override
  int get hashCode => Object.hash(level, prefixEnd);
}

/// Indent and outdent for paragraphs and list lines, as a
/// [HomericWritingFeature].
final class HomericBlockIndent extends HomericWritingFeature {
  /// Creates the feature. [types] are the block types whose text is
  /// indented as a paragraph; [isActive] is read before each rule, null
  /// is on. [tab] binds Tab and Shift-Tab; [typing] adds the space,
  /// Backspace and Enter rules.
  const HomericBlockIndent({
    this.isActive,
    this.types = defaultTypes,
    this.tab = true,
    this.typing = true,
  });

  /// Plain paragraphs.
  static const Set<String> defaultTypes = <String>{'paragraph'};

  /// Read before each rule; `false` leaves typing and Tab as they were.
  final ValueGetter<bool>? isActive;

  /// Block types that indent as paragraphs (and hold list lines).
  final Set<String> types;

  /// Whether Tab and Shift-Tab indent.
  final bool tab;

  /// Whether a space at a paragraph's start indents it, Backspace there
  /// outdents it, and Enter carries the indent to the next paragraph.
  final bool typing;

  /// The deepest a block goes: eight steps.
  static const int maxColumn = 8;

  @override
  String get id => 'blockIndent';

  @override
  VoidCallback installOn(HomericEditorController controller) {
    if (!typing) return homericWritingNoop;
    final stopIntercepting = controller.addCommandInterceptor((command) {
      if (command.controller != controller ||
          isActive?.call() == false ||
          controller.composing != null) {
        return HomericCommandInterception.ignored;
      }
      if (_typed(command, types)) return HomericCommandInterception.handled;
      return continueIndent(command, types: types);
    });
    final keeper = _CaretKeeper(controller, types);
    controller.addListener(keeper.onChanged);
    keeper.onChanged();
    return () {
      controller.removeListener(keeper.onChanged);
      stopIntercepting();
    };
  }

  @override
  List<HomericDocumentCommandBinding> get commandBindings => !tab
      ? const <HomericDocumentCommandBinding>[]
      : <HomericDocumentCommandBinding>[
          for (final outdent in const <bool>[false, true])
            HomericDocumentCommandBinding(
              shortcut: SingleActivator(
                LogicalKeyboardKey.tab,
                shift: outdent,
              ),
              onInvoke: (context) {
                if (!context.isCurrent ||
                    context.composing != null ||
                    isActive?.call() == false) {
                  return HomericDocumentCommandResult.ignored;
                }
                final selection = context.selection;
                if (selection == null) {
                  return HomericDocumentCommandResult.ignored;
                }
                final prepared = prepare(
                  context.document,
                  selection,
                  outdent: outdent,
                  types: types,
                );
                if (prepared != null) {
                  return HomericDocumentCommandResult.prepared(prepared);
                }
                // A line that can't move further keeps Tab: it does not
                // leave the text for the next control.
                return reachable(context.document, selection, types: types)
                    ? HomericDocumentCommandResult.rejected(
                        const _NoFurther(),
                        announcement: outdent
                            ? 'Already at the margin.'
                            : 'Already one step in from the line above.',
                      )
                    : HomericDocumentCommandResult.ignored;
              },
            ),
        ];

  /// [block]'s indent when it is a paragraph that can be indented (one of
  /// [types], not a heading, quote, fence, footnote or drop cap, and not a
  /// list line), even at level 0; null otherwise.
  static HomericParagraphIndent? paragraphIndentOf(
    Block block, {
    Set<String> types = defaultTypes,
  }) {
    if (!types.contains(block.type)) return null;
    final text = block.text;
    if (HomericMarkdownListPrefix.match(text) != null) return null;
    final prefixEnd = _leading(text);
    final words = text.substring(prefixEnd);
    if (_notProse.hasMatch(words)) return null;
    return HomericParagraphIndent(
      level: HomericListHang.depthOf(text.substring(0, prefixEnd)),
      prefixEnd: prefixEnd,
    );
  }

  /// How many steps in [block]'s words start: a list line's depth plus
  /// one (its marker takes a step), an indented paragraph's level, and 0
  /// for anything else.
  static int columnOf(Block block, {Set<String> types = defaultTypes}) {
    if (!types.contains(block.type)) return 0;
    final list = HomericMarkdownListPrefix.match(block.text);
    if (list != null) {
      return HomericListHang.depthOf(
            block.text.substring(0, list.indentLength),
          ) +
          1;
    }
    return paragraphIndentOf(block, types: types)?.level ?? 0;
  }

  /// Whether [selection] touches a block that indents at all, list line
  /// or paragraph, so Tab is the indent's even where it can't move.
  static bool reachable(
    Document document,
    HomericSelection selection, {
    Set<String> types = defaultTypes,
  }) {
    final range = _blockRange(document, selection);
    if (range == null) return false;
    for (var index = range.$1; index <= range.$2; index++) {
      if (_kindOf(document.blocks[index], types) != null) return true;
    }
    return false;
  }

  /// Whether [prepare] would move anything.
  static bool canIndent(
    Document document,
    HomericSelection selection, {
    bool outdent = false,
    Set<String> types = defaultTypes,
  }) =>
      _edits(document, selection, outdent: outdent, types: types).isNotEmpty;

  /// The command that indents (or with [outdent], outdents) every block
  /// [selection] touches by one step, as one undo step; the selection
  /// follows its words. Null when nothing can move.
  ///
  /// A selection that ends at the very start of a block leaves that block
  /// be, as a code editor does. A block that would sit more than one step
  /// right of the block above (as it will be) stays where it is.
  static HomericPreparedCommand? prepare(
    Document document,
    HomericSelection selection, {
    bool outdent = false,
    Set<String> types = defaultTypes,
  }) {
    final edits = _edits(document, selection, outdent: outdent, types: types);
    if (edits.isEmpty) return null;
    try {
      final transaction = Transaction(document);
      for (final (index, remove, insert) in edits) {
        if (remove > 0) {
          transaction.deleteRange(
            transaction.doc.positionAt(index, 0),
            transaction.doc.positionAt(index, remove),
          );
        }
        if (insert.isNotEmpty) {
          transaction.insertText(transaction.doc.positionAt(index, 0), insert);
        }
      }
      return HomericPreparedCommand(
        stages: <Transaction>[transaction],
        selection: selection.map(transaction.mapping),
      );
    } on ArgumentError {
      return null;
    }
  }

  /// Indents [controller]'s selection (or outdents it); false when
  /// nothing could move. For a host's own button or menu item.
  static bool indentSelection(
    HomericEditorController controller, {
    bool outdent = false,
    Set<String> types = defaultTypes,
  }) {
    final selection = controller.selection;
    if (selection == null ||
        controller.isReadOnly ||
        controller.composing != null) {
      return false;
    }
    final prepared = prepare(
      controller.document,
      selection,
      outdent: outdent,
      types: types,
    );
    return prepared != null && controller.applyPreparedCommand(prepared);
  }

  /// Indents block [blockId] (or outdents it), whatever the selection, which
  /// follows its words; false when it could not move. For a swipe on the
  /// line.
  static bool indentBlock(
    HomericEditorController controller,
    String blockId, {
    bool outdent = false,
    Set<String> types = defaultTypes,
  }) {
    if (controller.isReadOnly || controller.composing != null) return false;
    final document = controller.document;
    final index = document.indexOfBlockId(blockId);
    if (index == null) return false;
    final at = document.positionAt(
      index,
      document.blocks[index].contentLength,
    );
    final edits = _edits(
      document,
      HomericSelection.collapsed(at),
      outdent: outdent,
      types: types,
    );
    if (edits.isEmpty) return false;
    try {
      final transaction = Transaction(document);
      final (_, remove, insert) = edits.single;
      if (remove > 0) {
        transaction.deleteRange(
          document.positionAt(index, 0),
          document.positionAt(index, remove),
        );
      }
      if (insert.isNotEmpty) {
        transaction.insertText(transaction.doc.positionAt(index, 0), insert);
      }
      return controller.applyPreparedCommand(HomericPreparedCommand(
        stages: <Transaction>[transaction],
        selection: controller.selection?.map(transaction.mapping),
      ));
    } on ArgumentError {
      return false;
    }
  }

  /// The first and last block index [selection] touches, or null when an
  /// end is not in a text block.
  static (int, int)? _blockRange(Document document, HomericSelection selection) {
    final start = document.resolve(selection.start);
    final end = document.resolve(selection.end);
    if (start is! InlinePosition || end is! InlinePosition) return null;
    var last = end.blockIndex;
    if (!selection.isCollapsed && last > start.blockIndex && end.offset == 0) {
      last--;
    }
    return (start.blockIndex, last);
  }

  /// Per block that moves: its index, how many leading characters go, and
  /// what goes in their place.
  static List<(int, int, String)> _edits(
    Document document,
    HomericSelection selection, {
    required bool outdent,
    required Set<String> types,
  }) {
    final range = _blockRange(document, selection);
    if (range == null) return const <(int, int, String)>[];
    final edits = <(int, int, String)>[];
    // The column of the block above, as it will be once the blocks before
    // have moved.
    var above = range.$1 == 0
        ? 0
        : columnOf(document.blocks[range.$1 - 1], types: types);
    for (var index = range.$1; index <= range.$2; index++) {
      final block = document.blocks[index];
      final kind = _kindOf(block, types);
      final column = columnOf(block, types: types);
      if (kind == null) {
        above = column;
        continue;
      }
      final text = block.text;
      final leading = _leading(text);
      if (outdent) {
        if (leading == 0) {
          above = column;
          continue;
        }
        final remove = text.startsWith(HomericMarkdownListIndent.unit)
            ? HomericMarkdownListIndent.unit.length
            : 1;
        edits.add((index, remove, ''));
        above = HomericListHang.depthOf(text.substring(remove, leading)) +
            (kind ? 1 : 0);
        continue;
      }
      if (column + 1 > above + 1 || column + 1 > maxColumn) {
        above = column;
        continue;
      }
      edits.add((index, 0, HomericMarkdownListIndent.unit));
      above = column + 1;
    }
    return edits;
  }

  /// Whether [block] indents as a list line (`true`) or a paragraph
  /// (`false`); null when it doesn't.
  static bool? _kindOf(Block block, Set<String> types) {
    if (!types.contains(block.type)) return null;
    if (HomericMarkdownListPrefix.match(block.text) != null) return true;
    return paragraphIndentOf(block, types: types) == null ? null : false;
  }

  /// Handles the typing rules for [command]; true when it did.
  static bool _typed(HomericEditorCommand command, Set<String> types) {
    final selection = command.selection;
    if (selection == null || !selection.isCollapsed) return false;
    final controller = command.controller;
    final document = controller.document;
    final caret = document.resolve(selection.head);
    if (caret is! InlinePosition ||
        (command.blockId != null && caret.block.id != command.blockId)) {
      return false;
    }
    final block = caret.block;
    final indent = paragraphIndentOf(block, types: types);
    if (indent == null || caret.offset != indent.prefixEnd) return false;
    final text = block.text;
    final empty = text.length == indent.prefixEnd;
    final edits = command.edits;
    switch (command.kind) {
      case HomericCommandKind.preInsert:
        // A space typed (one insertion at the caret, not a paste) at the
        // start of a paragraph's words.
        if (command.text != ' ' ||
            empty ||
            command.replacementComposing != null ||
            (edits != null &&
                (edits.length != 1 ||
                    edits.single.start != caret.offset ||
                    edits.single.end != caret.offset))) {
          return false;
        }
        return _apply(controller, document, selection, outdent: false,
            types: types);
      case HomericCommandKind.preDelete:
        // Backspace: one character before the caret.
        if (indent.level == 0 ||
            edits == null ||
            edits.length != 1 ||
            edits.single.end != caret.offset ||
            edits.single.start != caret.offset - 1 ||
            edits.single.text.isNotEmpty) {
          return false;
        }
        return _apply(controller, document, selection, outdent: true,
            types: types);
      case HomericCommandKind.preBreak:
        if (command.text != '\n' || indent.level == 0) return false;
        // Enter on an empty indented paragraph steps out a level.
        if (empty) {
          return _apply(controller, document, selection, outdent: true,
              types: types);
        }
        return false;
      case HomericCommandKind.block:
        return false;
    }
  }

  static bool _apply(
    HomericEditorController controller,
    Document document,
    HomericSelection selection, {
    required bool outdent,
    required Set<String> types,
  }) {
    final prepared =
        prepare(document, selection, outdent: outdent, types: types);
    return prepared != null && controller.applyPreparedCommand(prepared);
  }

  /// Carries an indented paragraph's indent onto the paragraph Enter
  /// starts: an interceptor a host installs after the list rules. Part of
  /// [installOn]; exposed for hosts that order interceptors themselves.
  static HomericCommandInterception continueIndent(
    HomericEditorCommand command, {
    Set<String> types = defaultTypes,
  }) {
    final selection = command.selection;
    if (command.kind != HomericCommandKind.preBreak ||
        command.text != '\n' ||
        selection == null ||
        !selection.isCollapsed) {
      return HomericCommandInterception.ignored;
    }
    final controller = command.controller;
    final caret = controller.document.resolve(selection.head);
    if (caret is! InlinePosition) return HomericCommandInterception.ignored;
    final indent = paragraphIndentOf(caret.block, types: types);
    if (indent == null ||
        indent.level == 0 ||
        caret.offset < indent.prefixEnd ||
        caret.block.text.length == indent.prefixEnd) {
      return HomericCommandInterception.ignored;
    }
    final prefix = caret.block.text.substring(0, indent.prefixEnd);
    return controller.replaceSelectionStructurally(
      '\n$prefix',
      firstTrailingBlockId: command.trailingBlockId,
    )
        ? HomericCommandInterception.handled
        : HomericCommandInterception.ignored;
  }

  /// The position a caret at [offset] in [blockIndex] moves to so it is
  /// not inside a folded paragraph indent, or null when it is fine. [from]
  /// is its offset in the same block just before.
  @visibleForTesting
  static int? keptCaret(
    Document document,
    int blockIndex,
    int offset, {
    int? from,
    Set<String> types = defaultTypes,
  }) {
    final indent =
        paragraphIndentOf(document.blocks[blockIndex], types: types);
    if (indent == null || indent.level == 0 || offset >= indent.prefixEnd) {
      return null;
    }
    // ← from the start of the words: on to the end of the line above.
    if (from == indent.prefixEnd &&
        offset == indent.prefixEnd - 1 &&
        blockIndex > 0) {
      return document.positionAt(
        blockIndex - 1,
        document.blocks[blockIndex - 1].contentLength,
      );
    }
    return document.positionAt(blockIndex, indent.prefixEnd);
  }

  static int _leading(String text) {
    var end = 0;
    while (end < text.length) {
      final unit = text.codeUnitAt(end);
      if (unit != 0x20 && unit != 0x09) break;
      end++;
    }
    return end;
  }

  /// Words that read as something other than a paragraph once indented:
  /// a heading, a quote, a fence, a drop cap, a `%%` comment, a footnote's
  /// note, a divider.
  static final RegExp _notProse = RegExp(
    r'^(?:#{1,6}(?: |$)|>|```|~~~|\^\^|%%|\[\^[^\]]*\]:|-{3,}\s*$)',
  );
}

/// Why Tab did nothing on a line that can't move further.
final class _NoFurther {
  const _NoFurther();
}

/// Moves a collapsed caret that lands inside a folded paragraph indent to
/// where it can be seen.
final class _CaretKeeper {
  _CaretKeeper(this.controller, this.types);

  final HomericEditorController controller;
  final Set<String> types;

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
    final kept = HomericBlockIndent.keptCaret(
      document,
      caret.blockIndex,
      caret.offset,
      from: last != null && last.$1 == caret.block.id ? last.$2 : null,
      types: types,
    );
    if (kept == null) return;
    scheduleMicrotask(() {
      if (!identical(controller.document, document) ||
          controller.selection != selection) {
        return;
      }
      controller.setSelection(HomericSelection.collapsed(kept));
    });
  }
}
