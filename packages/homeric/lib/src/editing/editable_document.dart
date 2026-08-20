/// Experimental document-owned editing coordination.
library;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../input/text_input_session.dart';
import '../model/block.dart';
import '../model/position.dart';
import 'block_height_cache.dart';
import 'editor_controller.dart';

typedef HomericEditableBlockBuilder = Widget Function(
  BuildContext context,
  Block block,
  FocusNode focusNode,
);

enum HomericScrollToBlockResult { reached, missing, stale, notReached }

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
  final Map<String, GlobalKey> _rowKeys = <String, GlobalKey>{};
  final Map<GlobalKey, String> _blockIdsByRowKey = <GlobalKey, String>{};
  late BlockHeightCache _heightCache;
  late ScrollController _scrollController;
  double _layoutWidth = 0;
  double _pendingAnchorCorrection = 0;
  bool _anchorCorrectionScheduled = false;
  int _heightOrderRevision = -1;
  Object? _globalLayoutSignature;
  _BlockMoveWitness? _dragMoveWitness;

  @override
  void initState() {
    super.initState();
    _validateSession();
    _heightCache = BlockHeightCache(
      estimatedHeight: widget.estimatedBlockHeight,
    );
    _scrollController = widget.scrollController ?? ScrollController();
    _syncOrder(force: true);
    widget.controller.addListener(_controllerChanged);
  }

  @override
  void didUpdateWidget(HomericEditableDocument oldWidget) {
    super.didUpdateWidget(oldWidget);
    _validateSession();
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_controllerChanged);
      widget.controller.addListener(_controllerChanged);
      _syncOrder(force: true);
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
  void beginSelectionDrag() {
    if (_selectionDragActive) return;
    _selectionDragActive = true;
    widget.inputSession.suspendDeltas();
  }

  /// Retargets once to the final selection head and resumes platform input.
  bool endSelectionDrag() {
    if (!_selectionDragActive) return false;
    _selectionDragActive = false;
    final retargeted = _retargetActiveHost();
    widget.inputSession.resumeDeltas();
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
    return widget.inputSession.attach(
      blockId: blockId,
      commandDelegate: delegate,
    );
  }

  /// Whether [blockId] can move through any reorder surface right now.
  bool canReorderBlock(String blockId) {
    final document = widget.controller.document;
    if (document.indexOfBlockId(blockId) == null ||
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
    final documentChanged = _syncOrder();
    if (documentChanged && mounted) setState(() {});
    if (_selectionDragActive || !widget.inputSession.isAttached) return;
    final activeBlockId = widget.controller.activeBlockId;
    if (activeBlockId == widget.inputSession.activeBlockId) return;
    if (activeBlockId == null ||
        widget.controller.document.indexOfBlockId(activeBlockId) == null) {
      widget.inputSession.blur();
      return;
    }
    _retargetActiveHost();
  }

  bool _retargetActiveHost() {
    final blockId = widget.controller.activeBlockId;
    if (blockId == null) return false;
    final delegate = _commandHosts[blockId];
    if (delegate == null) return false;
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
    final revision = widget.controller.documentRevision;
    if (!force && revision == _heightOrderRevision) return false;
    _heightCache.replaceOrder(
      widget.controller.document.blocks.map((block) => block.id).toList(),
    );
    _heightOrderRevision = revision;
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
    widget.controller.removeListener(_controllerChanged);
    if (_selectionDragActive) widget.inputSession.resumeDeltas();
    _commandHosts.clear();
    _mountedRows.clear();
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
      child: child ?? LayoutBuilder(builder: _buildViewport),
    );
  }

  Widget _buildViewport(BuildContext context, BoxConstraints constraints) {
    _layoutWidth = constraints.maxWidth;
    final globalLayoutSignature = (_layoutWidth, widget.layoutRevision);
    if (_globalLayoutSignature != globalLayoutSignature) {
      _globalLayoutSignature = globalLayoutSignature;
      _heightCache.invalidateAll();
    }
    final document = widget.controller.document;
    return CustomScrollView(
      controller: _scrollController,
      // Flutter 3.24 minimum predates scrollCacheExtent.
      // ignore: deprecated_member_use
      cacheExtent: widget.cacheExtent,
      slivers: <Widget>[
        SliverPadding(
          padding: widget.padding,
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
                witness: witness,
                canReorder: () => canReorderBlock(block.id),
                onMove: (delta) => moveBlockBy(block.id, delta),
                onHeight: _recordHeight,
                onMount: (context) => _mountedRows[block.id] = context,
                onUnmount: (context) {
                  if (identical(_mountedRows[block.id], context)) {
                    _mountedRows.remove(block.id);
                  }
                  _releaseRowKeyWhenUnused(block.id);
                },
              );
            },
          ),
        ),
      ],
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
    required this.witness,
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
  final BlockHeightWitness witness;
  final ValueGetter<bool> canReorder;
  final ValueChanged<int> onMove;
  final void Function(BlockHeightWitness witness, double height) onHeight;
  final ValueChanged<BuildContext> onMount;
  final ValueChanged<BuildContext> onUnmount;

  @override
  State<_DocumentBlockRow> createState() => _DocumentBlockRowState();
}

class _DocumentBlockRowState extends State<_DocumentBlockRow>
    with AutomaticKeepAliveClientMixin<_DocumentBlockRow> {
  late final FocusNode _focusNode = FocusNode();

  @override
  bool get wantKeepAlive => widget.controller.activeBlockId == widget.block.id;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_controllerChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    widget.onMount(context);
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
    widget.onUnmount(context);
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
          Expanded(child: widget.builder(context, widget.block, _focusNode)),
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
