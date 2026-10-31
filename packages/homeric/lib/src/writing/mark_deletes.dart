/// Backspace and Delete beside typed marks: a folded mark's delimiters are
/// stepped over, and a shown one goes as a pair.
///
/// In live preview a `==highlight==`'s closing `==` is folded away, so a
/// caret after the last highlighted word sits after that hidden `==`.
/// Backspace there used to take a hidden `=` and break the highlight open.
/// With [HomericMarkDeletes]:
///
/// - A delimiter that is folded is never deleted: the key takes the letter
///   it hides behind instead, as if the mark were not there.
/// - A delimiter that shows (the caret in it, or a host that reveals the
///   source) goes with its partner: `==words==` becomes `words`, and an
///   annotation `{{words|note}}` becomes `words`. One undo brings it back.
/// - Deleting a mark's last letter takes the emptied mark with it.
library;

import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';

import '../decoration/decoration.dart';
import '../decoration/markdown_mark_visibility.dart';
import '../editing/editor_controller.dart';
import '../model/block.dart';
import '../model/position.dart';
import '../model/selection.dart';
import '../transform/transaction.dart';
import '../transform/builders.dart';
import 'note_marks.dart';
import 'syntax_decorations.dart';
import 'writing_feature.dart';

/// One typed mark's two delimiters in a block, as `[start, end)` offsets:
/// `==` and `==`, or an annotation's `{{` and `|note}}`.
@immutable
final class HomericMarkPair {
  /// A pair whose opening is `[openStart, openEnd)` and closing
  /// `[closeStart, closeEnd)`.
  const HomericMarkPair(
    this.openStart,
    this.openEnd,
    this.closeStart,
    this.closeEnd, {
    this.noteStart,
    this.noteEnd,
  });

  /// Where the opening delimiter starts; the mark's start.
  final int openStart;

  /// Where the opening delimiter ends; the words start.
  final int openEnd;

  /// Where the closing delimiter starts; the words end.
  final int closeStart;

  /// Where the closing delimiter ends; the mark's end.
  final int closeEnd;

  /// An annotation's note, `[noteStart, noteEnd)` inside the closing
  /// `|note}}`: text written in it, not delimiter. Null for other marks.
  final int? noteStart;

  /// See [noteStart].
  final int? noteEnd;

  /// Whether [offset] is a delimiter character of this pair.
  bool isDelimiter(int offset) {
    if (offset >= openStart && offset < openEnd) return true;
    if (offset < closeStart || offset >= closeEnd) return false;
    final from = noteStart;
    final to = noteEnd;
    return from == null || to == null || offset < from || offset >= to;
  }

  @override
  bool operator ==(Object other) =>
      other is HomericMarkPair &&
      other.openStart == openStart &&
      other.openEnd == openEnd &&
      other.closeStart == closeStart &&
      other.closeEnd == closeEnd &&
      other.noteStart == noteStart &&
      other.noteEnd == noteEnd;

  @override
  int get hashCode =>
      Object.hash(openStart, openEnd, closeStart, closeEnd, noteStart, noteEnd);

  @override
  String toString() =>
      'HomericMarkPair([$openStart, $openEnd), [$closeStart, $closeEnd))';
}

/// The paired marks [syntax] folds in [block]: `**bold**`, `*italic*`,
/// `` `code` ``, `==highlight==` with [HomericSyntax.markdown], and the
/// writing layer's `++asides++`, `~~strikes~~` and `{{annotations}}`.
List<HomericMarkPair> homericMarkPairs(HomericSyntax syntax, Block block) {
  final text = block.text;
  final pairs = <HomericMarkPair>[];
  void delimited(RegExp pattern, int width) {
    for (final m in pattern.allMatches(text)) {
      pairs.add(
        HomericMarkPair(m.start, m.start + width, m.end - width, m.end),
      );
    }
  }

  if (syntax.markdown) {
    delimited(RegExp(r'==(.+?)=='), 2);
    delimited(RegExp(r'\*\*(.+?)\*\*'), 2);
    delimited(RegExp(r'(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)'), 1);
    delimited(RegExp(r'`([^`]+)`'), 1);
  }
  final scan = HomericMarkScan(text);
  if (syntax.comments) {
    for (final m in scan.asides) {
      pairs.add(HomericMarkPair(m.start, m.start + 2, m.end - 2, m.end));
    }
  }
  if (syntax.strike) {
    for (final m in scan.strikes) {
      pairs.add(HomericMarkPair(m.start, m.start + 2, m.end - 2, m.end));
    }
  }
  if (syntax.annotations) {
    for (final m in scan.annotations) {
      final passageEnd = m.start + 2 + m.group(1)!.length;
      pairs.add(
        HomericMarkPair(
          m.start,
          m.start + 2,
          passageEnd,
          m.end,
          noteStart: m.group(2) == null ? null : passageEnd + 1,
          noteEnd: m.group(2) == null ? null : m.end - 2,
        ),
      );
    }
  }
  return pairs;
}

/// What a one-character Backspace or Delete at [caret] in [block] should
/// do instead, given the marks [syntax] folds there: the `[start, end)`
/// ranges to delete (in any order) and where the caret goes after. Null
/// when the key should do what it would anyway.
///
/// [deleted] is the range the key was about to delete. [revealCaret] is
/// the caret the host reveals marks' source by (its own
/// [HomericSyntax.decorationsFor] caret, which can be null while a mark
/// stays drawn); the editor itself shows a delimiter only with the caret
/// inside it.
({List<(int, int)> ranges, int caret})? homericMarkDelete(
  HomericSyntax syntax,
  Block block, {
  required int caret,
  required (int, int) deleted,
  int? revealCaret,
}) {
  final text = block.text;
  final (from, to) = deleted;
  if (from >= to || to > text.length) return null;
  final forward = from == caret;
  if (!forward && to != caret) return null;
  // One character beside the caret; a word or line delete goes as asked.
  if ((forward ? _graphemeAfter(text, caret) : _graphemeBefore(text, caret)) !=
      (from, to)) {
    return null;
  }
  final pairs = homericMarkPairs(syntax, block);
  if (pairs.isEmpty) return null;
  final hides = [
    for (final d in syntax.decorationsFor(block, caret: revealCaret))
      if (d.kind == DecorationKind.replace &&
          d.spec == MarkdownMarkHideSpec.instance &&
          // The editor shows a hidden range with the caret in it.
          !(caret >= d.start && caret < d.end))
        (d.start, d.end),
  ];
  bool folded(int start, int end) =>
      hides.any((h) => h.$1 <= start && end <= h.$2);

  // The delimiter (and its pair) a character at [offset] belongs to.
  (HomericMarkPair, bool)? delimiterAt(int offset) {
    for (final p in pairs) {
      if (!p.isDelimiter(offset)) continue;
      return offset < p.openEnd
          ? (p, folded(p.openStart, p.openEnd))
          : (p, folded(p.closeStart, p.closeEnd));
    }
    return null;
  }

  // A shown delimiter goes with its partner; the words stay.
  final touched = delimiterAt(forward ? from : to - 1);
  if (touched != null && !touched.$2) {
    final p = touched.$1;
    return (
      ranges: [(p.openStart, p.openEnd), (p.closeStart, p.closeEnd)],
      caret: _caretAfterUnwrap(p, caret),
    );
  }

  // Folded delimiters are stepped over: the letter past them goes.
  var at = forward ? from : to;
  var stepped = false;
  while (true) {
    final next = delimiterAt(forward ? at : at - 1);
    if (next == null || !next.$2) break;
    final p = next.$1;
    final inOpen = (forward ? at : at - 1) < p.openEnd;
    at = forward
        ? (inOpen ? p.openEnd : p.closeEnd)
        : (inOpen ? p.openStart : p.closeStart);
    stepped = true;
  }
  if (!stepped) {
    return _emptying(pairs, (from, to), caret);
  }
  if (forward ? at >= text.length : at <= 0) {
    return (ranges: const [], caret: caret);
  }
  final letter = forward ? _graphemeAfter(text, at) : _graphemeBefore(text, at);
  final shown = delimiterAt(forward ? at : at - 1);
  if (shown != null) {
    // Stepping over one mark onto another's shown delimiter: that one goes.
    final p = shown.$1;
    return (
      ranges: [(p.openStart, p.openEnd), (p.closeStart, p.closeEnd)],
      caret: _caretAfterUnwrap(p, caret),
    );
  }
  final emptied = _emptying(pairs, letter, caret);
  if (emptied != null) return emptied;
  final width = letter.$2 - letter.$1;
  return (
    ranges: [letter],
    caret: forward ? caret : caret - width,
  );
}

/// Deleting [range] empties a mark's words: the whole mark goes.
({List<(int, int)> ranges, int caret})? _emptying(
  List<HomericMarkPair> pairs,
  (int, int) range,
  int caret,
) {
  for (final p in pairs) {
    if (range.$1 == p.openEnd && range.$2 == p.closeStart) {
      final gone = p.closeEnd - p.openStart;
      return (
        ranges: [(p.openStart, p.closeEnd)],
        caret: caret >= p.closeEnd
            ? caret - gone
            : (caret <= p.openStart ? caret : p.openStart),
      );
    }
  }
  return null;
}

/// The caret after [p]'s delimiters go, from [caret] where it was.
int _caretAfterUnwrap(HomericMarkPair p, int caret) {
  final open = p.openEnd - p.openStart;
  final close = p.closeEnd - p.closeStart;
  if (caret <= p.openStart) return caret;
  if (caret <= p.openEnd) return p.openStart;
  if (caret <= p.closeStart) return caret - open;
  if (caret <= p.closeEnd) return p.closeStart - open;
  return caret - open - close;
}

(int, int) _graphemeBefore(String text, int at) {
  final last = text.substring(0, at).characters.last;
  return (at - last.length, at);
}

(int, int) _graphemeAfter(String text, int at) {
  final first = text.substring(at).characters.first;
  return (at, at + first.length);
}

final HomericPreparedCommand _nothing = HomericPreparedCommand(
  stages: const <Transaction>[],
  selection: null,
);

/// Backspace and Delete beside typed marks ([homericMarkDelete]): folded
/// delimiters are stepped over, shown ones go as a pair.
///
/// [syntax] must be the host's, so the marks it folds are the ones drawn.
/// [revealCaret] is the caret offset in a block the host reveals source
/// by; null uses the selection's.
final class HomericMarkDeletes extends HomericWritingFeature {
  /// Mark-aware deletes for [syntax].
  const HomericMarkDeletes({required this.syntax, this.revealCaret});

  /// The host's syntax.
  final HomericSyntax syntax;

  /// The host's reveal caret in a block, which may differ from the
  /// selection while a mark stays drawn.
  final int? Function(String blockId)? revealCaret;

  @override
  String get id => 'markDeletes';

  @override
  VoidCallback installOn(HomericEditorController controller) =>
      controller.addCommandInterceptor(intercept);

  /// Interceptor that applies [prepare]'s command; a key with nothing left
  /// to take (only folded marks before the caret) does nothing.
  HomericCommandInterception intercept(HomericEditorCommand command) {
    final prepared = prepare(command);
    if (prepared == null) return HomericCommandInterception.ignored;
    if (identical(prepared, _nothing)) {
      return HomericCommandInterception.rejected(#markDeletesNothing);
    }
    return command.controller.applyPreparedCommand(prepared)
        ? HomericCommandInterception.handled
        : HomericCommandInterception.ignored;
  }

  /// The command one Backspace or Delete beside a mark becomes, or null
  /// when it goes ahead as it would.
  HomericPreparedCommand? prepare(HomericEditorCommand command) {
    if (command.kind != HomericCommandKind.preDelete) return null;
    final controller = command.controller;
    if (controller.composing != null || command.replacementComposing != null) {
      return null;
    }
    final selection = command.selection;
    final edits = command.edits;
    if (selection == null ||
        !selection.isCollapsed ||
        edits == null ||
        edits.length != 1 ||
        edits.single.text.isNotEmpty) {
      return null;
    }
    final document = controller.document;
    final head = document.resolve(selection.head);
    if (head is! InlinePosition ||
        (command.blockId != null && head.block.id != command.blockId)) {
      return null;
    }
    final block = head.block;
    if (block.type == 'code') return null;
    final edit = edits.single;
    final plan = homericMarkDelete(
      syntax,
      block,
      caret: head.offset,
      deleted: (edit.start, edit.end),
      revealCaret: revealCaret == null ? head.offset : revealCaret!(block.id),
    );
    if (plan == null) return null;
    if (plan.ranges.isEmpty) return _nothing;
    final index = head.blockIndex;
    final transaction = Transaction(document);
    final ranges = [...plan.ranges]..sort((a, b) => b.$1.compareTo(a.$1));
    try {
      for (final (start, end) in ranges) {
        transaction.deleteRange(
          transaction.doc.positionAt(index, start),
          transaction.doc.positionAt(index, end),
        );
      }
    } on ArgumentError {
      return null;
    } on StepFailedError {
      return null;
    }
    return HomericPreparedCommand(
      stages: <Transaction>[transaction],
      selection: HomericSelection.collapsed(
        transaction.doc.positionAt(index, plan.caret),
      ),
    );
  }
}
