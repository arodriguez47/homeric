/// Experimental canonical editing state and transaction ownership.
library;

import 'dart:async';

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
import '../transform/change_list.dart';
import '../transform/mapping.dart';
import '../transform/replace_step.dart';
import '../transform/step_map.dart' show Mappable, MapResult;
import '../transform/transaction.dart';

/// Identifies the canonical command that produced a committed document change.
enum HomericCommitOrigin {
  /// Platform text input or a canonical text-editing intent.
  textInput,

  /// A structural editor command such as split, join, or block movement.
  structural,

  /// A transaction supplied by an embedding consumer.
  externalTransaction,

  /// Restoration of the previous history snapshot.
  undo,

  /// Reapplication of an undone history snapshot.
  redo,
}

/// Consumer interception points before built-in editor commands run.
enum HomericCommandKind {
  /// Canonical text will be inserted or replace selected text.
  preInsert,

  /// Canonical text or a structural boundary will be deleted.
  preDelete,

  /// A paragraph break will split the active block.
  preBreak,

  /// A whole-block command such as reorder will run.
  block,
}

/// One typed command presented to registered consumer interceptors.
final class HomericEditorCommand {
  /// Creates a command description.
  const HomericEditorCommand({
    required this.kind,
    required this.controller,
    required this.selection,
    this.blockId,
    this.text,
    this.forward,
    this.trailingBlockId,
    this.replacementSelection,
    this.replacementComposing,
    this.blockMove,
  });

  /// Interception point for this command.
  final HomericCommandKind kind;

  /// Sole canonical mutation owner.
  ///
  /// A handling interceptor may invoke one atomic controller intent. Nested
  /// command interception is suppressed while that interceptor runs.
  final HomericEditorController controller;

  /// Directional selection captured before the command.
  final HomericSelection? selection;

  /// Stable active or explicitly targeted block ID, when applicable.
  final String? blockId;

  /// Canonical inserted text for [HomericCommandKind.preInsert].
  final String? text;

  /// Structural-boundary direction for [HomericCommandKind.preDelete].
  ///
  /// `false` requests the boundary before the active block, `true` requests
  /// the boundary after it, and `null` identifies a block-local or range
  /// deletion. At a flat document edge the built-in command remains a no-op,
  /// but a consumer may claim the request for its own enclosing topology.
  final bool? forward;

  /// Explicit first trailing block identity requested for a paragraph break.
  final String? trailingBlockId;

  /// Requested block-local selection in the replacement result, when the
  /// platform supplied a complete text-editing value.
  final BlockTextSelection? replacementSelection;

  /// Requested block-local composing range in the replacement result.
  final BlockTextRange? replacementComposing;

  /// Captured move request for [HomericCommandKind.block].
  final BlockMoveRequest? blockMove;
}

/// The outcome returned by a [HomericCommandInterceptor].
sealed class HomericCommandInterception {
  const HomericCommandInterception();

  /// Continues to the next interceptor and then the built-in command.
  static const ignored = HomericCommandIgnored();

  /// Stops interception because the consumer handled the command atomically.
  static const handled = HomericCommandHandled();

  /// Stops the command without mutating canonical state.
  static HomericCommandRejected rejected(Object reason) =>
      HomericCommandRejected(reason);
}

/// The interceptor did not claim the command.
final class HomericCommandIgnored extends HomericCommandInterception {
  const HomericCommandIgnored();
}

/// The interceptor handled the command through one controller intent.
final class HomericCommandHandled extends HomericCommandInterception {
  const HomericCommandHandled();
}

/// The interceptor rejected the command for a typed consumer reason.
final class HomericCommandRejected extends HomericCommandInterception {
  /// Creates a rejection carrying [reason] without presentation semantics.
  const HomericCommandRejected(this.reason);

  /// Consumer-defined typed rejection reason.
  final Object reason;
}

/// Intercepts one typed command before the built-in editor behavior.
typedef HomericCommandInterceptor = HomericCommandInterception Function(
  HomericEditorCommand command,
);

/// Describes a proposed canonical mutation before the controller accepts it.
final class HomericMutationRequest {
  /// Creates a mutation-policy request.
  const HomericMutationRequest({
    required this.origin,
    required this.before,
    required this.after,
    required this.changes,
    this.retainedHistoryMutations = const <HomericRetainedHistoryMutation>[],
  });

  /// Command family proposing the mutation.
  final HomericCommitOrigin origin;

  /// Canonical document before the proposed mutation.
  final Document before;

  /// Canonical document after the proposed mutation.
  final Document after;

  /// Stable block identities touched by the proposed mutation.
  final ChangeList changes;

  /// Intermediate canonical transitions that this mutation will retain in
  /// undo history without publishing as committed changes.
  ///
  /// A persistence or topology policy can preflight their exact mapping and
  /// structural descriptors alongside [changes]. Ordinary mutations expose an
  /// empty list.
  final List<HomericRetainedHistoryMutation> retainedHistoryMutations;

  /// Intermediate documents retained by [retainedHistoryMutations].
  List<Document> get retainedHistoryDocuments => List<Document>.unmodifiable(
        retainedHistoryMutations.map((mutation) => mutation.after),
      );

  /// IDs of every block touched, created, or removed by the mutation.
  Iterable<String> get touchedBlockIds => changes.touchedBlockIds;
}

/// Returns whether a proposed canonical mutation may commit.
typedef HomericMutationPolicy = bool Function(HomericMutationRequest request);

/// One immutable history-only transition exposed during mutation preflight.
final class HomericRetainedHistoryMutation {
  /// Creates the exact transition retained as an additional undo step.
  HomericRetainedHistoryMutation({
    required this.before,
    required this.after,
    required Mapping mapping,
    required this.changes,
  }) : mapping = _ReadOnlyMapping.copy(mapping);

  /// Document before the retained transition.
  final Document before;

  /// History-only document after the retained transition.
  final Document after;

  /// Position mapping from [before] to [after].
  final Mappable mapping;

  /// Exact touched blocks and structural descriptors for the transition.
  final ChangeList changes;
}

/// One intermediate stage retained as an undo checkpoint by a prepared
/// command.
final class HomericPreparedUndoCheckpoint {
  /// Retains the document produced by [stage] with the explicit editor state.
  const HomericPreparedUndoCheckpoint({
    required this.stage,
    required this.selection,
    this.composing,
  });

  /// Zero-based index into the command's [HomericPreparedCommand.stageCount].
  final int stage;

  /// Selection restored with the retained stage document.
  final HomericSelection? selection;

  /// Composition restored with the retained stage document, when present.
  final HomericTextRange? composing;
}

/// A bounded sequence of already-prepared canonical transactions committed as
/// one observable editor command.
///
/// Every stage must start from the prior stage's resulting [Document]. The
/// controller validates the whole bundle and its explicit final editor state
/// before changing canonical state. Consumers may retain at most one
/// intermediate stage as an additional undo checkpoint. The command still
/// publishes one listener transition and one committed-change event, while the
/// checkpoint intentionally adds a second undo step.
final class HomericPreparedCommand {
  /// Creates a prepared command over [stages].
  HomericPreparedCommand({
    required List<Transaction> stages,
    required this.selection,
    this.composing,
    this.undoCheckpoint,
  }) : _stages = List<_HomericPreparedStage>.unmodifiable(
          stages.map(_HomericPreparedStage.freeze),
        );

  /// Number of frozen sequential transaction stages in this command.
  int get stageCount => _stages.length;

  final List<_HomericPreparedStage> _stages;

  /// Explicit selection in the final stage document.
  final HomericSelection? selection;

  /// Explicit composition in the final stage document.
  final HomericTextRange? composing;

  /// Optional history-only intermediate stage.
  final HomericPreparedUndoCheckpoint? undoCheckpoint;
}

final class _HomericPreparedStage {
  _HomericPreparedStage._({
    required this.before,
    required this.after,
    required this.mapping,
    required this.changes,
    required this.docChanged,
  });

  factory _HomericPreparedStage.freeze(Transaction transaction) {
    final result = transaction.finish();
    return _HomericPreparedStage._(
      before: transaction.before,
      after: result.doc,
      mapping: Mapping()..appendMapping(result.mapping),
      changes: result.changes,
      docChanged: transaction.docChanged,
    );
  }

  final Document before;
  final Document after;
  final Mapping mapping;
  final ChangeList changes;
  final bool docChanged;
}

final class _ReadOnlyMapping implements Mappable {
  _ReadOnlyMapping._(this._mapping);

  factory _ReadOnlyMapping.copy(Mapping mapping) =>
      _ReadOnlyMapping._(Mapping()..appendMapping(mapping));

  final Mapping _mapping;

  @override
  int map(int pos, {int assoc = 1}) => _mapping.map(pos, assoc: assoc);

  @override
  MapResult mapResult(int pos, {int assoc = 1}) =>
      _mapping.mapResult(pos, assoc: assoc);
}

/// One post-commit canonical document event.
final class HomericCommittedChange {
  /// Creates an immutable committed-change event.
  const HomericCommittedChange({
    required this.before,
    required this.after,
    required this.mapping,
    required this.changes,
    required this.contentRevision,
    required this.documentRevision,
    required this.origin,
  });

  /// Canonical document before the commit.
  final Document before;

  /// Canonical document after the commit.
  final Document after;

  /// Position mapping from [before] into [after].
  final Mapping mapping;

  /// Stable block identities affected by the commit.
  final ChangeList changes;

  /// Controller content revision after the commit.
  final int contentRevision;

  /// Controller document revision after the commit.
  final int documentRevision;

  /// Command family that committed the change.
  final HomericCommitOrigin origin;
}

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

enum _CommandDispatch { proceed, handled, rejected }

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

final class _HistoryEntry {
  const _HistoryEntry({
    required this.snapshot,
    required this.mapping,
    required this.changes,
  });

  final _EditorSnapshot snapshot;
  final Mapping mapping;
  final ChangeList changes;
}

final class _PreparedHistoryCheckpoint {
  const _PreparedHistoryCheckpoint({
    required this.stage,
    required this.snapshot,
  });

  final int stage;
  final _EditorSnapshot snapshot;
}

/// Owns Homeric's canonical document editing state.
///
/// This surface is experimental until a real Nexus consumer validates it.
/// Render objects remain read-only; input sessions and gestures translate
/// their events into this controller's canonical intents.
class HomericEditorController extends ChangeNotifier {
  static const int _maxPreparedCommandStages = 8;

  /// Creates a controller over [document].
  HomericEditorController({
    required Document document,
    DecorationSet decorations = DecorationSet.empty,
    HomericSelection? selection,
    HomericTextRange? composing,
    double? preferredX,
    bool readOnly = false,
    this.mutationPolicy,
    this.maxUndoDepth = 100,
    this.onBeforeCanonicalMutation,
  })  : _document = document,
        _decorations = decorations,
        _selection = selection,
        _composing = composing,
        _preferredX = preferredX,
        _readOnly = readOnly {
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
  bool _readOnly;

  final List<_HistoryEntry> _undoStack = <_HistoryEntry>[];
  final List<_HistoryEntry> _redoStack = <_HistoryEntry>[];
  final StreamController<HomericCommittedChange> _committedChanges =
      StreamController<HomericCommittedChange>.broadcast(sync: true);
  final List<HomericCommandInterceptor> _commandInterceptors =
      <HomericCommandInterceptor>[];
  _EditorSnapshot? _compositionStart;
  Mapping? _compositionMapping;
  final List<StructuralChange> _compositionStructural = <StructuralChange>[];
  bool _compositionDidEdit = false;
  int _stateRevision = 0;
  int _contentRevision = 0;
  int _documentRevision = 0;
  int _structureRevision = 0;
  bool _dispatchingCommandInterceptor = false;
  bool _notifyingTransition = false;
  bool _disposePending = false;
  bool _disposed = false;
  HomericCommandRejected? _lastCommandRejection;

  bool get _mutationUnavailable =>
      _disposed || _disposePending || _notifyingTransition;

  /// Called synchronously before a mutation touching hidden canonical text.
  ///
  /// The target is the full replace-decoration range, not merely the
  /// grapheme being removed. A host can therefore reveal the projection
  /// before accepting the canonical mutation.
  final ValueChanged<CanonicalEditTarget>? onBeforeCanonicalMutation;

  /// Optional consumer policy evaluated before every canonical mutation.
  final HomericMutationPolicy? mutationPolicy;

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

  /// Whether canonical mutations and history commands are disabled.
  bool get isReadOnly => _readOnly;

  /// Synchronous post-commit events for canonical document changes.
  ///
  /// Selection, focus, composition lifecycle, and presentation-only changes
  /// do not emit events on this stream.
  ///
  /// Events are delivered synchronously. Mutations attempted from an event
  /// callback are rejected; schedule follow-up mutations after publication.
  Stream<HomericCommittedChange> get committedChanges =>
      _committedChanges.stream;

  /// Most recent typed command rejection, cleared by the next dispatch.
  HomericCommandRejected? get lastCommandRejection => _lastCommandRejection;

  /// Registers [interceptor] after every currently registered interceptor.
  ///
  /// The returned callback removes only this registration. Interceptors run in
  /// registration order and stop at the first handled or rejected outcome.
  VoidCallback addCommandInterceptor(HomericCommandInterceptor interceptor) {
    if (_disposed || _disposePending) return () {};
    _commandInterceptors.add(interceptor);
    var registered = true;
    return () {
      if (!registered) return;
      registered = false;
      _commandInterceptors.remove(interceptor);
    };
  }

  /// Monotonic witness for every listener-visible state transition.
  int get stateRevision => _stateRevision;

  /// Monotonic witness for changes to canonical block text.
  int get contentRevision => _contentRevision;

  /// Monotonic witness for every canonical document version change.
  ///
  /// Unlike [stateRevision], selection-only movement does not advance it.
  /// Unlike [contentRevision], a reorder of text-identical blocks does.
  int get documentRevision => _documentRevision;

  /// Monotonic witness for block membership or order changes.
  ///
  /// Block-local text and attribute edits preserve this revision even though
  /// they advance [documentRevision].
  int get structureRevision => _structureRevision;

  /// Stable id of the selection's active block, or `null` without selection.
  String? get activeBlockId {
    final current = _selection;
    if (current == null) return null;
    final resolved = _document.resolve(current.head);
    return resolved is InlinePosition ? resolved.block.id : null;
  }

  /// Enables or disables canonical mutation while preserving navigation.
  ///
  /// Entering read-only mode commits an accepted platform composition as its
  /// existing single history unit before input is disabled.
  bool setReadOnly(bool value) {
    if (_mutationUnavailable || _readOnly == value) return false;
    if (value) _finishComposition(notify: false);
    _readOnly = value;
    _notifyTransition();
    return true;
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
    if (_mutationUnavailable) return false;
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
    if (_mutationUnavailable || !_isValidSelection(_document, value)) {
      return false;
    }
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
    if (_mutationUnavailable || !value.isFinite || value == _preferredX) {
      return false;
    }
    _preferredX = value;
    _notifyTransition();
    return true;
  }

  /// Clears vertical navigation's retained x coordinate.
  bool resetPreferredX() {
    if (_mutationUnavailable || _preferredX == null) return false;
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
    if (_mutationUnavailable ||
        _readOnly ||
        _compositionStart != null ||
        _composing != null) {
      return false;
    }
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

    final interception = _interceptedResult(HomericEditorCommand(
      kind: segments.length > 1
          ? HomericCommandKind.preBreak
          : normalized.isEmpty
              ? HomericCommandKind.preDelete
              : HomericCommandKind.preInsert,
      controller: this,
      selection: current,
      blockId: start.block.id,
      text: normalized,
      trailingBlockId: firstTrailingBlockId,
      replacementSelection: replacementSelection,
      replacementComposing: replacementComposing,
    ));
    if (interception != null) return interception;

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
    if (_mutationUnavailable ||
        _readOnly ||
        _compositionStart != null ||
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
    final interception = _interceptedResult(HomericEditorCommand(
      kind: HomericCommandKind.block,
      controller: this,
      selection: _selection,
      blockId: request.blockId,
      blockMove: request,
    ));
    if (interception != null) return interception;
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
    if (_mutationUnavailable ||
        _readOnly ||
        _compositionStart != null ||
        _composing != null) {
      return false;
    }
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
          if (host.blockIndex == 0) {
            return _interceptDocumentEdgeDelete(
              host.block.id,
              forward: false,
            );
          }
          return _joinAtBoundary(
            host.blockIndex,
            _document.blocks[host.blockIndex - 1].contentLength,
            forward: false,
          );
        }
        start = boundary.getLeadingTextBoundaryAt(offset - 1) ?? 0;
      } else {
        if (offset == host.block.contentLength) {
          if (host.blockIndex == _document.blockCount - 1) {
            return _interceptDocumentEdgeDelete(
              host.block.id,
              forward: true,
            );
          }
          return _joinAtBoundary(
            host.blockIndex + 1,
            offset,
            forward: true,
          );
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

  bool _interceptDocumentEdgeDelete(
    String blockId, {
    required bool forward,
  }) =>
      _interceptedResult(HomericEditorCommand(
        kind: HomericCommandKind.preDelete,
        controller: this,
        selection: _selection,
        blockId: blockId,
        forward: forward,
      )) ??
      false;

  bool _joinAtBoundary(
    int insertionIndex,
    int caretOffset, {
    required bool forward,
  }) {
    final leadingIndex = insertionIndex - 1;
    if (leadingIndex < 0 || insertionIndex >= _document.blockCount) {
      return false;
    }
    final interception = _interceptedResult(HomericEditorCommand(
      kind: HomericCommandKind.preDelete,
      controller: this,
      selection: _selection,
      blockId: _document.blocks[insertionIndex].id,
      forward: forward,
    ));
    if (interception != null) return interception;
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
    HomericCommitOrigin origin = HomericCommitOrigin.structural,
    Iterable<CanonicalEditTarget> revealTargets = const <CanonicalEditTarget>[],
  }) {
    if (!identical(transaction.before, _document) ||
        !transaction.docChanged ||
        !_isValidSelection(result.doc, nextSelection)) {
      return false;
    }
    if (!_allowsMutation(
      origin: origin,
      before: _document,
      after: result.doc,
      changes: result.changes,
    )) {
      return false;
    }
    final before = _snapshot();
    if (!_revealBeforeCanonicalMutation(revealTargets)) return false;
    _document = result.doc;
    _decorations = _decorations.map(result.mapping, result.changes);
    _selection = nextSelection;
    _composing = nextComposing;
    _preferredX = null;
    if (nextComposing == null) {
      _pushUndo(
        before,
        mapping: result.mapping,
        changes: result.changes,
      );
    } else {
      _compositionStart = before;
      _compositionDidEdit = true;
      _compositionMapping = Mapping()..appendMapping(result.mapping);
      _compositionStructural
        ..clear()
        ..addAll(result.changes.structural);
    }
    _redoStack.clear();
    _notifyTransition(
      documentChanged: true,
      contentChanged: _canonicalTextDiffers(before.document, _document),
      committedBefore: before.document,
      committedMapping: result.mapping,
      committedChanges: result.changes,
      committedOrigin: origin,
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
    if (_mutationUnavailable || _readOnly) return false;
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
    if (edits.isNotEmpty) {
      final inserts = edits.where((edit) => edit.text.isNotEmpty).toList();
      final interception = _interceptedResult(HomericEditorCommand(
        kind: inserts.isEmpty
            ? HomericCommandKind.preDelete
            : HomericCommandKind.preInsert,
        controller: this,
        selection: _selection,
        blockId: blockId,
        text: inserts.map((edit) => edit.text).join(),
      ));
      if (interception != null) return interception;
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
    if (tx.docChanged &&
        !_allowsMutation(
          origin: HomericCommitOrigin.textInput,
          before: _document,
          after: result.doc,
          changes: result.changes,
        )) {
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
      _compositionMapping = Mapping();
      _compositionStructural.clear();
    }
    if (!_revealBeforeCanonicalMutation(revealTargets)) return false;

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
      if (tx.docChanged) {
        _compositionMapping?.appendMapping(result.mapping);
        _compositionStructural.addAll(result.changes.structural);
      }
      if (composing == null) _finishComposition(notify: false);
    } else if (tx.docChanged) {
      _pushUndo(
        before,
        mapping: result.mapping,
        changes: result.changes,
      );
    }
    if (tx.docChanged) _redoStack.clear();
    _notifyTransition(
      documentChanged: tx.docChanged,
      contentChanged: _canonicalTextDiffers(before.document, _document),
      committedBefore: tx.docChanged ? before.document : null,
      committedMapping: tx.docChanged ? result.mapping : null,
      committedChanges: tx.docChanged ? result.changes : null,
      committedOrigin: tx.docChanged ? HomericCommitOrigin.textInput : null,
    );
    return true;
  }

  /// Applies a prebuilt external transaction and maps editor state through it.
  bool applyTransaction(Transaction transaction) {
    if (_mutationUnavailable || !identical(transaction.before, _document)) {
      return false;
    }
    if (!transaction.docChanged) {
      final compositionChanged = _finishComposition(notify: false);
      if (compositionChanged) _notifyTransition();
      return compositionChanged;
    }
    final result = transaction.finish();
    if (!_allowsMutation(
      origin: HomericCommitOrigin.externalTransaction,
      before: _document,
      after: result.doc,
      changes: result.changes,
    )) {
      return false;
    }
    _finishComposition(notify: false);
    final before = _snapshot();
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
    _pushUndo(
      before,
      mapping: result.mapping,
      changes: result.changes,
    );
    _redoStack.clear();
    _notifyTransition(
      documentChanged: true,
      contentChanged: _canonicalTextDiffers(before.document, _document),
      committedBefore: before.document,
      committedMapping: result.mapping,
      committedChanges: result.changes,
      committedOrigin: HomericCommitOrigin.externalTransaction,
    );
    return true;
  }

  /// Applies one bounded prepared command as a single observable transition.
  ///
  /// The final mutation and every history-retained intermediate document are
  /// presented to [mutationPolicy] before canonical state changes. A retained
  /// checkpoint is history-only: it produces neither a listener notification
  /// nor a [HomericCommittedChange].
  bool applyPreparedCommand(HomericPreparedCommand command) {
    if (_mutationUnavailable ||
        _readOnly ||
        _compositionStart != null ||
        _composing != null) {
      return false;
    }
    final stages = command._stages;
    if (stages.isEmpty || stages.length > _maxPreparedCommandStages) {
      return false;
    }

    var expectedBefore = _document;
    final results = <_HomericPreparedStage>[];
    for (final stage in stages) {
      if (!identical(stage.before, expectedBefore) || !stage.docChanged) {
        return false;
      }
      results.add(stage);
      expectedBefore = stage.after;
    }
    final finalDocument = results.last.after;
    if (!_isValidSelection(finalDocument, command.selection) ||
        !_isValidComposing(
          finalDocument,
          command.selection,
          command.composing,
        )) {
      return false;
    }

    final checkpoint = command.undoCheckpoint;
    _PreparedHistoryCheckpoint? preparedCheckpoint;
    if (checkpoint != null) {
      if (checkpoint.stage < 0 || checkpoint.stage >= stages.length - 1) {
        return false;
      }
      final checkpointDocument = results[checkpoint.stage].after;
      if (!_isValidSelection(checkpointDocument, checkpoint.selection) ||
          !_isValidComposing(
            checkpointDocument,
            checkpoint.selection,
            checkpoint.composing,
          )) {
        return false;
      }
      preparedCheckpoint = _PreparedHistoryCheckpoint(
        stage: checkpoint.stage,
        snapshot: _EditorSnapshot(
          checkpointDocument,
          _mapDecorationsThroughStages(
            _decorations,
            results,
            0,
            checkpoint.stage + 1,
          ),
          checkpoint.selection,
          checkpoint.composing,
          null,
        ),
      );
    }

    final mapping = _mappingForStages(results, 0, results.length);
    final changes = _changesForStages(
      _document,
      finalDocument,
      results,
      0,
      results.length,
    );
    final checkpointEnd =
        preparedCheckpoint == null ? null : preparedCheckpoint.stage + 1;
    final retainedMutation = checkpointEnd == null
        ? null
        : HomericRetainedHistoryMutation(
            before: _document,
            after: preparedCheckpoint!.snapshot.document,
            mapping: _mappingForStages(results, 0, checkpointEnd),
            changes: _changesForStages(
              _document,
              preparedCheckpoint.snapshot.document,
              results,
              0,
              checkpointEnd,
            ),
          );
    if (!_allowsMutation(
      origin: HomericCommitOrigin.externalTransaction,
      before: _document,
      after: finalDocument,
      changes: changes,
      retainedHistoryMutations: retainedMutation == null
          ? const <HomericRetainedHistoryMutation>[]
          : <HomericRetainedHistoryMutation>[retainedMutation],
    )) {
      return false;
    }

    final before = _snapshot();
    final finalDecorations =
        _mapDecorationsThroughStages(_decorations, results, 0, results.length);
    _document = finalDocument;
    _decorations = finalDecorations;
    _selection = command.selection;
    _composing = command.composing;
    _preferredX = null;

    if (preparedCheckpoint == null) {
      if (command.composing == null) {
        _pushUndo(before, mapping: mapping, changes: changes);
      } else {
        _beginPreparedComposition(before, mapping, changes);
      }
    } else {
      final checkpointEnd = preparedCheckpoint.stage + 1;
      final mappingToCheckpoint = _mappingForStages(results, 0, checkpointEnd);
      final changesToCheckpoint = _changesForStages(
        before.document,
        preparedCheckpoint.snapshot.document,
        results,
        0,
        checkpointEnd,
      );
      _pushUndo(
        before,
        mapping: mappingToCheckpoint,
        changes: changesToCheckpoint,
      );
      final mappingFromCheckpoint =
          _mappingForStages(results, checkpointEnd, results.length);
      final changesFromCheckpoint = _changesForStages(
        preparedCheckpoint.snapshot.document,
        finalDocument,
        results,
        checkpointEnd,
        results.length,
      );
      if (command.composing == null) {
        _pushUndo(
          preparedCheckpoint.snapshot,
          mapping: mappingFromCheckpoint,
          changes: changesFromCheckpoint,
        );
      } else {
        _beginPreparedComposition(
          preparedCheckpoint.snapshot,
          mappingFromCheckpoint,
          changesFromCheckpoint,
        );
      }
    }
    _redoStack.clear();
    _notifyTransition(
      documentChanged: true,
      contentChanged: _canonicalTextDiffers(before.document, _document),
      committedBefore: before.document,
      committedMapping: mapping,
      committedChanges: changes,
      committedOrigin: HomericCommitOrigin.externalTransaction,
    );
    return true;
  }

  void _beginPreparedComposition(
    _EditorSnapshot snapshot,
    Mapping mapping,
    ChangeList changes,
  ) {
    _compositionStart = snapshot;
    _compositionDidEdit = true;
    _compositionMapping = Mapping()..appendMapping(mapping);
    _compositionStructural
      ..clear()
      ..addAll(changes.structural);
  }

  static Mapping _mappingForStages(
    List<_HomericPreparedStage> results,
    int start,
    int end,
  ) {
    final mapping = Mapping();
    for (var index = start; index < end; index++) {
      mapping.appendMapping(results[index].mapping);
    }
    return mapping;
  }

  static ChangeList _changesForStages(
    Document before,
    Document after,
    List<_HomericPreparedStage> results,
    int start,
    int end,
  ) =>
      ChangeList.compute(
        before,
        after,
        <StructuralChange>[
          for (var index = start; index < end; index++)
            ...results[index].changes.structural,
        ],
      );

  static DecorationSet _mapDecorationsThroughStages(
    DecorationSet decorations,
    List<_HomericPreparedStage> results,
    int start,
    int end,
  ) {
    var mapped = decorations;
    for (var index = start; index < end; index++) {
      final result = results[index];
      mapped = mapped.map(result.mapping, result.changes);
    }
    return mapped;
  }

  /// Replaces the canonical decoration set as one undoable editor change.
  ///
  /// Decoration-only consumer controls use this instead of retaining a
  /// parallel decoration set beside the controller. An active composition is
  /// committed first, and [undo] restores the exact prior editor snapshot.
  bool replaceDecorations(DecorationSet value) {
    if (_mutationUnavailable || _readOnly) return false;
    final compositionChanged = _finishComposition(notify: false);
    if (identical(value, _decorations)) {
      if (compositionChanged) _notifyTransition();
      return compositionChanged;
    }
    final before = _snapshot();
    _decorations = value;
    _pushUndo(
      before,
      mapping: Mapping(),
      changes: ChangeList.compute(
        before.document,
        before.document,
        const <StructuralChange>[],
      ),
    );
    _redoStack.clear();
    _notifyTransition();
    return true;
  }

  /// Applies the composition policy for [event].
  bool interruptComposition(CompositionInterruption event) {
    if (_mutationUnavailable || event == CompositionInterruption.staleEpoch) {
      return false;
    }
    return _finishComposition(notify: true);
  }

  /// Restores the exact state before the latest committed edit group.
  bool undo() {
    if (_mutationUnavailable || _readOnly) return false;
    final compositionChanged = _finishComposition(notify: false);
    if (_undoStack.isEmpty) {
      if (compositionChanged) _notifyTransition();
      return compositionChanged;
    }
    final current = _snapshot();
    final entry = _undoStack.last;
    final snapshot = entry.snapshot;
    final changes = ChangeList.compute(
      current.document,
      snapshot.document,
      const <StructuralChange>[],
    );
    if (!_allowsMutation(
      origin: HomericCommitOrigin.undo,
      before: current.document,
      after: snapshot.document,
      changes: changes,
    )) {
      if (compositionChanged) _notifyTransition();
      return compositionChanged;
    }
    _undoStack.removeLast();
    _pushHistory(
      _redoStack,
      _HistoryEntry(
        snapshot: current,
        mapping: entry.mapping,
        changes: entry.changes,
      ),
    );
    final contentChanged = _canonicalTextDiffers(
      current.document,
      snapshot.document,
    );
    final documentChanged = !identical(current.document, snapshot.document);
    _restore(snapshot);
    _notifyTransition(
      documentChanged: documentChanged,
      contentChanged: contentChanged,
      committedBefore: documentChanged ? current.document : null,
      committedMapping: documentChanged ? entry.mapping.invert() : null,
      committedChanges: documentChanged ? changes : null,
      committedOrigin: documentChanged ? HomericCommitOrigin.undo : null,
    );
    return true;
  }

  /// Restores the exact state most recently displaced by [undo].
  bool redo() {
    if (_mutationUnavailable || _readOnly) return false;
    final compositionChanged = _finishComposition(notify: false);
    if (_redoStack.isEmpty) {
      if (compositionChanged) _notifyTransition();
      return compositionChanged;
    }
    final current = _snapshot();
    final entry = _redoStack.last;
    final snapshot = entry.snapshot;
    final changes = ChangeList.compute(
      current.document,
      snapshot.document,
      const <StructuralChange>[],
    );
    if (!_allowsMutation(
      origin: HomericCommitOrigin.redo,
      before: current.document,
      after: snapshot.document,
      changes: changes,
    )) {
      if (compositionChanged) _notifyTransition();
      return compositionChanged;
    }
    _redoStack.removeLast();
    _pushUndo(
      current,
      mapping: entry.mapping,
      changes: changes,
    );
    final contentChanged = _canonicalTextDiffers(
      current.document,
      snapshot.document,
    );
    final documentChanged = !identical(current.document, snapshot.document);
    _restore(snapshot);
    _notifyTransition(
      documentChanged: documentChanged,
      contentChanged: contentChanged,
      committedBefore: documentChanged ? current.document : null,
      committedMapping: documentChanged ? entry.mapping : null,
      committedChanges: documentChanged ? changes : null,
      committedOrigin: documentChanged ? HomericCommitOrigin.redo : null,
    );
    return true;
  }

  bool _finishComposition({required bool notify}) {
    final start = _compositionStart;
    if (start == null && _composing == null) return false;
    if (start != null && _compositionDidEdit) {
      _pushUndo(
        start,
        mapping: _compositionMapping ?? Mapping(),
        changes: ChangeList.compute(
          start.document,
          _document,
          List<StructuralChange>.of(_compositionStructural),
        ),
      );
    }
    _compositionStart = null;
    _compositionMapping = null;
    _compositionStructural.clear();
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

  void _pushUndo(
    _EditorSnapshot snapshot, {
    required Mapping mapping,
    required ChangeList changes,
  }) {
    _pushHistory(
      _undoStack,
      _HistoryEntry(
        snapshot: snapshot,
        mapping: mapping,
        changes: changes,
      ),
    );
  }

  void _pushHistory(
    List<_HistoryEntry> stack,
    _HistoryEntry entry,
  ) {
    stack.add(entry);
    final overflow = stack.length - maxUndoDepth;
    if (overflow > 0) {
      stack.removeRange(0, overflow);
    }
  }

  bool _allowsMutation({
    required HomericCommitOrigin origin,
    required Document before,
    required Document after,
    required ChangeList changes,
    List<HomericRetainedHistoryMutation> retainedHistoryMutations =
        const <HomericRetainedHistoryMutation>[],
  }) {
    if (_mutationUnavailable || _readOnly) return false;
    final policy = mutationPolicy;
    if (policy == null) return true;
    final allowed = policy(HomericMutationRequest(
      origin: origin,
      before: before,
      after: after,
      changes: changes,
      retainedHistoryMutations:
          List<HomericRetainedHistoryMutation>.unmodifiable(
        retainedHistoryMutations,
      ),
    ));
    return allowed && !_mutationUnavailable;
  }

  bool _revealBeforeCanonicalMutation(
    Iterable<CanonicalEditTarget> targets,
  ) {
    final callback = onBeforeCanonicalMutation;
    if (callback == null) return !_mutationUnavailable;
    for (final target in targets.toSet()) {
      callback(target);
      if (_mutationUnavailable) return false;
    }
    return true;
  }

  _CommandDispatch _intercept(HomericEditorCommand command) {
    if (_dispatchingCommandInterceptor || _commandInterceptors.isEmpty) {
      return _CommandDispatch.proceed;
    }
    _lastCommandRejection = null;
    final revisionBefore = _stateRevision;
    _dispatchingCommandInterceptor = true;
    try {
      for (final interceptor
          in List<HomericCommandInterceptor>.of(_commandInterceptors)) {
        final outcome = interceptor(command);
        switch (outcome) {
          case HomericCommandIgnored():
            if (_stateRevision != revisionBefore) {
              throw StateError(
                'An ignored Homeric command interceptor must not mutate '
                'editor state.',
              );
            }
            continue;
          case HomericCommandRejected():
            if (_stateRevision != revisionBefore) {
              throw StateError(
                'A rejected Homeric command interceptor must not mutate '
                'editor state.',
              );
            }
            _lastCommandRejection = outcome;
            return _CommandDispatch.rejected;
          case HomericCommandHandled():
            if (_stateRevision - revisionBefore > 1) {
              throw StateError(
                'A Homeric command interceptor may commit at most one '
                'canonical document change.',
              );
            }
            return _CommandDispatch.handled;
        }
      }
      return _CommandDispatch.proceed;
    } finally {
      _dispatchingCommandInterceptor = false;
    }
  }

  bool? _interceptedResult(HomericEditorCommand command) {
    final dispatch = _intercept(command);
    if (_mutationUnavailable) return false;
    return switch (dispatch) {
      _CommandDispatch.proceed => null,
      _CommandDispatch.handled => true,
      _CommandDispatch.rejected => false,
    };
  }

  void _notifyTransition({
    bool documentChanged = false,
    bool contentChanged = false,
    Document? committedBefore,
    Mapping? committedMapping,
    ChangeList? committedChanges,
    HomericCommitOrigin? committedOrigin,
  }) {
    if (_notifyingTransition) {
      throw StateError('Editor transitions cannot be published reentrantly.');
    }
    _notifyingTransition = true;
    try {
      _stateRevision++;
      if (documentChanged) _documentRevision++;
      if (contentChanged) _contentRevision++;
      if (documentChanged &&
          committedBefore != null &&
          _blockStructureDiffers(committedBefore, _document)) {
        _structureRevision++;
      }
      if (committedBefore != null &&
          committedMapping != null &&
          committedChanges != null &&
          committedOrigin != null) {
        _committedChanges.add(HomericCommittedChange(
          before: committedBefore,
          after: _document,
          mapping: committedMapping,
          changes: committedChanges,
          contentRevision: _contentRevision,
          documentRevision: _documentRevision,
          origin: committedOrigin,
        ));
      }
      if (!_disposePending) notifyListeners();
    } finally {
      _notifyingTransition = false;
      if (_disposePending) {
        _releaseController();
        super.dispose();
      }
    }
  }

  static bool _canonicalTextDiffers(Document before, Document after) {
    if (identical(before, after)) return false;
    if (before.blockCount != after.blockCount) return true;
    for (var index = 0; index < before.blockCount; index++) {
      if (before.blocks[index].text != after.blocks[index].text) return true;
    }
    return false;
  }

  static bool _blockStructureDiffers(Document before, Document after) {
    if (before.blockCount != after.blockCount) return true;
    for (var index = 0; index < before.blockCount; index++) {
      if (before.blocks[index].id != after.blocks[index].id) return true;
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
    if (_disposed || _disposePending) return;
    if (_notifyingTransition) {
      _disposePending = true;
      return;
    }
    _releaseController();
    super.dispose();
  }

  void _releaseController() {
    if (_disposed) return;
    _disposed = true;
    _disposePending = false;
    _finishComposition(notify: false);
    _committedChanges.close();
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
