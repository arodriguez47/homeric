/// Experimental one-block desktop editing host.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' show AdaptiveTextSelectionToolbar;
import 'package:flutter/rendering.dart' hide Decoration;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide Decoration;

import '../decoration/decoration.dart';
import '../input/text_input_session.dart';
import '../model/block.dart';
import '../model/selection.dart';
import '../render/homeric_paragraph.dart';
import '../render/paint_layers.dart';
import '../render/paragraph_geometry.dart';
import '../render/paragraph_source.dart';
import '../view/view_map.dart';
import 'editable_document.dart';
import 'editor_clipboard.dart';
import 'editor_controller.dart';
import 'spell_check.dart';

/// Builds layout-neutral consumer overlays from current paragraph geometry.
typedef HomericEditableOverlayBuilder = List<Widget> Function(
  BuildContext context,
  HomericEditableBlockGeometry geometry,
);

/// A generation-stamped geometry capability for one editable block.
///
/// Query methods return `null` after the render generation becomes stale.
/// Consumers should derive widgets during [HomericEditableOverlayBuilder]
/// rather than retaining this capability as model state.
final class HomericEditableBlockGeometry {
  const HomericEditableBlockGeometry._({
    required this.blockId,
    required this.documentRevision,
    required this.layoutGeneration,
    required ParagraphGeometry geometry,
    required bool Function() isCurrent,
  })  : _geometry = geometry,
        _isCurrent = isCurrent;

  /// Stable canonical block ID.
  final String blockId;

  /// Controller document revision used by this layout.
  final int documentRevision;

  /// Render generation used by this layout.
  final int layoutGeneration;

  final ParagraphGeometry _geometry;
  final bool Function() _isCurrent;

  /// Whether queries still address the mounted current generation.
  bool get isCurrent => _isCurrent();

  /// Paragraph-local layout bounds, or `null` after invalidation.
  Rect? get blockRect => isCurrent ? _geometry.blockRect.value : null;

  /// Returns a paragraph-local caret rectangle for a canonical block offset.
  Rect? caretRect(
    int offset, {
    HomericCaretAffinity affinity = HomericCaretAffinity.downstream,
  }) =>
      isCurrent
          ? _geometry
              .caretRect(
                DocOffset(offset),
                assoc: affinity == HomericCaretAffinity.upstream ? -1 : 1,
              )
              .value
          : null;

  /// Returns paragraph-local rectangles for one canonical block range.
  List<Rect>? rectsForRange(BlockTextRange range) => isCurrent
      ? List<Rect>.unmodifiable(
          _geometry
              .rectsForRange(DocRange(
                DocOffset(range.start),
                DocOffset(range.end),
              ))
              .value
              .map((box) => box.toRect()),
        )
      : null;

  /// Hit-tests [localPoint] into canonical block coordinates.
  HomericDocumentSelectionHit? positionForPoint(Offset localPoint) {
    if (!isCurrent) return null;
    final position = _geometry.positionForPoint(localPoint).value.value;
    final upstream = _geometry.caretRect(DocOffset(position), assoc: -1).value;
    final downstream = _geometry.caretRect(DocOffset(position), assoc: 1).value;
    return (
      offset: position,
      affinity: (localPoint - upstream.centerLeft).distanceSquared <
              (localPoint - downstream.centerLeft).distanceSquared
          ? HomericCaretAffinity.upstream
          : HomericCaretAffinity.downstream,
    );
  }
}

/// A directly editable Homeric paragraph backed by canonical editor state.
///
/// This surface is experimental until a real Nexus consumer validates it.
/// [controller] remains the sole owner of selection and composing state, and
/// [inputSession] must be shared by every paragraph participating in the same
/// one-active-block editor.
///
/// A host that hides canonical syntax must construct [controller] with
/// [HomericEditorController.onBeforeCanonicalMutation] so a pending deletion
/// can reveal the affected replace decoration before the document changes.
/// This widget additionally reveals replace decorations touched by the active
/// selection or composing range for its own layout, paint, and semantics.
class HomericEditableParagraph extends StatefulWidget {
  /// Creates one editable paragraph for [blockId].
  const HomericEditableParagraph({
    super.key,
    required this.controller,
    required this.inputSession,
    required this.blockId,
    required this.resolveStyle,
    this.focusNode,
    this.paragraphSpec = const BlockParagraphSpec(),
    this.baseStyle,
    this.textAlign = TextAlign.start,
    this.textScaler,
    this.slotBuilder,
    this.slotLayoutRevision,
    this.slotAlignment = ui.PlaceholderAlignment.middle,
    this.slotBaseline,
    this.paintStyler,
    this.paintLayers = const <PaintLayer>[],
    this.caretColor,
    this.selectionColor,
    this.inactiveSelectionColor,
    this.composingColor,
    this.caretWidth = 1.5,
    this.clipboard = const SystemHomericClipboard(),
    this.onHostEvent,
    this.onShowToolbar,
    this.spellCheckProvider,
    this.spellingColor,
    this.overlayBuilder,
  }) : assert(caretWidth > 0);

  /// Canonical state owner.
  final HomericEditorController controller;

  /// Shared epoch-bound Flutter input session.
  final HomericTextInputSession inputSession;

  /// Stable id of the block rendered by this host.
  final String blockId;

  /// Resolves each current paragraph run to a painting style.
  final RunStyleResolver<TextStyle> resolveStyle;

  /// Optional persistent focus node owned by the caller.
  final FocusNode? focusNode;

  /// Block-level paragraph inputs.
  final BlockParagraphSpec paragraphSpec;

  /// Base paragraph style.
  final TextStyle? baseStyle;

  /// Paragraph alignment.
  final TextAlign textAlign;

  /// Explicit text scaling override.
  final TextScaler? textScaler;

  /// Builds inline slot children.
  final SlotWidgetBuilder? slotBuilder;

  /// Revision for geometry-affecting state owned by [slotBuilder].
  final Object? slotLayoutRevision;

  /// Inline slot alignment.
  final ui.PlaceholderAlignment slotAlignment;

  /// Baseline for baseline-relative [slotAlignment].
  final TextBaseline? slotBaseline;

  /// Existing paint-only glyph styler.
  final PaintOnlyStyler? paintStyler;

  /// Consumer paint layers. Editing layers are inserted around these in the
  /// fixed order: existing underlays, selection, glyphs, existing overlays,
  /// composing underline, then caret.
  final List<PaintLayer> paintLayers;

  /// Focused caret color, or a visible brightness-aware default.
  final Color? caretColor;

  /// Focused selection color, or a visible brightness-aware default.
  final Color? selectionColor;

  /// Unfocused expanded-selection color, or a subdued default.
  final Color? inactiveSelectionColor;

  /// Focused composing underline color, or a visible default.
  final Color? composingColor;

  /// Width of the focused caret.
  final double caretWidth;

  /// Injectable plain-text clipboard boundary.
  final HomericClipboardAdapter clipboard;

  /// Receives typed clipboard rejection and failure feedback.
  final ValueChanged<HomericHostEvent>? onHostEvent;

  /// Optional toolbar request used by the desktop menu layer.
  final VoidCallback? onShowToolbar;

  /// Optional projected-text spelling provider.
  ///
  /// Desktop spelling is disabled when this is null; Homeric never silently
  /// substitutes a platform spell engine.
  final HomericSpellCheckProvider? spellCheckProvider;

  /// Color of transient spelling squiggles.
  final Color? spellingColor;

  /// Builds consumer overlays from the current paragraph generation.
  final HomericEditableOverlayBuilder? overlayBuilder;

  @override
  State<HomericEditableParagraph> createState() =>
      _HomericEditableParagraphState();
}

class _HomericEditableParagraphState extends State<HomericEditableParagraph> {
  static const _caretBlinkHalfPeriod = Duration(milliseconds: 500);

  late FocusNode _focusNode;
  int _geometryPublicationSerial = 0;
  int? _dragAnchor;
  BlockTextRange? _dragWordAnchor;
  _DragSelectionMode? _dragMode;
  RenderHomericParagraph? _renderParagraph;
  int? _renderGeneration;
  ParagraphGeometry? _paragraphGeometry;
  int _hostEpoch = 0;
  late _EditableHostCommandDelegate _commandDelegate;
  late HomericEditorClipboard _clipboard;
  HomericEditableDocumentState? _documentHost;
  late final VoidCallback _semanticsCopy;
  late final VoidCallback _semanticsCut;
  late final VoidCallback _semanticsPaste;
  late final VoidCallback _semanticsSelectAll;
  BuildContext? _commandContext;
  BuildContext? _overlayContext;
  Offset? _secondaryLocalPosition;
  BlockTextRange? _secondaryWordRange;
  ContextMenuController? _contextMenuController;
  int _spellRequestGeneration = 0;
  _SpellRequestKey? _spellRequestKey;
  List<_ResolvedSpellingSuggestion> _spellingSuggestions = const [];
  Timer? _caretTimer;
  final ValueNotifier<bool> _caretVisibility = ValueNotifier<bool>(true);
  HomericSelection? _caretSelection;
  HomericTextRange? _caretComposing;
  int _caretContentRevision = 0;
  bool _tickerEnabled = true;
  bool _disableAnimations = false;
  bool _disposing = false;

  HomericEditorController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _validateSession();
    _focusNode = widget.focusNode ?? FocusNode();
    _semanticsCopy = () => _dispatchIntent(CopySelectionTextIntent.copy);
    _semanticsCut = () => _dispatchIntent(const CopySelectionTextIntent.cut(
          SelectionChangedCause.toolbar,
        ));
    _semanticsPaste = () => _dispatchIntent(
          const PasteTextIntent(SelectionChangedCause.toolbar),
        );
    _semanticsSelectAll = () => _dispatchIntent(
          const SelectAllTextIntent(SelectionChangedCause.toolbar),
        );
    _renewHostBindings();
    _captureCaretState();
    _controller.addListener(_controllerChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final documentHost = HomericEditableDocument.maybeOf(context);
    if (!identical(documentHost, _documentHost)) {
      _documentHost?.unregisterCommandHost(widget.blockId, _commandDelegate);
      _documentHost?.unregisterSelectionHost(widget.blockId, this);
      _documentHost = documentHost;
      documentHost?.registerCommandHost(widget.blockId, _commandDelegate);
    }
    // `valuesOf` postdates Homeric's Flutter 3.24 minimum.
    // ignore: deprecated_member_use
    final tickerEnabled = TickerMode.of(context);
    final disableAnimations =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (_tickerEnabled == tickerEnabled &&
        _disableAnimations == disableAnimations) {
      return;
    }
    _tickerEnabled = tickerEnabled;
    _disableAnimations = disableAnimations;
    _syncCaretBlink(resetVisible: disableAnimations);
  }

  @override
  void didUpdateWidget(HomericEditableParagraph oldWidget) {
    super.didUpdateWidget(oldWidget);
    _validateSession();
    final hadFocus = _focusNode.hasFocus;
    final controllerChanged =
        !identical(oldWidget.controller, widget.controller);
    final sessionChanged =
        !identical(oldWidget.inputSession, widget.inputSession);
    final blockChanged = oldWidget.blockId != widget.blockId;
    final focusNodeChanged = !identical(oldWidget.focusNode, widget.focusNode);
    final caretDependenciesChanged =
        controllerChanged || sessionChanged || blockChanged || focusNodeChanged;
    final spellProviderChanged =
        !identical(oldWidget.spellCheckProvider, widget.spellCheckProvider);
    final hostDependenciesChanged = controllerChanged ||
        sessionChanged ||
        blockChanged ||
        focusNodeChanged ||
        !identical(oldWidget.clipboard, widget.clipboard);
    final oldDelegate = _commandDelegate;
    if (hadFocus &&
        (controllerChanged ||
            sessionChanged ||
            blockChanged ||
            focusNodeChanged)) {
      oldWidget.inputSession.blur();
    }
    if (controllerChanged) {
      oldWidget.controller.removeListener(_controllerChanged);
      widget.controller.addListener(_controllerChanged);
    }
    if (focusNodeChanged) {
      if (oldWidget.focusNode == null) _focusNode.dispose();
      _focusNode = widget.focusNode ?? FocusNode();
      if (hadFocus) _focusNode.requestFocus();
    }
    if (hostDependenciesChanged || spellProviderChanged) {
      _clearTransientState();
    }
    if (hostDependenciesChanged) {
      _documentHost?.unregisterCommandHost(oldWidget.blockId, oldDelegate);
      _documentHost?.unregisterSelectionHost(oldWidget.blockId, this);
      _renewHostBindings();
      _documentHost?.registerCommandHost(widget.blockId, _commandDelegate);
    }
    if (hadFocus && _focusNode.hasFocus && hostDependenciesChanged) {
      if (_controller.document.indexOfBlockId(widget.blockId) != null) {
        if (_controller.activeBlockId != widget.blockId) {
          _relocate(0, 0);
        } else {
          _attachInput();
        }
      }
    }
    if (controllerChanged) _captureCaretState();
    if (caretDependenciesChanged) {
      _syncCaretBlink(resetVisible: hadFocus);
    }
  }

  @override
  void dispose() {
    _disposing = true;
    _hostEpoch++;
    _clearTransientState();
    _stopCaretBlink();
    _caretVisibility.dispose();
    _clipboard.dispose();
    _documentHost?.unregisterCommandHost(widget.blockId, _commandDelegate);
    _documentHost?.unregisterSelectionHost(widget.blockId, this);
    _controller.removeListener(_controllerChanged);
    if (widget.inputSession.activeBlockId == widget.blockId) {
      widget.inputSession.blur();
    }
    if (widget.focusNode == null) _focusNode.dispose();
    super.dispose();
  }

  void _renewHostBindings() {
    if (_hostEpoch != 0) _clipboard.dispose();
    final epoch = ++_hostEpoch;
    _commandDelegate = _EditableHostCommandDelegate(this, epoch);
    _clipboard = HomericEditorClipboard(
      controller: widget.controller,
      blockId: widget.blockId,
      adapter: widget.clipboard,
      isHostCurrent: () => _isHostEpochCurrent(epoch),
      onEvent: (event) => widget.onHostEvent?.call(event),
    );
  }

  bool _isHostEpochCurrent(int epoch) =>
      mounted &&
      epoch == _hostEpoch &&
      _ownsEditingFocus &&
      _controller.activeBlockId == widget.blockId &&
      (_controller.isReadOnly ||
          widget.inputSession.activeBlockId == widget.blockId);

  bool get _ownsEditingFocus =>
      _focusNode.hasFocus || (_contextMenuController?.isShown ?? false);

  bool _attachInput() =>
      !_controller.isReadOnly &&
      (_documentHost?.attachCommandHost(
            widget.blockId,
            _commandDelegate,
          ) ??
          widget.inputSession.attach(
            blockId: widget.blockId,
            commandDelegate: _commandDelegate,
          ));

  void _validateSession() {
    if (!identical(widget.controller, widget.inputSession.controller)) {
      throw ArgumentError('inputSession must observe controller');
    }
  }

  void _controllerChanged() {
    if (!mounted) return;
    if (_controller.isReadOnly) {
      if (widget.inputSession.activeBlockId == widget.blockId) {
        widget.inputSession.blur();
      }
    } else if (_focusNode.hasFocus &&
        _controller.activeBlockId == widget.blockId &&
        !widget.inputSession.isAttached) {
      _attachInput();
    }
    if (_spellingSuggestions.isNotEmpty &&
        _spellingSuggestions.first.contentRevision !=
            _controller.contentRevision) {
      _spellingSuggestions = const [];
    }
    final caretStateChanged = _captureCaretState();
    if (caretStateChanged) _syncCaretBlink(resetVisible: true);
    setState(() {});
  }

  bool _captureCaretState() {
    final selection = _controller.selection;
    final composing = _controller.composing;
    final contentRevision = _controller.contentRevision;
    final changed = selection != _caretSelection ||
        composing != _caretComposing ||
        contentRevision != _caretContentRevision;
    _caretSelection = selection;
    _caretComposing = composing;
    _caretContentRevision = contentRevision;
    return changed;
  }

  bool get _canBlinkCaret {
    final selection = _localSelection();
    return _ownsEditingFocus &&
        !_controller.isReadOnly &&
        selection != null &&
        selection.isCollapsed &&
        _controller.composing == null;
  }

  void _syncCaretBlink({required bool resetVisible}) {
    _stopCaretBlink();
    if (resetVisible || _disableAnimations) _caretVisibility.value = true;
    if (!_canBlinkCaret || !_tickerEnabled || _disableAnimations) return;
    _caretTimer = Timer.periodic(_caretBlinkHalfPeriod, (_) {
      if (!_canBlinkCaret) {
        _stopCaretBlink();
        return;
      }
      _caretVisibility.value = !_caretVisibility.value;
    });
  }

  void _stopCaretBlink() {
    _caretTimer?.cancel();
    _caretTimer = null;
  }

  Block? get _block => _controller.document.blockById(widget.blockId);

  @override
  Widget build(BuildContext context) {
    final block = _block;
    if (block == null) return const SizedBox.shrink();
    final localSelection = _localSelection();
    final fullySelectedEmptyBlock = block.contentLength == 0 &&
        (_documentHost?.isBlockFullySelected(widget.blockId) ?? false);
    final localComposing = _localComposing();
    final decorations = _controller.decorations.forBlock(widget.blockId);
    final reveal = _revealState(decorations, localSelection, localComposing);
    final source = ParagraphSource<TextStyle>.build(
      block: block,
      decorations: decorations,
      reveal: reveal,
      resolveStyle: widget.resolveStyle,
      spec: widget.paragraphSpec,
    );
    final semanticsSource = ParagraphSource<Object?>.build(
      block: block,
      decorations: decorations,
      resolveStyle: (_) => null,
      spec: widget.paragraphSpec,
    );
    _ensureSpellCheck(semanticsSource);
    final focused = localSelection != null &&
        (_ownsEditingFocus || (_documentHost?.hasEditingFocus ?? false));
    final brightness = MediaQuery.maybePlatformBrightnessOf(context) ??
        ui.PlatformDispatcher.instance.platformBrightness;
    final caretColor = widget.caretColor ??
        (brightness == Brightness.dark
            ? const Color(0xFFF3F5FF)
            : const Color(0xFF202124));
    final selectionColor = widget.selectionColor ??
        (brightness == Brightness.dark
            ? const Color(0x668FA8FF)
            : const Color(0x664F64C8));
    final inactiveSelectionColor = widget.inactiveSelectionColor ??
        (brightness == Brightness.dark
            ? const Color(0x338FA8FF)
            : const Color(0x334F64C8));
    final composingColor = widget.composingColor ??
        (brightness == Brightness.dark
            ? const Color(0xFF9DB2FF)
            : const Color(0xFF3F51B5));
    final spellingColor = widget.spellingColor ??
        (brightness == Brightness.dark
            ? const Color(0xFFFF7B72)
            : const Color(0xFFD93025));
    final editingLayers = <PaintLayer>[
      ...widget.paintLayers,
      if (localSelection != null && !localSelection.isCollapsed)
        PaintLayer(
          range: DocRange(
            DocOffset(localSelection.start),
            DocOffset(localSelection.end),
          ),
          band: PaintBand.underlay,
          painter: solidWashPainter,
          spec: SolidWashSpec(
            focused ? selectionColor : inactiveSelectionColor,
          ),
        ),
      for (final suggestion in _currentSpellingSuggestions)
        PaintLayer(
          range: DocRange(
            DocOffset(suggestion.range.start),
            DocOffset(suggestion.range.end),
          ),
          band: PaintBand.overlay,
          painter: _paintSpellingSquiggle,
          spec: UnderlineSpec(spellingColor),
        ),
      if (focused && localComposing != null && !localComposing.isCollapsed)
        PaintLayer(
          range: DocRange(
            DocOffset(localComposing.start),
            DocOffset(localComposing.end),
          ),
          band: PaintBand.overlay,
          painter: underlinePainter,
          spec: UnderlineSpec(composingColor, thickness: 1.5, gap: -1),
        ),
    ];

    final paragraph = HomericParagraph(
      key: ValueKey<String>('homeric-editable-${widget.blockId}'),
      source: source,
      baseStyle: widget.baseStyle,
      textAlign: widget.textAlign,
      textScaler: widget.textScaler,
      slotBuilder: widget.slotBuilder,
      slotAlignment: widget.slotAlignment,
      slotBaseline: widget.slotBaseline,
      paintStyler: widget.paintStyler,
      paintLayers: editingLayers,
      semanticsSource: semanticsSource,
      onGeometryChanged: _geometryChanged,
    );

    final body = ParagraphOverlay(
      paragraph: paragraph,
      slotLayoutRevision: widget.slotLayoutRevision,
      overlayBuilder: (overlayContext, geometry) {
        _overlayContext = overlayContext;
        final geometryDocumentRevision = _controller.documentRevision;
        final consumerGeometry = HomericEditableBlockGeometry._(
          blockId: widget.blockId,
          documentRevision: geometryDocumentRevision,
          layoutGeneration: geometry.generation,
          geometry: geometry,
          isCurrent: () =>
              geometryDocumentRevision == _controller.documentRevision &&
              _isCurrentGeometry(geometry),
        );
        _documentHost?.registerSelectionHost(
          widget.blockId,
          owner: this,
          globalRect: () {
            final render = overlayContext.findRenderObject();
            if (render is! RenderBox || !render.attached || !render.hasSize) {
              return null;
            }
            return render.localToGlobal(Offset.zero) & render.size;
          },
          hitTest: (globalPoint) {
            if (!_isCurrentGeometry(geometry)) return null;
            final render = overlayContext.findRenderObject();
            if (render is! RenderBox || !render.attached || !render.hasSize) {
              return null;
            }
            final localPoint = render.globalToLocal(globalPoint);
            final rect = geometry.blockRect.value;
            final hit = _caretForPoint(
              geometry,
              Offset(
                localPoint.dx.clamp(rect.left, rect.right),
                localPoint.dy.clamp(rect.top, rect.bottom),
              ),
            );
            return (offset: hit.position, affinity: hit.affinity);
          },
          globalRangeRects: (range) {
            if (geometryDocumentRevision != _controller.documentRevision ||
                !_isCurrentGeometry(geometry)) {
              return null;
            }
            final render = overlayContext.findRenderObject();
            if (render is! RenderBox || !render.attached || !render.hasSize) {
              return null;
            }
            final localRects = consumerGeometry.rectsForRange(range);
            if (localRects == null) return null;
            return <Rect>[
              for (final rect in localRects)
                render.localToGlobal(rect.topLeft) & rect.size,
            ];
          },
          activeCaretGeometry: () {
            if (geometryDocumentRevision != _controller.documentRevision ||
                !_isCurrentGeometry(geometry) ||
                _controller.activeBlockId != widget.blockId) {
              return null;
            }
            final selection = _localSelection();
            final render = overlayContext.findRenderObject();
            if (selection == null ||
                !selection.isCollapsed ||
                render is! RenderBox ||
                !render.attached ||
                !render.hasSize) {
              return null;
            }
            final localRect = consumerGeometry.caretRect(
              selection.head,
              affinity: selection.affinity,
            );
            if (localRect == null) return null;
            final globalOrigin = render.localToGlobal(localRect.topLeft);
            return HomericActiveCaretGeometry(
              blockId: widget.blockId,
              documentRevision: geometryDocumentRevision,
              layoutGeneration: geometry.generation,
              globalRect: globalOrigin & localRect.size,
            );
          },
        );
        _scheduleGeometryPublication(overlayContext, geometry);
        final caret = focused && localSelection.isCollapsed
            ? geometry
                .caretRect(
                  DocOffset(localSelection.head),
                  assoc: _assoc(localSelection.affinity),
                )
                .value
            : null;
        return <Widget>[
          if (fullySelectedEmptyBlock)
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  key: ValueKey<String>(
                    'homeric-empty-selection-${widget.blockId}',
                  ),
                  color: focused ? selectionColor : inactiveSelectionColor,
                ),
              ),
            ),
          Positioned.fill(
            child: TextSelectionGestureDetector(
              behavior: HitTestBehavior.translucent,
              onTapDown: (details) => _tapDown(geometry, details),
              onDoubleTapDown: (details) => _doubleTapDown(geometry, details),
              onTripleTapDown: (details) => _tripleTapDown(geometry, details),
              onDragSelectionStart: (details) =>
                  _startSelectionDrag(geometry, details),
              onDragSelectionUpdate: (details) =>
                  _updateSelectionDrag(geometry, details.localPosition),
              onDragSelectionEnd: (_) => _endSelectionPointer(),
              onSingleTapCancel: _cancelSelectionPointer,
              onTapTrackReset: _cancelSelectionPointer,
              onSecondaryTapDown: (details) =>
                  _secondaryTapDown(geometry, details.localPosition),
              onSecondaryTap: () => _showContextMenu(useSecondaryAnchor: true),
              child: const SizedBox.expand(),
            ),
          ),
          ...?widget.overlayBuilder?.call(
            overlayContext,
            consumerGeometry,
          ),
          if (caret != null)
            Positioned.fromRect(
              rect: Rect.fromLTWH(
                caret.left - widget.caretWidth / 2,
                caret.top,
                widget.caretWidth,
                caret.height,
              ),
              child: ValueListenableBuilder<bool>(
                valueListenable: _caretVisibility,
                builder: (_, visible, __) => IgnorePointer(
                  child: visible
                      ? ColoredBox(color: caretColor)
                      : const SizedBox.shrink(),
                ),
              ),
            ),
        ];
      },
    );

    final shortcuts = <ShortcutActivator, Intent>{
      if (_documentHost != null)
        const SingleActivator(LogicalKeyboardKey.enter):
            const HomericInsertParagraphBreakIntent(),
      if (_documentHost != null)
        const SingleActivator(LogicalKeyboardKey.numpadEnter):
            const HomericInsertParagraphBreakIntent(),
      const SingleActivator(LogicalKeyboardKey.tab):
          const _TraverseIntent(false),
      const SingleActivator(LogicalKeyboardKey.tab, shift: true):
          const _TraverseIntent(true),
      const SingleActivator(
        LogicalKeyboardKey.arrowUp,
        meta: true,
        shift: true,
      ): const _MoveDocumentBlockIntent(-1),
      const SingleActivator(
        LogicalKeyboardKey.arrowDown,
        meta: true,
        shift: true,
      ): const _MoveDocumentBlockIntent(1),
    };
    final documentCommandBindings = _documentHost?.commandBindings ??
        const <HomericDocumentCommandBinding>[];
    final commandBindings =
        <ShortcutActivator, List<HomericDocumentCommandBinding>>{};
    for (final binding in documentCommandBindings) {
      commandBindings
          .putIfAbsent(
            binding.shortcut,
            () => <HomericDocumentCommandBinding>[],
          )
          .add(binding);
    }
    for (final entry in commandBindings.entries) {
      final fallback = shortcuts[entry.key];
      shortcuts[entry.key] = _DocumentCommandIntent(
        List<HomericDocumentCommandBinding>.unmodifiable(entry.value),
        registrationOwner: documentCommandBindings,
        fallback: fallback,
        appKitSelector: _appKitSelectorForShortcut(entry.key),
      );
    }
    final actions = <Type, Action<Intent>>{
      DoNothingAndStopPropagationTextIntent:
          DoNothingAction(consumesKey: false),
      _MoveCaretIntent: _HostAction<_MoveCaretIntent>(
        enabled: (_) => _canUseSelectionActions,
        invoke: _moveCaret,
      ),
      _TraverseIntent: _HostAction<_TraverseIntent>(
        invoke: (intent) => intent.backward
            ? _focusNode.previousFocus()
            : _focusNode.nextFocus(),
      ),
      _MoveDocumentBlockIntent: _HostAction<_MoveDocumentBlockIntent>(
        // Keep the exact chord at this nearest command boundary even when
        // composition or a cross-block selection makes the move a no-op.
        enabled: (_) => _canMutateActions && _documentHost != null,
        invoke: (intent) {
          widget.inputSession.suppressNextSelector(intent.delta < 0
              ? 'moveUpAndModifySelection:'
              : 'moveDownAndModifySelection:');
          return _documentHost?.moveActiveBlock(intent.delta);
        },
      ),
      HomericInsertParagraphBreakIntent:
          _HostAction<HomericInsertParagraphBreakIntent>(
        enabled: (_) => _canMutateActions && _documentHost != null,
        invoke: (_) => _controller.insertParagraphBreak(),
      ),
      DismissIntent: _HostAction<DismissIntent>(
        enabled: (_) => _contextMenuController?.isShown ?? false,
        invoke: (_) => _dismissContextMenu(),
      ),
      DeleteCharacterIntent: _HostAction<DeleteCharacterIntent>(
        enabled: (_) => _canMutateActions,
        invoke: (intent) => intent.forward
            ? _controller.deleteForward()
            : _controller.deleteBackward(),
      ),
      ExtendSelectionByCharacterIntent:
          _HostAction<ExtendSelectionByCharacterIntent>(
        enabled: (_) => _canUseSelectionActions,
        invoke: (intent) => _moveCaret(_MoveCaretIntent(
          intent.forward
              ? CaretMovementDirection.right
              : CaretMovementDirection.left,
          !intent.collapseSelection,
        )),
      ),
      ExtendSelectionVerticallyToAdjacentLineIntent:
          _HostAction<ExtendSelectionVerticallyToAdjacentLineIntent>(
        enabled: (_) => _canUseSelectionActions,
        invoke: (intent) => _moveCaret(_MoveCaretIntent(
          intent.forward
              ? CaretMovementDirection.down
              : CaretMovementDirection.up,
          !intent.collapseSelection,
        )),
      ),
      ExtendSelectionToLineBreakIntent:
          _HostAction<ExtendSelectionToLineBreakIntent>(
        enabled: (_) => _canUseSelectionActions,
        invoke: (intent) => _moveToLineBoundary(
          forward: intent.forward,
          extend: !intent.collapseSelection,
        ),
      ),
      ExpandSelectionToLineBreakIntent:
          _HostAction<ExpandSelectionToLineBreakIntent>(
        enabled: (_) => _canUseSelectionActions,
        invoke: (intent) => _moveToLineBoundary(
          forward: intent.forward,
          extend: true,
        ),
      ),
      ExtendSelectionToDocumentBoundaryIntent:
          _HostAction<ExtendSelectionToDocumentBoundaryIntent>(
        enabled: (_) => _canUseSelectionActions && _documentHost != null,
        invoke: (intent) => _documentHost?.moveToDocumentBoundary(
          forward: intent.forward,
          extend: !intent.collapseSelection,
        ),
      ),
      ExpandSelectionToDocumentBoundaryIntent:
          _HostAction<ExpandSelectionToDocumentBoundaryIntent>(
        enabled: (_) => _canUseSelectionActions && _documentHost != null,
        invoke: (intent) => _documentHost?.moveToDocumentBoundary(
          forward: intent.forward,
          extend: true,
        ),
      ),
      ExtendSelectionToNextWordBoundaryIntent:
          _HostAction<ExtendSelectionToNextWordBoundaryIntent>(
        enabled: (_) => _canUseSelectionActions,
        invoke: (intent) => _moveByWord(
          forward: intent.forward,
          collapseSelection: intent.collapseSelection,
        ),
      ),
      ExtendSelectionToNextWordBoundaryOrCaretLocationIntent:
          _HostAction<ExtendSelectionToNextWordBoundaryOrCaretLocationIntent>(
        enabled: (_) => _canUseSelectionActions,
        invoke: (intent) => _moveByWord(
          forward: intent.forward,
          collapseSelection: intent.collapseSelection,
          collapseAtReversal: intent.collapseAtReversal,
        ),
      ),
      DeleteToNextWordBoundaryIntent:
          _HostAction<DeleteToNextWordBoundaryIntent>(
        enabled: (_) => _canMutateActions,
        invoke: (intent) => _deleteByWord(forward: intent.forward),
      ),
      CopySelectionTextIntent: _HostAction<CopySelectionTextIntent>(
        enabled: (intent) =>
            _canCopy && (!intent.collapseSelection || _canMutateActions),
        invoke: (intent) =>
            intent.collapseSelection ? _clipboard.cut() : _clipboard.copy(),
      ),
      PasteTextIntent: _HostAction<PasteTextIntent>(
        enabled: (_) => _canMutateActions,
        invoke: (_) => _clipboard.paste(),
      ),
      SelectAllTextIntent: _HostAction<SelectAllTextIntent>(
        enabled: (_) =>
            _canUseSelectionActions &&
            (_documentHost != null || block.contentLength > 0),
        invoke: (_) => _documentHost?.selectAll() ?? _selectAll(),
      ),
      UndoTextIntent: _HostAction<UndoTextIntent>(
        enabled: (_) => _canMutateActions && _controller.canUndo,
        invoke: (_) => _controller.undo(),
      ),
      RedoTextIntent: _HostAction<RedoTextIntent>(
        enabled: (_) => _canMutateActions && _controller.canRedo,
        invoke: (_) => _controller.redo(),
      ),
      _DocumentCommandIntent: _DocumentCommandAction(this, _hostEpoch),
    };

    final semanticsSelection = localSelection == null
        ? null
        : TextSelection(
            baseOffset: localSelection.anchor,
            extentOffset: localSelection.head,
            affinity: localSelection.affinity == HomericCaretAffinity.upstream
                ? TextAffinity.upstream
                : TextAffinity.downstream,
          );
    return _EditableSemantics(
      value: block.text,
      selection: semanticsSelection,
      focused: _focusNode.hasFocus,
      editable:
          _documentHost == null || _controller.activeBlockId == widget.blockId,
      readOnly: _controller.isReadOnly,
      textDirection: widget.paragraphSpec.direction == ParagraphDirection.rtl
          ? TextDirection.rtl
          : TextDirection.ltr,
      onFocus: _focusNode.requestFocus,
      onTap: _focusNode.requestFocus,
      onSetText: _controller.isReadOnly ? null : _setSemanticsText,
      onSetSelection: _setSemanticsSelection,
      onCopy: _canCopy ? _semanticsCopy : null,
      onCut: _canCopy && _canMutateActions ? _semanticsCut : null,
      onPaste: _canMutateActions ? _semanticsPaste : null,
      onSelectAll: _canUseSelectionActions && block.contentLength > 0
          ? _semanticsSelectAll
          : null,
      child: ExcludeSemantics(
        child: DefaultTextEditingShortcuts(
          child: Shortcuts(
            shortcuts: shortcuts,
            child: Actions(
              actions: actions,
              child: Builder(
                builder: (commandContext) {
                  _commandContext = commandContext;
                  return Focus(
                    focusNode: _focusNode,
                    onFocusChange: _focusChanged,
                    child: body,
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool get _canUseSelectionActions =>
      _ownsEditingFocus &&
      _controller.activeBlockId == widget.blockId &&
      _controller.composing == null;

  bool get _canMutateActions =>
      _canUseSelectionActions && !_controller.isReadOnly;

  bool get _canCopy {
    final selection = _controller.selection;
    return _canUseSelectionActions &&
        selection != null &&
        !selection.isCollapsed;
  }

  Object? _dispatchIntent(Intent intent) {
    final commandContext = _commandContext;
    return commandContext == null
        ? null
        : Actions.maybeInvoke(commandContext, intent);
  }

  _DocumentCommandDisposition _invokeDocumentCommand(
    _DocumentCommandIntent intent,
    int epoch,
  ) {
    if (!_isHostEpochCurrent(epoch)) {
      return _DocumentCommandDisposition.ignored;
    }
    final documentHost = _documentHost;
    if (documentHost == null) return _DocumentCommandDisposition.ignored;
    if (!identical(documentHost.commandBindings, intent.registrationOwner)) {
      return _DocumentCommandDisposition.ignored;
    }
    final context = documentHost.createCommandContext(
      blockId: widget.blockId,
      hostEpoch: epoch,
      isCurrent: () => _isHostEpochCurrent(epoch),
    );
    for (final binding in intent.bindings) {
      if (!context.isCurrent) {
        return _DocumentCommandDisposition.ignored;
      }
      final revisionBefore = _controller.stateRevision;
      final result = binding.onInvoke(context);
      if (_controller.stateRevision != revisionBefore) {
        throw StateError(
          'A Homeric document command handler must return before editor '
          'state changes.',
        );
      }
      switch (result) {
        case HomericDocumentCommandIgnored():
          continue;
        case HomericDocumentCommandRejected():
          _suppressFollowUpSelector(intent);
          final rejection = HomericDocumentCommandRejection(
            reason: result.reason,
            announcement: result.announcement,
            blockId: widget.blockId,
            hostEpoch: epoch,
          );
          documentHost.reportCommandRejection(rejection);
          // Flutter 3.24 does not yet expose the multi-view announcement API.
          // ignore: deprecated_member_use
          SemanticsService.announce(
            result.announcement,
            Directionality.of(this.context),
          );
          return _DocumentCommandDisposition.handled;
        case HomericDocumentCommandHandled():
          _suppressFollowUpSelector(intent);
          return _DocumentCommandDisposition.handled;
        case HomericDocumentCommandPrepared():
          if (!context.isCurrent) {
            return _DocumentCommandDisposition.ignored;
          }
          _controller.applyPreparedCommand(result.command);
          _suppressFollowUpSelector(intent);
          return _DocumentCommandDisposition.handled;
      }
    }
    final fallback = intent.fallback;
    if (fallback != null && context.isCurrent) {
      _dispatchIntent(fallback);
      return _DocumentCommandDisposition.handled;
    }
    return _DocumentCommandDisposition.ignored;
  }

  void _suppressFollowUpSelector(_DocumentCommandIntent intent) {
    final selector = intent.appKitSelector;
    if (selector != null) widget.inputSession.suppressNextSelector(selector);
  }

  Object? _selectAll() {
    final block = _block;
    if (block == null) return null;
    _setLocalSelection(
      0,
      block.contentLength,
      affinity: HomericCaretAffinity.downstream,
      resetPreferredX: true,
    );
    return null;
  }

  BlockTextSelection? _localSelection() {
    final documentHost = _documentHost;
    if (documentHost != null) {
      return documentHost.selectionFragmentForBlock(widget.blockId);
    }
    final selection = _controller.selection;
    if (selection == null) return null;
    try {
      return BlockTextSelection(
        anchor: _controller.blockOffsetForGlobalPosition(
          widget.blockId,
          selection.anchor,
        ),
        head: _controller.blockOffsetForGlobalPosition(
          widget.blockId,
          selection.head,
        ),
        affinity: selection.affinity,
      );
    } on ArgumentError {
      return null;
    }
  }

  BlockTextRange? _localComposing() {
    final composing = _controller.composing;
    if (composing == null) return null;
    try {
      return BlockTextRange(
        _controller.blockOffsetForGlobalPosition(
          widget.blockId,
          composing.start,
        ),
        _controller.blockOffsetForGlobalPosition(
          widget.blockId,
          composing.end,
        ),
      );
    } on ArgumentError {
      return null;
    }
  }

  RevealState _revealState(
    List<Decoration> decorations,
    BlockTextSelection? selection,
    BlockTextRange? composing,
  ) {
    final revealed = <Decoration>[];
    for (final decoration in decorations) {
      if (decoration.kind != DecorationKind.replace) continue;
      if (_touches(decoration.start, decoration.end, selection?.start,
              selection?.end) ||
          _touches(decoration.start, decoration.end, composing?.start,
              composing?.end)) {
        revealed.add(decoration);
      }
    }
    return revealed.isEmpty ? RevealState.none : RevealState.of(revealed);
  }

  static bool _touches(int start, int end, int? rangeStart, int? rangeEnd) {
    if (rangeStart == null || rangeEnd == null) return false;
    if (rangeStart == rangeEnd) return rangeStart >= start && rangeStart <= end;
    return rangeStart < end && rangeEnd > start;
  }

  void _tapDown(ParagraphGeometry geometry, TapDragDownDetails details) {
    if (details.consecutiveTapCount != 1 || !_canUsePointer(geometry)) return;
    _dismissContextMenu();
    final hit = _caretForPoint(geometry, details.localPosition);
    _resetPointerState();
    _relocate(hit.position, hit.position, affinity: hit.affinity);
  }

  void _doubleTapDown(
    ParagraphGeometry geometry,
    TapDragDownDetails details,
  ) {
    if (!_canUsePointer(geometry)) return;
    _dismissContextMenu();
    _startWordSelection(geometry, details.localPosition);
  }

  void _tripleTapDown(
    ParagraphGeometry geometry,
    TapDragDownDetails details,
  ) {
    if (!_canUsePointer(geometry)) return;
    _dismissContextMenu();
    _startParagraphSelection();
  }

  void _startSelectionDrag(
    ParagraphGeometry geometry,
    TapDragStartDetails details,
  ) {
    if (!_canUsePointer(geometry)) return;
    _dismissContextMenu();
    final count = details.consecutiveTapCount;
    if (count >= 3) {
      _startParagraphSelection();
      return;
    }
    if (count == 2) {
      _startWordSelection(geometry, details.localPosition);
      return;
    }
    final hit = _caretForPoint(geometry, details.localPosition);
    _dragMode = _DragSelectionMode.character;
    _dragAnchor = hit.position;
    _dragWordAnchor = null;
    _relocate(hit.position, hit.position, affinity: hit.affinity);
    final documentHost = _documentHost;
    if (documentHost != null) {
      documentHost.beginPointerSelectionDrag(
        _controller.globalPositionForBlockOffset(
          widget.blockId,
          hit.position,
        ),
        owner: this,
      );
    }
  }

  void _updateSelectionDrag(ParagraphGeometry geometry, Offset point) {
    final documentHost = _documentHost;
    if (documentHost?.pointerSelectionDragActive ?? false) {
      final render = _overlayContext?.findRenderObject();
      if (render is RenderBox && render.attached) {
        documentHost!.updatePointerSelectionDrag(render.localToGlobal(point));
      }
      return;
    }
    final anchor = _dragAnchor;
    final mode = _dragMode;
    if (anchor == null || mode == null || !_canUsePointer(geometry)) return;
    if (mode == _DragSelectionMode.paragraph) {
      final length = _block?.contentLength ?? 0;
      _relocate(0, length);
      return;
    }
    final rect = geometry.blockRect.value;
    final clamped = Offset(
      point.dx.clamp(rect.left, rect.right),
      point.dy.clamp(rect.top, rect.bottom),
    );
    if (mode == _DragSelectionMode.word) {
      final initial = _dragWordAnchor;
      if (initial == null) return;
      final word = _wordForPoint(geometry, clamped);
      if (word.end <= initial.start) {
        _relocate(initial.end, word.start,
            affinity: HomericCaretAffinity.upstream);
      } else {
        _relocate(initial.start, word.end);
      }
      return;
    }
    final hit = _caretForPoint(geometry, clamped);
    _relocate(anchor, hit.position, affinity: hit.affinity);
  }

  bool _canUsePointer(ParagraphGeometry geometry) =>
      _isCurrentGeometry(geometry) &&
      (_controller.composing == null ||
          _controller.activeBlockId != widget.blockId);

  void _startWordSelection(ParagraphGeometry geometry, Offset point) {
    final word = _wordForPoint(geometry, point);
    _dragMode = _DragSelectionMode.word;
    _dragWordAnchor = word;
    _dragAnchor = word.start;
    _relocate(word.start, word.end);
  }

  void _startParagraphSelection() {
    final length = _block?.contentLength ?? 0;
    _dragMode = _DragSelectionMode.paragraph;
    _dragAnchor = 0;
    _dragWordAnchor = null;
    _relocate(0, length);
  }

  BlockTextRange _wordForPoint(ParagraphGeometry geometry, Offset point) {
    final hit = _caretForPoint(geometry, point);
    return _wordForHit(geometry, hit);
  }

  BlockTextRange _wordForHit(
    ParagraphGeometry geometry,
    ({int position, HomericCaretAffinity affinity}) hit,
  ) {
    final range = geometry
        .wordBoundaryAt(
          DocOffset(hit.position),
          assoc: _assoc(hit.affinity),
        )
        .value;
    return BlockTextRange(range.start.value, range.end.value);
  }

  void _resetPointerState() {
    _dragAnchor = null;
    _dragWordAnchor = null;
    _dragMode = null;
  }

  void _endSelectionPointer() {
    _documentHost?.endPointerSelectionDrag(owner: this);
    _resetPointerState();
  }

  void _cancelSelectionPointer() {
    _documentHost?.cancelPointerSelectionDrag(owner: this);
    _resetPointerState();
  }

  void _secondaryTapDown(ParagraphGeometry geometry, Offset point) {
    if (!_canUsePointer(geometry)) return;
    _resetPointerState();
    final hit = _caretForPoint(geometry, point);
    final selection = _localSelection();
    final insideSelection = selection != null &&
        !selection.isCollapsed &&
        hit.position >= selection.start &&
        hit.position < selection.end;
    final word = _wordForHit(geometry, hit);
    if (!insideSelection) _relocate(word.start, word.end);
    _secondaryLocalPosition = point;
    _secondaryWordRange = word;
  }

  void _showContextMenu({bool useSecondaryAnchor = false}) {
    final context = _overlayContext;
    final point =
        useSecondaryAnchor ? _secondaryLocalPosition : _selectionMenuAnchor();
    if (context == null || point == null || !_canUseSelectionActions) return;
    if (!useSecondaryAnchor) {
      final geometry = _currentGeometry();
      final selection = _localSelection();
      if (geometry != null && selection != null) {
        final range = geometry
            .wordBoundaryAt(
              DocOffset(selection.head),
              assoc: _assoc(selection.affinity),
            )
            .value;
        _secondaryWordRange =
            BlockTextRange(range.start.value, range.end.value);
      }
    }
    widget.onShowToolbar?.call();
    if (Overlay.maybeOf(context, rootOverlay: true) == null) return;
    final render = context.findRenderObject();
    if (render is! RenderBox || !render.attached) return;
    final witness = _MenuWitness(
      epoch: _hostEpoch,
      stateRevision: _controller.stateRevision,
    );
    final anchor = render.localToGlobal(point);
    _dismissContextMenu();
    late final ContextMenuController menu;
    menu = ContextMenuController(onRemove: () {
      if (identical(_contextMenuController, menu)) {
        _contextMenuController = null;
      }
      if (mounted && !_disposing) _focusNode.requestFocus();
    });
    _contextMenuController = menu;
    var focusScheduled = false;
    menu.show(
      context: context,
      debugRequiredFor: widget,
      contextMenuBuilder: (menuContext) {
        if (!focusScheduled) {
          focusScheduled = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && menu.isShown) {
              FocusScope.of(menuContext).nextFocus();
            }
          });
        }
        return Shortcuts(
          shortcuts: const <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          },
          child: Focus(
            canRequestFocus: false,
            onFocusChange: (focused) {
              if (!focused && menu.isShown) _dismissContextMenu();
            },
            onKeyEvent: (_, event) {
              if (event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.escape) {
                _dismissContextMenu();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: AdaptiveTextSelectionToolbar.buttonItems(
              anchors: TextSelectionToolbarAnchors(primaryAnchor: anchor),
              buttonItems: _contextMenuItems(witness),
            ),
          ),
        );
      },
    );
  }

  Offset? _selectionMenuAnchor() {
    final geometry = _currentGeometry();
    final selection = _localSelection();
    if (geometry == null || selection == null) return null;
    if (selection.isCollapsed) {
      return geometry
          .caretRect(
            DocOffset(selection.head),
            assoc: _assoc(selection.affinity),
          )
          .value
          .topCenter;
    }
    final boxes = geometry
        .rectsForRange(DocRange(
          DocOffset(selection.start),
          DocOffset(selection.end),
        ))
        .value;
    if (boxes.isEmpty) return null;
    var rect = boxes.first.toRect();
    for (final box in boxes.skip(1)) {
      rect = rect.expandToInclude(box.toRect());
    }
    return rect.topCenter;
  }

  List<ContextMenuButtonItem> _contextMenuItems(_MenuWitness witness) {
    final selection = _localSelection();
    final block = _block;
    final canCopy = selection != null && !selection.isCollapsed;
    final canSelectAll = block != null &&
        block.contentLength > 0 &&
        (selection == null ||
            selection.start != 0 ||
            selection.end != block.contentLength);
    final spelling = _spellingSuggestions.where((suggestion) {
      final word = _secondaryWordRange;
      return word != null &&
          suggestion.range.start <= word.start &&
          suggestion.range.end >= word.end;
    });
    return <ContextMenuButtonItem>[
      for (final suggestion in spelling)
        for (final replacement in suggestion.replacements)
          ContextMenuButtonItem(
            label: replacement,
            onPressed: _controller.isReadOnly
                ? null
                : () => _applySpellingSuggestion(
                      witness,
                      suggestion,
                      replacement,
                    ),
          ),
      ContextMenuButtonItem(
        type: ContextMenuButtonType.cut,
        onPressed: canCopy && !_controller.isReadOnly
            ? () => _invokeMenuIntent(
                  witness,
                  const CopySelectionTextIntent.cut(
                    SelectionChangedCause.toolbar,
                  ),
                )
            : null,
      ),
      ContextMenuButtonItem(
        type: ContextMenuButtonType.copy,
        onPressed: canCopy
            ? () => _invokeMenuIntent(witness, CopySelectionTextIntent.copy)
            : null,
      ),
      ContextMenuButtonItem(
        type: ContextMenuButtonType.paste,
        onPressed: _controller.isReadOnly
            ? null
            : () => _invokeMenuIntent(
                  witness,
                  const PasteTextIntent(SelectionChangedCause.toolbar),
                ),
      ),
      ContextMenuButtonItem(
        type: ContextMenuButtonType.selectAll,
        onPressed: canSelectAll
            ? () => _invokeMenuIntent(
                  witness,
                  const SelectAllTextIntent(SelectionChangedCause.toolbar),
                )
            : null,
      ),
      ContextMenuButtonItem(
        // Flutter exposes localized button types for Cut through Select All,
        // but no public Undo/Redo context-menu label in the supported SDKs.
        label: 'Undo',
        onPressed: !_controller.isReadOnly && _controller.canUndo
            ? () => _invokeMenuIntent(
                  witness,
                  const UndoTextIntent(SelectionChangedCause.toolbar),
                )
            : null,
      ),
      ContextMenuButtonItem(
        label: 'Redo',
        onPressed: !_controller.isReadOnly && _controller.canRedo
            ? () => _invokeMenuIntent(
                  witness,
                  const RedoTextIntent(SelectionChangedCause.toolbar),
                )
            : null,
      ),
    ];
  }

  void _invokeMenuIntent(_MenuWitness witness, Intent intent) {
    final isCurrent = _isMenuWitnessCurrent(witness);
    if (!isCurrent) {
      _dismissContextMenu();
      return;
    }
    _focusNode.requestFocus();
    // Dispatch while the menu still counts as this host's editing focus. The
    // focus request settles after this callback, but Actions enablement and an
    // async clipboard witness must be captured synchronously.
    _dispatchIntent(intent);
    _dismissContextMenu();
  }

  void _applySpellingSuggestion(
    _MenuWitness witness,
    _ResolvedSpellingSuggestion suggestion,
    String replacement,
  ) {
    final isCurrent = _isMenuWitnessCurrent(witness);
    _dismissContextMenu();
    if (!isCurrent ||
        suggestion.contentRevision != _controller.contentRevision ||
        replacement.contains('\n') ||
        replacement.contains('\r')) {
      return;
    }
    _controller.applyBlockEditBatch(
      blockId: widget.blockId,
      edits: <CanonicalTextEdit>[
        CanonicalTextEdit(
          suggestion.range.start,
          suggestion.range.end,
          replacement,
        ),
      ],
      selection: BlockTextSelection.collapsed(
        suggestion.range.start + replacement.length,
      ),
    );
    _focusNode.requestFocus();
  }

  bool _isMenuWitnessCurrent(_MenuWitness witness) =>
      _isHostEpochCurrent(witness.epoch) &&
      witness.stateRevision == _controller.stateRevision &&
      _controller.composing == null;

  void _dismissContextMenu() {
    final menu = _contextMenuController;
    _contextMenuController = null;
    menu?.remove();
  }

  void _clearTransientState() {
    _resetPointerState();
    _secondaryLocalPosition = null;
    _secondaryWordRange = null;
    _dismissContextMenu();
    _spellRequestGeneration++;
    _spellRequestKey = null;
    _spellingSuggestions = const [];
  }

  Iterable<_ResolvedSpellingSuggestion> get _currentSpellingSuggestions =>
      _spellingSuggestions.where(
        (suggestion) =>
            suggestion.contentRevision == _controller.contentRevision,
      );

  void _ensureSpellCheck(ParagraphSource<Object?> source) {
    final provider = widget.spellCheckProvider;
    if (provider == null ||
        _controller.composing != null ||
        !_isHostEpochCurrent(_hostEpoch)) {
      return;
    }
    final key = _SpellRequestKey(
      provider: provider,
      blockId: widget.blockId,
      contentRevision: _controller.contentRevision,
      text: source.viewText,
      viewMap: source.viewMap,
    );
    if (_spellRequestKey == key) return;
    _spellRequestKey = key;
    _spellingSuggestions = const [];
    final generation = ++_spellRequestGeneration;
    final epoch = _hostEpoch;
    late final Future<List<SuggestionSpan>> pending;
    try {
      pending = provider.check(HomericSpellCheckRequest(
        blockId: key.blockId,
        text: key.text,
        contentRevision: key.contentRevision,
      ));
    } on Object {
      return;
    }
    pending.then((suggestions) {
      if (!mounted ||
          epoch != _hostEpoch ||
          generation != _spellRequestGeneration ||
          _spellRequestKey != key ||
          _controller.contentRevision != key.contentRevision ||
          _controller.composing != null) {
        return;
      }
      final resolved = <_ResolvedSpellingSuggestion>[];
      for (final suggestion in suggestions) {
        if (suggestion.range.start < 0 ||
            suggestion.range.end <= suggestion.range.start ||
            suggestion.range.end > source.viewText.length ||
            suggestion.suggestions.isEmpty) {
          continue;
        }
        final start =
            source.viewMap.viewToDoc(suggestion.range.start, assoc: -1);
        final end = source.viewMap.viewToDoc(suggestion.range.end, assoc: 1);
        if (start >= end) continue;
        resolved.add(_ResolvedSpellingSuggestion(
          range: BlockTextRange(start, end),
          replacements: List<String>.unmodifiable(suggestion.suggestions),
          contentRevision: key.contentRevision,
        ));
      }
      setState(() => _spellingSuggestions = List.unmodifiable(resolved));
    }, onError: (_) {
      if (!mounted ||
          epoch != _hostEpoch ||
          generation != _spellRequestGeneration ||
          _spellRequestKey != key) {
        return;
      }
      setState(() => _spellingSuggestions = const []);
    });
  }

  ({int position, HomericCaretAffinity affinity}) _caretForPoint(
      ParagraphGeometry geometry, Offset point) {
    final position = geometry.positionForPoint(point).value.value;
    final upstream = geometry.caretRect(DocOffset(position), assoc: -1).value;
    final downstream = geometry.caretRect(DocOffset(position), assoc: 1).value;
    final upstreamDistance = (point - upstream.centerLeft).distanceSquared;
    final downstreamDistance = (point - downstream.centerLeft).distanceSquared;
    return (
      position: position,
      affinity: upstreamDistance < downstreamDistance
          ? HomericCaretAffinity.upstream
          : HomericCaretAffinity.downstream,
    );
  }

  void _relocate(int anchor, int head,
      {HomericCaretAffinity affinity = HomericCaretAffinity.downstream}) {
    final selection = HomericSelection(
      anchor: _controller.globalPositionForBlockOffset(widget.blockId, anchor),
      head: _controller.globalPositionForBlockOffset(widget.blockId, head),
      affinity: affinity,
    );
    _controller.relocateSelection(selection);
    _focusNode.requestFocus();
    _attachInput();
  }

  Object? _moveCaret(_MoveCaretIntent intent) {
    final documentHost = _documentHost;
    final documentSelectionIsCrossBlock =
        documentHost != null && !documentHost.selectionIsBlockLocal;
    if (documentSelectionIsCrossBlock && !intent.extend) {
      documentHost.moveDocumentSelection(
        intent.direction,
        extend: intent.extend,
      );
      return null;
    }
    final local = _localSelection();
    if (local == null) return null;
    if (!intent.extend && !local.isCollapsed) {
      if (intent.direction == CaretMovementDirection.left ||
          intent.direction == CaretMovementDirection.right) {
        final edge = intent.direction == CaretMovementDirection.left
            ? local.start
            : local.end;
        _setLocalSelection(
          edge,
          edge,
          affinity: intent.direction == CaretMovementDirection.left
              ? HomericCaretAffinity.upstream
              : HomericCaretAffinity.downstream,
          resetPreferredX: true,
        );
        return null;
      }
    }
    final geometry = _currentGeometry();
    if (geometry == null) return null;
    final result = geometry
        .moveCaret(
          DocOffset(local.head),
          affinity: local.affinity,
          direction: intent.direction,
          preferredX: _controller.preferredX,
        )
        .value;
    final crossesHorizontalBoundary =
        intent.direction == CaretMovementDirection.left
            ? local.head == 0 && result.position.value == local.head
            : intent.direction == CaretMovementDirection.right
                ? local.head == (_block?.contentLength ?? 0) &&
                    result.position.value == local.head
                : false;
    final currentCaret = geometry
        .caretRect(
          DocOffset(local.head),
          assoc: _assoc(local.affinity),
        )
        .value;
    final blockRect = geometry.blockRect.value;
    final crossesVerticalBoundary = switch (intent.direction) {
      CaretMovementDirection.up => currentCaret.top <= blockRect.top + 0.5,
      CaretMovementDirection.down =>
        currentCaret.bottom >= blockRect.bottom - 0.5,
      _ => false,
    };
    if (documentHost != null &&
        (crossesHorizontalBoundary || crossesVerticalBoundary) &&
        documentHost.moveAcrossBlockBoundary(
          widget.blockId,
          intent.direction,
          extend: intent.extend,
          preferredX: result.preferredX,
        )) {
      return null;
    }
    final anchor = intent.extend ? local.anchor : result.position.value;
    if (documentSelectionIsCrossBlock && intent.extend) {
      documentHost.setSelectionHead(
        widget.blockId,
        result.position.value,
        affinity: result.affinity,
        preferredX: result.preferredX,
        resetPreferredX: result.preferredX == null,
      );
    } else {
      _setLocalSelection(
        anchor,
        result.position.value,
        affinity: result.affinity,
        preferredX: result.preferredX,
        resetPreferredX: result.preferredX == null,
      );
    }
    return null;
  }

  Object? _moveToLineBoundary({
    required bool forward,
    required bool extend,
  }) {
    final local = _localSelection();
    final geometry = _currentGeometry();
    if (local == null || geometry == null) return null;
    final boundary = geometry
        .lineBoundaryAt(
          DocOffset(local.head),
          assoc: _assoc(local.affinity),
        )
        .value;
    final target = forward ? boundary.end.value : boundary.start.value;
    _setLocalSelection(
      extend ? local.anchor : target,
      target,
      affinity: forward
          ? HomericCaretAffinity.downstream
          : HomericCaretAffinity.upstream,
      resetPreferredX: true,
    );
    return null;
  }

  Object? _moveByWord({
    required bool forward,
    required bool collapseSelection,
    bool collapseAtReversal = false,
  }) {
    final local = _localSelection();
    final geometry = _currentGeometry();
    if (local == null || geometry == null) return null;
    final result = geometry
        .moveByWord(
          DocOffset(local.head),
          direction: forward
              ? WordMovementDirection.forward
              : WordMovementDirection.backward,
          affinity: local.affinity,
        )
        .value;
    final crossedAnchor = collapseAtReversal &&
        (local.anchor - local.head) * (local.anchor - result.position.value) <
            0;
    final collapseAtAnchor = !collapseSelection &&
        (crossedAnchor || result.position.value == local.anchor);
    final target = collapseAtAnchor ? local.anchor : result.position.value;
    _setLocalSelection(
      collapseSelection || collapseAtAnchor ? target : local.anchor,
      target,
      affinity:
          collapseAtAnchor ? HomericCaretAffinity.downstream : result.affinity,
      resetPreferredX: true,
    );
    return null;
  }

  Object? _deleteByWord({required bool forward}) {
    final local = _localSelection();
    if (local == null) return null;
    if (!local.isCollapsed) {
      _controller.deleteBackward();
      return null;
    }
    final geometry = _currentGeometry();
    if (geometry == null) return null;
    final result = geometry
        .moveByWord(
          DocOffset(local.head),
          direction: forward
              ? WordMovementDirection.forward
              : WordMovementDirection.backward,
          affinity: local.affinity,
        )
        .value;
    final start = forward ? local.head : result.position.value;
    final end = forward ? result.position.value : local.head;
    if (start == end) return null;
    _controller.applyBlockEditBatch(
      blockId: widget.blockId,
      edits: <CanonicalTextEdit>[CanonicalTextEdit(start, end, '')],
      selection: BlockTextSelection.collapsed(start),
    );
    return null;
  }

  ParagraphGeometry? _currentGeometry() {
    final render = _renderParagraph;
    if (render == null ||
        !render.hasCurrentGeometry ||
        render.layoutGeneration != _renderGeneration) {
      return null;
    }
    final geometry = _paragraphGeometry;
    if (geometry != null && geometry.generation == _renderGeneration) {
      return geometry;
    }
    return _paragraphGeometry = ParagraphGeometry(render);
  }

  bool _isCurrentGeometry(ParagraphGeometry geometry) {
    final render = _renderParagraph;
    return render != null &&
        render.hasCurrentGeometry &&
        render.layoutGeneration == _renderGeneration &&
        geometry.generation == _renderGeneration;
  }

  void _geometryChanged(RenderHomericParagraph render, int generation) {
    if (!identical(_renderParagraph, render) ||
        _renderGeneration != generation) {
      _paragraphGeometry = null;
    }
    _renderParagraph = render;
    _renderGeneration = generation;
  }

  void _setLocalSelection(
    int anchor,
    int head, {
    required HomericCaretAffinity affinity,
    double? preferredX,
    bool resetPreferredX = false,
  }) {
    _controller.setSelection(
      HomericSelection(
        anchor:
            _controller.globalPositionForBlockOffset(widget.blockId, anchor),
        head: _controller.globalPositionForBlockOffset(widget.blockId, head),
        affinity: affinity,
      ),
      preferredX: preferredX,
      resetPreferredX: resetPreferredX,
    );
  }

  void _focusChanged(bool focused) {
    if (focused) {
      if (_controller.activeBlockId != widget.blockId) {
        _relocate(0, 0);
      } else {
        _attachInput();
      }
    } else if (_contextMenuController?.isShown ?? false) {
      // The adaptive toolbar is part of this host's editing focus. Keyboard
      // traversal may focus a menu button without ending the input epoch.
    } else if (_documentHost?.pointerSelectionDragActive ?? false) {
      // Recycling may temporarily remove focus from the anchor row while the
      // document coordinator owns the drag and preserves its input epoch.
      _documentHost?.schedulePointerDragFocusLossCheck();
    } else {
      _cancelSelectionPointer();
      _clearTransientState();
      _renewHostBindings();
      widget.inputSession.blur();
    }
    _syncCaretBlink(resetVisible: true);
    if (mounted) setState(() {});
  }

  void _setSemanticsText(String text) {
    if (text.contains('\n') || text.contains('\r')) return;
    final block = _block;
    if (block == null) return;
    _relocate(0, block.contentLength);
    _controller.replaceSelection(text);
  }

  void _setSemanticsSelection(TextSelection selection) {
    final block = _block;
    if (block == null ||
        !selection.isValid ||
        selection.start < 0 ||
        selection.end > block.contentLength) {
      return;
    }
    _relocate(
      selection.baseOffset,
      selection.extentOffset,
      affinity: selection.affinity == TextAffinity.upstream
          ? HomericCaretAffinity.upstream
          : HomericCaretAffinity.downstream,
    );
  }

  void _scheduleGeometryPublication(
      BuildContext overlayContext, ParagraphGeometry geometry) {
    if (!_focusNode.hasFocus || _controller.activeBlockId != widget.blockId) {
      return;
    }
    final serial = ++_geometryPublicationSerial;
    final documentRevision = _controller.document;
    final generation = geometry.generation;
    final blockRect = geometry.blockRect;
    final localSelection = _localSelection();
    if (localSelection == null) return;
    final caret = geometry.caretRect(
      DocOffset(localSelection.head),
      assoc: _assoc(localSelection.affinity),
    );
    Rect? composingRect;
    final composing = _localComposing();
    if (composing != null && !composing.isCollapsed) {
      final boxes = geometry
          .rectsForRange(DocRange(
            DocOffset(composing.start),
            DocOffset(composing.end),
          ))
          .value;
      for (final box in boxes) {
        composingRect = composingRect == null
            ? box.toRect()
            : composingRect.expandToInclude(box.toRect());
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          blockRect.isStale ||
          caret.isStale ||
          !identical(documentRevision, _controller.document) ||
          _geometryPublicationSerial != serial) {
        return;
      }
      final render = overlayContext.findRenderObject();
      if (render is! RenderBox || !render.attached) return;
      widget.inputSession.publishGeometry(
        documentRevision: documentRevision,
        layoutGeneration: generation,
        editableSize: blockRect.value.size,
        transform: render.getTransformTo(null),
        caretRect: caret.value,
        composingRect: composingRect,
      );
    });
  }

  static int _assoc(HomericCaretAffinity affinity) =>
      affinity == HomericCaretAffinity.upstream ? -1 : 1;
}

final class _MoveCaretIntent extends Intent {
  const _MoveCaretIntent(this.direction, this.extend);

  final CaretMovementDirection direction;
  final bool extend;
}

final class _MoveDocumentBlockIntent extends Intent {
  const _MoveDocumentBlockIntent(this.delta);

  final int delta;
}

enum _DragSelectionMode { character, word, paragraph }

final class _MenuWitness {
  const _MenuWitness({
    required this.epoch,
    required this.stateRevision,
  });

  final int epoch;
  final int stateRevision;
}

final class _SpellRequestKey {
  const _SpellRequestKey({
    required this.provider,
    required this.blockId,
    required this.contentRevision,
    required this.text,
    required this.viewMap,
  });

  final HomericSpellCheckProvider provider;
  final String blockId;
  final int contentRevision;
  final String text;
  final ViewMap viewMap;

  @override
  bool operator ==(Object other) =>
      other is _SpellRequestKey &&
      identical(other.provider, provider) &&
      other.blockId == blockId &&
      other.contentRevision == contentRevision &&
      other.text == text &&
      other.viewMap == viewMap;

  @override
  int get hashCode => Object.hash(
        identityHashCode(provider),
        blockId,
        contentRevision,
        text,
        viewMap,
      );
}

final class _ResolvedSpellingSuggestion {
  const _ResolvedSpellingSuggestion({
    required this.range,
    required this.replacements,
    required this.contentRevision,
  });

  final BlockTextRange range;
  final List<String> replacements;
  final int contentRevision;
}

void _paintSpellingSquiggle(
  ui.Canvas canvas,
  Rect rect,
  Object? spec,
) {
  final style = spec! as UnderlineSpec;
  final baseline = rect.bottom - 0.25;
  const halfWave = 2.0;
  const amplitude = 1.0;
  final path = ui.Path()..moveTo(rect.left, baseline);
  var x = rect.left;
  var rises = true;
  while (x < rect.right) {
    x = x + halfWave < rect.right ? x + halfWave : rect.right;
    path.lineTo(x, baseline + (rises ? -amplitude : amplitude));
    rises = !rises;
  }
  canvas.drawPath(
    path,
    ui.Paint()
      ..color = style.color
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 1.0,
  );
}

final class _TraverseIntent extends Intent {
  const _TraverseIntent(this.backward);

  final bool backward;
}

final class _DocumentCommandIntent extends Intent {
  const _DocumentCommandIntent(
    this.bindings, {
    required this.registrationOwner,
    required this.fallback,
    required this.appKitSelector,
  });

  final List<HomericDocumentCommandBinding> bindings;
  final Object registrationOwner;
  final Intent? fallback;
  final String? appKitSelector;
}

String? _appKitSelectorForShortcut(ShortcutActivator shortcut) {
  if (shortcut ==
      const SingleActivator(
        LogicalKeyboardKey.arrowUp,
        meta: true,
        shift: true,
      )) {
    return 'moveUpAndModifySelection:';
  }
  if (shortcut ==
      const SingleActivator(
        LogicalKeyboardKey.arrowDown,
        meta: true,
        shift: true,
      )) {
    return 'moveDownAndModifySelection:';
  }
  return null;
}

enum _DocumentCommandDisposition { ignored, handled }

final class _DocumentCommandAction extends Action<_DocumentCommandIntent> {
  _DocumentCommandAction(this.state, this.epoch);

  final _HomericEditableParagraphState state;
  final int epoch;

  @override
  bool isEnabled(_DocumentCommandIntent intent) =>
      state._isHostEpochCurrent(epoch);

  @override
  _DocumentCommandDisposition invoke(_DocumentCommandIntent intent) =>
      state._invokeDocumentCommand(intent, epoch);

  @override
  KeyEventResult toKeyEventResult(
    _DocumentCommandIntent intent,
    _DocumentCommandDisposition invokeResult,
  ) =>
      invokeResult == _DocumentCommandDisposition.handled
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
}

final class _HostAction<T extends Intent> extends Action<T> {
  _HostAction(
      {required Object? Function(T intent) invoke,
      bool Function(T intent)? enabled})
      : _invoke = invoke,
        _enabled = enabled;

  final Object? Function(T intent) _invoke;
  final bool Function(T intent)? _enabled;

  @override
  bool isEnabled(T intent) => _enabled?.call(intent) ?? true;

  @override
  Object? invoke(T intent) => _invoke(intent);
}

final class _EditableHostCommandDelegate
    implements HomericTextInputCommandDelegate {
  const _EditableHostCommandDelegate(this.state, this.epoch);

  final _HomericEditableParagraphState state;
  final int epoch;

  @override
  Object? invoke(Intent intent) {
    if (!state._isHostEpochCurrent(epoch)) return null;
    return state._dispatchIntent(intent);
  }

  @override
  void showToolbar() {
    if (!state._isHostEpochCurrent(epoch)) return;
    state._showContextMenu();
  }
}

const _selectAllSemanticsAction = CustomSemanticsAction(label: 'Select all');

final class _EditableSemantics extends SingleChildRenderObjectWidget {
  const _EditableSemantics({
    required this.value,
    required this.selection,
    required this.focused,
    required this.editable,
    required this.readOnly,
    required this.textDirection,
    required this.onFocus,
    required this.onTap,
    required this.onSetText,
    required this.onSetSelection,
    required this.onCopy,
    required this.onCut,
    required this.onPaste,
    required this.onSelectAll,
    required super.child,
  });

  final String value;
  final TextSelection? selection;
  final bool focused;
  final bool editable;
  final bool readOnly;
  final TextDirection textDirection;
  final VoidCallback onFocus;
  final VoidCallback onTap;
  final ValueChanged<String>? onSetText;
  final ValueChanged<TextSelection> onSetSelection;
  final VoidCallback? onCopy;
  final VoidCallback? onCut;
  final VoidCallback? onPaste;
  final VoidCallback? onSelectAll;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderEditableSemantics(
        value: value,
        selection: selection,
        focused: focused,
        editable: editable,
        readOnly: readOnly,
        textDirection: textDirection,
        onFocus: onFocus,
        onTap: onTap,
        onSetText: onSetText,
        onSetSelection: onSetSelection,
        onCopy: onCopy,
        onCut: onCut,
        onPaste: onPaste,
        onSelectAll: onSelectAll,
      );

  @override
  void updateRenderObject(
      BuildContext context, _RenderEditableSemantics renderObject) {
    renderObject
      ..value = value
      ..selection = selection
      ..focused = focused
      ..editable = editable
      ..readOnly = readOnly
      ..textDirection = textDirection
      ..onFocus = onFocus
      ..onTap = onTap
      ..onSetText = onSetText
      ..onSetSelection = onSetSelection
      ..onCopy = onCopy
      ..onCut = onCut
      ..onPaste = onPaste
      ..onSelectAll = onSelectAll;
  }
}

final class _RenderEditableSemantics extends RenderProxyBox {
  _RenderEditableSemantics({
    required String value,
    required TextSelection? selection,
    required bool focused,
    required bool editable,
    required bool readOnly,
    required TextDirection textDirection,
    required VoidCallback onFocus,
    required VoidCallback onTap,
    required ValueChanged<String>? onSetText,
    required ValueChanged<TextSelection> onSetSelection,
    required VoidCallback? onCopy,
    required VoidCallback? onCut,
    required VoidCallback? onPaste,
    required VoidCallback? onSelectAll,
  })  : _value = value,
        _selection = selection,
        _focused = focused,
        _editable = editable,
        _readOnly = readOnly,
        _textDirection = textDirection,
        _onFocus = onFocus,
        _onTap = onTap,
        _onSetText = onSetText,
        _onSetSelection = onSetSelection,
        _onCopy = onCopy,
        _onCut = onCut,
        _onPaste = onPaste,
        _onSelectAll = onSelectAll;

  String _value;
  TextSelection? _selection;
  bool _focused;
  bool _editable;
  bool _readOnly;
  TextDirection _textDirection;
  VoidCallback _onFocus;
  VoidCallback _onTap;
  ValueChanged<String>? _onSetText;
  ValueChanged<TextSelection> _onSetSelection;
  VoidCallback? _onCopy;
  VoidCallback? _onCut;
  VoidCallback? _onPaste;
  VoidCallback? _onSelectAll;

  set value(String value) {
    if (_value == value) return;
    _value = value;
    markNeedsSemanticsUpdate();
  }

  set selection(TextSelection? value) {
    if (_selection == value) return;
    _selection = value;
    markNeedsSemanticsUpdate();
  }

  set focused(bool value) {
    if (_focused == value) return;
    _focused = value;
    markNeedsSemanticsUpdate();
  }

  set editable(bool value) {
    if (_editable == value) return;
    _editable = value;
    markNeedsSemanticsUpdate();
  }

  set readOnly(bool value) {
    if (_readOnly == value) return;
    _readOnly = value;
    markNeedsSemanticsUpdate();
  }

  set textDirection(TextDirection value) {
    if (_textDirection == value) return;
    _textDirection = value;
    markNeedsSemanticsUpdate();
  }

  set onFocus(VoidCallback value) {
    if (identical(_onFocus, value)) return;
    _onFocus = value;
    markNeedsSemanticsUpdate();
  }

  set onTap(VoidCallback value) {
    if (identical(_onTap, value)) return;
    _onTap = value;
    markNeedsSemanticsUpdate();
  }

  set onSetText(ValueChanged<String>? value) {
    if (identical(_onSetText, value)) return;
    _onSetText = value;
    markNeedsSemanticsUpdate();
  }

  set onSetSelection(ValueChanged<TextSelection> value) {
    if (identical(_onSetSelection, value)) return;
    _onSetSelection = value;
    markNeedsSemanticsUpdate();
  }

  set onCopy(VoidCallback? value) {
    if (identical(_onCopy, value)) return;
    _onCopy = value;
    markNeedsSemanticsUpdate();
  }

  set onCut(VoidCallback? value) {
    if (identical(_onCut, value)) return;
    _onCut = value;
    markNeedsSemanticsUpdate();
  }

  set onPaste(VoidCallback? value) {
    if (identical(_onPaste, value)) return;
    _onPaste = value;
    markNeedsSemanticsUpdate();
  }

  set onSelectAll(VoidCallback? value) {
    if (identical(_onSelectAll, value)) return;
    _onSelectAll = value;
    markNeedsSemanticsUpdate();
  }

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config
      ..isSemanticBoundary = true
      ..value = _value
      ..textDirection = _textDirection
      ..onFocus = _onFocus
      ..onTap = _onTap;
    if (!_editable) return;
    config
      ..isTextField = true
      ..isReadOnly = _readOnly
      ..isMultiline = false
      ..isFocused = _focused
      ..onSetSelection = _onSetSelection;
    if (_onSetText case final callback?) config.onSetText = callback;
    if (_onCopy case final callback?) config.onCopy = callback;
    if (_onCut case final callback?) config.onCut = callback;
    if (_onPaste case final callback?) config.onPaste = callback;
    if (_onSelectAll case final callback?) {
      config.customSemanticsActions = <CustomSemanticsAction, VoidCallback>{
        _selectAllSemanticsAction: callback,
      };
    }
    final selection = _selection;
    if (selection != null) config.textSelection = selection;
  }
}
