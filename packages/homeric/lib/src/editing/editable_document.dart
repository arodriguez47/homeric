/// Experimental document-owned editing coordination.
library;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../input/text_input_session.dart';
import '../model/block.dart';
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
  late BlockHeightCache _heightCache;
  late ScrollController _scrollController;
  double _layoutWidth = 0;
  double _pendingAnchorCorrection = 0;
  bool _anchorCorrectionScheduled = false;
  int _heightOrderRevision = -1;
  Object? _globalLayoutSignature;

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
              if (key is! ValueKey<String>) return null;
              return widget.controller.document.indexOfBlockId(key.value);
            },
            // Flutter 3.24 exposes only this callback.
            // ignore: deprecated_member_use
            onReorder: (_, __) {},
            itemBuilder: (context, index) {
              final block = document.blocks[index];
              final witness = _heightCache.prepareMeasurement(
                blockId: block.id,
                documentRevision: widget.controller.documentRevision,
                layoutSignature: (block, _layoutWidth, widget.layoutRevision),
              );
              return _DocumentBlockRow(
                key: ValueKey<String>(block.id),
                controller: widget.controller,
                block: block,
                builder: widget.blockBuilder!,
                witness: witness,
                onHeight: _recordHeight,
                onMount: (context) => _mountedRows[block.id] = context,
                onUnmount: (context) {
                  if (identical(_mountedRows[block.id], context)) {
                    _mountedRows.remove(block.id);
                  }
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

class _DocumentBlockRow extends StatefulWidget {
  const _DocumentBlockRow({
    super.key,
    required this.controller,
    required this.block,
    required this.builder,
    required this.witness,
    required this.onHeight,
    required this.onMount,
    required this.onUnmount,
  });

  final HomericEditorController controller;
  final Block block;
  final HomericEditableBlockBuilder builder;
  final BlockHeightWitness witness;
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

  void _controllerChanged() => updateKeepAlive();

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
    return _MeasureNaturalHeight(
      witness: widget.witness,
      onHeight: widget.onHeight,
      child: widget.builder(context, widget.block, _focusNode),
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
