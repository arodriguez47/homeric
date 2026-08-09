/// The playground's one [ChangeNotifier]: owns the document, the
/// decoration set, a tap-to-place caret stub, and undo history, and
/// exposes every Phase 1 transaction builder plus decoration
/// add/remove/toggle as commands.
///
/// Deliberately free of Flutter/`dart:ui` types (no [Color], no
/// [TextStyle]) — this is the "model" side of the flutter-architecture
/// skill's MVVM split; `views/` resolves style/paint from theme + the
/// [PlaygroundSpec] kinds this file's decorations carry. Every mutating
/// method funnels through [_run], which wraps exactly one [Transaction]
/// per call and calls [notifyListeners] exactly once, only when the
/// transaction actually changed the document — commands on an empty
/// document or a degenerate range fail the builder's own validation (or
/// its own documented no-op, e.g. `deleteRange` on an empty range) and
/// return `false` as a value; nothing throws out to the UI.
library;

import 'package:flutter/foundation.dart';
import 'package:homeric/homeric.dart';

import '../decoration_spec.dart';

/// One committed transaction's undo record: the transaction itself (for
/// [Step.invert]-based document undo — the plan's explicit ask to exercise
/// Phase 1's R3 invert guarantee live) plus the decoration set and caret
/// snapshotted immediately before it, restored verbatim on undo.
///
/// Decorations are restored by snapshot rather than by inverse-mapping
/// them through the transaction: [DecorationSet.map] is a forward-mapping
/// operation (document edit → re-anchored decorations) with no declared
/// inverse, and a snapshot is exactly correct and cheap (the set shares
/// untouched shards by reference with every other version).
final class _UndoEntry {
  _UndoEntry(this.tx, this.decorationsBefore, this.caretBefore);

  final Transaction tx;
  final DecorationSet decorationsBefore;
  final int? caretBefore;
}

/// Owns `(Document, DecorationSet, caret)` and exposes every Phase 1
/// builder, decoration commands, and undo as methods views call in
/// response to user input.
class DocumentViewModel extends ChangeNotifier {
  /// Creates a view-model starting from [document] and [decorations].
  DocumentViewModel({
    required Document document,
    DecorationSet decorations = DecorationSet.empty,
  })  : _document = document,
        _decorations = decorations;

  Document _document;
  DecorationSet _decorations;
  int? _caret;
  final List<_UndoEntry> _undoStack = <_UndoEntry>[];
  final Set<String> _hideDelimitersBlocks = <String>{};

  /// The current document.
  Document get document => _document;

  /// The current decoration set.
  DecorationSet get decorations => _decorations;

  /// The tap-to-place caret, as a global document position, or `null` when
  /// nothing has been tapped yet. This is a display/anchor stub, not a
  /// real selection — Phase 3 owns selection gestures.
  int? get caret => _caret;

  /// Whether an undo is available.
  bool get canUndo => _undoStack.isNotEmpty;

  /// Whether [blockId]'s hide-delimiter decorations are currently applied.
  bool isHidingDelimiters(String blockId) =>
      _hideDelimitersBlocks.contains(blockId);

  // --- Caret (display-only stub; R10 demo input) --------------------------

  /// Places the caret at document [position]. No-ops on an out-of-range
  /// position instead of throwing (positions come from tap geometry, which
  /// is always in range for the block it queried, but a stale/foreign
  /// value should never crash the view-model).
  void placeCaretAt(int position) {
    if (position < 0 || position > _document.size || position == _caret) {
      return;
    }
    _caret = position;
    notifyListeners();
  }

  /// Clears the caret (nothing tapped / focus lost).
  void clearCaret() {
    if (_caret == null) return;
    _caret = null;
    notifyListeners();
  }

  /// The [RevealState] for [blockId]'s derivation this frame (R10): reveals
  /// every `replace` decoration in [blockId] whose range contains the
  /// caret, when the caret currently resolves inside that block — the
  /// mechanism `MarkerRevealController` becomes. Every other block gets
  /// [RevealState.none].
  RevealState revealStateForBlock(String blockId) {
    final caret = _caret;
    if (caret == null) return RevealState.none;
    final resolved = _document.resolve(caret);
    if (resolved is! InlinePosition || resolved.block.id != blockId) {
      return RevealState.none;
    }
    final local = resolved.offset;
    final revealed = <Decoration>[
      for (final d in _decorations.forBlock(blockId))
        if (d.kind == DecorationKind.replace &&
            d.start <= local &&
            local <= d.end)
          d,
    ];
    return revealed.isEmpty ? RevealState.none : RevealState.of(revealed);
  }

  // --- Transaction plumbing ------------------------------------------------

  /// Runs [build] against a fresh [Transaction] over the current document.
  ///
  /// A validation failure the builders raise as a thrown error
  /// ([ArgumentError], Phase 1's [PositionOutOfRangeError], or
  /// [StepFailedError] from a step that does not fit) is caught here and
  /// turned into a `false` return — the view-model boundary the plan asks
  /// for, so no builder misuse ever reaches the UI as an exception. A
  /// transaction that validates but makes no change (e.g. `deleteRange`
  /// with `to <= from`) is also reported as `false`, with **no**
  /// [notifyListeners] call — only a transaction that actually changed the
  /// document notifies, and it does so exactly once.
  bool _run(void Function(Transaction tx) build) {
    final tx = Transaction(_document);
    try {
      build(tx);
    } on ArgumentError {
      return false;
    } on PositionOutOfRangeError {
      return false;
    } on StepFailedError {
      return false;
    }
    if (!tx.docChanged) return false;

    final decorationsBefore = _decorations;
    final caretBefore = _caret;
    final result = tx.finish();
    _document = result.doc;
    _decorations = _decorations.map(result.mapping, result.changes);
    final caret = _caret;
    if (caret != null) {
      _caret = result.mapping.map(caret, assoc: 1).clamp(0, _document.size);
    }
    _undoStack.add(_UndoEntry(tx, decorationsBefore, caretBefore));
    notifyListeners();
    return true;
  }

  // --- Builder commands (every Phase 1 TransactionBuilders member) --------

  /// Inserts [text] at the current caret. No-ops without a placed caret or
  /// with empty [text].
  bool insertTextAtCaret(String text,
      {Attributes attributes = emptyAttributes}) {
    final pos = _caret;
    if (pos == null || text.isEmpty) return false;
    return _run((tx) => tx.insertText(pos, text, attributes: attributes));
  }

  /// Deletes document range `[from, to)`.
  bool deleteRange(int from, int to) {
    if (from < 0 || to < from || to > _document.size) return false;
    return _run((tx) => tx.deleteRange(from, to));
  }

  /// Deletes the [count] positions immediately before the caret.
  bool deleteBackwardFromCaret(int count) {
    final pos = _caret;
    if (pos == null || count <= 0) return false;
    final from = (pos - count).clamp(0, _document.size);
    return deleteRange(from, pos);
  }

  /// Splits the block at the current caret.
  bool splitAtCaret({String? trailingBlockId}) {
    final pos = _caret;
    if (pos == null) return false;
    return _run((tx) => tx.splitBlock(pos, trailingBlockId: trailingBlockId));
  }

  /// Joins the two blocks meeting at document [boundary].
  bool joinAtBoundary(int boundary) {
    if (boundary < 0 || boundary > _document.size) return false;
    return _run((tx) => tx.joinBlocks(boundary));
  }

  /// Joins the block [blockId] with the block immediately after it.
  bool joinBlockWithNext(String blockId) {
    final index = _document.indexOfBlockId(blockId);
    if (index == null || index >= _document.blockCount - 1) return false;
    return joinAtBoundary(_document.positionAfterBlock(index));
  }

  /// Moves block [blockId] to [targetIndex].
  bool moveBlock(String blockId, int targetIndex) {
    if (_document.indexOfBlockId(blockId) == null) return false;
    if (targetIndex < 0 || targetIndex >= _document.blockCount) return false;
    return _run((tx) => tx.moveBlock(blockId, targetIndex));
  }

  /// Moves block [blockId] one position earlier.
  bool moveBlockUp(String blockId) {
    final index = _document.indexOfBlockId(blockId);
    if (index == null || index == 0) return false;
    return moveBlock(blockId, index - 1);
  }

  /// Moves block [blockId] one position later.
  bool moveBlockDown(String blockId) {
    final index = _document.indexOfBlockId(blockId);
    if (index == null || index >= _document.blockCount - 1) return false;
    return moveBlock(blockId, index + 1);
  }

  /// Changes block [blockId]'s type.
  bool setBlockType(String blockId, String type) {
    if (_document.indexOfBlockId(blockId) == null) return false;
    return _run((tx) => tx.setBlockType(blockId, type));
  }

  /// Replaces block [blockId]'s attribute bag.
  bool setBlockAttributes(String blockId, Attributes attributes) {
    if (_document.indexOfBlockId(blockId) == null) return false;
    return _run((tx) => tx.setBlockAttributes(blockId, attributes));
  }

  /// Toggles inline attribute [key] = [value] over document range
  /// `[from, to)`.
  bool toggleMark(int from, int to, String key, Object? value) {
    if (from < 0 || to < from || to > _document.size) return false;
    return _run((tx) => tx.toggleMark(from, to, key, value));
  }

  // --- Undo (Step.invert, applied in reverse — R3 live) -------------------

  /// Undoes the most recently committed transaction by inverting each of
  /// its steps, in reverse order, against the document it produced —
  /// exactly Phase 1's documented invert contract
  /// (`Step.invert(docBefore)`; `docBefore` is `tx.docs[i]`, the document
  /// `tx.steps[i]` was applied to). Decorations and the caret are restored
  /// from the snapshot taken before the transaction ran (see
  /// [_UndoEntry]).
  bool undoLast() {
    if (_undoStack.isEmpty) return false;
    final entry = _undoStack.removeLast();
    final tx = entry.tx;
    var doc = tx.doc;
    for (var i = tx.steps.length - 1; i >= 0; i--) {
      final inverted = tx.steps[i].invert(tx.docs[i]);
      final result = inverted.apply(doc);
      if (result.failed) {
        // Should be unreachable given Phase 1's lossless-invert guarantee
        // (R3); fail safe rather than leave the document half-restored.
        return false;
      }
      doc = result.doc!;
    }
    _document = doc;
    _decorations = entry.decorationsBefore;
    _caret = entry.caretBefore;
    notifyListeners();
    return true;
  }

  // --- Decorations ----------------------------------------------------------

  /// Adds [decoration] to the set.
  void addDecoration(Decoration decoration) {
    _decorations = _decorations.add([decoration]);
    notifyListeners();
  }

  /// Removes [decoration] from the set. No-ops (no notify) if it is not
  /// present.
  void removeDecoration(Decoration decoration) {
    final next = _decorations.remove([decoration]);
    if (identical(next, _decorations)) return;
    _decorations = next;
    notifyListeners();
  }

  /// Toggles hide-delimiter decorations over [blockId]'s `**`/`%%` markers
  /// (R10/R8 demo): applies replace decorations over each marker pair when
  /// off, or removes every hide-marker decoration in that block when on.
  ///
  /// These decorations are real [DecorationSet] members, not recomputed
  /// per build — once applied they survive edits like any other decoration
  /// (`DecorationSet.map`'s re-anchoring), which is the point of building
  /// this as decorations rather than a pure text-scan-at-render-time
  /// effect.
  void toggleHideDelimiters(String blockId) {
    final block = _document.blockById(blockId);
    if (block == null) return;
    if (_hideDelimitersBlocks.contains(blockId)) {
      final existing = _decorations
          .forBlock(blockId)
          .where((d) =>
              d.kind == DecorationKind.replace &&
              d.spec is PlaygroundSpec &&
              (d.spec! as PlaygroundSpec).kind ==
                  PlaygroundDecorationKind.hideMarker)
          .toList();
      _decorations = _decorations.remove(existing);
      _hideDelimitersBlocks.remove(blockId);
    } else {
      final markers = markerDecorationsFor(block);
      if (markers.isEmpty) return;
      _decorations = _decorations.add(markers);
      _hideDelimitersBlocks.add(blockId);
    }
    notifyListeners();
  }

  /// Adds a mention/annotation background-wash decoration over
  /// `[start, end)` of [blockId]'s content (U5 underlay paint layer demo).
  void addMentionWash(String blockId, int start, int end) {
    if (start < 0 || end < start) return;
    addDecoration(Decoration.inline(blockId, start, end,
        spec: const PlaygroundSpec(PlaygroundDecorationKind.mentionWash)));
  }

  /// Adds an annotation-underline decoration over `[start, end)` of
  /// [blockId]'s content (U5 overlay paint layer demo).
  void addAnnotationUnderline(String blockId, int start, int end) {
    if (start < 0 || end < start) return;
    addDecoration(Decoration.inline(blockId, start, end,
        spec: const PlaygroundSpec(PlaygroundDecorationKind.annotation)));
  }

  /// Inserts a widget-chip decoration at content [offset] of [blockId]
  /// (U3 placeholder-slot demo). Purely additive to the decoration set —
  /// a widget decoration never requires document content at its offset
  /// (`deriveViewText` injects the placeholder character in view space).
  bool insertWidgetChip(String blockId, int offset, {required String label}) {
    final block = _document.blockById(blockId);
    if (block == null || offset < 0 || offset > block.contentLength) {
      return false;
    }
    addDecoration(
        Decoration.widget(blockId, offset, spec: PlaygroundSpec.chip(label)));
    return true;
  }
}
