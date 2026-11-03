/// The system's corrections as the writer types: autocorrect and text
/// replacement, from a [HomericTypingCorrections] such as macOS's own
/// checker ([HomericMacSpelling]).
///
/// - Text replacement: a shortcut from the writer's list (`omw`) becomes its
///   phrase (`On my way!`) when a space or punctuation follows it. The
///   shortcut as typed is its own undo step, so one undo puts it back, as
///   does Backspace straight after.
/// - Autocorrect: a misspelled word is corrected when a space, punctuation
///   or Return follows it, as its own undo step.
///
/// Each follows its system setting ("Correct spelling automatically", "Use
/// text replacements" on macOS), read on every keystroke. Code, web
/// addresses, `#tags`, `@names` and `[[links]]` keep what was typed.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../editing/editor_controller.dart';
import '../editing/system_spelling.dart';
import '../model/attributes.dart';
import '../model/block.dart';
import '../model/document.dart';
import '../model/position.dart';
import '../model/selection.dart';
import '../transform/builders.dart';
import '../transform/transaction.dart';
import 'smart_punctuation.dart';
import 'writing_feature.dart';

/// Autocorrect and text replacement as a [HomericWritingFeature].
final class HomericSystemCorrections extends HomericWritingFeature {
  /// Creates the feature over [corrections].
  const HomericSystemCorrections({
    required this.corrections,
    this.isActive,
    this.isLiteral,
  });

  /// Where the settings, the replacement list and corrections come from.
  final HomericTypingCorrections corrections;

  /// Read before each correction; `false` leaves typing as typed. Null is
  /// always on (each correction still follows its system setting).
  final ValueGetter<bool>? isActive;

  /// More places where text stays as typed.
  final HomericLiteralTextTest? isLiteral;

  @override
  String get id => 'systemCorrections';

  /// A session for [controller], for hosts with their own interceptor chain.
  HomericSystemCorrectionsSession sessionFor(
    HomericEditorController controller,
  ) =>
      HomericSystemCorrectionsSession._(this, controller);

  @override
  VoidCallback installOn(HomericEditorController controller) {
    final session = sessionFor(controller);
    return controller.addCommandInterceptor(session.intercept);
  }

  /// Whether [character] ends a word for correcting: whitespace or
  /// punctuation, not an apostrophe or a hyphen inside a word.
  static bool endsWord(String character) {
    if (character.isEmpty) return false;
    if (_wordChar.hasMatch(character)) return false;
    return !'\'’-_'.contains(character);
  }

  /// The word ending at [end] of [text]: letters, with apostrophes and
  /// hyphens between them; null for none.
  @visibleForTesting
  static ({int start, String word})? wordBefore(String text, int end) {
    var start = end;
    while (start > 0) {
      final previous = text[start - 1];
      if (_wordChar.hasMatch(previous)) {
        start--;
        continue;
      }
      // An apostrophe or a hyphen joins two letters (`don't`, `well-known`).
      if ('\'’-'.contains(previous) &&
          start - 2 >= 0 &&
          _wordChar.hasMatch(text[start - 2]) &&
          start < end) {
        start--;
        continue;
      }
      break;
    }
    if (start == end) return null;
    return (start: start, word: text.substring(start, end));
  }

  /// The run of non-space characters ending at [end] of [text], for a
  /// replacement shortcut (`;sig`, `omw`).
  @visibleForTesting
  static ({int start, String token})? tokenBefore(String text, int end) {
    var start = end;
    while (start > 0 && !_space.hasMatch(text[start - 1])) {
      start--;
    }
    if (start == end) return null;
    return (start: start, token: text.substring(start, end));
  }

  static final RegExp _wordChar = RegExp(r'[\p{L}\p{M}]', unicode: true);
  static final RegExp _digit = RegExp(r'\p{N}', unicode: true);
  static final RegExp _space = RegExp(r'\s');
}

/// Corrections bound to one controller.
final class HomericSystemCorrectionsSession {
  HomericSystemCorrectionsSession._(this.feature, this.controller);

  /// The rules this session applies.
  final HomericSystemCorrections feature;

  /// The controller the session corrects.
  final HomericEditorController controller;

  _Replaced? _last;

  HomericTypingCorrections get _source => feature.corrections;

  /// Interceptor: applies a text replacement at once, and asks for a
  /// correction of the word just ended, applied when it comes.
  HomericCommandInterception intercept(HomericEditorCommand command) {
    if (command.controller != controller) {
      return HomericCommandInterception.ignored;
    }
    final last = _last;
    _last = null;
    if (feature.isActive?.call() == false) {
      return HomericCommandInterception.ignored;
    }
    final prepared = switch (command.kind) {
      HomericCommandKind.preInsert => _prepareInsert(command),
      HomericCommandKind.preBreak => _askCorrection(command, '\n'),
      HomericCommandKind.preDelete =>
        last == null ? null : _prepareRevert(command, last),
      _ => null,
    };
    if (prepared == null) return HomericCommandInterception.ignored;
    return controller.applyPreparedCommand(prepared)
        ? HomericCommandInterception.handled
        : HomericCommandInterception.ignored;
  }

  /// Where typing lands: the caret block and offset, when [command] is
  /// plain typing at a collapsed caret.
  InlinePosition? _typingAt(HomericEditorCommand command, String typed) {
    final selection = command.selection;
    if (selection == null ||
        !selection.isCollapsed ||
        controller.composing != null ||
        command.replacementComposing != null) {
      return null;
    }
    final caret = controller.document.resolve(selection.head);
    if (caret is! InlinePosition ||
        (command.blockId != null && caret.block.id != command.blockId)) {
      return null;
    }
    final edits = command.edits;
    if (edits != null &&
        (edits.length != 1 ||
            edits.single.start != caret.offset ||
            edits.single.end != caret.offset ||
            edits.single.text != typed)) {
      return null;
    }
    return caret;
  }

  bool _isLiteral(Block block, int start, int end) {
    if (block.type == 'code') return true;
    for (final run in _runsOver(block, start, end)) {
      if (run['code'] == true) return true;
    }
    final text = block.text;
    if (HomericSmartPunctuation.isLiteralText(text, end)) return true;
    if (feature.isLiteral?.call(block, start) ?? false) return true;
    // `#tag`, `@name`, a path or an address.
    if (start > 0 && '#@/\\.:'.contains(text[start - 1])) return true;
    // Inside a `[[link]]` still open on this line.
    final lineStart = start == 0 ? 0 : text.lastIndexOf('\n', start - 1) + 1;
    final before = text.substring(lineStart, start);
    if (before.lastIndexOf('[[') > before.lastIndexOf(']]')) return true;
    return false;
  }

  HomericPreparedCommand? _prepareInsert(HomericEditorCommand command) {
    final typed = command.text;
    if (typed == null ||
        typed.length != 1 ||
        !HomericSystemCorrections.endsWord(typed)) {
      return null;
    }
    final caret = _typingAt(command, typed);
    if (caret == null) return null;
    final block = caret.block;
    final offset = caret.offset;
    final text = block.text;

    if (_source.replacesTextAutomatically) {
      final token = HomericSystemCorrections.tokenBefore(text, offset);
      final phrase =
          token == null ? null : _source.textReplacements[token.token];
      if (token != null &&
          phrase != null &&
          phrase != token.token &&
          !phrase.contains('\n') &&
          !_isLiteral(block, token.start, offset)) {
        return _prepareReplacement(
          command,
          caret,
          typed,
          token.start,
          token.token,
          phrase,
        );
      }
    }
    _askCorrection(command, typed, caret: caret);
    return null;
  }

  /// Text replacement: the typed character goes in as typed (its own undo
  /// step), then the shortcut before it becomes its phrase.
  HomericPreparedCommand? _prepareReplacement(
    HomericEditorCommand command,
    InlinePosition caret,
    String typed,
    int start,
    String shortcut,
    String phrase,
  ) {
    final document = controller.document;
    final index = caret.blockIndex;
    final offset = caret.offset;
    try {
      final literal = Transaction(document)
        ..insertText(
          command.selection!.head,
          typed,
          attributes: command.edits?.single.attributes ??
              _attributesBefore(caret.block, offset),
        );
      final literalDocument = literal.doc;
      final literalBlock = literalDocument.blocks[index];
      final conversion = Transaction(literalDocument)
        ..deleteRange(
          literalDocument.positionAt(index, start),
          literalDocument.positionAt(index, offset),
        );
      conversion.insertText(
        conversion.doc.positionAt(index, start),
        phrase,
        attributes: _attributesAt(literalBlock, start),
      );
      final caretAfter = start + phrase.length + typed.length;
      final finalDocument = conversion.doc;
      _last = _Replaced(
        document: finalDocument,
        blockId: caret.block.id,
        start: start,
        replacement: phrase,
        original: shortcut,
        typed: typed,
      );
      return HomericPreparedCommand(
        stages: <Transaction>[literal, conversion],
        selection: HomericSelection.collapsed(
          finalDocument.positionAt(index, caretAfter),
        ),
        undoCheckpoint: HomericPreparedUndoCheckpoint(
          stage: 0,
          selection: HomericSelection.collapsed(
            literalDocument.positionAt(index, offset + typed.length),
          ),
        ),
      );
    } on ArgumentError {
      _last = null;
      return null;
    }
  }

  /// Backspace straight after a replacement deletes the character typed
  /// after the phrase: the shortcut comes back instead, with that
  /// character.
  HomericPreparedCommand? _prepareRevert(
    HomericEditorCommand command,
    _Replaced last,
  ) {
    final document = controller.document;
    final edits = command.edits;
    final selection = command.selection;
    if (!identical(document, last.document) ||
        command.blockId != last.blockId ||
        selection == null ||
        !selection.isCollapsed ||
        edits == null ||
        edits.length != 1) {
      return null;
    }
    final phraseEnd = last.start + last.replacement.length;
    final edit = edits.single;
    if (edit.start != phraseEnd ||
        edit.end != phraseEnd + last.typed.length ||
        edit.text.isNotEmpty) {
      return null;
    }
    final caret = document.resolve(selection.head);
    if (caret is! InlinePosition ||
        caret.block.id != last.blockId ||
        caret.offset != phraseEnd + last.typed.length) {
      return null;
    }
    try {
      final index = caret.blockIndex;
      final revert = Transaction(document)
        ..deleteRange(
          document.positionAt(index, last.start),
          document.positionAt(index, edit.end),
        );
      revert.insertText(
        revert.doc.positionAt(index, last.start),
        last.original,
        attributes: _attributesAt(caret.block, last.start),
      );
      return HomericPreparedCommand(
        stages: <Transaction>[revert],
        selection: HomericSelection.collapsed(
          revert.doc.positionAt(index, last.start + last.original.length),
        ),
      );
    } on ArgumentError {
      return null;
    }
  }

  /// Asks for a correction of the word before the caret, which [typed]
  /// (a space, punctuation, or `\n` for Return) is about to end. Always
  /// lets the command go ahead; returns null.
  HomericPreparedCommand? _askCorrection(
    HomericEditorCommand command,
    String typed, {
    InlinePosition? caret,
  }) {
    if (!_source.correctsSpellingAutomatically) return null;
    final at = caret ??
        (command.selection != null && command.selection!.isCollapsed
            ? controller.document.resolve(command.selection!.head)
            : null);
    if (at is! InlinePosition || controller.composing != null) return null;
    final block = at.block;
    final text = block.text;
    final found = HomericSystemCorrections.wordBefore(text, at.offset);
    if (found == null || found.word.length < 2) return null;
    final start = found.start;
    final end = at.offset;
    if (HomericSystemCorrections._digit.hasMatch(found.word) ||
        _isLiteral(block, start, end)) {
      return null;
    }
    final blockId = block.id;
    final word = found.word;
    unawaited(_source.correction(text, start, end).then((corrected) {
      if (corrected == null || corrected.contains('\n')) return;
      _applyCorrection(blockId, start, word, corrected, typed);
    }, onError: (Object _) {}));
    return null;
  }

  /// Puts [corrected] in place of [word] at [start] of [blockId], when the
  /// word and the character after it are still as they were.
  void _applyCorrection(
    String blockId,
    int start,
    String word,
    String corrected,
    String typed,
  ) {
    if (feature.isActive?.call() == false ||
        !_source.correctsSpellingAutomatically ||
        controller.composing != null) {
      return;
    }
    final document = controller.document;
    final index = document.indexOfBlockId(blockId);
    if (index == null) return;
    final block = document.blocks[index];
    final text = block.text;
    final end = start + word.length;
    if (end > text.length || text.substring(start, end) != word) return;
    // The word still ends there: Return left it at the block's end, any
    // other character still follows it.
    if (typed == '\n'
        ? end != text.length
        : end >= text.length || text[end] != typed) {
      return;
    }
    // Not while the caret sits inside the word (the writer came back to it).
    final selection = controller.selection;
    final caret = selection == null ? null : document.resolve(selection.head);
    if (caret is InlinePosition &&
        caret.block.id == blockId &&
        caret.offset > start &&
        caret.offset < end) {
      return;
    }
    try {
      final correction = Transaction(document)
        ..deleteRange(
          document.positionAt(index, start),
          document.positionAt(index, end),
        );
      correction.insertText(
        correction.doc.positionAt(index, start),
        corrected,
        attributes: _attributesAt(block, start),
      );
      controller.applyPreparedCommand(HomericPreparedCommand(
        stages: <Transaction>[correction],
        selection: selection?.map(correction.mapping),
      ));
    } on ArgumentError {
      return;
    }
  }

  static Iterable<Attributes> _runsOver(Block block, int start, int end) sync* {
    var cursor = 0;
    for (final run in block.runs) {
      final next = cursor + run.length;
      if (next > start && cursor < end) yield run.attributes;
      cursor = next;
    }
  }

  static Attributes _attributesAt(Block block, int offset) {
    var cursor = 0;
    for (final run in block.runs) {
      final end = cursor + run.length;
      if (offset >= cursor && offset < end) return run.attributes;
      cursor = end;
    }
    return emptyAttributes;
  }

  static Attributes _attributesBefore(Block block, int offset) {
    if (block.runs.isEmpty) return emptyAttributes;
    final probe =
        offset > 0 ? offset - 1 : (offset < block.contentLength ? offset : 0);
    var cursor = 0;
    for (final run in block.runs) {
      final next = cursor + run.length;
      if (!run.isEmpty && probe >= cursor && probe < next) {
        return run.attributes;
      }
      cursor = next;
    }
    return block.runs.last.attributes;
  }
}

final class _Replaced {
  const _Replaced({
    required this.document,
    required this.blockId,
    required this.start,
    required this.replacement,
    required this.original,
    required this.typed,
  });

  final Document document;
  final String blockId;
  final int start;
  final String replacement;
  final String original;
  final String typed;
}
