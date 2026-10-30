/// Typing an opening marker over a selection wraps it, as a code editor does.
///
/// With words selected, `{` writes `{words}` and keeps the words selected, so
/// a second `{` makes `{{words}}`; the same for `[`, `(`, `=`, `~`, `+`,
/// `%`, `*`, `_`, `` ` `` and quotes. Typing the marker once more than its
/// syntax uses (`=` on `==words==`, `(` on `(words)`) takes the wrap off
/// again, and Backspace straight after a wrap puts the words back as they
/// were, still selected. With no selection, typing is untouched.
///
/// `{{` and `[[` lead somewhere: by default `{{words|}}` leaves the caret in
/// the note slot and `[[|words]]` leaves it where the link's target goes,
/// with the words kept as its alias (a host that opens a menu there reads
/// it with [HomericLinkQuery.at]'s `wrappedAt`). A host with its own note
/// composer turns the slot off and answers [HomericTypedWraps.onWrapped].
///
/// Only plain typing wraps: a character an input method is still composing
/// (a dead key's `"`, `'`, `` ` ``, `^` or `~` on US-International) replaces
/// the selection as it always has, since the platform owns that text until
/// it commits.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../editing/editor_controller.dart';
import '../model/document.dart';
import '../model/position.dart';
import '../model/selection.dart';
import '../transform/builders.dart';
import '../transform/transaction.dart';
import 'writing_feature.dart';

/// The marker one typed character wraps a selection in.
@immutable
final class HomericWrapPair {
  /// Creates a pair writing [open] before the selection and [close] after.
  const HomericWrapPair(this.open, this.close, {this.depth = 1});

  /// Written before the selection.
  final String open;

  /// Written after it.
  final String close;

  /// How many layers typing adds before the next press takes them all off:
  /// 2 for `==`, 3 for `***`, 1 for `(`.
  final int depth;
}

/// A wrap just made, as [HomericTypedWraps.onWrapped] hears it.
@immutable
final class HomericTypedWrap {
  /// Creates the report of a wrap in [blockId].
  const HomericTypedWrap({
    required this.blockId,
    required this.typed,
    required this.depth,
    required this.start,
    required this.end,
    required this.innerStart,
    required this.innerEnd,
  });

  /// The block the words are in.
  final String blockId;

  /// The character typed (`{`, `[`, `=`…).
  final String typed;

  /// How many layers of it now sit around the words; 0 when the press
  /// took the wrap off.
  final int depth;

  /// Block-local start of the first marker.
  final int start;

  /// Block-local end after the last marker.
  final int end;

  /// Block-local start of the words.
  final int innerStart;

  /// Block-local end of the words.
  final int innerEnd;

  @override
  bool operator ==(Object other) =>
      other is HomericTypedWrap &&
      other.blockId == blockId &&
      other.typed == typed &&
      other.depth == depth &&
      other.start == start &&
      other.end == end &&
      other.innerStart == innerStart &&
      other.innerEnd == innerEnd;

  @override
  int get hashCode =>
      Object.hash(blockId, typed, depth, start, end, innerStart, innerEnd);

  @override
  String toString() => 'HomericTypedWrap($blockId, "$typed"×$depth, '
      '$start..$end, words $innerStart..$innerEnd)';
}

/// Typed wraps as a [HomericWritingFeature].
final class HomericTypedWraps extends HomericWritingFeature {
  /// Creates the feature.
  const HomericTypedWraps({
    this.pairs = standardPairs,
    this.annotationNoteSlot = true,
    this.linkAlias = true,
    this.curlyQuotes,
    this.isActive,
    this.onWrapped,
  });

  /// Every character that wraps, and what it writes.
  static const Map<String, HomericWrapPair> standardPairs =
      <String, HomericWrapPair>{
    '{': HomericWrapPair('{', '}', depth: 2),
    '[': HomericWrapPair('[', ']', depth: 2),
    '(': HomericWrapPair('(', ')'),
    '=': HomericWrapPair('=', '=', depth: 2),
    '~': HomericWrapPair('~', '~', depth: 2),
    '+': HomericWrapPair('+', '+', depth: 2),
    '%': HomericWrapPair('%', '%', depth: 2),
    '*': HomericWrapPair('*', '*', depth: 3),
    '_': HomericWrapPair('_', '_', depth: 2),
    '`': HomericWrapPair('`', '`'),
    '"': HomericWrapPair('“', '”'),
    "'": HomericWrapPair('‘', '’'),
  };

  /// The characters that wrap.
  final Map<String, HomericWrapPair> pairs;

  /// Whether `{{` writes `{{words|}}` with the caret where the note goes.
  /// Off, `{{words}}` keeps the words selected for the host's composer.
  final bool annotationNoteSlot;

  /// Whether `[[` writes `[[|words]]` with the caret where the target goes
  /// and the words as the link's alias. Off, `[[words]]` keeps them
  /// selected.
  final bool linkAlias;

  /// Read on each quote; false writes straight quotes. Null is curly, as
  /// smart punctuation types them. Code always gets straight quotes.
  final ValueGetter<bool>? curlyQuotes;

  /// Read on each press; false leaves typing as typed. Null is always on.
  final ValueGetter<bool>? isActive;

  /// Hears each wrap after the frame that lays it out, so a host can open
  /// its note composer on `{{` or place a menu.
  final ValueChanged<HomericTypedWrap>? onWrapped;

  @override
  String get id => 'typedWraps';

  /// A session for [controller], for hosts with their own interceptor chain
  /// (they call [HomericTypedWrapsSession.prepare]); others use [installOn].
  HomericTypedWrapsSession sessionFor(HomericEditorController controller) =>
      HomericTypedWrapsSession._(this, controller);

  @override
  VoidCallback installOn(HomericEditorController controller) =>
      controller.addCommandInterceptor(sessionFor(controller).intercept);
}

/// [HomericTypedWraps] bound to one controller: it remembers the last wrap
/// so Backspace straight after can undo it.
final class HomericTypedWrapsSession {
  HomericTypedWrapsSession._(this.feature, this.controller);

  /// The wraps this session applies.
  final HomericTypedWraps feature;

  /// The controller it prepares commands for.
  final HomericEditorController controller;

  _LastWrap? _last;

  /// Interceptor that applies [prepare]'s command.
  HomericCommandInterception intercept(HomericEditorCommand command) {
    final prepared = prepare(command);
    if (prepared == null) return HomericCommandInterception.ignored;
    return command.controller.applyPreparedCommand(prepared)
        ? HomericCommandInterception.handled
        : HomericCommandInterception.ignored;
  }

  /// The command that wraps (or unwraps) the selection for [command], or
  /// null when it goes ahead as typed. A host applies it with
  /// [HomericEditorController.applyPreparedCommand].
  HomericPreparedCommand? prepare(HomericEditorCommand command) {
    if (command.controller != controller) return null;
    final last = _last;
    _last = null;
    if (feature.isActive?.call() == false) return null;
    if (command.kind != HomericCommandKind.preInsert &&
        command.kind != HomericCommandKind.preDelete) {
      return null;
    }
    if (controller.composing != null || command.replacementComposing != null) {
      return null;
    }
    final selection = command.selection;
    final edits = command.edits;
    if (selection == null || edits == null) return null;
    final document = controller.document;
    final anchor = document.resolve(selection.anchor);
    final head = document.resolve(selection.head);
    if (anchor is! InlinePosition ||
        head is! InlinePosition ||
        anchor.blockIndex != head.blockIndex ||
        (command.blockId != null && anchor.block.id != command.blockId)) {
      return null;
    }
    final block = anchor.block;
    final text = block.text;
    var result = text;
    try {
      for (final edit in edits) {
        result = result.replaceRange(edit.start, edit.end, edit.text);
      }
    } on RangeError {
      return null;
    }
    final start = anchor.offset < head.offset ? anchor.offset : head.offset;
    final end = anchor.offset < head.offset ? head.offset : anchor.offset;

    // Backspace straight after a wrap: the words come back as they were.
    if (last != null &&
        identical(last.document, document) &&
        last.blockId == block.id &&
        last.selection == selection &&
        _deletesAtSelection(text, result, start, end)) {
      return _revert(document, anchor.blockIndex, last);
    }

    // One character typed over a selection: exactly the selection gives way
    // to it, however the platform split the edit.
    if (start == end || result.length != text.length - (end - start) + 1) {
      return null;
    }
    final typed = result[start];
    final pair = feature.pairs[typed];
    if (pair == null || result != text.replaceRange(start, end, typed)) {
      return null;
    }
    final words = text.substring(start, end);
    if (words.contains('\n') || words.trim().isEmpty) return null;
    if (block.type == 'code' && typed != '`') return null;
    return _prepareWrap(
      document,
      selection,
      anchor.blockIndex,
      start,
      end,
      typed,
      _pairFor(typed, pair, block.type == 'code'),
      continuing: last != null &&
              identical(last.document, document) &&
              last.blockId == block.id &&
              last.selection == selection
          ? last
          : null,
    );
  }

  /// Wraps [selection] in [typed]'s pair until it holds [depth] layers (or
  /// takes them off, for 0), as one command, without a key: for an edit
  /// menu's Link, Note or Highlight. Null when the selection is collapsed,
  /// spans blocks or holds a line break. Repeating a menu item on words
  /// already wrapped that deep takes the wrap off.
  HomericPreparedCommand? prepareMenuWrap(
    HomericSelection? selection,
    String typed,
  ) {
    final pair = feature.pairs[typed];
    if (selection == null || selection.isCollapsed || pair == null) {
      return null;
    }
    final document = controller.document;
    final anchor = document.resolve(selection.anchor);
    final head = document.resolve(selection.head);
    if (anchor is! InlinePosition ||
        head is! InlinePosition ||
        anchor.blockIndex != head.blockIndex) {
      return null;
    }
    final start = anchor.offset < head.offset ? anchor.offset : head.offset;
    final end = anchor.offset < head.offset ? head.offset : anchor.offset;
    final text = anchor.block.text;
    final words = text.substring(start, end);
    if (words.contains('\n') || words.trim().isEmpty) return null;
    _last = null;
    final resolved = _pairFor(typed, pair, anchor.block.type == 'code');
    final current = _depthAround(text, start, end, resolved);
    return _prepareWrap(
      document,
      selection,
      anchor.blockIndex,
      start,
      end,
      typed,
      resolved,
      target: current >= resolved.depth ? 0 : resolved.depth,
    );
  }

  /// [pair], with quotes straight in code or when curly quotes are off.
  HomericWrapPair _pairFor(String typed, HomericWrapPair pair, bool code) {
    if ((typed == '"' || typed == "'") &&
        (code || feature.curlyQuotes?.call() == false)) {
      return HomericWrapPair(typed, typed, depth: pair.depth);
    }
    return pair;
  }

  HomericPreparedCommand? _prepareWrap(
    Document document,
    HomericSelection selection,
    int index,
    int start,
    int end,
    String typed,
    HomericWrapPair pair, {
    _LastWrap? continuing,
    int? target,
  }) {
    final block = document.blocks[index];
    final text = block.text;
    final current = _depthAround(text, start, end, pair);
    final depth = target ?? (current >= pair.depth ? 0 : current + 1);
    final open = pair.open;
    final close = pair.close;
    final words = text.substring(start, end);
    final outerStart = start - current * open.length;
    final outerEnd = end + current * close.length;
    final link = feature.linkAlias && typed == '[' && depth == 2;
    final note = feature.annotationNoteSlot && typed == '{' && depth == 2;
    final String replacement;
    final int innerStart;
    final int caret;
    if (link) {
      replacement = '${open * 2}|$words${close * 2}';
      innerStart = outerStart + 3;
      caret = outerStart + 2;
    } else if (note) {
      replacement = '${open * 2}$words|${close * 2}';
      innerStart = outerStart + 2;
      caret = innerStart + words.length + 1;
    } else {
      replacement = '${open * depth}$words${close * depth}';
      innerStart = outerStart + depth * open.length;
      caret = -1;
    }
    final innerEnd = innerStart + words.length;
    final transaction = Transaction(document);
    try {
      // Only the markers change, so the words keep their runs and anchors.
      transaction
        ..deleteRange(
          document.positionAt(index, end),
          document.positionAt(index, outerEnd),
        )
        ..insertText(
          document.positionAt(index, end),
          replacement.substring(innerEnd - outerStart),
        );
      // Positions before `end` are unmoved by the edit after them.
      transaction
        ..deleteRange(
          transaction.doc.positionAt(index, outerStart),
          transaction.doc.positionAt(index, start),
        )
        ..insertText(
          transaction.doc.positionAt(index, outerStart),
          replacement.substring(0, innerStart - outerStart),
        );
    } on ArgumentError {
      return null;
    } on StepFailedError {
      return null;
    }
    final after = transaction.doc;
    final forward = selection.head >= selection.anchor;
    final HomericSelection selected;
    if (caret >= 0) {
      selected = HomericSelection.collapsed(after.positionAt(index, caret));
    } else {
      final from = after.positionAt(index, forward ? innerStart : innerEnd);
      final to = after.positionAt(index, forward ? innerEnd : innerStart);
      selected = HomericSelection(
        anchor: from,
        head: to,
        affinity: selection.affinity,
      );
    }
    final outerAfter = outerStart + replacement.length;
    // A wrap typed onto the words the last one left extends that run, so
    // one Backspace takes back the whole `{{`, not just its second brace.
    final grew = replacement.length - (outerEnd - outerStart);
    _last = _LastWrap(
      document: after,
      blockId: block.id,
      selection: selected,
      start: continuing?.start ?? outerStart,
      end: continuing == null ? outerAfter : continuing.end + grew,
      original: continuing?.original ?? text.substring(outerStart, outerEnd),
      leading: continuing?.leading ?? start - outerStart,
      originalWords: continuing?.originalWords ?? words,
      wordsAt: innerStart,
      forward: forward,
      affinity: selection.affinity,
    );
    final callback = feature.onWrapped;
    if (callback != null) {
      final report = HomericTypedWrap(
        blockId: block.id,
        typed: typed,
        depth: depth,
        start: outerStart,
        end: outerAfter,
        innerStart: innerStart,
        innerEnd: innerEnd,
      );
      SchedulerBinding.instance
        ..addPostFrameCallback((_) {
          // Only a wrap the controller applied, and nothing typed since.
          if (identical(controller.document, after)) callback(report);
        })
        ..ensureVisualUpdate();
    }
    return HomericPreparedCommand(
      stages: <Transaction>[transaction],
      selection: selected,
    );
  }

  /// Backspace (or Delete) straight after a wrap takes back every wrap typed
  /// in that run and selects the words again.
  HomericPreparedCommand? _revert(
    Document document,
    int index,
    _LastWrap last,
  ) {
    // Only the markers go back; the words keep their runs.
    final wordsEnd = last.wordsAt + last.originalWords.length;
    final before = last.original.substring(0, last.leading);
    final after = last.original.substring(
      last.leading + last.originalWords.length,
    );
    final transaction = Transaction(document);
    try {
      transaction
        ..deleteRange(
          document.positionAt(index, wordsEnd),
          document.positionAt(index, last.end),
        )
        ..insertText(document.positionAt(index, wordsEnd), after);
      transaction
        ..deleteRange(
          transaction.doc.positionAt(index, last.start),
          transaction.doc.positionAt(index, last.wordsAt),
        )
        ..insertText(transaction.doc.positionAt(index, last.start), before);
    } on ArgumentError {
      return null;
    } on StepFailedError {
      return null;
    }
    final reverted = transaction.doc;
    final from = last.start + last.leading;
    final to = from + last.originalWords.length;
    return HomericPreparedCommand(
      stages: <Transaction>[transaction],
      selection: HomericSelection(
        anchor: reverted.positionAt(index, last.forward ? from : to),
        head: reverted.positionAt(index, last.forward ? to : from),
        affinity: last.affinity,
      ),
    );
  }

  /// Whether going from [text] to [result] deletes what a Backspace or
  /// Delete would at the selection `[start, end)`: the selected words, or
  /// one character beside a caret.
  static bool _deletesAtSelection(
    String text,
    String result,
    int start,
    int end,
  ) {
    if (start != end) return result == text.replaceRange(start, end, '');
    if (result.length >= text.length) return false;
    final before =
        start > 0 && result == text.replaceRange(start - 1, start, '');
    final after = start < text.length &&
        result == text.replaceRange(start, start + 1, '');
    return before || after;
  }

  /// How many layers of [pair] already sit right around `[start, end)` of
  /// [text], up to its depth.
  static int _depthAround(
    String text,
    int start,
    int end,
    HomericWrapPair pair,
  ) {
    var depth = 0;
    while (depth < pair.depth) {
      final before = start - (depth + 1) * pair.open.length;
      final after = end + (depth + 1) * pair.close.length;
      if (before < 0 || after > text.length) break;
      if (text.substring(before, before + pair.open.length) != pair.open ||
          text.substring(after - pair.close.length, after) != pair.close) {
        break;
      }
      depth++;
    }
    return depth;
  }
}

/// The last wrap, for Backspace straight after it.
final class _LastWrap {
  const _LastWrap({
    required this.document,
    required this.blockId,
    required this.selection,
    required this.start,
    required this.end,
    required this.original,
    required this.leading,
    required this.originalWords,
    required this.wordsAt,
    required this.forward,
    required this.affinity,
  });

  /// The document right after the wrap.
  final Document document;
  final String blockId;

  /// The selection the wrap left.
  final HomericSelection selection;

  /// Block-local range the wraps of this run cover, after the wrap.
  final int start;
  final int end;

  /// What that range held before the run's first wrap.
  final String original;

  /// Offset of the words inside [original].
  final int leading;

  /// The words as they were.
  final String originalWords;

  /// Block-local offset of the words after the wrap.
  final int wordsAt;

  final bool forward;
  final HomericCaretAffinity affinity;
}
