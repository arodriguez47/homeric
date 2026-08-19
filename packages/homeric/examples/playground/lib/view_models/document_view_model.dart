/// The playground adapter around one public [HomericEditorController] and one
/// shared [HomericTextInputSession].
///
/// Deliberately free of Flutter/`dart:ui` types (no [Color], no
/// [TextStyle]) — this is the "model" side of the flutter-architecture
/// skill's MVVM split; `views/` resolves style/paint from theme + the
/// [PlaygroundSpec] kinds this file's decorations carry. Every mutating
/// method funnels through the same controller transaction and undo pipeline
/// used by keyboard, pointer, semantics, and platform composition input.
library;

import 'package:flutter/foundation.dart';
import 'package:homeric/homeric.dart';

import '../decoration_spec.dart';

/// Exposes the playground's debug commands without duplicating editor state.
class DocumentViewModel extends ChangeNotifier {
  /// Creates a view-model starting from [document] and [decorations].
  DocumentViewModel({
    required Document document,
    DecorationSet decorations = DecorationSet.empty,
  }) {
    editorController = HomericEditorController(
      document: document,
      decorations: decorations,
    );
    inputSession = HomericTextInputSession(controller: editorController);
    editorController.addListener(_editorChanged);
  }

  /// The sole owner of document, decorations, selection, composition, and
  /// undo state used by the playground.
  late final HomericEditorController editorController;

  /// The one epoch-bound platform input session shared by every paragraph.
  late final HomericTextInputSession inputSession;

  /// The current document.
  Document get document => editorController.document;

  /// The current decoration set.
  DecorationSet get decorations => editorController.decorations;

  /// Compatibility name used by the debug panel for the active selection
  /// head. Selection remains canonical controller state.
  int? get caret => editorController.selection?.head;

  /// Whether an undo is available.
  bool get canUndo => editorController.canUndo;

  /// Whether a redo is available.
  bool get canRedo => editorController.canRedo;

  /// Whether [blockId]'s hide-delimiter decorations are currently applied.
  ///
  /// Derived on demand from [decorations] itself, rather than a
  /// separately-tracked flag: a flag can drift out of sync with the
  /// decoration set whenever something other than [toggleHideDelimiters]
  /// changes it wholesale — [undoLast] restoring a decoration snapshot is
  /// exactly that case (a bug this fixed: toggling hide-delimiters on and
  /// then undoing left a stale flag reporting "still hiding" after the
  /// decorations were already restored to their pre-toggle, not-hiding
  /// state). Scanning is cheap: `forBlock` is already a per-block view and
  /// a block carries only a handful of decorations.
  bool isHidingDelimiters(String blockId) =>
      decorations.forBlock(blockId).any((d) =>
          d.kind == DecorationKind.replace &&
          d.spec is PlaygroundSpec &&
          (d.spec! as PlaygroundSpec).kind ==
              PlaygroundDecorationKind.hideMarker);

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
    final tx = Transaction(document);
    try {
      build(tx);
    } on ArgumentError {
      return false;
    } on PositionOutOfRangeError {
      return false;
    } on StepFailedError {
      return false;
    }
    return tx.docChanged && editorController.applyTransaction(tx);
  }

  // --- Builder commands (every Phase 1 TransactionBuilders member) --------

  /// Inserts [text] at the current caret. No-ops without a placed caret or
  /// with empty [text].
  bool insertTextAtCaret(String text,
      {Attributes attributes = emptyAttributes}) {
    final pos = caret;
    if (pos == null || text.isEmpty) return false;
    return _run((tx) => tx.insertText(pos, text, attributes: attributes));
  }

  /// Deletes document range `[from, to)`.
  bool deleteRange(int from, int to) {
    if (from < 0 || to < from || to > document.size) return false;
    return _run((tx) => tx.deleteRange(from, to));
  }

  /// Deletes the [count] positions immediately before the caret.
  bool deleteBackwardFromCaret(int count) {
    final pos = caret;
    if (pos == null || count <= 0) return false;
    final from = (pos - count).clamp(0, document.size);
    return deleteRange(from, pos);
  }

  /// Splits the block at the current caret.
  bool splitAtCaret({String? trailingBlockId}) {
    final pos = caret;
    if (pos == null) return false;
    return _run((tx) => tx.splitBlock(pos, trailingBlockId: trailingBlockId));
  }

  /// Joins the two blocks meeting at document [boundary].
  bool joinAtBoundary(int boundary) {
    if (boundary < 0 || boundary > document.size) return false;
    return _run((tx) => tx.joinBlocks(boundary));
  }

  /// Joins the block [blockId] with the block immediately after it.
  bool joinBlockWithNext(String blockId) {
    final index = document.indexOfBlockId(blockId);
    if (index == null || index >= document.blockCount - 1) return false;
    return joinAtBoundary(document.positionAfterBlock(index));
  }

  /// Moves block [blockId] to [targetIndex].
  bool moveBlock(String blockId, int targetIndex) {
    if (document.indexOfBlockId(blockId) == null) return false;
    if (targetIndex < 0 || targetIndex >= document.blockCount) return false;
    return _run((tx) => tx.moveBlock(blockId, targetIndex));
  }

  /// Moves block [blockId] one position earlier.
  bool moveBlockUp(String blockId) {
    final index = document.indexOfBlockId(blockId);
    if (index == null || index == 0) return false;
    return moveBlock(blockId, index - 1);
  }

  /// Moves block [blockId] one position later.
  bool moveBlockDown(String blockId) {
    final index = document.indexOfBlockId(blockId);
    if (index == null || index >= document.blockCount - 1) return false;
    return moveBlock(blockId, index + 1);
  }

  /// Changes block [blockId]'s type.
  bool setBlockType(String blockId, String type) {
    if (document.indexOfBlockId(blockId) == null) return false;
    return _run((tx) => tx.setBlockType(blockId, type));
  }

  /// Replaces block [blockId]'s attribute bag.
  bool setBlockAttributes(String blockId, Attributes attributes) {
    if (document.indexOfBlockId(blockId) == null) return false;
    return _run((tx) => tx.setBlockAttributes(blockId, attributes));
  }

  /// Toggles inline attribute [key] = [value] over document range
  /// `[from, to)`.
  bool toggleMark(int from, int to, String key, Object? value) {
    if (from < 0 || to < from || to > document.size) return false;
    return _run((tx) => tx.toggleMark(from, to, key, value));
  }

  // --- Undo ----------------------------------------------------------------

  /// Undoes the latest keyboard, platform, debug, or decoration edit through
  /// the controller's exact snapshot history.
  bool undoLast() => editorController.undo();

  /// Redoes the latest undone editor change through the same history owner.
  bool redoLast() => editorController.redo();

  // --- Decorations ----------------------------------------------------------

  /// Adds [decoration] to the set.
  void addDecoration(Decoration decoration) {
    editorController.replaceDecorations(decorations.add([decoration]));
  }

  /// Removes [decoration] from the set. No-ops (no notify) if it is not
  /// present.
  void removeDecoration(Decoration decoration) {
    final next = decorations.remove([decoration]);
    if (identical(next, decorations)) return;
    editorController.replaceDecorations(next);
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
    final block = document.blockById(blockId);
    if (block == null) return;
    if (isHidingDelimiters(blockId)) {
      final existing = decorations
          .forBlock(blockId)
          .where((d) =>
              d.kind == DecorationKind.replace &&
              d.spec is PlaygroundSpec &&
              (d.spec! as PlaygroundSpec).kind ==
                  PlaygroundDecorationKind.hideMarker)
          .toList();
      editorController.replaceDecorations(decorations.remove(existing));
    } else {
      final markers = markerDecorationsFor(block);
      if (markers.isEmpty) return;
      editorController.replaceDecorations(decorations.add(markers));
    }
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
    final block = document.blockById(blockId);
    if (block == null || offset < 0 || offset > block.contentLength) {
      return false;
    }
    addDecoration(
        Decoration.widget(blockId, offset, spec: PlaygroundSpec.chip(label)));
    return true;
  }

  void _editorChanged() => notifyListeners();

  @override
  void dispose() {
    editorController.removeListener(_editorChanged);
    inputSession.dispose();
    editorController.dispose();
    super.dispose();
  }
}
