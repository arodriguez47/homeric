/// Experimental document-owned editing coordination.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../input/text_input_session.dart';
import '../model/block.dart';
import '../model/document.dart';
import '../model/position.dart';
import '../model/selection.dart';
import '../render/paragraph_geometry.dart';
import '../render/homeric_paragraph.dart';
import 'block_height_cache.dart';
import 'editor_controller.dart';

typedef HomericEditableBlockBuilder = Widget Function(
  BuildContext context,
  Block block,
  FocusNode focusNode,
);

typedef HomericDocumentSelectionHit = ({
  int offset,
  HomericCaretAffinity affinity,
});

typedef HomericDocumentSelectionHitTest = HomericDocumentSelectionHit? Function(
    Offset globalPoint);

enum HomericScrollToBlockResult { reached, missing, stale, notReached }

/// Outcome of settling keyboard focus on a stable block.
enum HomericFocusSettlementResult { focused, missing, stale, notReached }

/// Current active-caret geometry in global coordinates.
final class HomericActiveCaretGeometry {
  /// Creates a generation-stamped active-caret snapshot.
  const HomericActiveCaretGeometry({
    required this.blockId,
    required this.documentRevision,
    required this.layoutGeneration,
    required this.globalRect,
  });

  /// Stable active block ID.
  final String blockId;

  /// Controller document revision used to shape the paragraph.
  final int documentRevision;

  /// Render generation used to query the caret.
  final int layoutGeneration;

  /// Caret rectangle in global coordinates.
  final Rect globalRect;
}

const _documentSelectAllSemanticsAction =
    CustomSemanticsAction(label: 'Select all document text');
const _documentUndoSemanticsAction =
    CustomSemanticsAction(label: 'Undo document edit');
const _documentRedoSemanticsAction =
    CustomSemanticsAction(label: 'Redo document edit');

/// Coordinates one canonical controller and one platform input session.
///
/// This first-stage shell intentionally owns no scrolling or row-height policy;
/// it establishes the document-level input capability that the virtualized
/// viewport builds on.
class HomericEditableDocument extends StatefulWidget {
  const HomericEditableDocument({
    super.key,
    required this.controller,
    required this.inputSession,
    required this.child,
  })  : blockBuilder = null,
        scrollController = null,
        padding = EdgeInsets.zero,
        scrollPadding = null,
        cacheExtent = 250,
        estimatedBlockHeight = 48,
        layoutRevision = null;

  const HomericEditableDocument.builder({
    super.key,
    required this.controller,
    required this.inputSession,
    required this.blockBuilder,
    this.scrollController,
    this.padding = EdgeInsets.zero,
    this.scrollPadding,
    this.cacheExtent = 250,
    this.estimatedBlockHeight = 48,
    this.layoutRevision,
  })  : assert(cacheExtent >= 0),
        assert(estimatedBlockHeight > 0),
        child = null;

  final HomericEditorController controller;
  final HomericTextInputSession inputSession;
  final Widget? child;
  final HomericEditableBlockBuilder? blockBuilder;
  final ScrollController? scrollController;
  final EdgeInsetsGeometry padding;

  /// Optional live scroll padding, overriding [padding] without replacing the
  /// controller or input session.
  final ValueListenable<EdgeInsetsGeometry>? scrollPadding;
  final double cacheExtent;
  final double estimatedBlockHeight;
  final Object? layoutRevision;

  /// Returns the nearest document editing coordinator, if present.
  static HomericEditableDocumentState? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_HomericEditableDocumentScope>()
      ?.state;

  @override
  State<HomericEditableDocument> createState() =>
      HomericEditableDocumentState();
}

class HomericEditableDocumentState extends State<HomericEditableDocument> {
  bool _selectionDragActive = false;
  final Map<String, HomericTextInputCommandDelegate> _commandHosts = {};
  final Map<String, BuildContext> _mountedRows = <String, BuildContext>{};
  final Map<String, FocusNode> _mountedFocusNodes = <String, FocusNode>{};
  final Map<String, GlobalKey> _rowKeys = <String, GlobalKey>{};
  final Map<GlobalKey, String> _blockIdsByRowKey = <GlobalKey, String>{};
  final Map<String, _MountedSelectionHost> _selectionHosts =
      <String, _MountedSelectionHost>{};
  late BlockHeightCache _heightCache;
  late final HomericParagraphLayoutCache _paragraphLayoutCache;
  late ScrollController _scrollController;
  double _layoutWidth = 0;
  double _pendingAnchorCorrection = 0;
  bool _anchorCorrectionScheduled = false;
  int _heightOrderDocumentRevision = -1;
  int _heightOrderContentRevision = -1;
  int _heightOrderRebuildCount = 0;
  Document? _heightOrderDocument;
  Object? _globalLayoutSignature;
  _BlockMoveWitness? _dragMoveWitness;
  int _selectionDragGeneration = 0;
  int? _selectionDragAnchor;
  int? _selectionDragDocumentRevision;
  Object? _selectionDragOwner;
  Offset? _selectionDragPointer;
  Timer? _selectionAutoScrollTimer;
  int _selectionAutoScrollDirection = 0;
  int _focusRequestGeneration = 0;
  int _focusLossCheckGeneration = 0;
  HomericSelection? _semanticsSelection;
  HomericTextRange? _semanticsComposing;
  bool _semanticsCanUndo = false;
  bool _semanticsCanRedo = false;
  bool _semanticsReadOnly = false;

  @override
  void initState() {
    super.initState();
    _validateSession();
    _heightCache = BlockHeightCache(
      estimatedHeight: widget.estimatedBlockHeight,
    );
    _paragraphLayoutCache = HomericParagraphLayoutCache();
    _scrollController = widget.scrollController ?? ScrollController();
    _syncOrder(force: true);
    _captureSemanticsState();
    widget.controller.addListener(_controllerChanged);
    FocusManager.instance.addListener(_focusTreeChanged);
  }

  @override
  void didUpdateWidget(HomericEditableDocument oldWidget) {
    super.didUpdateWidget(oldWidget);
    _validateSession();
    if (!identical(oldWidget.controller, widget.controller) ||
        !identical(oldWidget.inputSession, widget.inputSession) ||
        !identical(oldWidget.scrollController, widget.scrollController)) {
      cancelPointerSelectionDrag();
    }
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_controllerChanged);
      widget.controller.addListener(_controllerChanged);
      _focusRequestGeneration++;
      _paragraphLayoutCache.clear();
      _syncOrder(force: true);
      _captureSemanticsState();
    }
    if (!identical(oldWidget.inputSession, widget.inputSession)) {
      oldWidget.inputSession.resumeDeltas();
      if (_selectionDragActive) widget.inputSession.suspendDeltas();
    }
    if (!identical(oldWidget.scrollController, widget.scrollController)) {
      if (oldWidget.scrollController == null) _scrollController.dispose();
      _scrollController = widget.scrollController ?? ScrollController();
    }
    if (oldWidget.estimatedBlockHeight != widget.estimatedBlockHeight) {
      _heightCache = BlockHeightCache(
        estimatedHeight: widget.estimatedBlockHeight,
      );
      _syncOrder(force: true);
    }
  }

  /// Suspends platform deltas while a document-global drag moves its head.
  bool get pointerSelectionDragActive =>
      _selectionDragActive && _selectionDragAnchor != null;

  /// Number of full stable-ID order rebuilds performed by this viewport.
  ///
  /// Exposed for performance-contract tests; ordinary block-local text edits
  /// must not advance it.
  int get debugHeightOrderRebuildCount => _heightOrderRebuildCount;

  /// Number of detached shaped paragraphs retained for recycled rows.
  int get debugParagraphLayoutCacheEntries => _paragraphLayoutCache.entryCount;

  /// Bounded retained source-text footprint of the paragraph cache.
  int get debugParagraphLayoutCacheTextCodeUnits =>
      _paragraphLayoutCache.textCodeUnits;

  /// Cancels a pointer drag if focus remains outside every editor row.
  ///
  /// The deferred check lets a recycled row transfer focus within the same
  /// frame without terminating the document-owned drag.
  void schedulePointerDragFocusLossCheck() {
    if (!pointerSelectionDragActive) return;
    final generation = ++_focusLossCheckGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _focusLossCheckGeneration ||
          !pointerSelectionDragActive ||
          hasEditingFocus) {
        return;
      }
      _cancelPointerSelectionDragWithoutRetarget();
      widget.inputSession.blur();
    });
  }

  void _focusTreeChanged() {
    if (pointerSelectionDragActive) schedulePointerDragFocusLossCheck();
  }

  /// Suspends platform deltas while a document-global drag moves its head.
  void beginSelectionDrag() {
    if (_selectionDragActive) return;
    _selectionDragActive = true;
    widget.inputSession.suspendDeltas();
  }

  /// Starts one document-owned pointer selection generation at [anchor].
  void beginPointerSelectionDrag(int anchor, {Object? owner}) {
    cancelPointerSelectionDrag();
    _selectionDragGeneration++;
    _focusLossCheckGeneration++;
    _selectionDragAnchor = anchor;
    _selectionDragDocumentRevision = widget.controller.documentRevision;
    _selectionDragOwner = owner;
    beginSelectionDrag();
  }

  /// Extends the current pointer selection through mounted row geometry.
  void updatePointerSelectionDrag(Offset globalPoint) {
    if (!_selectionDragActive || _selectionDragAnchor == null) return;
    _selectionDragPointer = globalPoint;
    _updatePointerSelectionHead(globalPoint);
    _syncSelectionAutoscroll(globalPoint);
  }

  /// Ends the pointer generation and retargets platform input once.
  bool endPointerSelectionDrag({Object? owner}) {
    if (owner != null && !identical(owner, _selectionDragOwner)) return false;
    _stopSelectionAutoscroll();
    _selectionDragPointer = null;
    _selectionDragAnchor = null;
    _selectionDragDocumentRevision = null;
    _selectionDragOwner = null;
    _selectionDragGeneration++;
    _focusLossCheckGeneration++;
    return endSelectionDrag();
  }

  /// Cancels any pointer generation without retaining a recurrent timer.
  void cancelPointerSelectionDrag({Object? owner}) {
    if (owner != null && !identical(owner, _selectionDragOwner)) return;
    if (!_selectionDragActive && _selectionAutoScrollTimer == null) return;
    endPointerSelectionDrag(owner: owner);
  }

  void _cancelPointerSelectionDragWithoutRetarget() {
    if (!_selectionDragActive && _selectionAutoScrollTimer == null) return;
    _stopSelectionAutoscroll();
    _selectionDragPointer = null;
    _selectionDragAnchor = null;
    _selectionDragDocumentRevision = null;
    _selectionDragOwner = null;
    _selectionDragGeneration++;
    _focusLossCheckGeneration++;
    if (_selectionDragActive) {
      _selectionDragActive = false;
      widget.inputSession.resumeDeltas();
    }
    if (mounted) setState(() {});
  }

  /// Registers current mounted hit-test geometry for [blockId].
  void registerSelectionHost(
    String blockId, {
    required Object owner,
    required Rect? Function() globalRect,
    required HomericDocumentSelectionHitTest hitTest,
    required List<Rect>? Function(BlockTextRange range) globalRangeRects,
    required HomericActiveCaretGeometry? Function() activeCaretGeometry,
  }) {
    _selectionHosts[blockId] = _MountedSelectionHost(
      owner: owner,
      globalRect: globalRect,
      hitTest: hitTest,
      globalRangeRects: globalRangeRects,
      activeCaretGeometry: activeCaretGeometry,
    );
  }

  /// Removes a selection host only when [owner] still owns it.
  void unregisterSelectionHost(String blockId, Object owner) {
    if (identical(_selectionHosts[blockId]?.owner, owner)) {
      _selectionHosts.remove(blockId);
    }
  }

  /// Retargets once to the final selection head and resumes platform input.
  bool endSelectionDrag() {
    if (!_selectionDragActive) return false;
    _selectionDragActive = false;
    final retargeted = _retargetActiveHost();
    widget.inputSession.resumeDeltas();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
    return retargeted;
  }

  /// Registers the current mounted command capability for [blockId].
  void registerCommandHost(
    String blockId,
    HomericTextInputCommandDelegate delegate,
  ) {
    _commandHosts[blockId] = delegate;
  }

  /// Removes [delegate] only when it is still the current host capability.
  void unregisterCommandHost(
    String blockId,
    HomericTextInputCommandDelegate delegate,
  ) {
    if (identical(_commandHosts[blockId], delegate)) {
      _commandHosts.remove(blockId);
    }
  }

  /// Attaches platform input through the document-owned host capability.
  bool attachCommandHost(
    String blockId,
    HomericTextInputCommandDelegate delegate,
  ) {
    registerCommandHost(blockId, delegate);
    if (widget.controller.isReadOnly) return false;
    return widget.inputSession.attach(
      blockId: blockId,
      commandDelegate: delegate,
    );
  }

  /// Whether [blockId] can move through any reorder surface right now.
  bool canReorderBlock(String blockId) {
    final document = widget.controller.document;
    if (widget.controller.isReadOnly ||
        document.indexOfBlockId(blockId) == null ||
        widget.controller.composing != null) {
      return false;
    }
    final selection = widget.controller.selection;
    if (selection == null) return false;
    final anchor = document.resolve(selection.anchor);
    final head = document.resolve(selection.head);
    return anchor is InlinePosition &&
        head is InlinePosition &&
        anchor.blockIndex == head.blockIndex;
  }

  /// Whether any mounted paragraph currently owns the editing focus.
  bool get hasEditingFocus =>
      _mountedFocusNodes.values.any((focusNode) => focusNode.hasFocus);

  /// Stable id of the mounted paragraph that currently owns focus.
  String? get focusedBlockId {
    for (final entry in _mountedFocusNodes.entries) {
      if (entry.value.hasFocus) return entry.key;
    }
    return null;
  }

  /// Current generation-stamped active caret, or `null` while unavailable.
  HomericActiveCaretGeometry? get activeCaretGeometry {
    final blockId = widget.controller.activeBlockId;
    return blockId == null
        ? null
        : _selectionHosts[blockId]?.activeCaretGeometry();
  }

  /// Current mounted selection rectangles in global coordinates.
  ///
  /// Returns an empty list while any selected mounted fragment has stale
  /// layout geometry. Recycled off-screen blocks do not contribute until they
  /// are mounted; callers must treat this as an ephemeral viewport capability,
  /// not a complete document measurement.
  List<Rect> get globalSelectionRects {
    final selection = widget.controller.selection;
    if (selection == null || selection.isCollapsed) return const <Rect>[];
    final rects = <Rect>[];
    for (final block in widget.controller.document.blocks) {
      final host = _selectionHosts[block.id];
      if (host == null) continue;
      final fragment = selectionFragmentForBlock(block.id);
      if (fragment == null || fragment.isCollapsed) continue;
      final current = host.globalRangeRects(
        BlockTextRange(fragment.start, fragment.end),
      );
      if (current == null) return const <Rect>[];
      rects.addAll(current);
    }
    return List<Rect>.unmodifiable(rects);
  }

  /// Whether both directional endpoints resolve inside one block.
  bool get selectionIsBlockLocal {
    final selection = widget.controller.selection;
    if (selection == null) return false;
    final document = widget.controller.document;
    final anchor = document.resolve(selection.anchor);
    final head = document.resolve(selection.head);
    return anchor is InlinePosition &&
        head is InlinePosition &&
        anchor.blockIndex == head.blockIndex;
  }

  /// Returns this row's directional intersection with the global selection.
  BlockTextSelection? selectionFragmentForBlock(String blockId) {
    final selection = widget.controller.selection;
    final document = widget.controller.document;
    final index = document.indexOfBlockId(blockId);
    if (selection == null || index == null) return null;
    final block = document.blocks[index];
    final contentStart = document.positionAt(index, 0);
    final contentEnd = document.positionAt(index, block.contentLength);
    if (selection.isCollapsed) {
      final head = document.resolve(selection.head);
      if (head is! InlinePosition || head.block.id != blockId) return null;
      return BlockTextSelection.collapsed(
        head.offset,
        affinity: selection.affinity,
      );
    }
    if (selection.end < contentStart || selection.start > contentEnd) {
      return null;
    }
    final localStart =
        (selection.start - contentStart).clamp(0, block.contentLength);
    final localEnd =
        (selection.end - contentStart).clamp(0, block.contentLength);
    if (localStart == localEnd &&
        !isBlockFullySelected(blockId) &&
        block.contentLength != 0) {
      final head = document.resolve(selection.head);
      if (head is! InlinePosition || head.block.id != blockId) return null;
      return BlockTextSelection.collapsed(
        head.offset,
        affinity: selection.affinity,
      );
    }
    return selection.anchor <= selection.head
        ? BlockTextSelection(
            anchor: localStart,
            head: localEnd,
            affinity: selection.affinity,
          )
        : BlockTextSelection(
            anchor: localEnd,
            head: localStart,
            affinity: selection.affinity,
          );
  }

  /// Whether the global range contains the complete structural block span.
  bool isBlockFullySelected(String blockId) {
    final selection = widget.controller.selection;
    final document = widget.controller.document;
    final index = document.indexOfBlockId(blockId);
    return selection != null &&
        !selection.isCollapsed &&
        index != null &&
        selection.start <= document.positionBeforeBlock(index) &&
        selection.end >= document.positionAfterBlock(index);
  }

  /// Moves or extends a cross-block selection from its logical head.
  bool moveDocumentSelection(
    CaretMovementDirection direction, {
    required bool extend,
  }) {
    final selection = widget.controller.selection;
    if (selection == null) return false;
    if (!extend && !selection.isCollapsed) {
      final target = direction == CaretMovementDirection.left ||
              direction == CaretMovementDirection.up
          ? selection.start
          : selection.end;
      return _setDocumentSelection(
        target,
        target,
        affinity: direction == CaretMovementDirection.left ||
                direction == CaretMovementDirection.up
            ? HomericCaretAffinity.upstream
            : HomericCaretAffinity.downstream,
        resetPreferredX: true,
      );
    }
    final head = widget.controller.document.resolve(selection.head);
    if (head is! InlinePosition) return false;
    return moveAcrossBlockBoundary(
      head.block.id,
      direction,
      extend: extend,
    );
  }

  /// Crosses from [blockId] to the adjacent block in [direction].
  bool moveAcrossBlockBoundary(
    String blockId,
    CaretMovementDirection direction, {
    required bool extend,
    double? preferredX,
  }) {
    final document = widget.controller.document;
    final sourceIndex = document.indexOfBlockId(blockId);
    final selection = widget.controller.selection;
    if (sourceIndex == null || selection == null) return false;
    final backward = direction == CaretMovementDirection.left ||
        direction == CaretMovementDirection.up;
    final targetIndex = sourceIndex + (backward ? -1 : 1);
    if (targetIndex < 0 || targetIndex >= document.blockCount) return false;
    final targetOffset =
        backward ? document.blocks[targetIndex].contentLength : 0;
    final target = document.positionAt(targetIndex, targetOffset);
    return _setDocumentSelection(
      extend ? selection.anchor : target,
      target,
      affinity: backward
          ? HomericCaretAffinity.upstream
          : HomericCaretAffinity.downstream,
      preferredX: direction == CaretMovementDirection.up ||
              direction == CaretMovementDirection.down
          ? preferredX ?? widget.controller.preferredX
          : null,
      resetPreferredX: direction == CaretMovementDirection.left ||
          direction == CaretMovementDirection.right,
    );
  }

  /// Moves only the global head to [offset] inside [blockId].
  bool setSelectionHead(
    String blockId,
    int offset, {
    required HomericCaretAffinity affinity,
    double? preferredX,
    bool resetPreferredX = false,
  }) {
    final selection = widget.controller.selection;
    final index = widget.controller.document.indexOfBlockId(blockId);
    if (selection == null || index == null) return false;
    return _setDocumentSelection(
      selection.anchor,
      widget.controller.document.positionAt(index, offset),
      affinity: affinity,
      preferredX: preferredX,
      resetPreferredX: resetPreferredX,
    );
  }

  /// Moves or extends to the canonical start/end of the whole document.
  bool moveToDocumentBoundary({
    required bool forward,
    required bool extend,
  }) {
    final selection = widget.controller.selection;
    if (selection == null) return false;
    final document = widget.controller.document;
    final lastIndex = document.blockCount - 1;
    final target = forward
        ? document.positionAt(
            lastIndex,
            document.blocks[lastIndex].contentLength,
          )
        : document.positionAt(0, 0);
    return _setDocumentSelection(
      extend ? selection.anchor : target,
      target,
      affinity: forward
          ? HomericCaretAffinity.downstream
          : HomericCaretAffinity.upstream,
      resetPreferredX: true,
    );
  }

  /// Selects from the first block's start through the last block's end.
  bool selectAll() => _setDocumentSelection(
        widget.controller.document.positionAt(0, 0),
        widget.controller.document.positionAt(
          widget.controller.document.blockCount - 1,
          widget.controller.document.blocks.last.contentLength,
        ),
        affinity: HomericCaretAffinity.downstream,
        resetPreferredX: true,
      );

  bool _setDocumentSelection(
    int anchor,
    int head, {
    required HomericCaretAffinity affinity,
    double? preferredX,
    bool resetPreferredX = false,
  }) {
    final changed = widget.controller.setSelection(
      HomericSelection(anchor: anchor, head: head, affinity: affinity),
      preferredX: preferredX,
      resetPreferredX: resetPreferredX,
    );
    if (!changed) return false;
    final resolved = widget.controller.document.resolve(head);
    if (resolved is InlinePosition) _focusBlock(resolved.block.id);
    return true;
  }

  void _focusBlock(String blockId) {
    unawaited(settleFocusOnBlock(blockId));
  }

  /// Scrolls and settles focus on [blockId] without replacing editor state.
  Future<HomericFocusSettlementResult> settleFocusOnBlock(
    String blockId,
  ) async {
    if (widget.controller.document.indexOfBlockId(blockId) == null) {
      return HomericFocusSettlementResult.missing;
    }
    final generation = ++_focusRequestGeneration;
    final mountedFocus = _mountedFocusNodes[blockId];
    if (mountedFocus != null) {
      mountedFocus.requestFocus();
      return HomericFocusSettlementResult.focused;
    }
    final result = await scrollToBlock(blockId);
    if (!mounted ||
        generation != _focusRequestGeneration ||
        widget.controller.document.indexOfBlockId(blockId) == null) {
      return HomericFocusSettlementResult.stale;
    }
    if (result != HomericScrollToBlockResult.reached) {
      return switch (result) {
        HomericScrollToBlockResult.missing =>
          HomericFocusSettlementResult.missing,
        HomericScrollToBlockResult.stale => HomericFocusSettlementResult.stale,
        _ => HomericFocusSettlementResult.notReached,
      };
    }
    final focusNode = _mountedFocusNodes[blockId];
    if (focusNode == null) return HomericFocusSettlementResult.notReached;
    focusNode.requestFocus();
    return HomericFocusSettlementResult.focused;
  }

  /// Moves the active selection block by [delta] through the shared command.
  bool moveActiveBlock(int delta) {
    final blockId = widget.controller.activeBlockId;
    return blockId != null && moveBlockBy(blockId, delta);
  }

  /// Moves [blockId] by [delta] through one stale-safe controller request.
  bool moveBlockBy(String blockId, int delta) {
    if (!canReorderBlock(blockId) || delta == 0) return false;
    final document = widget.controller.document;
    final sourceIndex = document.indexOfBlockId(blockId);
    if (sourceIndex == null) return false;
    final targetIndex = sourceIndex + delta;
    if (targetIndex < 0 || targetIndex >= document.blockCount) return false;
    return _moveBlock(
      _captureMoveWitness(sourceIndex),
      targetIndex,
    );
  }

  Future<HomericScrollToBlockResult> scrollToBlock(String blockId) async {
    final revision = widget.controller.documentRevision;
    final index = widget.controller.document.indexOfBlockId(blockId);
    if (index == null) return HomericScrollToBlockResult.missing;
    if (!_scrollController.hasClients) {
      return HomericScrollToBlockResult.notReached;
    }
    for (var attempt = 0; attempt < 8; attempt++) {
      if (revision != widget.controller.documentRevision) {
        return HomericScrollToBlockResult.stale;
      }
      final position = _scrollController.position;
      final target = _heightCache
          .offsetBefore(index)
          .clamp(position.minScrollExtent, position.maxScrollExtent);
      _scrollController.jumpTo(target);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || revision != widget.controller.documentRevision) {
        return HomericScrollToBlockResult.stale;
      }
      final rowContext = _mountedRows[blockId];
      if (rowContext != null && rowContext.mounted) {
        await Scrollable.ensureVisible(rowContext, alignment: 0.5);
        return HomericScrollToBlockResult.reached;
      }
    }
    return HomericScrollToBlockResult.notReached;
  }

  void _controllerChanged() {
    if (_selectionDragAnchor != null &&
        widget.controller.documentRevision != _selectionDragDocumentRevision) {
      cancelPointerSelectionDrag();
    }
    final documentChanged =
        widget.controller.documentRevision != _heightOrderDocumentRevision;
    _syncOrder();
    final semanticsChanged = _captureSemanticsState();
    if ((documentChanged || semanticsChanged) && mounted) setState(() {});
    if (widget.controller.isReadOnly) {
      widget.inputSession.blur();
      return;
    }
    if (_selectionDragActive || !widget.inputSession.isAttached) return;
    final activeBlockId = widget.controller.activeBlockId;
    if (activeBlockId == widget.inputSession.activeBlockId) return;
    if (activeBlockId == null ||
        widget.controller.document.indexOfBlockId(activeBlockId) == null) {
      widget.inputSession.blur();
      return;
    }
    if (!_retargetActiveHost()) _scheduleActiveHostSettlement(activeBlockId);
  }

  void _scheduleActiveHostSettlement(String blockId) {
    final generation = ++_focusRequestGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted ||
          generation != _focusRequestGeneration ||
          widget.controller.activeBlockId != blockId) {
        return;
      }
      if (_retargetActiveHost()) return;
      final result = await scrollToBlock(blockId);
      if (!mounted ||
          generation != _focusRequestGeneration ||
          widget.controller.activeBlockId != blockId ||
          result != HomericScrollToBlockResult.reached) {
        return;
      }
      _retargetActiveHost();
    });
  }

  bool _captureSemanticsState() {
    final selection = widget.controller.selection;
    final composing = widget.controller.composing;
    final canUndo = widget.controller.canUndo;
    final canRedo = widget.controller.canRedo;
    final readOnly = widget.controller.isReadOnly;
    final changed = selection != _semanticsSelection ||
        composing != _semanticsComposing ||
        canUndo != _semanticsCanUndo ||
        canRedo != _semanticsCanRedo ||
        readOnly != _semanticsReadOnly;
    _semanticsSelection = selection;
    _semanticsComposing = composing;
    _semanticsCanUndo = canUndo;
    _semanticsCanRedo = canRedo;
    _semanticsReadOnly = readOnly;
    return changed;
  }

  void _updatePointerSelectionHead(Offset globalPoint) {
    final anchor = _selectionDragAnchor;
    if (anchor == null) return;
    final candidates =
        <({String blockId, Rect rect, _MountedSelectionHost host})>[];
    for (final entry in _selectionHosts.entries) {
      final rect = entry.value.globalRect();
      if (rect != null) {
        candidates.add((blockId: entry.key, rect: rect, host: entry.value));
      }
    }
    if (candidates.isEmpty) return;
    candidates.sort((a, b) => a.rect.top.compareTo(b.rect.top));
    var target = candidates.first;
    for (final candidate in candidates) {
      if (candidate.rect.contains(globalPoint)) {
        target = candidate;
        break;
      }
      if (globalPoint.dy >= candidate.rect.top) target = candidate;
    }
    final clampedPoint = Offset(
      globalPoint.dx.clamp(target.rect.left, target.rect.right),
      globalPoint.dy.clamp(target.rect.top, target.rect.bottom),
    );
    final hit = target.host.hitTest(clampedPoint);
    if (hit == null) return;
    final head = widget.controller.globalPositionForBlockOffset(
      target.blockId,
      hit.offset,
    );
    widget.controller.setSelection(HomericSelection(
      anchor: anchor,
      head: head,
      affinity: hit.affinity,
    ));
  }

  void _syncSelectionAutoscroll(Offset globalPoint) {
    if (!_scrollController.hasClients) return;
    final render = context.findRenderObject();
    if (render is! RenderBox || !render.attached) return;
    final viewport = render.localToGlobal(Offset.zero) & render.size;
    const edge = 36.0;
    final direction = globalPoint.dy < viewport.top + edge
        ? -1
        : globalPoint.dy > viewport.bottom - edge
            ? 1
            : 0;
    if (direction == 0) {
      _stopSelectionAutoscroll();
      return;
    }
    if (_selectionAutoScrollTimer != null &&
        direction == _selectionAutoScrollDirection) {
      return;
    }
    _stopSelectionAutoscroll();
    final generation = _selectionDragGeneration;
    _selectionAutoScrollDirection = direction;
    _selectionAutoScrollTimer = Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _selectionAutoscrollTick(generation, direction),
    );
  }

  void _selectionAutoscrollTick(int generation, int direction) {
    if (!mounted ||
        generation != _selectionDragGeneration ||
        !_selectionDragActive ||
        !_scrollController.hasClients ||
        widget.controller.documentRevision != _selectionDragDocumentRevision) {
      _stopSelectionAutoscroll();
      return;
    }
    final position = _scrollController.position;
    final target = (_scrollController.offset + direction * 12)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((target - _scrollController.offset).abs() < 0.5) {
      _stopSelectionAutoscroll();
      return;
    }
    _scrollController.jumpTo(target);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final pointer = _selectionDragPointer;
      if (!mounted ||
          generation != _selectionDragGeneration ||
          pointer == null) {
        return;
      }
      _updatePointerSelectionHead(pointer);
    });
  }

  void _stopSelectionAutoscroll() {
    _selectionAutoScrollTimer?.cancel();
    _selectionAutoScrollTimer = null;
    _selectionAutoScrollDirection = 0;
  }

  bool _retargetActiveHost() {
    final blockId = widget.controller.activeBlockId;
    if (blockId == null) return false;
    final delegate = _commandHosts[blockId];
    if (delegate == null) return false;
    _mountedFocusNodes[blockId]?.requestFocus();
    return widget.inputSession.retarget(
      blockId: blockId,
      commandDelegate: delegate,
    );
  }

  _BlockMoveWitness _captureMoveWitness(int sourceIndex) {
    final document = widget.controller.document;
    return _BlockMoveWitness(
      blockId: document.blocks[sourceIndex].id,
      documentRevision: widget.controller.documentRevision,
      previousBlockId:
          sourceIndex == 0 ? null : document.blocks[sourceIndex - 1].id,
      nextBlockId: sourceIndex == document.blockCount - 1
          ? null
          : document.blocks[sourceIndex + 1].id,
    );
  }

  void _reorderStarted(int index) {
    if (index < 0 || index >= widget.controller.document.blockCount) return;
    final witness = _captureMoveWitness(index);
    _dragMoveWitness = canReorderBlock(witness.blockId) ? witness : null;
  }

  void _reorderEnded(int _) => _dragMoveWitness = null;

  void _reorder(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= widget.controller.document.blockCount) {
      _dragMoveWitness = null;
      return;
    }
    final witness = _dragMoveWitness ?? _captureMoveWitness(oldIndex);
    _dragMoveWitness = null;
    final targetIndex = newIndex > oldIndex ? newIndex - 1 : newIndex;
    _moveBlock(witness, targetIndex);
  }

  bool _moveBlock(_BlockMoveWitness witness, int targetIndex) {
    if (!canReorderBlock(witness.blockId)) return false;
    final anchor = _captureViewportAnchor(witness.blockId);
    final moved = widget.controller.moveBlock(BlockMoveRequest(
      blockId: witness.blockId,
      targetIndex: targetIndex,
      documentRevision: witness.documentRevision,
      previousBlockId: witness.previousBlockId,
      nextBlockId: witness.nextBlockId,
    ));
    if (!moved) return false;
    _restoreViewportAnchor(anchor);
    final nextIndex =
        widget.controller.document.indexOfBlockId(witness.blockId);
    if (nextIndex != null) {
      // Flutter 3.24 does not yet expose the multi-view announcement API.
      // ignore: deprecated_member_use
      SemanticsService.announce(
        'Moved block to position ${nextIndex + 1}',
        Directionality.of(context),
      );
    }
    return true;
  }

  _ViewportAnchor? _captureViewportAnchor(String movingBlockId) {
    if (!_scrollController.hasClients) return null;
    final index = _heightCache.indexAtOffset(_scrollController.offset);
    if (index == null) return null;
    final blocks = widget.controller.document.blocks;
    var anchorIndex = index;
    if (blocks[index].id == movingBlockId && blocks.length > 1) {
      anchorIndex = index + 1 < blocks.length ? index + 1 : index - 1;
    }
    return _ViewportAnchor(
      blocks[anchorIndex].id,
      _scrollController.offset - _heightCache.offsetBefore(anchorIndex),
    );
  }

  void _restoreViewportAnchor(_ViewportAnchor? anchor) {
    if (anchor == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final index = widget.controller.document.indexOfBlockId(anchor.blockId);
      if (index == null) return;
      final position = _scrollController.position;
      final target =
          (_heightCache.offsetBefore(index) + anchor.intraBlockOffset)
              .clamp(position.minScrollExtent, position.maxScrollExtent);
      if ((_scrollController.offset - target).abs() > 0.5) {
        _scrollController.jumpTo(target);
      }
    });
  }

  GlobalKey _rowKeyFor(String blockId) {
    final existing = _rowKeys[blockId];
    if (existing != null) return existing;
    final key = GlobalKey(debugLabel: 'homeric-block-$blockId');
    _rowKeys[blockId] = key;
    _blockIdsByRowKey[key] = blockId;
    return key;
  }

  void _releaseRowKeyWhenUnused(String blockId) {
    final key = _rowKeys[blockId];
    if (key == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !identical(_rowKeys[blockId], key) ||
          key.currentContext != null ||
          widget.controller.activeBlockId == blockId) {
        return;
      }
      _rowKeys.remove(blockId);
      _blockIdsByRowKey.remove(key);
    });
  }

  void _validateSession() {
    if (!identical(widget.controller, widget.inputSession.controller)) {
      throw ArgumentError('inputSession must observe controller');
    }
  }

  bool _syncOrder({bool force = false}) {
    final documentRevision = widget.controller.documentRevision;
    if (!force && documentRevision == _heightOrderDocumentRevision) {
      return false;
    }
    final contentRevision = widget.controller.contentRevision;
    final document = widget.controller.document;
    final previousDocument = _heightOrderDocument;
    final activeBlockId = widget.controller.activeBlockId;
    final expectedActiveIndex =
        activeBlockId == null ? null : _heightCache.indexOf(activeBlockId);
    final blockLocalContentChange = !force &&
        contentRevision != _heightOrderContentRevision &&
        previousDocument != null &&
        document.blockCount == _heightCache.length &&
        expectedActiveIndex != null &&
        document.blocks[expectedActiveIndex].id == activeBlockId &&
        _onlyActiveBlockChanged(
          previousDocument,
          document,
          expectedActiveIndex,
        );
    _heightOrderDocumentRevision = documentRevision;
    _heightOrderContentRevision = contentRevision;
    _heightOrderDocument = document;
    if (blockLocalContentChange) return false;
    final blockIds = document.blocks.map((block) => block.id).toList();
    _heightCache.replaceOrder(blockIds);
    _paragraphLayoutCache.retainKeys(blockIds.toSet());
    _heightOrderRebuildCount++;
    return true;
  }

  bool _onlyActiveBlockChanged(
    Document before,
    Document after,
    int activeIndex,
  ) {
    if (before.blockCount != after.blockCount ||
        identical(before.blocks[activeIndex], after.blocks[activeIndex]) ||
        before.blocks[activeIndex].id != after.blocks[activeIndex].id) {
      return false;
    }
    for (var index = 0; index < after.blockCount; index++) {
      if (index != activeIndex &&
          !identical(before.blocks[index], after.blocks[index])) {
        return false;
      }
    }
    return true;
  }

  void _recordHeight(BlockHeightWitness witness, double height) {
    final anchorIndex = _scrollController.hasClients
        ? _heightCache.indexAtOffset(_scrollController.offset)
        : null;
    final change = _heightCache.record(witness, height);
    if (change == null ||
        anchorIndex == null ||
        change.index >= anchorIndex ||
        !_scrollController.hasClients ||
        _scrollController.position.isScrollingNotifier.value) {
      return;
    }
    _pendingAnchorCorrection += change.delta;
    if (_anchorCorrectionScheduled) return;
    _anchorCorrectionScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _anchorCorrectionScheduled = false;
      final correction = _pendingAnchorCorrection;
      _pendingAnchorCorrection = 0;
      if (!mounted ||
          correction == 0 ||
          !_scrollController.hasClients ||
          _scrollController.position.isScrollingNotifier.value) {
        return;
      }
      final position = _scrollController.position;
      _scrollController.jumpTo(
        (_scrollController.offset + correction)
            .clamp(position.minScrollExtent, position.maxScrollExtent),
      );
    });
  }

  @override
  void dispose() {
    _stopSelectionAutoscroll();
    FocusManager.instance.removeListener(_focusTreeChanged);
    widget.controller.removeListener(_controllerChanged);
    if (_selectionDragActive) widget.inputSession.resumeDeltas();
    _commandHosts.clear();
    _mountedRows.clear();
    _mountedFocusNodes.clear();
    _selectionHosts.clear();
    _paragraphLayoutCache.dispose();
    _rowKeys.clear();
    _blockIdsByRowKey.clear();
    if (widget.scrollController == null) _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final child = widget.child;
    return _HomericEditableDocumentScope(
      state: this,
      child: child ??
          LayoutBuilder(
            builder: (context, constraints) {
              final listenable = widget.scrollPadding;
              if (listenable == null) {
                return _buildViewport(
                  context,
                  constraints,
                  widget.padding,
                );
              }
              return ValueListenableBuilder<EdgeInsetsGeometry>(
                valueListenable: listenable,
                builder: (context, padding, _) =>
                    _buildViewport(context, constraints, padding),
              );
            },
          ),
    );
  }

  Widget _buildViewport(
    BuildContext context,
    BoxConstraints constraints,
    EdgeInsetsGeometry padding,
  ) {
    _layoutWidth = constraints.maxWidth;
    final globalLayoutSignature = (_layoutWidth, widget.layoutRevision);
    if (_globalLayoutSignature != globalLayoutSignature) {
      _globalLayoutSignature = globalLayoutSignature;
      _heightCache.invalidateAll();
    }
    final document = widget.controller.document;
    final documentActions = <CustomSemanticsAction, VoidCallback>{
      if (widget.controller.selection != null &&
          widget.controller.composing == null)
        _documentSelectAllSemanticsAction: selectAll,
      if (!widget.controller.isReadOnly && widget.controller.canUndo)
        _documentUndoSemanticsAction: widget.controller.undo,
      if (!widget.controller.isReadOnly && widget.controller.canRedo)
        _documentRedoSemanticsAction: widget.controller.redo,
    };
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: 'Document editor, ${document.blockCount} blocks',
      customSemanticsActions: documentActions,
      child: CustomScrollView(
        controller: _scrollController,
        // Flutter 3.24 minimum predates scrollCacheExtent.
        // ignore: deprecated_member_use
        cacheExtent: widget.cacheExtent,
        slivers: <Widget>[
          SliverPadding(
            padding: padding,
            sliver: SliverReorderableList(
              itemCount: document.blockCount,
              findChildIndexCallback: (key) {
                final stableKey = key is GlobalObjectKey && key.value is Key
                    ? key.value as Key
                    : key;
                final blockId = stableKey is GlobalKey
                    ? _blockIdsByRowKey[stableKey]
                    : stableKey is ValueKey<String>
                        ? stableKey.value
                        : null;
                return blockId == null
                    ? null
                    : widget.controller.document.indexOfBlockId(blockId);
              },
              // Flutter 3.24 exposes only this callback.
              // ignore: deprecated_member_use
              onReorder: _reorder,
              onReorderStart: _reorderStarted,
              onReorderEnd: _reorderEnded,
              proxyDecorator: (child, _, __) => MouseRegion(
                cursor: SystemMouseCursors.grabbing,
                child: child,
              ),
              itemBuilder: (context, index) {
                final block = document.blocks[index];
                final witness = _heightCache.prepareMeasurement(
                  blockId: block.id,
                  documentRevision: widget.controller.documentRevision,
                  layoutSignature: (block, _layoutWidth, widget.layoutRevision),
                );
                return _DocumentBlockRow(
                  key: _rowKeyFor(block.id),
                  controller: widget.controller,
                  block: block,
                  index: index,
                  totalCount: document.blockCount,
                  builder: widget.blockBuilder!,
                  paragraphLayoutCache: _paragraphLayoutCache,
                  witness: witness,
                  keepAlive: () =>
                      widget.controller.activeBlockId == block.id ||
                      (_selectionDragActive &&
                          widget.inputSession.activeBlockId == block.id),
                  canReorder: () => canReorderBlock(block.id),
                  onMove: (delta) => moveBlockBy(block.id, delta),
                  onHeight: _recordHeight,
                  onMount: (context, focusNode) {
                    _mountedRows[block.id] = context;
                    _mountedFocusNodes[block.id] = focusNode;
                  },
                  onUnmount: (context, focusNode) {
                    if (identical(_mountedRows[block.id], context)) {
                      _mountedRows.remove(block.id);
                    }
                    if (identical(_mountedFocusNodes[block.id], focusNode)) {
                      _mountedFocusNodes.remove(block.id);
                    }
                    _releaseRowKeyWhenUnused(block.id);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _HomericEditableDocumentScope extends InheritedWidget {
  const _HomericEditableDocumentScope({
    required this.state,
    required super.child,
  });

  final HomericEditableDocumentState state;

  @override
  bool updateShouldNotify(_HomericEditableDocumentScope oldWidget) =>
      !identical(state, oldWidget.state);
}

final class _BlockMoveWitness {
  const _BlockMoveWitness({
    required this.blockId,
    required this.documentRevision,
    required this.previousBlockId,
    required this.nextBlockId,
  });

  final String blockId;
  final int documentRevision;
  final String? previousBlockId;
  final String? nextBlockId;
}

final class _MountedSelectionHost {
  const _MountedSelectionHost({
    required this.owner,
    required this.globalRect,
    required this.hitTest,
    required this.globalRangeRects,
    required this.activeCaretGeometry,
  });

  final Object owner;
  final Rect? Function() globalRect;
  final HomericDocumentSelectionHitTest hitTest;
  final List<Rect>? Function(BlockTextRange range) globalRangeRects;
  final HomericActiveCaretGeometry? Function() activeCaretGeometry;
}

final class _ViewportAnchor {
  const _ViewportAnchor(this.blockId, this.intraBlockOffset);

  final String blockId;
  final double intraBlockOffset;
}

class _DocumentBlockRow extends StatefulWidget {
  const _DocumentBlockRow({
    super.key,
    required this.controller,
    required this.block,
    required this.index,
    required this.totalCount,
    required this.builder,
    required this.paragraphLayoutCache,
    required this.witness,
    required this.keepAlive,
    required this.canReorder,
    required this.onMove,
    required this.onHeight,
    required this.onMount,
    required this.onUnmount,
  });

  final HomericEditorController controller;
  final Block block;
  final int index;
  final int totalCount;
  final HomericEditableBlockBuilder builder;
  final HomericParagraphLayoutCache paragraphLayoutCache;
  final BlockHeightWitness witness;
  final ValueGetter<bool> keepAlive;
  final ValueGetter<bool> canReorder;
  final ValueChanged<int> onMove;
  final void Function(BlockHeightWitness witness, double height) onHeight;
  final void Function(BuildContext context, FocusNode focusNode) onMount;
  final void Function(BuildContext context, FocusNode focusNode) onUnmount;

  @override
  State<_DocumentBlockRow> createState() => _DocumentBlockRowState();
}

class _DocumentBlockRowState extends State<_DocumentBlockRow>
    with AutomaticKeepAliveClientMixin<_DocumentBlockRow> {
  late final FocusNode _focusNode = FocusNode();

  @override
  bool get wantKeepAlive => widget.keepAlive();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_controllerChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    widget.onMount(context, _focusNode);
  }

  @override
  void didUpdateWidget(_DocumentBlockRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_controllerChanged);
      widget.controller.addListener(_controllerChanged);
    }
    updateKeepAlive();
  }

  void _controllerChanged() {
    updateKeepAlive();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.onUnmount(context, _focusNode);
    widget.controller.removeListener(_controllerChanged);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final inheritedColor =
        DefaultTextStyle.of(context).style.color ?? const Color(0xFF000000);
    final canReorder = widget.canReorder();
    final canMoveUp = canReorder && widget.index > 0;
    final canMoveDown = canReorder && widget.index + 1 < widget.totalCount;
    final actions = <CustomSemanticsAction, VoidCallback>{
      if (canMoveUp)
        const CustomSemanticsAction(label: 'Move block up'): () {
          widget.onMove(-1);
        },
      if (canMoveDown)
        const CustomSemanticsAction(label: 'Move block down'): () {
          widget.onMove(1);
        },
    };
    return _MeasureNaturalHeight(
      witness: widget.witness,
      onHeight: widget.onHeight,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Semantics(
            container: true,
            excludeSemantics: true,
            button: true,
            enabled: canReorder,
            label:
                'Move block, block ${widget.index + 1} of ${widget.totalCount}',
            customSemanticsActions: actions,
            child: ReorderableDragStartListener(
              index: widget.index,
              enabled: canReorder,
              child: MouseRegion(
                cursor:
                    canReorder ? SystemMouseCursors.grab : MouseCursor.defer,
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Center(
                    child: Text(
                      '⋮',
                      style: TextStyle(color: inheritedColor.withAlpha(255)),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: HomericParagraphLayoutCacheScope(
              cache: widget.paragraphLayoutCache,
              cacheKey: widget.block.id,
              child: widget.builder(context, widget.block, _focusNode),
            ),
          ),
        ],
      ),
    );
  }
}

class _MeasureNaturalHeight extends SingleChildRenderObjectWidget {
  const _MeasureNaturalHeight({
    required this.witness,
    required this.onHeight,
    required super.child,
  });

  final BlockHeightWitness witness;
  final void Function(BlockHeightWitness witness, double height) onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasureNaturalHeight(witness, onHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderMeasureNaturalHeight renderObject,
  ) {
    renderObject
      ..witness = witness
      ..onHeight = onHeight;
  }
}

class _RenderMeasureNaturalHeight extends RenderProxyBox {
  _RenderMeasureNaturalHeight(this.witness, this.onHeight);

  BlockHeightWitness witness;
  void Function(BlockHeightWitness witness, double height) onHeight;

  @override
  void performLayout() {
    super.performLayout();
    final currentWitness = witness;
    final height = size.height;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      onHeight(currentWitness, height);
    });
  }
}
