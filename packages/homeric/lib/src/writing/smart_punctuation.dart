/// Typed punctuation set the way a typesetter would, as the writer types.
///
/// - `--` becomes an em dash `—`.
/// - `...` becomes an ellipsis `…`.
/// - `"` and `'` become curly quotes, opening or closing by what comes
///   before them; `'` after a letter is an apostrophe `’`.
///
/// Code (a `code` block, a `code` run, or between backticks) and web
/// addresses keep what was typed. The characters as typed are committed
/// first and kept as their own undo step, so one undo puts them back, as
/// does Backspace straight after the substitution.
///
/// A `---` divider is not here: what a divider *is* (a block type, a line of
/// text drawn as a rule) is the host's model, and the em-dash rule leaves
/// `—-` for a host rule to recognize.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../editing/editor_controller.dart';
import '../model/attributes.dart';
import '../model/block.dart';
import '../model/document.dart';
import '../model/position.dart';
import '../model/selection.dart';
import '../transform/builders.dart';
import '../transform/transaction.dart';
import 'writing_feature.dart';

/// One substitution: block-local `[start, end)` becomes [replacement].
@immutable
final class HomericPunctuationEdit {
  /// Creates an edit replacing `[start, end)` with [replacement].
  const HomericPunctuationEdit(this.start, this.end, this.replacement);

  /// Inclusive block-local start of the typed characters.
  final int start;

  /// Exclusive block-local end of the typed characters.
  final int end;

  /// What the typed characters become.
  final String replacement;

  /// The characters it replaces in [text].
  String original(String text) => text.substring(start, end);

  @override
  bool operator ==(Object other) =>
      other is HomericPunctuationEdit &&
      other.start == start &&
      other.end == end &&
      other.replacement == replacement;

  @override
  int get hashCode => Object.hash(start, end, replacement);

  @override
  String toString() => 'HomericPunctuationEdit($start, $end, "$replacement")';
}

/// Whether text at block-local `offset` of [block] must stay as typed, beyond
/// Homeric's own code and web-address rules.
typedef HomericLiteralTextTest = bool Function(Block block, int offset);

/// Attributes for typed text inserted at block-local `offset` of [block].
typedef HomericTypingAttributes = Attributes Function(Block block, int offset);

/// Smart punctuation as a [HomericWritingFeature].
///
/// Every rule is on by default once the feature is installed; turn one off
/// with its flag. [isActive] is read on every keystroke, so a host setting
/// can switch the whole feature without reinstalling it.
final class HomericSmartPunctuation extends HomericWritingFeature {
  /// Creates the feature.
  const HomericSmartPunctuation({
    this.emDash = true,
    this.ellipsis = true,
    this.quotes = true,
    this.backspaceReverts = true,
    this.isActive,
    this.isLiteral,
    this.typingAttributes,
  });

  /// Whether `--` becomes `—`.
  final bool emDash;

  /// Whether `...` becomes `…`.
  final bool ellipsis;

  /// Whether straight quotes curl.
  final bool quotes;

  /// Whether Backspace straight after a substitution puts back what was
  /// typed (an undo does either way).
  final bool backspaceReverts;

  /// Read before each substitution; `false` leaves typing as typed. Null is
  /// always on.
  final ValueGetter<bool>? isActive;

  /// More places where text stays as typed (a host's own literal syntax, a
  /// block it does not let the writer edit).
  final HomericLiteralTextTest? isLiteral;

  /// Attributes for the characters as typed. Null inherits from the text
  /// before the caret, as plain typing does.
  final HomericTypingAttributes? typingAttributes;

  static const String emDashCharacter = '—';
  static const String ellipsisCharacter = '…';

  @override
  String get id => 'smartPunctuation';

  /// A session for [controller]: hosts with their own interceptor chain call
  /// [HomericSmartPunctuationSession.prepare] where the rule belongs in it;
  /// others use [installOn].
  HomericSmartPunctuationSession sessionFor(
    HomericEditorController controller,
  ) =>
      HomericSmartPunctuationSession._(this, controller);

  @override
  VoidCallback installOn(HomericEditorController controller) {
    final session = sessionFor(controller);
    final stopIntercepting =
        controller.addCommandInterceptor(session.intercept);
    final stopListening = session.listen();
    return () {
      stopListening();
      stopIntercepting();
    };
  }

  /// What the character just typed at [at] in [text] becomes, or null when
  /// it stays as typed. [text] already holds the typed character. Pure, for
  /// hosts that apply punctuation outside the command path (previews,
  /// imports).
  HomericPunctuationEdit? editFor(String text, int at) {
    if (at < 0 || at >= text.length) return null;
    final typed = text[at];
    if (!'-."\''.contains(typed)) return null;
    if (isLiteralText(text, at)) return null;
    switch (typed) {
      case '-':
        // `--`, not the end of a longer run: `---` typed with the dash put
        // back by Backspace stays as typed.
        if (emDash &&
            at >= 1 &&
            text[at - 1] == '-' &&
            (at < 2 || text[at - 2] != '-')) {
          return HomericPunctuationEdit(at - 1, at + 1, emDashCharacter);
        }
      case '.':
        if (ellipsis &&
            at >= 2 &&
            text[at - 1] == '.' &&
            text[at - 2] == '.' &&
            (at < 3 || text[at - 3] != '.')) {
          return HomericPunctuationEdit(at - 2, at + 1, ellipsisCharacter);
        }
      case '"':
        if (quotes) {
          return HomericPunctuationEdit(
            at,
            at + 1,
            _closes(text, at) ? '”' : '“',
          );
        }
      case '\'':
        if (quotes) {
          return HomericPunctuationEdit(
            at,
            at + 1,
            _closes(text, at) ? '’' : '‘',
          );
        }
    }
    return null;
  }

  /// Whether text typed at [at] in [text] is code or a web address, where
  /// characters mean exactly what was typed.
  static bool isLiteralText(String text, int at) {
    final lineStart = text.lastIndexOf('\n', at > 0 ? at - 1 : 0) + 1;
    final before = text.substring(lineStart, at);
    // Inside `code`, closed or still being typed: an odd count of backticks
    // before it on the line.
    if ('`'.allMatches(before).length.isOdd) return true;
    // The word it is typed into is a web address or a link's target.
    final wordStart = before.lastIndexOf(RegExp(r'\s')) + 1;
    final word = before.substring(wordStart);
    if (_urlStart.hasMatch(word) || _bareAddress.hasMatch(word)) return true;
    if (word.contains('](')) return true;
    return false;
  }

  /// A quote closes, or is an apostrophe, after a letter, digit or closing
  /// punctuation; anywhere else (a line's start, a space, a bracket, a dash,
  /// `*` emphasis) it opens.
  static bool _closes(String text, int at) {
    if (at == 0) return false;
    final before = text[at - 1];
    if (_wordChar.hasMatch(before)) return true;
    return '.,;:!?)]}%…’”'.contains(before);
  }

  static final RegExp _wordChar = RegExp(r'[\p{L}\p{N}\p{M}]', unicode: true);

  static final RegExp _urlStart = RegExp(
    r'(^|[(\[<])(https?://|www\.|mailto:)',
    caseSensitive: false,
  );

  /// A bare address with a path, as in `example.com/foo`.
  static final RegExp _bareAddress = RegExp(
    r'(^|[(\[<])[\p{L}\p{N}-]+(\.[\p{L}\p{N}-]+)*\.\p{L}{2,}(:\d+)?/',
    unicode: true,
  );
}

/// Smart punctuation bound to one controller: it remembers the last
/// substitution so Backspace straight after can put back what was typed.
final class HomericSmartPunctuationSession {
  HomericSmartPunctuationSession._(this.feature, this.controller);

  /// The rules this session applies.
  final HomericSmartPunctuation feature;

  /// The controller the session prepares commands for.
  final HomericEditorController controller;

  _Substitution? _last;

  /// Where the open composition started (block id, block-local offset).
  ({String blockId, int start})? _composingFrom;

  /// Follows dead-key compositions so a quote typed as marked text curls
  /// when it commits (`'` and `"` on US-International wait for the next
  /// key). [HomericSmartPunctuation.installOn] calls it; a host that calls
  /// [prepare] from its own chain calls it too. Returns the stop callback.
  VoidCallback listen() {
    controller.addListener(_onControllerChanged);
    return () => controller.removeListener(_onControllerChanged);
  }

  void _onControllerChanged() {
    final composing = controller.composing;
    if (composing != null) {
      if (_composingFrom != null) return;
      final at = controller.document.resolve(composing.start);
      if (at is InlinePosition) {
        _composingFrom = (blockId: at.block.id, start: at.offset);
      }
      return;
    }
    final from = _composingFrom;
    if (from == null) return;
    _composingFrom = null;
    final document = controller.document;
    // After the commit settles, as typing a character would.
    scheduleMicrotask(() {
      if (!identical(controller.document, document)) return;
      final prepared = _prepareCommitted(from.blockId, from.start);
      if (prepared != null) controller.applyPreparedCommand(prepared);
    });
  }

  /// A quote a composition just committed at [start] of [blockId].
  HomericPreparedCommand? _prepareCommitted(String blockId, int start) {
    _last = null;
    if (feature.isActive?.call() == false || controller.composing != null) {
      return null;
    }
    final document = controller.document;
    final index = document.indexOfBlockId(blockId);
    if (index == null) return null;
    final block = document.blocks[index];
    final text = block.text;
    if (start >= text.length || !'"\''.contains(text[start])) return null;
    if (_isCode(block, start) ||
        (feature.isLiteral?.call(block, start) ?? false)) {
      return null;
    }
    final edit = feature.editFor(text, start);
    if (edit == null) return null;
    final selection = controller.selection;
    try {
      final conversion = Transaction(document)
        ..deleteRange(
          document.positionAt(index, edit.start),
          document.positionAt(index, edit.end),
        );
      conversion.insertText(
        conversion.doc.positionAt(index, edit.start),
        edit.replacement,
        attributes: _attributesAt(block, edit.start),
      );
      // The quote keeps its length, so the caret stays where it was.
      final caret = selection == null ? null : document.resolve(selection.head);
      if (feature.backspaceReverts &&
          caret is InlinePosition &&
          caret.block.id == blockId) {
        _last = _Substitution(
          document: conversion.doc,
          blockId: blockId,
          start: edit.start,
          replacement: edit.replacement,
          original: edit.original(text),
          caret: caret.offset,
        );
      }
      return HomericPreparedCommand(
        stages: <Transaction>[conversion],
        selection: selection,
      );
    } on ArgumentError {
      return null;
    }
  }

  /// Interceptor that applies [prepare]'s command.
  HomericCommandInterception intercept(HomericEditorCommand command) {
    final prepared = prepare(command);
    if (prepared == null) return HomericCommandInterception.ignored;
    return command.controller.applyPreparedCommand(prepared)
        ? HomericCommandInterception.handled
        : HomericCommandInterception.ignored;
  }

  /// The command that sets typed punctuation for [command], or null when
  /// typing goes ahead as typed. A host applies it with
  /// [HomericEditorController.applyPreparedCommand] (or its own wrapper).
  HomericPreparedCommand? prepare(HomericEditorCommand command) {
    if (command.controller != controller) return null;
    final last = _last;
    _last = null;
    if (feature.isActive?.call() == false) return null;
    return switch (command.kind) {
      HomericCommandKind.preInsert => _prepareInsert(command),
      HomericCommandKind.preDelete => last == null
          ? null
          : _prepareRevert(
              command,
              last,
            ),
      _ => null,
    };
  }

  HomericPreparedCommand? _prepareInsert(HomericEditorCommand command) {
    final typed = command.text;
    final selection = command.selection;
    if (typed == null ||
        selection == null ||
        !selection.isCollapsed ||
        controller.composing != null ||
        command.replacementComposing != null) {
      return null;
    }
    // One character, or two when a dead key commits its quote together with
    // the next letter.
    if (typed.length != 1 && !(typed.length == 2 && '"\''.contains(typed[0]))) {
      return null;
    }
    final document = controller.document;
    final caret = document.resolve(selection.head);
    if (caret is! InlinePosition ||
        (command.blockId != null && caret.block.id != command.blockId)) {
      return null;
    }
    final block = caret.block;
    final offset = caret.offset;
    // Only plain typing: one insertion at the caret. A replacement or a
    // batch that also deletes goes ahead as the platform asked.
    final edits = command.edits;
    if (edits != null &&
        (edits.length != 1 ||
            edits.single.start != offset ||
            edits.single.end != offset ||
            edits.single.text != typed)) {
      return null;
    }
    final explicit = edits?.single.attributes;
    if (explicit?['code'] == true ||
        _isCode(block, offset) ||
        (feature.isLiteral?.call(block, offset) ?? false)) {
      return null;
    }
    final text = block.text.replaceRange(offset, offset, typed);
    final edit = feature.editFor(text, offset);
    if (edit == null) return null;
    try {
      final literal = Transaction(document)
        ..insertText(
          selection.head,
          typed,
          attributes: explicit ??
              feature.typingAttributes?.call(block, offset) ??
              _inheritedAttributes(block, offset),
        );
      final literalDocument = literal.doc;
      final index = caret.blockIndex;
      final literalBlock = literalDocument.blocks[index];
      final conversion = Transaction(literalDocument)
        ..deleteRange(
          literalDocument.positionAt(index, edit.start),
          literalDocument.positionAt(index, edit.end),
        );
      conversion.insertText(
        conversion.doc.positionAt(index, edit.start),
        edit.replacement,
        // The first typed character's run, so an anchor it carried moves to
        // the substitute.
        attributes: _attributesAt(literalBlock, edit.start),
      );
      final caretAfter = offset +
          typed.length -
          (edit.end - edit.start) +
          edit.replacement.length;
      final finalDocument = conversion.doc;
      final prepared = HomericPreparedCommand(
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
      if (feature.backspaceReverts) {
        _last = _Substitution(
          document: finalDocument,
          blockId: block.id,
          start: edit.start,
          replacement: edit.replacement,
          original: edit.original(text),
          caret: caretAfter,
        );
      }
      return prepared;
    } on ArgumentError {
      return null;
    }
  }

  /// Backspace straight after a substitution: nothing else changed the
  /// document, and the delete takes exactly the substitute.
  HomericPreparedCommand? _prepareRevert(
    HomericEditorCommand command,
    _Substitution last,
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
    final edit = edits.single;
    final end = last.start + last.replacement.length;
    if (edit.start != last.start || edit.end != end || edit.text.isNotEmpty) {
      return null;
    }
    final caret = document.resolve(selection.head);
    if (caret is! InlinePosition ||
        caret.block.id != last.blockId ||
        caret.offset != last.caret ||
        last.caret != end) {
      return null;
    }
    try {
      final index = caret.blockIndex;
      final revert = Transaction(document)
        ..deleteRange(
          document.positionAt(index, last.start),
          document.positionAt(index, end),
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

  /// A code block, or typing into a `code` run (the run plain typing at
  /// [offset] would join).
  static bool _isCode(Block block, int offset) =>
      block.type == 'code' ||
      _inheritedAttributes(block, offset)['code'] == true;

  static Attributes _attributesAt(Block block, int offset) {
    var cursor = 0;
    for (final run in block.runs) {
      final end = cursor + run.length;
      if (offset >= cursor && offset < end) return run.attributes;
      cursor = end;
    }
    return emptyAttributes;
  }

  /// The run before the caret, as plain typing inherits it.
  static Attributes _inheritedAttributes(Block block, int offset) {
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

final class _Substitution {
  const _Substitution({
    required this.document,
    required this.blockId,
    required this.start,
    required this.replacement,
    required this.original,
    required this.caret,
  });

  final Document document;
  final String blockId;
  final int start;
  final String replacement;
  final String original;
  final int caret;
}
