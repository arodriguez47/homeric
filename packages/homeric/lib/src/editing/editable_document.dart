/// Experimental document-owned editing coordination.
library;

import 'dart:async';

import 'package:flutter/cupertino.dart'
    show cupertinoTextSelectionHandleControls;
import 'package:flutter/foundation.dart'
    show
        TargetPlatform,
        ValueListenable,
        defaultTargetPlatform,
        visibleForTesting;
import 'package:flutter/material.dart'
    show TextMagnifier, materialTextSelectionHandleControls;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show RawFloatingCursorPoint;
import 'package:flutter/widgets.dart';
import 'package:meta/meta.dart' show internal;

import '../input/text_input_session.dart';
import '../model/block.dart';
import '../model/document.dart';
import '../model/position.dart';
import '../model/selection.dart';
import '../render/paragraph_geometry.dart';
import '../render/homeric_paragraph.dart';
import 'block_height_cache.dart';
import 'editor_controller.dart';
import 'selection_overlay.dart';

typedef HomericEditableBlockBuilder = Widget Function(
  BuildContext context,
  Block block,
  FocusNode focusNode,
);

/// Consumer-owned presentation for the document edge grabber.
///
/// Homeric keeps the 44px reorder target and its semantics stable while the
/// consumer chooses how prominently the `⋮` glyph is painted. The default
/// remains fully visible for products that want an explicit affordance;
/// setting [idleOpacity] to zero creates a hover-only desktop handle without
/// changing drag or accessibility behavior.
final class HomericBlockGrabberStyle {
  const HomericBlockGrabberStyle({
    this.idleOpacity = 1,
    this.hoverOpacity = 1,
    this.fadeDuration = const Duration(milliseconds: 100),
    this.textStyle,
  })  : assert(idleOpacity >= 0 && idleOpacity <= 1),
        assert(hoverOpacity >= 0 && hoverOpacity <= 1);

  /// Glyph opacity while the pointer is outside this block's handle.
  final double idleOpacity;

  /// Glyph opacity while the pointer is over this block's handle.
  final double hoverOpacity;

  /// Duration used when moving between idle and hover opacity.
  final Duration fadeDuration;

  /// Optional glyph style merged over the inherited text color.
  final TextStyle? textStyle;
}

/// Platform-adaptive touch-selection policy for an editable host.
final class HomericTouchSelectionConfiguration {
  /// Uses Flutter's mobile controls and magnifier on iOS and Android.
  const HomericTouchSelectionConfiguration.adaptive({
    this.selectionControls,
    this.magnifierConfiguration,
    this.enableOnDesktop = false,
  }) : enabled = true;

  /// Disables touch handles, toolbar, magnifier, and long-press chrome.
  const HomericTouchSelectionConfiguration.disabled()
      : enabled = false,
        selectionControls = null,
        magnifierConfiguration = null,
        enableOnDesktop = false;

  /// Whether touch-selection chrome may be resolved.
  final bool enabled;

  /// Optional consumer controls replacing the platform mobile default.
  final TextSelectionControls? selectionControls;

  /// Optional consumer magnifier replacing Flutter's adaptive default.
  final TextMagnifierConfiguration? magnifierConfiguration;

  /// Opts desktop platforms into touch chrome.
  ///
  /// Desktop opt-in requires explicit [selectionControls] so Homeric never
  /// guesses a consumer's hybrid mouse/touch policy.
  final bool enableOnDesktop;

  /// Resolves this policy for [platform], or returns `null` when disabled.
  HomericResolvedTouchSelectionConfiguration? resolve(
    TargetPlatform platform,
  ) {
    if (!enabled) return null;
    final mobileControls = switch (platform) {
      TargetPlatform.iOS => cupertinoTextSelectionHandleControls,
      TargetPlatform.android => materialTextSelectionHandleControls,
      _ => null,
    };
    final controls = selectionControls ?? mobileControls;
    final isMobile =
        platform == TargetPlatform.iOS || platform == TargetPlatform.android;
    if (controls == null || (!isMobile && !enableOnDesktop)) return null;
    return HomericResolvedTouchSelectionConfiguration(
      selectionControls: controls,
      magnifierConfiguration: magnifierConfiguration ??
          (isMobile
              ? TextMagnifier.adaptiveMagnifierConfiguration
              : TextMagnifierConfiguration.disabled),
    );
  }
}

/// Resolved controls used by one current editable host.
final class HomericResolvedTouchSelectionConfiguration {
  const HomericResolvedTouchSelectionConfiguration({
    required this.selectionControls,
    required this.magnifierConfiguration,
  });

  final TextSelectionControls selectionControls;
  final TextMagnifierConfiguration magnifierConfiguration;
}

/// Epoch-bound context supplied to a document-level command binding.
final class HomericDocumentCommandContext {
  const HomericDocumentCommandContext._({
    required this.document,
    required this.selection,
    required this.composing,
    required this.stateRevision,
    required this.documentRevision,
    required this.blockId,
    required this.hostEpoch,
    required bool Function() isCurrent,
  }) : _isCurrent = isCurrent;

  /// Immutable canonical document captured before the handler runs.
  final Document document;

  /// Directional selection captured before the handler runs.
  final HomericSelection? selection;

  /// Canonical composition captured before the handler runs.
  final HomericTextRange? composing;

  /// Listener-visible state generation captured before the handler runs.
  final int stateRevision;

  /// Canonical document generation captured before the handler runs.
  final int documentRevision;

  /// Stable block id of the paragraph that received the command.
  final String blockId;

  /// Mounted paragraph command generation.
  final int hostEpoch;

  final bool Function() _isCurrent;

  /// Whether this command still belongs to the active mounted host.
  bool get isCurrent => _isCurrent();
}

/// Result returned by a [HomericDocumentCommandHandler].
sealed class HomericDocumentCommandResult {
  const HomericDocumentCommandResult();

  /// Continue through later registrations, then the built-in action.
  static const ignored = HomericDocumentCommandIgnored();

  /// Stop after the consumer handled the command.
  static const handled = HomericDocumentCommandHandled();

  /// Ask the mounted host to apply one already-prepared canonical command.
  static HomericDocumentCommandPrepared prepared(
    HomericPreparedCommand command,
  ) =>
      HomericDocumentCommandPrepared(command);

  /// Stop without mutation and report a typed rejection.
  static HomericDocumentCommandRejected rejected(
    Object reason, {
    required String announcement,
  }) =>
      HomericDocumentCommandRejected(
        reason,
        announcement: announcement,
      );
}

/// The binding did not claim the physical command.
final class HomericDocumentCommandIgnored extends HomericDocumentCommandResult {
  const HomericDocumentCommandIgnored();
}

/// The binding handled the physical command.
final class HomericDocumentCommandHandled extends HomericDocumentCommandResult {
  const HomericDocumentCommandHandled();
}

/// The binding prepared one mutation for the mounted host to apply.
final class HomericDocumentCommandPrepared
    extends HomericDocumentCommandResult {
  const HomericDocumentCommandPrepared(this.command);

  /// Frozen canonical command applied only after the handler returns.
  final HomericPreparedCommand command;
}

/// The binding rejected the physical command with consumer-owned feedback.
final class HomericDocumentCommandRejected
    extends HomericDocumentCommandResult {
  const HomericDocumentCommandRejected(
    this.reason, {
    required this.announcement,
  });

  /// Consumer-defined typed rejection reason.
  final Object reason;

  /// Accessible explanation announced by the mounted document host.
  final String announcement;
}

/// Handles one document-level consumer shortcut.
typedef HomericDocumentCommandHandler = HomericDocumentCommandResult Function(
  HomericDocumentCommandContext context,
);

/// Epoch-bound context supplied before any block-reorder mutation.
final class HomericBlockMoveContext {
  const HomericBlockMoveContext._({
    required this.document,
    required this.selection,
    required this.composing,
    required this.stateRevision,
    required this.documentRevision,
    required this.blockId,
    required this.targetIndex,
    required bool Function() isCurrent,
  }) : _isCurrent = isCurrent;

  final Document document;
  final HomericSelection? selection;
  final HomericTextRange? composing;
  final int stateRevision;
  final int documentRevision;
  final String blockId;
  final int targetIndex;
  final bool Function() _isCurrent;

  /// Whether the originating reorder capability still owns current state.
  bool get isCurrent => _isCurrent();
}

/// Consumer hook for grouping or rejecting one block-reorder request.
typedef HomericBlockMoveHandler = HomericDocumentCommandResult Function(
  HomericBlockMoveContext context,
);

/// One ordered document-level shortcut/action registration.
final class HomericDocumentCommandBinding {
  const HomericDocumentCommandBinding({
    required this.shortcut,
    required this.onInvoke,
  });

  /// Physical shortcut resolved inside the nearest editable paragraph.
  final ShortcutActivator shortcut;

  /// Typed consumer action.
  final HomericDocumentCommandHandler onInvoke;
}

/// Observable rejection from a document command binding.
final class HomericDocumentCommandRejection {
  const HomericDocumentCommandRejection({
    required this.reason,
    required this.announcement,
    required this.blockId,
    required this.hostEpoch,
  });

  final Object reason;
  final String announcement;
  final String blockId;

  final int hostEpoch;
}

/// Observable rejection from a document-owned reorder surface.
final class HomericBlockMoveRejection {
  const HomericBlockMoveRejection({
    required this.reason,
    required this.announcement,
    required this.blockId,
    required this.documentRevision,
  });

  final Object reason;
  final String announcement;
  final String blockId;
  final int documentRevision;
}

typedef HomericDocumentSelectionHit = ({
  int offset,
  HomericCaretAffinity affinity,
});

typedef HomericDocumentSelectionHitTest = HomericDocumentSelectionHit? Function(
    Offset globalPoint);

/// Which normalized edge of the canonical selection is being queried.
enum HomericSelectionEndpoint { start, end }

/// Maps a normalized selection edge to the physical handle that owns it.
@internal
HomericSelectionEndpoint homericPhysicalSelectionEndpoint({
  required HomericSelectionEndpoint endpoint,
  required int selectionStart,
  required int selectionEnd,
  required int selectionHead,
  required HomericSelectionEndpoint? movingEndpoint,
}) {
  if (movingEndpoint == null) return endpoint;
  final opposite = movingEndpoint == HomericSelectionEndpoint.start
      ? HomericSelectionEndpoint.end
      : HomericSelectionEndpoint.start;
  if (selectionStart == selectionEnd) {
    return endpoint == HomericSelectionEndpoint.start
        ? movingEndpoint
        : opposite;
  }
  final position = endpoint == HomericSelectionEndpoint.start
      ? selectionStart
      : selectionEnd;
  return position == selectionHead ? movingEndpoint : opposite;
}

/// Revocable geometry for one normalized canonical selection endpoint.
final class HomericSelectionEndpointGeometry {
  const HomericSelectionEndpointGeometry._({
    required this.endpoint,
    required this.blockId,
    required this.blockOffset,
    required this.globalPosition,
    required this.affinity,
    required this.documentRevision,
    required this.layoutGeneration,
    required this.textDirection,
    required Rect globalRect,
    required LayerLink layerLink,
    required bool Function() isCurrent,
  })  : _globalRect = globalRect,
        _layerLink = layerLink,
        _isCurrent = isCurrent;

  final HomericSelectionEndpoint endpoint;
  final String blockId;
  final int blockOffset;
  final int globalPosition;
  final HomericCaretAffinity affinity;
  final int documentRevision;
  final int layoutGeneration;
  final TextDirection textDirection;

  final Rect _globalRect;
  final LayerLink _layerLink;
  final bool Function() _isCurrent;

  /// Whether this snapshot still addresses the mounted current generation.
  bool get isCurrent => _isCurrent();

  /// Current global caret rectangle, or `null` after invalidation.
  Rect? get globalRect => isCurrent ? _globalRect : null;

  /// Current caret line height, or `null` after invalidation.
  double? get lineHeight => globalRect?.height;

  /// Current composited handle target, or `null` after invalidation.
  LayerLink? get layerLink => isCurrent ? _layerLink : null;
}

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
    this.commandBindings = const <HomericDocumentCommandBinding>[],
    this.onMoveBlock,
    this.onMoveRejected,
    this.onCommandRejected,
    this.touchSelectionConfiguration =
        const HomericTouchSelectionConfiguration.adaptive(),
  })  : blockBuilder = null,
        blockGrabberStyle = const HomericBlockGrabberStyle(),
        scrollController = null,
        padding = EdgeInsets.zero,
        scrollPadding = null,
        cacheExtent = 250,
        estimatedBlockHeight = 48,
        layoutRevision = null,
        typewriterFocus = false;

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
    this.typewriterFocus = false,
    this.commandBindings = const <HomericDocumentCommandBinding>[],
    this.onMoveBlock,
    this.onMoveRejected,
    this.onCommandRejected,
    this.blockGrabberStyle = const HomericBlockGrabberStyle(),
    this.touchSelectionConfiguration =
        const HomericTouchSelectionConfiguration.adaptive(),
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

  /// When true, keeps the collapsed caret line in the middle third of the
  /// document viewport by scrolling the page (iA Writer-style typewriter
  /// focus). Opt-in: hosts must set this on [HomericEditableDocument.builder].
  ///
  /// Near document edges, scroll extent may prevent centering; combining with
  /// [padding] / [scrollPadding] gives room to keep the caret mid-viewport.
  final bool typewriterFocus;

  /// Ordered consumer shortcut registrations shared by every paragraph.
  ///
  /// As with other Flutter widget collections, treat this list as immutable
  /// and replace it with a new instance when registrations change.
  final List<HomericDocumentCommandBinding> commandBindings;

  /// Optional consumer policy shared by drag, semantics, and programmatic
  /// reorder surfaces. Ignored results retain Homeric's built-in move.
  final HomericBlockMoveHandler? onMoveBlock;

  /// Receives typed feedback when a document-owned reorder is rejected.
  final ValueChanged<HomericBlockMoveRejection>? onMoveRejected;

  /// Receives typed rejected-command feedback.
  final ValueChanged<HomericDocumentCommandRejection>? onCommandRejected;

  /// Presentation applied to every document edge grabber.
  final HomericBlockGrabberStyle blockGrabberStyle;

  /// Touch-selection policy shared by every mounted paragraph.
  final HomericTouchSelectionConfiguration touchSelectionConfiguration;

  /// Returns the nearest document editing coordinator, if present.
  static HomericEditableDocumentState? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_HomericEditableDocumentScope>()
      ?.state;

  @override
  State<HomericEditableDocument> createState() =>
      HomericEditableDocumentState();
}

class HomericEditableDocumentState extends State<HomericEditableDocument>
    with WidgetsBindingObserver {
  bool _selectionDragActive = false;
  final Map<String, HomericTextInputCommandDelegate> _commandHosts = {};
  final Map<String, BuildContext> _mountedRows = <String, BuildContext>{};
  final Map<String, FocusNode> _mountedFocusNodes = <String, FocusNode>{};
  final Map<String, GlobalKey> _rowKeys = <String, GlobalKey>{};
  final Map<GlobalKey, String> _blockIdsByRowKey = <GlobalKey, String>{};
  final Map<String, _MountedSelectionHost> _selectionHosts =
      <String, _MountedSelectionHost>{};
  final LayerLink _touchToolbarLayerLink = LayerLink();
  final LayerLink _touchStartHandleLayerLink = LayerLink();
  final LayerLink _touchEndHandleLayerLink = LayerLink();
  final HomericSelectionOverlayCoordinator _touchOverlayCoordinator =
      HomericSelectionOverlayCoordinator();
  final Object _touchHandleDragOwner = Object();
  HomericSelectionEndpoint? _touchMovingEndpoint;
  String? _touchStationaryBlockId;
  Object? _touchStationaryHostOwner;
  int? _touchStationaryLayoutGeneration;
  bool _touchSelectionRequested = false;
  bool _touchSelectionSyncScheduled = false;
  late BlockHeightCache _heightCache;
  late final HomericParagraphLayoutCache _paragraphLayoutCache;
  late ScrollController _scrollController;
  double _layoutWidth = 0;
  double _pendingAnchorCorrection = 0;
  bool _anchorCorrectionScheduled = false;
  int _heightOrderDocumentRevision = -1;
  int _heightOrderStructureRevision = -1;
  int _heightOrderRebuildCount = 0;
  Document? _heightOrderDocument;
  Object? _globalLayoutSignature;
  _BlockMoveWitness? _dragMoveWitness;
  int _selectionDragGeneration = 0;
  int? _selectionDragAnchor;
  ({int start, int end})? _selectionDragWordAnchor;
  int? _selectionDragDocumentRevision;
  Object? _selectionDragOwner;
  Offset? _selectionDragPointer;
  Timer? _selectionAutoScrollTimer;
  int _selectionAutoScrollDirection = 0;
  int _focusRequestGeneration = 0;
  int _consumerScrollGeneration = 0;
  int _focusLossCheckGeneration = 0;
  int _typewriterFocusGeneration = 0;
  VoidCallback? _removeTypewriterScrollIdleListener;
  HomericSelection? _typewriterSelection;
  int _typewriterContentRevision = -1;
  HomericSelection? _semanticsSelection;
  HomericTextRange? _semanticsComposing;
  bool _semanticsCanUndo = false;
  bool _semanticsCanRedo = false;
  bool _semanticsReadOnly = false;

  /// Current ordered consumer command bindings.
  List<HomericDocumentCommandBinding> get commandBindings =>
      widget.commandBindings;

  /// Reports one rejected command through the document-owned callback.
  void reportCommandRejection(HomericDocumentCommandRejection rejection) =>
      widget.onCommandRejected?.call(rejection);

  /// Creates a host-owned epoch witness for a mounted paragraph command.
  HomericDocumentCommandContext createCommandContext({
    required String blockId,
    required int hostEpoch,
    required bool Function() isCurrent,
  }) =>
      HomericDocumentCommandContext._(
        document: widget.controller.document,
        selection: widget.controller.selection,
        composing: widget.controller.composing,
        stateRevision: widget.controller.stateRevision,
        documentRevision: widget.controller.documentRevision,
        blockId: blockId,
        hostEpoch: hostEpoch,
        isCurrent: isCurrent,
      );

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
    widget.scrollPadding?.addListener(_scrollPaddingChanged);
    FocusManager.instance.addListener(_focusTreeChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) return;
    blurEditingFocus();
  }

  @override
  void didChangeMetrics() {
    cancelPointerSelectionDrag();
    if (!_touchSelectionRequested) return;
    _disposeTouchSelectionOverlay();
    _scheduleTouchSelectionSync();
  }

  @override
  void didUpdateWidget(HomericEditableDocument oldWidget) {
    super.didUpdateWidget(oldWidget);
    _validateSession();
    final scrollControllerChanged =
        !identical(oldWidget.scrollController, widget.scrollController);
    final scrollPaddingChanged =
        !identical(oldWidget.scrollPadding, widget.scrollPadding);
    if (!identical(oldWidget.controller, widget.controller) ||
        !identical(oldWidget.inputSession, widget.inputSession) ||
        scrollControllerChanged) {
      cancelPointerSelectionDrag();
      hideTouchSelectionChrome();
    } else if (!identical(
      oldWidget.touchSelectionConfiguration,
      widget.touchSelectionConfiguration,
    )) {
      hideTouchSelectionChrome();
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
    if (scrollPaddingChanged) {
      oldWidget.scrollPadding?.removeListener(_scrollPaddingChanged);
      widget.scrollPadding?.addListener(_scrollPaddingChanged);
    }
    if (scrollControllerChanged) {
      _typewriterFocusGeneration++;
      _cancelTypewriterScrollIdleWait();
      if (oldWidget.scrollController == null) _scrollController.dispose();
      _scrollController = widget.scrollController ?? ScrollController();
    }
    if (oldWidget.estimatedBlockHeight != widget.estimatedBlockHeight) {
      _heightCache = BlockHeightCache(
        estimatedHeight: widget.estimatedBlockHeight,
      );
      _syncOrder(force: true);
    }
    if (!widget.typewriterFocus && oldWidget.typewriterFocus) {
      _typewriterFocusGeneration++;
      _cancelTypewriterScrollIdleWait();
    }
    if (widget.typewriterFocus &&
        (!oldWidget.typewriterFocus ||
            !identical(oldWidget.controller, widget.controller) ||
            scrollControllerChanged ||
            scrollPaddingChanged ||
            oldWidget.padding != widget.padding ||
            oldWidget.layoutRevision != widget.layoutRevision)) {
      _scheduleTypewriterFocus(force: true);
    }
  }

  void _scrollPaddingChanged() {
    _scheduleTypewriterFocus(force: true);
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
    _selectionDragWordAnchor = null;
    _selectionDragDocumentRevision = widget.controller.documentRevision;
    _selectionDragOwner = owner;
    beginSelectionDrag();
  }

  /// Starts a word-granular touch drag with one immutable initial word.
  void beginPointerWordSelectionDrag(
    int start,
    int end, {
    Object? owner,
  }) {
    beginPointerSelectionDrag(start, owner: owner);
    _selectionDragWordAnchor = (start: start, end: end);
  }

  /// Extends the current pointer selection through mounted row geometry.
  bool updatePointerSelectionDrag(
    Offset globalPoint, {
    Object? owner,
  }) {
    if (owner != null && !identical(owner, _selectionDragOwner)) return false;
    if (!_selectionDragActive || _selectionDragAnchor == null) return false;
    _selectionDragPointer = globalPoint;
    _updatePointerSelectionHead(globalPoint);
    _syncSelectionAutoscroll(globalPoint);
    return true;
  }

  /// Ends the pointer generation and retargets platform input once.
  bool endPointerSelectionDrag({Object? owner}) {
    if (owner != null && !identical(owner, _selectionDragOwner)) return false;
    final wasTouchHandleDrag =
        identical(_selectionDragOwner, _touchHandleDragOwner);
    _stopSelectionAutoscroll();
    _selectionDragPointer = null;
    _selectionDragAnchor = null;
    _selectionDragWordAnchor = null;
    _selectionDragDocumentRevision = null;
    _selectionDragOwner = null;
    _selectionDragGeneration++;
    _focusLossCheckGeneration++;
    if (wasTouchHandleDrag) {
      _touchMovingEndpoint = null;
      _clearTouchStationaryWitness();
      _touchOverlayCoordinator.hideMagnifier();
      if (_touchSelectionRequested) _scheduleTouchSelectionSync();
    }
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
    final wasTouchHandleDrag =
        identical(_selectionDragOwner, _touchHandleDragOwner);
    _stopSelectionAutoscroll();
    _selectionDragPointer = null;
    _selectionDragAnchor = null;
    _selectionDragWordAnchor = null;
    _selectionDragDocumentRevision = null;
    _selectionDragOwner = null;
    _selectionDragGeneration++;
    _focusLossCheckGeneration++;
    if (wasTouchHandleDrag) {
      _touchMovingEndpoint = null;
      _clearTouchStationaryWitness();
      _touchOverlayCoordinator.hideMagnifier();
    }
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
    required BlockTextRange? Function(Offset globalPoint) wordRangeAt,
    required List<Rect>? Function(BlockTextRange range) globalRangeRects,
    required HomericActiveCaretGeometry? Function() activeCaretGeometry,
    required MagnifierInfo? Function(Offset globalPoint) magnifierInfo,
    required ({
      Rect globalRect,
      int layoutGeneration,
      LayerLink layerLink,
      TextDirection textDirection,
    })?
        Function(
      HomericSelectionEndpoint endpoint,
      int blockOffset,
      HomericCaretAffinity affinity,
    ) selectionEndpointGeometry,
  }) {
    _selectionHosts[blockId] = _MountedSelectionHost(
      owner: owner,
      globalRect: globalRect,
      hitTest: hitTest,
      wordRangeAt: wordRangeAt,
      globalRangeRects: globalRangeRects,
      activeCaretGeometry: activeCaretGeometry,
      magnifierInfo: magnifierInfo,
      selectionEndpointGeometry: selectionEndpointGeometry,
    );
    if (_touchSelectionRequested) _scheduleTouchSelectionSync();
  }

  /// Removes a selection host only when [owner] still owns it.
  void unregisterSelectionHost(String blockId, Object owner) {
    if (identical(_selectionHosts[blockId]?.owner, owner)) {
      _selectionHosts.remove(blockId);
      final stationaryHostRecycled = blockId == _touchStationaryBlockId &&
          identical(owner, _touchStationaryHostOwner);
      if (stationaryHostRecycled) {
        _touchStationaryHostOwner = null;
        _touchStationaryLayoutGeneration = null;
      }
      if (_touchSelectionRequested &&
          !(stationaryHostRecycled &&
              identical(_selectionDragOwner, _touchHandleDragOwner))) {
        _scheduleTouchSelectionSync();
      }
    }
  }

  /// Revokes a handle drag only when its stationary geometry changes.
  @internal
  void selectionHostLayoutChanged(
    String blockId, {
    required Object owner,
    required int layoutGeneration,
  }) {
    if (!identical(_selectionDragOwner, _touchHandleDragOwner) ||
        blockId != _touchStationaryBlockId) {
      return;
    }
    if (_touchStationaryHostOwner == null) return;
    if (identical(owner, _touchStationaryHostOwner) &&
        layoutGeneration == _touchStationaryLayoutGeneration) {
      return;
    }
    cancelTransientTouchInput();
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

  /// Ends the current platform epoch and removes focus from every mounted row.
  void blurEditingFocus() {
    cancelPointerSelectionDrag();
    hideTouchSelectionChrome();
    widget.inputSession.blur();
    for (final focusNode in _mountedFocusNodes.values) {
      focusNode.unfocus();
    }
  }

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

  /// Current platform touch-selection policy for this document.
  HomericResolvedTouchSelectionConfiguration?
      get resolvedTouchSelectionConfiguration =>
          widget.touchSelectionConfiguration.resolve(defaultTargetPlatform);

  /// Returns current geometry for one normalized selection endpoint.
  HomericSelectionEndpointGeometry? selectionEndpointGeometry(
    HomericSelectionEndpoint endpoint,
  ) {
    final selection = widget.controller.selection;
    if (selection == null) return null;
    final globalPosition = endpoint == HomericSelectionEndpoint.start
        ? selection.start
        : selection.end;
    final resolved = widget.controller.document.resolve(globalPosition);
    if (resolved is! InlinePosition) return null;
    final host = _selectionHosts[resolved.block.id];
    if (host == null) return null;
    final affinity = globalPosition == selection.head
        ? selection.affinity
        : endpoint == HomericSelectionEndpoint.start
            ? HomericCaretAffinity.downstream
            : HomericCaretAffinity.upstream;
    final raw = host.selectionEndpointGeometry(
      endpoint,
      resolved.offset,
      affinity,
    );
    if (raw == null) return null;
    final documentRevision = widget.controller.documentRevision;
    final owner = host.owner;
    bool isCurrent() {
      if (widget.controller.documentRevision != documentRevision) return false;
      final currentHost = _selectionHosts[resolved.block.id];
      if (currentHost == null || !identical(currentHost.owner, owner)) {
        return false;
      }
      final current = currentHost.selectionEndpointGeometry(
        endpoint,
        resolved.offset,
        affinity,
      );
      return current != null &&
          current.layoutGeneration == raw.layoutGeneration &&
          identical(current.layerLink, raw.layerLink);
    }

    return HomericSelectionEndpointGeometry._(
      endpoint: endpoint,
      blockId: resolved.block.id,
      blockOffset: resolved.offset,
      globalPosition: globalPosition,
      affinity: affinity,
      documentRevision: documentRevision,
      layoutGeneration: raw.layoutGeneration,
      textDirection: raw.textDirection,
      globalRect: raw.globalRect,
      layerLink: raw.layerLink,
      isCurrent: isCurrent,
    );
  }

  /// Whether document-owned touch handles are currently mounted.
  bool get touchSelectionChromeVisible => _touchOverlayCoordinator.visible;

  /// Whether the current start handle is visible in the document viewport.
  @visibleForTesting
  bool get debugTouchStartHandleVisible =>
      _touchOverlayCoordinator.startHandleVisible;

  /// Whether the current end handle is visible in the document viewport.
  @visibleForTesting
  bool get debugTouchEndHandleVisible =>
      _touchOverlayCoordinator.endHandleVisible;

  /// Whether the adaptive touch magnifier currently has an overlay entry.
  @visibleForTesting
  bool get debugTouchMagnifierVisible =>
      _touchOverlayCoordinator.magnifierVisible;

  /// Logical endpoint currently owned by a touch-handle drag.
  @visibleForTesting
  HomericSelectionEndpoint? get debugTouchMovingEndpoint =>
      _touchMovingEndpoint;

  /// Stable document-owned attachment for one logical selection endpoint.
  ///
  /// During a drag the logical start/end may swap, but the physical handle
  /// being dragged must retain its layer link across rows and at the exact
  /// collapsed crossing point.
  @internal
  LayerLink touchSelectionLayerLink(HomericSelectionEndpoint endpoint) {
    final selection = widget.controller.selection;
    final physicalEndpoint = selection == null
        ? endpoint
        : homericPhysicalSelectionEndpoint(
            endpoint: endpoint,
            selectionStart: selection.start,
            selectionEnd: selection.end,
            selectionHead: selection.head,
            movingEndpoint: _touchMovingEndpoint,
          );
    return physicalEndpoint == HomericSelectionEndpoint.start
        ? _touchStartHandleLayerLink
        : _touchEndHandleLayerLink;
  }

  /// Shows touch handles for the current canonical selection after layout.
  void showTouchSelectionChrome() {
    if (resolvedTouchSelectionConfiguration == null ||
        widget.controller.selection == null) {
      hideTouchSelectionChrome();
      return;
    }
    _touchSelectionRequested = true;
    _scheduleTouchSelectionSync();
  }

  /// Whether a still-focused recycled row may forward one structural key.
  ///
  /// A paragraph break advances the canonical active block synchronously,
  /// before the fresh row can mount and take focus. Hardware can deliver a
  /// second Return during that gap; the document remains the command owner and
  /// accepts it unless another transient document gesture or mutation gate is
  /// active.
  @internal
  bool get acceptsPendingRowStructuralKey =>
      mounted &&
      !_selectionDragActive &&
      !widget.controller.isReadOnly &&
      widget.controller.composing == null &&
      widget.controller.activeBlockId != null;

  /// Hides every document-owned touch overlay without changing selection.
  void hideTouchSelectionChrome() {
    _touchSelectionRequested = false;
    _touchSelectionSyncScheduled = false;
    if (identical(_selectionDragOwner, _touchHandleDragOwner)) {
      _cancelPointerSelectionDragWithoutRetarget();
    }
    _disposeTouchSelectionOverlay();
  }

  /// Revokes touch state owned by [owner] or by the document handle overlay.
  ///
  /// Platform connection closure must not retarget input while it is already
  /// being torn down, so this cancellation never calls [endSelectionDrag].
  @internal
  void cancelTransientTouchInput({Object? owner}) {
    final dragOwner = _selectionDragOwner;
    if (owner == null ||
        identical(dragOwner, owner) ||
        identical(dragOwner, _touchHandleDragOwner)) {
      _cancelPointerSelectionDragWithoutRetarget();
    }
    hideTouchSelectionChrome();
  }

  void _scheduleTouchSelectionSync() {
    if (_touchSelectionSyncScheduled) return;
    _touchSelectionSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _touchSelectionSyncScheduled = false;
      if (mounted && _touchSelectionRequested) _syncTouchSelectionOverlay();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _syncTouchSelectionOverlay() {
    final configuration = resolvedTouchSelectionConfiguration;
    final selection = widget.controller.selection;
    if (configuration == null || selection == null) {
      hideTouchSelectionChrome();
      return;
    }
    final rawStart = selectionEndpointGeometry(HomericSelectionEndpoint.start);
    final rawEnd = selectionEndpointGeometry(HomericSelectionEndpoint.end);
    var start =
        rawStart != null && _touchEndpointIsVisible(rawStart) ? rawStart : null;
    var end = rawEnd != null && _touchEndpointIsVisible(rawEnd) ? rawEnd : null;
    if (homericPhysicalSelectionEndpoint(
          endpoint: HomericSelectionEndpoint.start,
          selectionStart: selection.start,
          selectionEnd: selection.end,
          selectionHead: selection.head,
          movingEndpoint: _touchMovingEndpoint,
        ) ==
        HomericSelectionEndpoint.end) {
      final previousStart = start;
      start = end;
      end = previousStart;
    }
    if (start == null && end == null) {
      _disposeTouchSelectionOverlay();
      return;
    }
    _touchOverlayCoordinator.sync(
      context: context,
      debugRequiredFor: widget,
      controls: configuration.selectionControls,
      magnifierConfiguration: configuration.magnifierConfiguration,
      toolbarLayerLink: _touchToolbarLayerLink,
      collapsed: selection.isCollapsed && _touchMovingEndpoint == null,
      start: _touchOverlayEndpoint(start),
      end: _touchOverlayEndpoint(end),
      onSelectionHandleTapped: _showTouchToolbar,
      onStartHandleDragStart: (details) => _beginTouchHandleDrag(
        HomericSelectionEndpoint.start,
        details.globalPosition,
      ),
      onStartHandleDragUpdate: (details) =>
          _updateTouchHandleDrag(details.globalPosition),
      onStartHandleDragEnd: (_) => _endTouchHandleDrag(),
      onEndHandleDragStart: (details) => _beginTouchHandleDrag(
        HomericSelectionEndpoint.end,
        details.globalPosition,
      ),
      onEndHandleDragUpdate: (details) =>
          _updateTouchHandleDrag(details.globalPosition),
      onEndHandleDragEnd: (_) => _endTouchHandleDrag(),
    );
  }

  void _beginTouchHandleDrag(
    HomericSelectionEndpoint endpoint,
    Offset globalPosition,
  ) {
    final selection = widget.controller.selection;
    if (selection == null || widget.controller.composing != null) {
      _endTouchHandleDrag();
      return;
    }
    final stationaryEndpoint = endpoint == HomericSelectionEndpoint.start
        ? HomericSelectionEndpoint.end
        : HomericSelectionEndpoint.start;
    final stationary = stationaryEndpoint == HomericSelectionEndpoint.start
        ? selection.start
        : selection.end;
    final resolved = widget.controller.document.resolve(stationary);
    if (resolved is! InlinePosition) {
      _touchOverlayCoordinator.hideMagnifier();
      return;
    }
    final stationaryGeometry = selectionEndpointGeometry(stationaryEndpoint);
    final stationaryOwner = stationaryGeometry == null
        ? null
        : _selectionHosts[stationaryGeometry.blockId]?.owner;
    beginPointerSelectionDrag(stationary, owner: _touchHandleDragOwner);
    _touchMovingEndpoint = endpoint;
    _touchStationaryBlockId = resolved.block.id;
    _touchStationaryHostOwner = stationaryOwner;
    _touchStationaryLayoutGeneration = stationaryGeometry?.layoutGeneration;
    _updateTouchMagnifier(globalPosition);
  }

  void _updateTouchHandleDrag(Offset globalPosition) {
    if (_touchMovingEndpoint == null ||
        !identical(_selectionDragOwner, _touchHandleDragOwner)) {
      return;
    }
    updatePointerSelectionDrag(globalPosition, owner: _touchHandleDragOwner);
    _updateTouchMagnifier(globalPosition);
  }

  void _endTouchHandleDrag() {
    endPointerSelectionDrag(owner: _touchHandleDragOwner);
  }

  void _clearTouchStationaryWitness() {
    _touchStationaryBlockId = null;
    _touchStationaryHostOwner = null;
    _touchStationaryLayoutGeneration = null;
  }

  /// Updates the document-owned magnifier from a current touch gesture.
  bool updateTouchSelectionMagnifier(
    Offset globalPosition, {
    Object? owner,
  }) {
    if (owner != null && !identical(owner, _selectionDragOwner)) return false;
    _updateTouchMagnifier(globalPosition);
    return true;
  }

  /// Hides the document-owned magnifier without changing logical selection.
  void hideTouchSelectionMagnifier() {
    _touchOverlayCoordinator.hideMagnifier();
  }

  void _updateTouchMagnifier(Offset globalPosition) {
    final info = _magnifierInfoAt(globalPosition);
    if (info == null) {
      _touchOverlayCoordinator.hideMagnifier();
      return;
    }
    _touchOverlayCoordinator.showOrUpdateMagnifier(info);
  }

  MagnifierInfo? _magnifierInfoAt(Offset globalPosition) {
    final candidates = <({Rect rect, _MountedSelectionHost host})>[];
    for (final host in _selectionHosts.values) {
      final rect = host.globalRect();
      if (rect != null) candidates.add((rect: rect, host: host));
    }
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) => a.rect.top.compareTo(b.rect.top));
    var target = candidates.first;
    for (final candidate in candidates) {
      if (candidate.rect.contains(globalPosition)) {
        target = candidate;
        break;
      }
      if (globalPosition.dy >= candidate.rect.top) target = candidate;
    }
    final clamped = Offset(
      globalPosition.dx.clamp(target.rect.left, target.rect.right),
      globalPosition.dy.clamp(target.rect.top, target.rect.bottom),
    );
    return target.host.magnifierInfo(clamped);
  }

  HomericSelectionOverlayEndpoint? _touchOverlayEndpoint(
    HomericSelectionEndpointGeometry? endpoint,
  ) {
    final rect = endpoint?.globalRect;
    final link = endpoint?.layerLink;
    if (endpoint == null || rect == null || link == null) return null;
    return HomericSelectionOverlayEndpoint(
      globalRect: rect,
      layerLink: link,
      textDirection: endpoint.textDirection,
    );
  }

  bool _touchEndpointIsVisible(HomericSelectionEndpointGeometry endpoint) {
    final endpointRect = endpoint.globalRect;
    final render = context.findRenderObject();
    if (endpointRect == null ||
        render is! RenderBox ||
        !render.attached ||
        !render.hasSize) {
      return false;
    }
    final viewportRect = render.localToGlobal(Offset.zero) & render.size;
    return viewportRect.overlaps(endpointRect) ||
        viewportRect.contains(endpointRect.center);
  }

  void _showTouchToolbar() {
    final activeBlockId = widget.controller.activeBlockId;
    if (activeBlockId == null) return;
    _commandHosts[activeBlockId]?.showToolbar();
  }

  void _disposeTouchSelectionOverlay() {
    _touchOverlayCoordinator.hide();
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
    final mounted = <({int index, String blockId})>[];
    for (final blockId in _selectionHosts.keys) {
      final index = widget.controller.document.indexOfBlockId(blockId);
      if (index != null) mounted.add((index: index, blockId: blockId));
    }
    mounted.sort((left, right) => left.index.compareTo(right.index));
    for (final entry in mounted) {
      final host = _selectionHosts[entry.blockId]!;
      final fragment = selectionFragmentForBlock(entry.blockId);
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
    if (document.isEmpty) return false;
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
  bool selectAll() {
    final document = widget.controller.document;
    if (document.isEmpty) return false;
    return _setDocumentSelection(
      document.positionAt(0, 0),
      document.positionAt(
        document.blockCount - 1,
        document.blocks.last.contentLength,
      ),
      affinity: HomericCaretAffinity.downstream,
      resetPreferredX: true,
    );
  }

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

  Future<HomericScrollToBlockResult> scrollToBlock(String blockId) =>
      _scrollToBlock(blockId);

  /// Scrolls to [blockId] while superseding any prior consumer request.
  Future<HomericScrollToBlockResult> scrollToBlockLatest(String blockId) {
    final generation = ++_consumerScrollGeneration;
    return _scrollToBlock(
      blockId,
      isCurrent: () => generation == _consumerScrollGeneration,
    );
  }

  Future<HomericScrollToBlockResult> _scrollToBlock(
    String blockId, {
    bool Function()? isCurrent,
  }) async {
    final revision = widget.controller.documentRevision;
    final index = widget.controller.document.indexOfBlockId(blockId);
    if (index == null) return HomericScrollToBlockResult.missing;
    if (!_scrollController.hasClients) {
      return HomericScrollToBlockResult.notReached;
    }
    for (var attempt = 0; attempt < 8; attempt++) {
      if ((isCurrent != null && !isCurrent()) ||
          revision != widget.controller.documentRevision) {
        return HomericScrollToBlockResult.stale;
      }
      if (!_scrollController.hasClients) {
        return HomericScrollToBlockResult.notReached;
      }
      final position = _scrollController.position;
      final target = _heightCache
          .offsetBefore(index)
          .clamp(position.minScrollExtent, position.maxScrollExtent);
      _scrollController.jumpTo(target);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted ||
          (isCurrent != null && !isCurrent()) ||
          revision != widget.controller.documentRevision) {
        return HomericScrollToBlockResult.stale;
      }
      final rowContext = _mountedRows[blockId];
      if (rowContext != null && rowContext.mounted) {
        await Scrollable.ensureVisible(rowContext, alignment: 0.5);
        if (!mounted || (isCurrent != null && !isCurrent())) {
          return HomericScrollToBlockResult.stale;
        }
        _scheduleTypewriterFocus(force: true);
        return HomericScrollToBlockResult.reached;
      }
    }
    return HomericScrollToBlockResult.notReached;
  }

  /// Invalidates an in-flight [scrollToBlockLatest] request.
  void cancelPendingScrollToBlock() {
    _consumerScrollGeneration++;
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
    if (_touchSelectionRequested) _scheduleTouchSelectionSync();
    _scheduleTypewriterFocus();
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
    if (!_retargetActiveHost()) {
      // A structural command can make a not-yet-mounted trailing row active.
      // Retarget the canonical platform value immediately so characters that
      // arrive before the next frame cannot be dropped against the old block's
      // shadow value. The mounted row replaces the narrow temporary command
      // binding during settlement below.
      widget.inputSession.retarget(
        blockId: activeBlockId,
        commandDelegate: _PendingRowCommandDelegate(this, activeBlockId),
      );
      _scheduleActiveHostSettlement(activeBlockId);
    }
  }

  /// Scrolls so the collapsed caret line stays in the middle third of the
  /// viewport when [HomericEditableDocument.typewriterFocus] is enabled.
  void _scheduleTypewriterFocus({bool force = false}) {
    if (!widget.typewriterFocus || widget.blockBuilder == null) return;
    final selection = widget.controller.selection;
    final contentRevision = widget.controller.contentRevision;
    if (!force &&
        selection == _typewriterSelection &&
        contentRevision == _typewriterContentRevision) {
      return;
    }
    _typewriterSelection = selection;
    _typewriterContentRevision = contentRevision;
    _cancelTypewriterScrollIdleWait();
    final generation = ++_typewriterFocusGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _typewriterFocusGeneration) return;
      _applyTypewriterFocus();
    });
  }

  void _applyTypewriterFocus({int attempt = 0}) {
    if (!widget.typewriterFocus ||
        widget.blockBuilder == null ||
        _selectionDragActive ||
        _selectionAutoScrollTimer != null ||
        !_scrollController.hasClients) {
      return;
    }
    final position = _scrollController.position;
    if (position.isScrollingNotifier.value) {
      _waitForTypewriterScrollIdle(position, attempt: attempt);
      return;
    }
    final selection = widget.controller.selection;
    if (selection == null || !selection.isCollapsed) return;
    final caret = activeCaretGeometry;
    if (caret == null) {
      // Geometry may arrive one frame after a recycled row mounts.
      if (attempt >= 2) return;
      final generation = _typewriterFocusGeneration;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || generation != _typewriterFocusGeneration) return;
        _applyTypewriterFocus(attempt: attempt + 1);
      });
      return;
    }
    final render = context.findRenderObject();
    if (render is! RenderBox || !render.attached || !render.hasSize) return;
    final viewportTop = render.localToGlobal(Offset.zero).dy;
    final viewportHeight = render.size.height;
    if (viewportHeight <= 0) return;
    final caretCenterY = caret.globalRect.center.dy - viewportTop;
    // Keep the caret line at viewport center (always inside the middle third
    // when scroll extent allows). Near document edges, clamping may leave the
    // caret outside the band until [padding]/[scrollPadding] creates room.
    final delta = caretCenterY - viewportHeight / 2;
    if (delta.abs() < 0.5) return;
    final target = (_scrollController.offset + delta)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((target - _scrollController.offset).abs() < 0.5) return;
    _scrollController.jumpTo(target);
  }

  void _waitForTypewriterScrollIdle(
    ScrollPosition position, {
    required int attempt,
  }) {
    _cancelTypewriterScrollIdleWait();
    final generation = _typewriterFocusGeneration;
    late VoidCallback listener;
    listener = () {
      if (!mounted ||
          generation != _typewriterFocusGeneration ||
          !widget.typewriterFocus) {
        _cancelTypewriterScrollIdleWait();
        return;
      }
      if (position.isScrollingNotifier.value) return;
      _cancelTypewriterScrollIdleWait();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || generation != _typewriterFocusGeneration) return;
        _applyTypewriterFocus(attempt: attempt);
      });
    };
    position.isScrollingNotifier.addListener(listener);
    _removeTypewriterScrollIdleListener =
        () => position.isScrollingNotifier.removeListener(listener);
  }

  void _cancelTypewriterScrollIdleWait() {
    final remove = _removeTypewriterScrollIdleListener;
    _removeTypewriterScrollIdleListener = null;
    remove?.call();
  }

  void _scheduleActiveHostSettlement(String blockId) {
    final generation = ++_focusRequestGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted ||
          generation != _focusRequestGeneration ||
          widget.controller.activeBlockId != blockId) {
        return;
      }
      if (_retargetActiveHost()) {
        _scheduleTypewriterFocus(force: true);
        return;
      }
      final result = await scrollToBlock(blockId);
      if (!mounted ||
          generation != _focusRequestGeneration ||
          widget.controller.activeBlockId != blockId ||
          result != HomericScrollToBlockResult.reached) {
        return;
      }
      _retargetActiveHost();
      _scheduleTypewriterFocus(force: true);
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
    final wordAnchor = _selectionDragWordAnchor;
    if (wordAnchor != null) {
      final word = target.host.wordRangeAt(clampedPoint);
      if (word == null) return;
      final targetStart = widget.controller.globalPositionForBlockOffset(
        target.blockId,
        word.start,
      );
      final targetEnd = widget.controller.globalPositionForBlockOffset(
        target.blockId,
        word.end,
      );
      final before = targetEnd <= wordAnchor.start;
      widget.controller.setSelection(HomericSelection(
        anchor: before ? wordAnchor.end : wordAnchor.start,
        head: before ? targetStart : targetEnd,
        affinity: before
            ? HomericCaretAffinity.upstream
            : HomericCaretAffinity.downstream,
      ));
      return;
    }
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
    final request = BlockMoveRequest(
      blockId: witness.blockId,
      targetIndex: targetIndex,
      documentRevision: witness.documentRevision,
      previousBlockId: witness.previousBlockId,
      nextBlockId: witness.nextBlockId,
    );
    final handler = widget.onMoveBlock;
    var moved = false;
    if (handler == null) {
      moved = widget.controller.moveBlock(request);
    } else {
      final stateRevision = widget.controller.stateRevision;
      bool isCurrent() =>
          mounted &&
          widget.controller.stateRevision == stateRevision &&
          widget.controller.documentRevision == witness.documentRevision &&
          canReorderBlock(witness.blockId);
      final result = handler(HomericBlockMoveContext._(
        document: widget.controller.document,
        selection: widget.controller.selection,
        composing: widget.controller.composing,
        stateRevision: stateRevision,
        documentRevision: witness.documentRevision,
        blockId: witness.blockId,
        targetIndex: targetIndex,
        isCurrent: isCurrent,
      ));
      if (widget.controller.stateRevision != stateRevision) {
        throw StateError(
          'A Homeric block move handler must return before editor state '
          'changes.',
        );
      }
      if (!isCurrent()) {
        return false;
      }
      switch (result) {
        case HomericDocumentCommandIgnored():
          moved = widget.controller.moveBlock(request);
        case HomericDocumentCommandPrepared(:final command):
          moved = widget.controller.applyPreparedCommand(command);
        case HomericDocumentCommandHandled():
          moved = false;
        case HomericDocumentCommandRejected(
            :final reason,
            :final announcement,
          ):
          widget.onMoveRejected?.call(HomericBlockMoveRejection(
            reason: reason,
            announcement: announcement,
            blockId: witness.blockId,
            documentRevision: witness.documentRevision,
          ));
          // Flutter 3.24 does not yet expose the multi-view announcement API.
          // ignore: deprecated_member_use
          SemanticsService.announce(
            announcement,
            Directionality.of(context),
          );
      }
    }
    if (!moved) return false;
    _restoreViewportAnchor(anchor);
    // AppKit can deliver a block-move chord through the text-input selector
    // callback. Moving the active row during that callback may temporarily
    // release the native first responder even though the Flutter FocusNode is
    // retained. Settle the same stable block again after its new row position
    // mounts so subsequent platform input remains attached.
    _scheduleActiveHostSettlement(witness.blockId);
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
    return _captureViewportAnchorIn(
      widget.controller.document,
      movingBlockId: movingBlockId,
    );
  }

  _ViewportAnchor? _captureViewportAnchorIn(
    Document document, {
    String? movingBlockId,
  }) {
    if (!_scrollController.hasClients) return null;
    final index = _heightCache.indexAtOffset(_scrollController.offset);
    if (index == null || index >= document.blockCount) return null;
    final blocks = document.blocks;
    var anchorIndex = index;
    if (movingBlockId != null &&
        blocks[index].id == movingBlockId &&
        blocks.length > 1) {
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
      _scheduleTypewriterFocus(force: true);
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
    final document = widget.controller.document;
    final structureRevision = widget.controller.structureRevision;
    final previousDocument = _heightOrderDocument;
    _heightOrderDocumentRevision = documentRevision;
    _heightOrderDocument = document;
    if (!force && structureRevision == _heightOrderStructureRevision) {
      return false;
    }
    final viewportAnchor = !force && previousDocument != null
        ? _captureViewportAnchorIn(previousDocument)
        : null;
    _heightOrderStructureRevision = structureRevision;
    final blockIds = document.blocks.map((block) => block.id).toList();
    _heightCache.replaceOrder(blockIds);
    _paragraphLayoutCache.retainKeys(blockIds.toSet());
    _heightOrderRebuildCount++;
    _restoreViewportAnchor(viewportAnchor);
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
      _scheduleTypewriterFocus(force: true);
    });
  }

  @override
  void dispose() {
    _stopSelectionAutoscroll();
    _cancelTypewriterScrollIdleWait();
    _touchOverlayCoordinator.dispose();
    WidgetsBinding.instance.removeObserver(this);
    FocusManager.instance.removeListener(_focusTreeChanged);
    widget.controller.removeListener(_controllerChanged);
    widget.scrollPadding?.removeListener(_scrollPaddingChanged);
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
      touchSelectionConfiguration: widget.touchSelectionConfiguration,
      child: CompositedTransformTarget(
        link: _touchToolbarLayerLink,
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
                  grabberStyle: widget.blockGrabberStyle,
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

final class _PendingRowCommandDelegate
    implements HomericTextInputCommandDelegate {
  const _PendingRowCommandDelegate(this.state, this.blockId);

  final HomericEditableDocumentState state;
  final String blockId;

  @override
  Object? invoke(Intent intent) {
    final controller = state.widget.controller;
    if (!state.mounted ||
        state._selectionDragActive ||
        controller.isReadOnly ||
        controller.composing != null ||
        controller.activeBlockId != blockId) {
      return false;
    }
    if (intent is HomericInsertParagraphBreakIntent) {
      return controller.insertParagraphBreak();
    }
    if (intent is DeleteCharacterIntent) {
      return intent.forward
          ? controller.deleteForward()
          : controller.deleteBackward();
    }
    return null;
  }

  @override
  void showToolbar() {}

  @override
  void showAutocorrectionPromptRect(TextRange range) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void cancelTransientInput() {}
}

class _HomericEditableDocumentScope extends InheritedWidget {
  const _HomericEditableDocumentScope({
    required this.state,
    required this.touchSelectionConfiguration,
    required super.child,
  });

  final HomericEditableDocumentState state;
  final HomericTouchSelectionConfiguration touchSelectionConfiguration;

  @override
  bool updateShouldNotify(_HomericEditableDocumentScope oldWidget) =>
      !identical(state, oldWidget.state) ||
      !identical(
        touchSelectionConfiguration,
        oldWidget.touchSelectionConfiguration,
      );
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
    required this.wordRangeAt,
    required this.globalRangeRects,
    required this.activeCaretGeometry,
    required this.magnifierInfo,
    required this.selectionEndpointGeometry,
  });

  final Object owner;
  final Rect? Function() globalRect;
  final HomericDocumentSelectionHitTest hitTest;
  final BlockTextRange? Function(Offset globalPoint) wordRangeAt;
  final List<Rect>? Function(BlockTextRange range) globalRangeRects;
  final HomericActiveCaretGeometry? Function() activeCaretGeometry;
  final MagnifierInfo? Function(Offset globalPoint) magnifierInfo;
  final ({
    Rect globalRect,
    int layoutGeneration,
    LayerLink layerLink,
    TextDirection textDirection,
  })?
      Function(
    HomericSelectionEndpoint endpoint,
    int blockOffset,
    HomericCaretAffinity affinity,
  ) selectionEndpointGeometry;
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
    required this.grabberStyle,
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
  final HomericBlockGrabberStyle grabberStyle;
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
  ValueNotifier<bool>? _grabberHovered;

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
    _grabberHovered?.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final inheritedColor =
        DefaultTextStyle.of(context).style.color ?? const Color(0xFF000000);
    final canReorder = widget.canReorder();
    final hoverChangesOpacity =
        widget.grabberStyle.idleOpacity != widget.grabberStyle.hoverOpacity;
    final grabberTextStyle = TextStyle(
      color: inheritedColor.withAlpha(255),
    ).merge(widget.grabberStyle.textStyle);
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
    Widget grabber = Text(
      '⋮',
      style: grabberTextStyle,
    );
    if (hoverChangesOpacity) {
      final hovered = _grabberHovered ??= ValueNotifier<bool>(false);
      grabber = ValueListenableBuilder<bool>(
        valueListenable: hovered,
        builder: (context, isHovered, child) => AnimatedOpacity(
          opacity: isHovered && canReorder
              ? widget.grabberStyle.hoverOpacity
              : widget.grabberStyle.idleOpacity,
          duration: widget.grabberStyle.fadeDuration,
          child: child,
        ),
        child: grabber,
      );
    } else if (widget.grabberStyle.idleOpacity != 1) {
      grabber = Opacity(
        opacity: widget.grabberStyle.idleOpacity,
        child: grabber,
      );
    }
    final row = Row(
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
              cursor: canReorder ? SystemMouseCursors.grab : MouseCursor.defer,
              child: SizedBox(
                width: 44,
                height: 44,
                child: Center(child: grabber),
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
    );
    return _MeasureNaturalHeight(
      witness: widget.witness,
      onHeight: widget.onHeight,
      child: hoverChangesOpacity
          ? MouseRegion(
              onEnter: (_) {
                _grabberHovered!.value = true;
              },
              onExit: (_) {
                if (_grabberHovered!.value) {
                  _grabberHovered!.value = false;
                }
              },
              child: row,
            )
          : row,
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
