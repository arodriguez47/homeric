/// Experimental canonical editing state and transaction ownership.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../decoration/decoration.dart';
import '../decoration/decoration_set.dart';
import '../model/attributes.dart';
import '../model/block.dart';
import '../model/document.dart';
import '../model/inline_run.dart';
import '../model/position.dart';
import '../model/selection.dart';
import '../transform/builders.dart';
import '../transform/replace_step.dart';
import '../transform/transaction.dart';

/// A normalized UTF-16 range inside one block's canonical text.
final class BlockTextRange {
  /// Creates `[start, end)`.
  const BlockTextRange(this.start, this.end)
      : assert(start >= 0),
        assert(end >= start);

  /// Creates an empty range at [offset].
  const BlockTextRange.collapsed(int offset)
      : start = offset,
        end = offset,
        assert(offset >= 0);

  /// The inclusive block-local start.
  final int start;

  /// The exclusive block-local end.
  final int end;

  /// Whether the range is empty.
  bool get isCollapsed => start == end;

  @override
  bool operator ==(Object other) =>
      other is BlockTextRange && start == other.start && end == other.end;

  @override
  int get hashCode => Object.hash(start, end);
}

/// A directional selection in one block's canonical UTF-16 text.
final class BlockTextSelection {
  /// Creates a block-local selection with a fixed [anchor] and active [head].
  const BlockTextSelection({
    required this.anchor,
    required this.head,
    this.affinity = HomericCaretAffinity.downstream,
  })  : assert(anchor >= 0),
        assert(head >= 0);

  /// Creates a collapsed block-local selection at [offset].
  const BlockTextSelection.collapsed(
    int offset, {
    this.affinity = HomericCaretAffinity.downstream,
  })  : anchor = offset,
        head = offset,
        assert(offset >= 0);

  /// The fixed block-local endpoint.
  final int anchor;

  /// The active block-local endpoint.
  final int head;

  /// The active head's visual affinity.
  final HomericCaretAffinity affinity;

  /// The normalized start.
  int get start => anchor < head ? anchor : head;

  /// The normalized end.
  int get end => anchor > head ? anchor : head;

  /// Whether no canonical content is selected.
  bool get isCollapsed => anchor == head;

  /// Whether the head is at or after the anchor.
  bool get isForward => head >= anchor;

  @override
  bool operator ==(Object other) =>
      other is BlockTextSelection &&
      anchor == other.anchor &&
      head == other.head &&
      affinity == other.affinity;

  @override
  int get hashCode => Object.hash(anchor, head, affinity);
}

/// One sequential replacement in a canonical block-local editing batch.
final class CanonicalTextEdit {
  /// Replaces `[start, end)` with [text].
  const CanonicalTextEdit(this.start, this.end, this.text, {this.attributes})
      : assert(start >= 0),
        assert(end >= start);

  /// The inclusive start in the batch's current shadow text.
  final int start;

  /// The exclusive end in the batch's current shadow text.
  final int end;

  /// Canonical replacement text. Newlines are rejected by this phase.
  final String text;

  /// Explicit inserted attributes, or `null` for deterministic inheritance.
  final Attributes? attributes;
}

/// A canonical range that must be revealed before a hidden-text mutation.
final class CanonicalEditTarget {
  /// Creates a block-local reveal target.
  const CanonicalEditTarget(this.blockId, this.start, this.end);

  /// Stable host block id.
  final String blockId;

  /// Inclusive canonical block-local start.
  final int start;

  /// Exclusive canonical block-local end.
  final int end;

  @override
  bool operator ==(Object other) =>
      other is CanonicalEditTarget &&
      blockId == other.blockId &&
      start == other.start &&
      end == other.end;

  @override
  int get hashCode => Object.hash(blockId, start, end);
}

/// A stale-safe request to move one stable block to [targetIndex].
///
/// [previousBlockId] and [nextBlockId] are the source block's neighbors at
/// capture time. Together with [documentRevision] they prevent a delayed drop
/// or shortcut from applying to a structurally different document.
final class BlockMoveRequest {
  /// Creates a captured block-move request.
  const BlockMoveRequest({
    required this.blockId,
    required this.targetIndex,
    required this.documentRevision,
    required this.previousBlockId,
    required this.nextBlockId,
  });

  /// Stable ID of the block being moved.
  final String blockId;

  /// Destination index in the resulting document.
  final int targetIndex;

  /// Controller document revision observed when this request was captured.
  final int documentRevision;

  /// Source neighbor immediately before [blockId], or null at the start.
  final String? previousBlockId;

  /// Source neighbor immediately after [blockId], or null at the end.
  final String? nextBlockId;
}

/// Events that interrupt an open platform composition.
enum CompositionInterruption {
  blur,
  platformClose,
  pointerRelocation,
  activeBlockSwitch,
  externalBlockReplacement,
  disposal,
  staleEpoch,
}

final class _EditorSnapshot {
  const _EditorSnapshot(
    this.document,
    this.decorations,
    this.selection,
    this.composing,
    this.preferredX,
  );

  final Document document;
  final DecorationSet decorations;
  final HomericSelection? selection;
  final HomericTextRange? composing;
  final double? preferredX;
}

/// Owns Homeric's canonical document editing state.
///
/// This surface is experimental until a real Nexus consumer validates it.
/// Render objects remain read-only; input sessions and gestures translate
/// their events into this controller's canonical intents.
class HomericEditorController extends ChangeNotifier {
  /// Creates a controller over [document].
  HomericEditorController({
    required Document document,
    DecorationSet decorations = DecorationSet.empty,
    HomericSelection? selection,
    HomericTextRange? composing,
    double? preferredX,
    this.maxUndoDepth = 100,
    this.onBeforeCanonicalMutation,
  })  : _document = document,
        _decorations = decorations,
        _selection = selection,
        _composing = composing,
        _preferredX = preferredX {
    if (maxUndoDepth < 1) {
      throw ArgumentError.value(
        maxUndoDepth,
        'maxUndoDepth',
        'must be at least 1',
      );
    }
    if (!_isValidSelection(document, selection)) {
      throw ArgumentError.value(
        selection,
        'selection',
        'endpoints must resolve inside document blocks',
      );
    }
    if (!_isValidComposing(document, selection, composing)) {
      throw ArgumentError.value(composing, 'composing',
          'range must resolve inside the active selection block');
    }
  }

  Document _document;
  DecorationSet _decorations;
  HomericSelection? _selection;
  HomericTextRange? _composing;
  double? _preferredX;

  final List<_EditorSnapshot> _undoStack = <_EditorSnapshot>[];
  final List<_EditorSnapshot> _redoStack = <_EditorSnapshot>[];
  _EditorSnapshot? _compositionStart;
  bool _compositionDidEdit = false;
  int _stateRevision = 0;
  int _contentRevision = 0;
  int _documentRevision = 0;

  /// Called synchronously before a mutation touching hidden canonical text.
  ///
  /// The target is the full replace-decoration range, not merely the
  /// grapheme being removed. A host can therefore reveal the projection
  /// before accepting the canonical mutation.
  final ValueChanged<CanonicalEditTarget>? onBeforeCanonicalMutation;

  /// Maximum number of committed editor snapshots retained for undo.
  final int maxUndoDepth;

  /// Current canonical document.
  Document get document => _document;

  /// Current mapped decorations.
  DecorationSet get decorations => _decorations;

  /// Current directional global selection, or `null` when inactive.
  HomericSelection? get selection => _selection;

  /// Current global composing range, or `null` outside composition.
  HomericTextRange? get composing => _composing;

  /// Retained horizontal coordinate for repeated vertical navigation.
  double? get preferredX => _preferredX;

  /// Whether a committed document edit can be undone.
  bool get canUndo => _undoStack.isNotEmpty;

  /// Whether an undone editor snapshot can be restored.
  bool get canRedo => _redoStack.isNotEmpty;

  /// Monotonic witness for every listener-visible state transition.
  int get stateRevision => _stateRevision;

  /// Monotonic witness for changes to canonical block text.
  int get contentRevision => _contentRevision;

  /// Monotonic witness for every canonical document version change.
  ///
  /// Unlike [stateRevision], selection-only movement does not advance it.
  /// Unlike [contentRevision], a reorder of text-identical blocks does.
  int get documentRevision => _documentRevision;

  /// Stable id of the selection's active block, or `null` without selection.
  String? get activeBlockId {
    final current = _selection;
    if (current == null) return null;
    final resolved = _document.resolve(current.head);
    return resolved is InlinePosition ? resolved.block.id : null;
  }

  /// Converts [offset] in [blockId] to a global canonical position.
  int globalPositionForBlockOffset(String blockId, int offset) {
    final index = _document.indexOfBlockId(blockId);
    if (index == null) {
      throw ArgumentError.value(blockId, 'blockId', 'unknown block');
    }
    if (offset < 0 || offset > _document.blocks[index].contentLength) {
      throw RangeError.range(
        offset,
        0,
        _document.blocks[index].contentLength,
        'offset',
      );
    }
    return _document.positionAt(index, offset);
  }

  /// Converts a global [position] to an offset inside [blockId].
  int blockOffsetForGlobalPosition(String blockId, int position) {
    final resolved = _document.resolve(position);
    if (resolved is! InlinePosition || resolved.block.id != blockId) {
      throw ArgumentError.value(
        position,
        'position',
        'does not resolve inside block "$blockId"',
      );
    }
    return resolved.offset;
  }

  /// Replaces the logical selection without changing the document.
  bool setSelection(
    HomericSelection? value, {
    double? preferredX,
    bool resetPreferredX = false,
  }) {
    final nextPreferredX = resetPreferredX ? null : preferredX ?? _preferredX;
    if (_compositionStart != null ||
        _composing != null ||
        !_isValidSelection(_document, value) ||
        (value == _selection && nextPreferredX == _preferredX)) {
      return false;
    }
    _selection = value;
    _preferredX = nextPreferredX;
    _notifyTransition();
    return true;
  }

  /// Commits composition, then applies a pointer-derived selection.
  bool relocateSelection(HomericSelection value) {
    if (!_isValidSelection(_document, value)) return false;
    final compositionChanged = _finishComposition(notify: false);
    if (value == _selection) {
      if (compositionChanged) _notifyTransition();
      return compositionChanged;
    }
    _selection = value;
    _preferredX = null;
    _notifyTransition();
    return true;
  }

  /// Retains [value] for subsequent vertical movement.
  bool setPreferredX(double value) {
    if (!value.isFinite || value == _preferredX) return false;
    _preferredX = value;
    _notifyTransition();
    return true;
  }

  /// Clears vertical navigation's retained x coordinate.
  bool resetPreferredX() {
    if (_preferredX == null) return false;
    _preferredX = null;
    _notifyTransition();
    return true;
  }

  /// Replaces the current canonical selection and collapses after [text].
  bool replaceSelection(
    String text, {
    Attributes? attributes,
  }) {
    if (_compositionStart != null ||
        _composing != null ||
        text.contains('\n') ||
        text.contains('\r')) {
      return false;
    }
    final current = _selection;
    final host = _selectionHost(_document, current);
    if (current == null || host == null) return false;
    final localStart = current.start - host.blockStart - 1;
    final localEnd = current.end - host.blockStart - 1;
    return applyBlockEditBatch(
      blockId: host.block.id,
      edits: [
        CanonicalTextEdit(localStart, localEnd, text, attributes: attributes)
      ],
      selection: BlockTextSelection.collapsed(localStart + text.length),
    );
  }

  /// Replaces the directional canonical selection with possibly multiline
  /// [text] as one structural transaction.
  ///
  /// Line separators create blocks, including empty blocks between adjacent
  /// separators. The leading selected block keeps its stable ID. Every
  /// additional block receives a fresh transaction-scoped ID; callers may
  /// pin the first one with [firstTrailingBlockId] for deterministic split
  /// and replay tests.
  bool replaceSelectionStructurally(
    String text, {
    String? firstTrailingBlockId,
  }) =>
      _replaceSelectionStructurally(
        text,
        firstTrailingBlockId: firstTrailingBlockId,
      );

  /// Applies one block-local platform value over a document-global selection.
  ///
  /// [selection] and [composing] address [text], not the old active block. This
  /// lets a block-local platform client replace a cross-block canonical range
  /// in one observable controller transition without exposing whole-document
  /// text to the platform.
  bool applyDocumentSelectionTextInput({
    required String text,
    required BlockTextSelection selection,
    BlockTextRange? composing,
  }) {
    if (text.contains('\n') ||
        text.contains('\r') ||
        !_validBlockSelection(selection, text.length) ||
        (composing != null && !_validBlockRange(composing, text.length))) {
      return false;
    }
    return _replaceSelectionStructurally(
      text,
      replacementSelection: selection,
      replacementComposing: composing,
    );
  }

  bool _replaceSelectionStructurally(
    String text, {
    String? firstTrailingBlockId,
    BlockTextSelection? replacementSelection,
    BlockTextRange? replacementComposing,
  }) {
    if (_compositionStart != null || _composing != null) return false;
    final current = _selection;
    if (current == null || !_isValidSelection(_document, current)) {
      return false;
    }
    final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final segments = normalized.split('\n');
    final start = _document.resolve(current.start);
    final end = _document.resolve(current.end);
    if (start is! InlinePosition || end is! InlinePosition) return false;
    if (segments.length == 1 && start.blockIndex == end.blockIndex) {
      return replaceSelection(segments.single);
    }

    final tx = Transaction(_document);
    String? lastInsertedId;
    try {
      final inserted = <Block>[];
      for (var index = 0; index < segments.length; index++) {
        final id = switch (index) {
          0 => start.block.id,
          1 when firstTrailingBlockId != null => firstTrailingBlockId,
          _ => tx.allocateBlockId(),
        };
        lastInsertedId = id;
        inserted.add(Block(
          id: id,
          type: start.block.type,
          attributes: start.block.attributes,
          runs: segments[index].isEmpty
              ? const <InlineRun>[]
              : <InlineRun>[
                  InlineRun(
                    segments[index],
                    attributes: _typingAttributes(
                      start.block,
                      start.offset,
                      start.offset,
                    ),
                  ),
                ],
        ));
      }
      tx.step(ReplaceStep(
        current.start,
        current.end,
        Slice(inserted, openStart: true, openEnd: true),
      ));
    } on ArgumentError {
      return false;
    } on PositionOutOfRangeError {
      return false;
    } on StepFailedError {
      return false;
    } on StateError {
      return false;
    }

    final result = tx.finish();
    final targetId = replacementSelection != null || segments.length == 1
        ? start.block.id
        : lastInsertedId!;
    final targetIndex = result.doc.indexOfBlockId(targetId);
    if (targetIndex == null) return false;
    final nextSelection = replacementSelection == null
        ? HomericSelection.collapsed(
            result.doc.positionAt(
              targetIndex,
              segments.length == 1
                  ? start.offset + segments.single.length
                  : segments.last.length,
            ),
          )
        : HomericSelection(
            anchor: result.doc.positionAt(
              targetIndex,
              start.offset + replacementSelection.anchor,
            ),
            head: result.doc.positionAt(
              targetIndex,
              start.offset + replacementSelection.head,
            ),
            affinity: replacementSelection.affinity,
          );
    final nextComposing = replacementComposing == null
        ? null
        : HomericTextRange(
            result.doc.positionAt(
              targetIndex,
              start.offset + replacementComposing.start,
            ),
            result.doc.positionAt(
              targetIndex,
              start.offset + replacementComposing.end,
            ),
          );
    return _commitStructuralTransaction(
      tx,
      result,
      nextSelection,
      nextComposing: nextComposing,
      revealTargets: _hiddenTargetsForSelection(current),
    );
  }

  /// Splits after replacing any expanded selection, focusing the fresh
  /// trailing block at offset zero.
  bool insertParagraphBreak({String? trailingBlockId}) =>
      replaceSelectionStructurally(
        '\n',
        firstTrailingBlockId: trailingBlockId,
      );

  /// Applies a stale-safe stable-ID block move as one history unit.
  ///
  /// Directional selection endpoints are mapped through the mirrored move;
  /// the model preserves endpoints and affinity, not a non-contiguous set of
  /// content when a moved block crosses the other endpoint.
  bool moveBlock(BlockMoveRequest request) {
    if (_compositionStart != null ||
        _composing != null ||
        _selectionHost(_document, _selection) == null ||
        request.documentRevision != _documentRevision) {
      return false;
    }
    final sourceIndex = _document.indexOfBlockId(request.blockId);
    if (sourceIndex == null ||
        request.targetIndex < 0 ||
        request.targetIndex >= _document.blockCount ||
        request.targetIndex == sourceIndex) {
      return false;
    }
    final previous =
        sourceIndex == 0 ? null : _document.blocks[sourceIndex - 1].id;
    final next = sourceIndex == _document.blockCount - 1
        ? null
        : _document.blocks[sourceIndex + 1].id;
    if (previous != request.previousBlockId || next != request.nextBlockId) {
      return false;
    }
    final tx = Transaction(_document);
    try {
      tx.moveBlock(request.blockId, request.targetIndex);
    } on ArgumentError {
      return false;
    } on StepFailedError {
      return false;
    }
    final result = tx.finish();
    final mappedSelection = _selection?.map(result.mapping);
    if (!_isValidSelection(result.doc, mappedSelection)) return false;
    return _commitStructuralTransaction(
      tx,
      result,
      mappedSelection,
    );
  }

  /// Deletes the selection or the preceding canonical grapheme.
  bool deleteBackward() => _deleteCanonical(backward: true);

  /// Deletes the selection or the following canonical grapheme.
  bool deleteForward() => _deleteCanonical(backward: false);

  bool _deleteCanonical({required bool backward}) {
    if (_compositionStart != null || _composing != null) return false;
    final current = _selection;
    final host = _selectionHost(_document, current);
    if (current == null || !_isValidSelection(_document, current)) return false;
    if (host == null) {
      return current.isCollapsed ? false : replaceSelectionStructurally('');
    }
    var start = current.start - host.blockStart - 1;
    var end = current.end - host.blockStart - 1;
    if (current.isCollapsed) {
      final offset = start;
      final boundary = CharacterBoundary(host.block.text);
      if (backward) {
        if (offset == 0) {
          if (host.blockIndex == 0) return false;
          return _joinAtBoundary(
            host.blockIndex,
            _document.blocks[host.blockIndex - 1].contentLength,
          );
        }
        start = boundary.getLeadingTextBoundaryAt(offset - 1) ?? 0;
      } else {
        if (offset == host.block.contentLength) {
          if (host.blockIndex == _document.blockCount - 1) return false;
          return _joinAtBoundary(host.blockIndex + 1, offset);
        }
        end = boundary.getTrailingTextBoundaryAt(offset) ??
            host.block.contentLength;
      }
    }
    return applyBlockEditBatch(
      blockId: host.block.id,
      edits: [CanonicalTextEdit(start, end, '')],
      selection: BlockTextSelection.collapsed(start),
    );
  }

  bool _joinAtBoundary(int insertionIndex, int caretOffset) {
    final leadingIndex = insertionIndex - 1;
    if (leadingIndex < 0 || insertionIndex >= _document.blockCount) {
      return false;
    }
    final tx = Transaction(_document);
    try {
      tx.joinBlocks(_document.positionBeforeBlock(insertionIndex));
    } on ArgumentError {
      return false;
    } on StepFailedError {
      return false;
    }
    final result = tx.finish();
    return _commitStructuralTransaction(
      tx,
      result,
      HomericSelection.collapsed(
        result.doc.positionAt(leadingIndex, caretOffset),
      ),
    );
  }

  bool _commitStructuralTransaction(
    Transaction transaction,
    TransactionResult result,
    HomericSelection? nextSelection, {
    HomericTextRange? nextComposing,
    Iterable<CanonicalEditTarget> revealTargets = const <CanonicalEditTarget>[],
  }) {
    if (!identical(transaction.before, _document) ||
        !transaction.docChanged ||
        !_isValidSelection(result.doc, nextSelection)) {
      return false;
    }
    final before = _snapshot();
    final callback = onBeforeCanonicalMutation;
    if (callback != null) {
      for (final target in revealTargets.toSet()) {
        callback(target);
      }
    }
    _document = result.doc;
    _decorations = _decorations.map(result.mapping, result.changes);
    _selection = nextSelection;
    _composing = nextComposing;
    _preferredX = null;
    if (nextComposing == null) {
      _pushUndo(before);
    } else {
      _compositionStart = before;
      _compositionDidEdit = true;
    }
    _redoStack.clear();
    _notifyTransition(
      documentChanged: true,
      contentChanged: _canonicalTextDiffers(before.document, _document),
    );
    return true;
  }

  Iterable<CanonicalEditTarget> _hiddenTargetsForSelection(
    HomericSelection selection,
  ) sync* {
    if (selection.isCollapsed) return;
    final start = _document.resolve(selection.start);
    final end = _document.resolve(selection.end);
    if (start is! InlinePosition || end is! InlinePosition) return;
    for (var index = start.blockIndex; index <= end.blockIndex; index++) {
      final block = _document.blocks[index];
      final localStart = index == start.blockIndex ? start.offset : 0;
      final localEnd =
          index == end.blockIndex ? end.offset : block.contentLength;
      for (final decoration in _decorations.forBlock(block.id)) {
        if (decoration.kind == DecorationKind.replace &&
            decoration.end > localStart &&
            decoration.start < localEnd) {
          yield CanonicalEditTarget(
            block.id,
            decoration.start,
            decoration.end,
          );
        }
      }
    }
  }

  /// Applies sequential canonical edits as one observable transition.
  ///
  /// Every edit's offsets address the text produced by the preceding edit.
  /// A non-null [composing] range opens or extends one composition undo group;
  /// the first subsequent call with `composing: null` closes that group.
  bool applyBlockEditBatch({
    required String blockId,
    List<CanonicalTextEdit> edits = const <CanonicalTextEdit>[],
    required BlockTextSelection selection,
    BlockTextRange? composing,
  }) {
    final index = _document.indexOfBlockId(blockId);
    if (index == null) return false;
    if (!_validBlockSelection(
          selection,
          _document.blocks[index].contentLength,
        ) &&
        edits.isEmpty) {
      return false;
    }
    if (edits
        .any((edit) => edit.text.contains('\n') || edit.text.contains('\r'))) {
      return false;
    }

    final tx = Transaction(_document);
    final revealTargets = <CanonicalEditTarget>[];
    try {
      for (final edit in edits) {
        final currentIndex = tx.doc.indexOfBlockId(blockId);
        if (currentIndex == null) return false;
        final block = tx.doc.blocks[currentIndex];
        if (!_validEdit(edit, block.contentLength)) return false;
        revealTargets.addAll(
          _hiddenTargets(tx, blockId, edit.start, edit.end),
        );
        if (edit.start == edit.end && edit.text.isEmpty) continue;
        _replaceBlockText(tx, currentIndex, edit);
      }
    } on ArgumentError {
      return false;
    } on PositionOutOfRangeError {
      return false;
    } on StepFailedError {
      return false;
    }

    final result = tx.finish();
    final finalIndex = result.doc.indexOfBlockId(blockId);
    if (finalIndex == null) return false;
    final finalLength = result.doc.blocks[finalIndex].contentLength;
    if (!_validBlockSelection(selection, finalLength) ||
        (composing != null && !_validBlockRange(composing, finalLength))) {
      return false;
    }

    final switchingComposition = _compositionStart != null &&
        activeBlockId != null &&
        activeBlockId != blockId;
    if (switchingComposition) _finishComposition(notify: false);
    final before = _snapshot();
    if (composing != null && _compositionStart == null) {
      _compositionStart = before;
      _compositionDidEdit = false;
    }
    final callback = onBeforeCanonicalMutation;
    if (callback != null) {
      for (final target in revealTargets.toSet()) {
        callback(target);
      }
    }

    final nextSelection = HomericSelection(
      anchor: result.doc.positionAt(finalIndex, selection.anchor),
      head: result.doc.positionAt(finalIndex, selection.head),
      affinity: selection.affinity,
    );
    final nextComposing = composing == null
        ? null
        : HomericTextRange(
            result.doc.positionAt(finalIndex, composing.start),
            result.doc.positionAt(finalIndex, composing.end),
          );
    final changed = tx.docChanged ||
        nextSelection != _selection ||
        nextComposing != _composing;
    if (!changed) return false;

    if (tx.docChanged) {
      _document = result.doc;
      _decorations = _decorations.map(result.mapping, result.changes);
      _preferredX = null;
    }
    _selection = nextSelection;
    _composing = nextComposing;

    if (_compositionStart != null) {
      _compositionDidEdit = _compositionDidEdit || tx.docChanged;
      if (composing == null) _finishComposition(notify: false);
    } else if (tx.docChanged) {
      _pushUndo(before);
    }
    if (tx.docChanged) _redoStack.clear();
    _notifyTransition(
      documentChanged: tx.docChanged,
      contentChanged: _canonicalTextDiffers(before.document, _document),
    );
    return true;
  }

  /// Applies a prebuilt external transaction and maps editor state through it.
  bool applyTransaction(Transaction transaction) {
    if (!identical(transaction.before, _document)) return false;
    final compositionChanged = _finishComposition(notify: false);
    if (!transaction.docChanged) {
      if (compositionChanged) _notifyTransition();
      return compositionChanged;
    }
    final before = _snapshot();
    final result = transaction.finish();
    final mappedSelection = _selection?.map(result.mapping);
    final mappedComposing = _composing?.map(result.mapping);
    _document = result.doc;
    _decorations = _decorations.map(result.mapping, result.changes);
    _selection =
        _isValidSelection(_document, mappedSelection) ? mappedSelection : null;
    _composing = _isValidComposing(
      _document,
      _selection,
      mappedComposing,
    )
        ? mappedComposing
        : null;
    _pushUndo(before);
    _redoStack.clear();
    _notifyTransition(
      documentChanged: true,
      contentChanged: _canonicalTextDiffers(before.document, _document),
    );
    return true;
  }

  /// Replaces the canonical decoration set as one undoable editor change.
  ///
  /// Decoration-only consumer controls use this instead of retaining a
  /// parallel decoration set beside the controller. An active composition is
  /// committed first, and [undo] restores the exact prior editor snapshot.
  bool replaceDecorations(DecorationSet value) {
    final compositionChanged = _finishComposition(notify: false);
    if (identical(value, _decorations)) {
      if (compositionChanged) _notifyTransition();
      return compositionChanged;
    }
    final before = _snapshot();
    _decorations = value;
    _pushUndo(before);
    _redoStack.clear();
    _notifyTransition();
    return true;
  }

  /// Applies the composition policy for [event].
  bool interruptComposition(CompositionInterruption event) {
    if (event == CompositionInterruption.staleEpoch) return false;
    return _finishComposition(notify: true);
  }

  /// Restores the exact state before the latest committed edit group.
  bool undo() {
    final compositionChanged = _finishComposition(notify: false);
    if (_undoStack.isEmpty) {
      if (compositionChanged) _notifyTransition();
      return compositionChanged;
    }
    final current = _snapshot();
    final snapshot = _undoStack.removeLast();
    _pushHistory(_redoStack, current);
    final contentChanged = _canonicalTextDiffers(
      current.document,
      snapshot.document,
    );
    final documentChanged = !identical(current.document, snapshot.document);
    _restore(snapshot);
    _notifyTransition(
      documentChanged: documentChanged,
      contentChanged: contentChanged,
    );
    return true;
  }

  /// Restores the exact state most recently displaced by [undo].
  bool redo() {
    final compositionChanged = _finishComposition(notify: false);
    if (_redoStack.isEmpty) {
      if (compositionChanged) _notifyTransition();
      return compositionChanged;
    }
    final current = _snapshot();
    final snapshot = _redoStack.removeLast();
    _pushUndo(current);
    final contentChanged = _canonicalTextDiffers(
      current.document,
      snapshot.document,
    );
    final documentChanged = !identical(current.document, snapshot.document);
    _restore(snapshot);
    _notifyTransition(
      documentChanged: documentChanged,
      contentChanged: contentChanged,
    );
    return true;
  }

  bool _finishComposition({required bool notify}) {
    final start = _compositionStart;
    if (start == null && _composing == null) return false;
    if (start != null && _compositionDidEdit) _pushUndo(start);
    _compositionStart = null;
    _compositionDidEdit = false;
    _composing = null;
    if (notify) _notifyTransition();
    return true;
  }

  _EditorSnapshot _snapshot() => _EditorSnapshot(
        _document,
        _decorations,
        _selection,
        _composing,
        _preferredX,
      );

  void _restore(_EditorSnapshot snapshot) {
    _document = snapshot.document;
    _decorations = snapshot.decorations;
    _selection = snapshot.selection;
    _composing = snapshot.composing;
    _preferredX = snapshot.preferredX;
  }

  void _replaceBlockText(
    Transaction tx,
    int blockIndex,
    CanonicalTextEdit edit,
  ) {
    final block = tx.doc.blocks[blockIndex];
    final from = tx.doc.positionAt(blockIndex, edit.start);
    final to = tx.doc.positionAt(blockIndex, edit.end);
    if (edit.text.isEmpty) {
      tx.step(ReplaceStep(from, to, Slice.empty));
      return;
    }
    final attributes =
        edit.attributes ?? _typingAttributes(block, edit.start, edit.end);
    tx.step(ReplaceStep(
      from,
      to,
      Slice(
        [
          Block(
            id: block.id,
            type: block.type,
            runs: [InlineRun(edit.text, attributes: attributes)],
          ),
        ],
        openStart: true,
        openEnd: true,
      ),
    ));
  }

  Attributes _typingAttributes(Block block, int start, int end) {
    if (block.runs.isEmpty) return emptyAttributes;
    final probe = start > 0 ? start - 1 : (end < block.contentLength ? end : 0);
    var offset = 0;
    for (final run in block.runs) {
      final next = offset + run.length;
      if (!run.isEmpty && probe >= offset && probe < next) {
        return run.attributes;
      }
      offset = next;
    }
    return block.runs.last.attributes;
  }

  void _pushUndo(_EditorSnapshot snapshot) {
    _pushHistory(_undoStack, snapshot);
  }

  void _pushHistory(
    List<_EditorSnapshot> stack,
    _EditorSnapshot snapshot,
  ) {
    stack.add(snapshot);
    final overflow = stack.length - maxUndoDepth;
    if (overflow > 0) {
      stack.removeRange(0, overflow);
    }
  }

  void _notifyTransition({
    bool documentChanged = false,
    bool contentChanged = false,
  }) {
    _stateRevision++;
    if (documentChanged) _documentRevision++;
    if (contentChanged) _contentRevision++;
    notifyListeners();
  }

  static bool _canonicalTextDiffers(Document before, Document after) {
    if (identical(before, after)) return false;
    if (before.blockCount != after.blockCount) return true;
    for (var index = 0; index < before.blockCount; index++) {
      if (before.blocks[index].text != after.blocks[index].text) return true;
    }
    return false;
  }

  Iterable<CanonicalEditTarget> _hiddenTargets(
    Transaction tx,
    String blockId,
    int start,
    int end,
  ) sync* {
    if (start == end) {
      return;
    }
    for (final decoration in _decorations.forBlock(blockId)) {
      if (decoration.kind != DecorationKind.replace) {
        continue;
      }
      final mapped = DecorationSet.of([decoration])
          .map(tx.mapping, tx.changes)
          .forBlock(blockId);
      if (mapped.isEmpty ||
          mapped.single.end <= start ||
          mapped.single.start >= end) {
        continue;
      }
      yield CanonicalEditTarget(
        blockId,
        decoration.start,
        decoration.end,
      );
    }
  }

  @override
  void dispose() {
    _finishComposition(notify: false);
    super.dispose();
  }

  static bool _validEdit(CanonicalTextEdit edit, int length) =>
      edit.start >= 0 && edit.end >= edit.start && edit.end <= length;

  static bool _validBlockRange(BlockTextRange range, int length) =>
      range.start >= 0 && range.end >= range.start && range.end <= length;

  static bool _validBlockSelection(
    BlockTextSelection selection,
    int length,
  ) =>
      selection.anchor >= 0 &&
      selection.anchor <= length &&
      selection.head >= 0 &&
      selection.head <= length;

  static InlinePosition? _selectionHost(
    Document document,
    HomericSelection? selection,
  ) {
    if (selection == null) return null;
    if (selection.anchor < 0 ||
        selection.anchor > document.size ||
        selection.head < 0 ||
        selection.head > document.size) {
      return null;
    }
    final anchor = document.resolve(selection.anchor);
    final head = document.resolve(selection.head);
    if (anchor is! InlinePosition ||
        head is! InlinePosition ||
        anchor.blockIndex != head.blockIndex) {
      return null;
    }
    return head;
  }

  static bool _isValidSelection(
    Document document,
    HomericSelection? selection,
  ) {
    if (selection == null) return true;
    if (selection.anchor < 0 ||
        selection.anchor > document.size ||
        selection.head < 0 ||
        selection.head > document.size) {
      return false;
    }
    return document.resolve(selection.anchor) is InlinePosition &&
        document.resolve(selection.head) is InlinePosition;
  }

  static bool _isValidComposing(
    Document document,
    HomericSelection? selection,
    HomericTextRange? composing,
  ) {
    if (composing == null) return true;
    final host = _selectionHost(document, selection);
    if (host == null) return false;
    if (composing.start < 0 ||
        composing.start > document.size ||
        composing.end < composing.start ||
        composing.end > document.size) {
      return false;
    }
    final start = document.resolve(composing.start);
    final end = document.resolve(composing.end);
    return start is InlinePosition &&
        end is InlinePosition &&
        start.blockIndex == host.blockIndex &&
        end.blockIndex == host.blockIndex;
  }
}
