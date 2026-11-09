/// Typing a double mark's opening closes it for the writer: `**` becomes
/// `**▍**`, the caret between the markers, as the format bar's bold button
/// does at a bare caret.
///
/// - Only the double marks `**`, `==` and `~~`, and only where a mark can
///   start: after the start of the line, a space or an opening bracket or
///   quote, and before the end, a space or punctuation. `2**8`, `a == b`
///   written without spaces, or a closing `**` after a word are left as
///   typed. A single `*`, `` ` `` or `~` never pairs (list bullets,
///   italics typed by hand, US-International dead keys), nor do `[[`,
///   `{{`, `%%`, `++` or `@`, which have their own menus and meanings.
/// - Typing the marker again right after a word, where the closing one
///   starts, steps over it,
///   so typing a whole `**bold**` by hand gives `**bold**`, not
///   `**bold****`. Tab steps out too, as does the format button.
/// - Left empty, the closing marker added goes again and the opening the
///   writer typed stays ([HomericOpenPairs]).
/// - Composing input (a dead key's accent, an IME) is never paired.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter/widgets.dart' show SingleActivator;

import '../editing/editable_document.dart';
import '../editing/editor_controller.dart';
import '../model/attributes.dart';
import '../model/block.dart';
import '../model/position.dart';
import '../model/selection.dart';
import '../transform/builders.dart';
import '../transform/transaction.dart';
import 'open_pairs.dart';
import 'writing_feature.dart';

/// Closes `**`, `==` and `~~` as they are typed; Tab steps out of a mark
/// opened at the caret.
final class HomericTypedPairs extends HomericWritingFeature {
  /// Typed pairs for [markers], each a doubled character.
  const HomericTypedPairs({
    this.markers = defaultMarkers,
    this.isActive,
    this.tab = true,
  });

  /// `**`, `==` and `~~`.
  static const List<String> defaultMarkers = <String>['**', '==', '~~'];

  /// The marks closed as typed; each is one character twice.
  final List<String> markers;

  /// Read before each keystroke; `false` leaves typing as it was.
  final bool Function()? isActive;

  /// Whether Tab steps out of a mark opened at the caret (typed or from a
  /// format button). Bound before the host's own Tab, it gives way to it
  /// everywhere else.
  final bool tab;

  @override
  String get id => 'typedPairs';

  static final List<HomericEditorController> _installed =
      <HomericEditorController>[];

  @override
  VoidCallback installOn(HomericEditorController controller) {
    _installed.add(controller);
    final stop = controller.addCommandInterceptor(
      (command) => intercept(command),
    );
    return () {
      stop();
      _installed.remove(controller);
    };
  }

  @override
  List<HomericDocumentCommandBinding> get commandBindings => !tab
      ? const <HomericDocumentCommandBinding>[]
      : <HomericDocumentCommandBinding>[
          HomericDocumentCommandBinding(
            // Const, as the editor's own Tab, so the host's other Tab
            // bindings group with this one.
            shortcut: _tab,
            onInvoke: tabResult,
          ),
        ];

  /// Tab inside a mark opened at the caret: the caret steps out past its
  /// closing marker. Anywhere else Tab goes on to the host's binding.
  static HomericDocumentCommandResult tabResult(
    HomericDocumentCommandContext context,
  ) {
    final caret = context.selection;
    if (!context.isCurrent ||
        context.composing != null ||
        caret == null ||
        !caret.isCollapsed) {
      return HomericDocumentCommandResult.ignored;
    }
    final matches = <HomericEditorController>[
      for (final controller in _installed)
        if (identical(controller.document, context.document) &&
            controller.selection == caret &&
            (HomericOpenPairs.maybeOf(controller)?.holds(caret) ?? false))
          controller,
    ];
    if (matches.length != 1) return HomericDocumentCommandResult.ignored;
    final controller = matches.single;
    // A handler can't change the editor itself: right after it.
    scheduleMicrotask(() {
      if (controller.selection == caret) {
        HomericOpenPairs.of(controller).stepOut();
      }
    });
    return HomericDocumentCommandResult.handled;
  }

  /// The interceptor [installOn] adds.
  HomericCommandInterception intercept(HomericEditorCommand command) {
    if (command.kind != HomericCommandKind.preInsert) {
      return HomericCommandInterception.ignored;
    }
    if (isActive?.call() == false) return HomericCommandInterception.ignored;
    final controller = command.controller;
    final typed = command.text;
    final selection = command.selection;
    if (typed == null ||
        typed.length != 1 ||
        selection == null ||
        !selection.isCollapsed ||
        controller.composing != null ||
        command.replacementComposing != null) {
      return HomericCommandInterception.ignored;
    }
    final document = controller.document;
    final at = document.resolve(selection.head);
    if (at is! InlinePosition ||
        (command.blockId != null && at.block.id != command.blockId)) {
      return HomericCommandInterception.ignored;
    }
    final edits = command.edits;
    if (edits != null &&
        (edits.length != 1 ||
            edits.single.start != at.offset ||
            edits.single.end != at.offset)) {
      return HomericCommandInterception.ignored;
    }
    if (at.block.type == 'code') return HomericCommandInterception.ignored;
    for (final marker in markers) {
      if (marker[0] != typed) continue;
      final pairs = HomericOpenPairs.of(controller);
      // At an open mark's closing marker: step over it.
      final closing = pairs.closingAt(selection, marker);
      if (closing != null &&
          closing.close > closing.inner &&
          // A closing marker follows a word; after a space, `*` opens.
          !_space.hasMatch(at.block.text[at.offset - 1]) &&
          _evenLone(
            at.block.text.substring(
              at.offset - (closing.close - closing.inner),
              at.offset,
            ),
            typed,
          )) {
        _stepped = (
          controller,
          selection.head + marker.length,
          controller.documentRevision,
          typed,
        );
        return controller.setSelection(
          HomericSelection.collapsed(selection.head + marker.length),
        )
            ? HomericCommandInterception.handled
            : HomericCommandInterception.ignored;
      }
      // The second half of a marker just stepped over: already there.
      final stepped = _stepped;
      if (stepped != null &&
          identical(stepped.$1, controller) &&
          stepped.$2 == selection.head &&
          stepped.$3 == controller.documentRevision &&
          stepped.$4 == typed &&
          marker.length == 2) {
        _stepped = null;
        return HomericCommandInterception.rejected(#typedPairsStepped);
      }
      final plan = closeAt(at.block.text, at.offset, marker);
      if (!plan) continue;
      // Two steps: the character typed, then the closing marker, so one
      // undo takes back only the closing marker.
      final Transaction typedTx;
      final Transaction closeTx;
      // The attributes the key would have typed with, for both, so a pair
      // opened in an italic run stays italic.
      final attributes =
          edits?.single.attributes ?? _typingAttributes(at.block, at.offset);
      try {
        typedTx = Transaction(document)
          ..insertText(
            document.positionAt(at.blockIndex, at.offset),
            typed,
            attributes: attributes,
          );
        final next = typedTx.finish().doc;
        closeTx = Transaction(next)
          ..insertText(
            next.positionAt(at.blockIndex, at.offset + 1),
            marker,
            attributes: attributes,
          );
      } on ArgumentError {
        return HomericCommandInterception.ignored;
      }
      final inner = selection.head + 1;
      final applied = controller.applyPreparedCommand(HomericPreparedCommand(
        stages: <Transaction>[typedTx, closeTx],
        selection: HomericSelection.collapsed(inner),
        undoCheckpoint: HomericPreparedUndoCheckpoint(
          stage: 0,
          selection: HomericSelection.collapsed(inner),
        ),
      ));
      if (!applied) return HomericCommandInterception.ignored;
      pairs.followTyped(marker, inner: inner, close: inner);
      return HomericCommandInterception.handled;
    }
    _stepped = null;
    return HomericCommandInterception.ignored;
  }

  /// Whether typing [marker]'s character at [offset] in [text] finishes an
  /// opening [marker] that should be closed: its first character is just
  /// before [offset], a mark can start there and nothing follows that
  /// would make it a closing one.
  @visibleForTesting
  static bool closeAt(String text, int offset, String marker) {
    final char = marker[0];
    if (offset < 1 || text[offset - 1] != char) return false;
    final start = offset - 1;
    // `***` and longer runs are left as typed.
    if (start > 0 && text[start - 1] == char) return false;
    if (offset < text.length && text[offset] == char) return false;
    if (start > 0 && !_opensAfter.hasMatch(text[start - 1])) return false;
    if (offset < text.length && !_closesBefore.hasMatch(text[offset])) {
      return false;
    }
    // An odd count of the marker before it: this one closes a mark.
    final before = marker.allMatches(text.substring(0, start)).length;
    return before.isEven;
  }

  /// Whether [text] holds an even number of lone [char]s (`*` not part of
  /// `**`), so a mark inside it is closed: the next `*` closes the outer.
  static bool _evenLone(String text, String char) {
    var lone = 0;
    for (var i = 0; i < text.length; i++) {
      if (text[i] != char) continue;
      final doubled = (i + 1 < text.length && text[i + 1] == char);
      if (doubled) {
        i++;
        continue;
      }
      lone++;
    }
    return lone.isEven;
  }
}

(HomericEditorController, int, int, String)? _stepped;

/// The attributes a key typed at [offset] in [block] takes: those of the
/// letter before it, or at a block's start the letter after, as the
/// controller types.
Attributes _typingAttributes(Block block, int offset) {
  if (block.runs.isEmpty) return emptyAttributes;
  final probe =
      offset > 0 ? offset - 1 : (offset < block.contentLength ? offset : 0);
  var start = 0;
  for (final run in block.runs) {
    final next = start + run.length;
    if (!run.isEmpty && probe >= start && probe < next) return run.attributes;
    start = next;
  }
  return block.runs.last.attributes;
}

/// What may stand before a mark's opening: a space or an opening bracket,
/// quote or dash.
final RegExp _opensAfter = RegExp(r'''[\s(\[{"'“‘«—–-]''');

/// What may follow a just-opened mark: a space or punctuation.
final RegExp _closesBefore = RegExp(r'''[\s.,;:!?)\]}"'”’»—–-]''');

final RegExp _space = RegExp(r'\s');

const SingleActivator _tab = SingleActivator(LogicalKeyboardKey.tab);
