/// Closing punctuation goes before a footnote marker, not after it.
///
/// `word^[note]` + `.` reads `word.^[note]`: the typographic convention
/// puts the superscript after the full stop. Hosts that keep footnotes as
/// typed syntax install [HomericFootnotePunctuation]; a host that keeps its
/// footnotes elsewhere (as run attributes) uses the same rule through
/// [HomericFootnotePunctuation.trailing].
library;

import 'package:flutter/foundation.dart';

import '../editing/editor_controller.dart';
import '../model/attributes.dart';
import '../model/block.dart';
import '../model/position.dart';
import '../model/selection.dart';
import '../transform/builders.dart';
import '../transform/transaction.dart';
import 'note_marks.dart';
import 'writing_feature.dart';

/// The footnote punctuation hop as a [HomericWritingFeature].
final class HomericFootnotePunctuation extends HomericWritingFeature {
  /// Creates the feature; [isActive] is read before each hop (null is
  /// always on).
  const HomericFootnotePunctuation({this.isActive});

  /// Read before each hop; `false` leaves typing as typed.
  final ValueGetter<bool>? isActive;

  /// Closing punctuation a footnote marker follows rather than precedes.
  static const Set<String> trailing = <String>{
    '.',
    ',',
    ';',
    ':',
    '!',
    '?',
    ')',
    ']',
    '"',
    '\'',
    '’',
    '”',
    '…',
  };

  @override
  String get id => 'footnotePunctuation';

  @override
  VoidCallback installOn(HomericEditorController controller) =>
      controller.addCommandInterceptor(intercept);

  /// Interceptor that applies [prepare]'s command.
  HomericCommandInterception intercept(HomericEditorCommand command) {
    if (isActive?.call() == false) return HomericCommandInterception.ignored;
    final prepared = prepare(command);
    if (prepared == null) return HomericCommandInterception.ignored;
    return command.controller.applyPreparedCommand(prepared)
        ? HomericCommandInterception.handled
        : HomericCommandInterception.ignored;
  }

  /// Where [typed] goes when typed at [caret] in [text]: the start of the
  /// `^[note]` or `[^id]` marker that ends at the caret, or null when there
  /// is none or [typed] is not closing punctuation.
  static int? hopTarget(String text, int caret, String typed) {
    if (!trailing.contains(typed) || caret <= 0 || caret > text.length) {
      return null;
    }
    final scan = HomericMarkScan(text);
    for (final m in <RegExpMatch>[
      ...scan.inlineFootnotes,
      ...scan.references,
    ]) {
      if (m.end == caret) return m.start;
    }
    return null;
  }

  /// The command that types [HomericEditorCommand.text] before the marker
  /// ending at the caret, with the caret staying after the marker; null
  /// when typing goes ahead as typed.
  static HomericPreparedCommand? prepare(HomericEditorCommand command) {
    final typed = command.text;
    final selection = command.selection;
    final controller = command.controller;
    if (command.kind != HomericCommandKind.preInsert ||
        typed == null ||
        selection == null ||
        !selection.isCollapsed ||
        controller.composing != null ||
        command.replacementComposing != null) {
      return null;
    }
    final document = controller.document;
    final caret = document.resolve(selection.head);
    if (caret is! InlinePosition ||
        (command.blockId != null && caret.block.id != command.blockId)) {
      return null;
    }
    final offset = caret.offset;
    final edits = command.edits;
    if (edits != null &&
        (edits.length != 1 ||
            edits.single.start != offset ||
            edits.single.end != offset ||
            edits.single.text != typed)) {
      return null;
    }
    final block = caret.block;
    final target = hopTarget(block.text, offset, typed);
    if (target == null) return null;
    try {
      final index = caret.blockIndex;
      final transaction = Transaction(document)
        ..insertText(
          document.positionAt(index, target),
          typed,
          attributes: _attributesBefore(block, target),
        );
      return HomericPreparedCommand(
        stages: <Transaction>[transaction],
        selection: HomericSelection.collapsed(
          transaction.doc.positionAt(index, offset + typed.length),
        ),
      );
    } on ArgumentError {
      return null;
    }
  }

  static Attributes _attributesBefore(Block block, int offset) {
    if (offset == 0 || block.runs.isEmpty) return emptyAttributes;
    var cursor = 0;
    for (final run in block.runs) {
      final end = cursor + run.length;
      if (offset - 1 >= cursor && offset - 1 < end) return run.attributes;
      cursor = end;
    }
    return emptyAttributes;
  }
}
