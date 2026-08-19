/// Experimental one-block desktop editing host.
library;

import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
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
import 'editor_clipboard.dart';
import 'editor_controller.dart';

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
    this.composingColor,
    this.caretWidth = 1.5,
    this.clipboard = const SystemHomericClipboard(),
    this.onHostEvent,
    this.onShowToolbar,
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

  /// Focused composing underline color, or a visible default.
  final Color? composingColor;

  /// Width of the static focused caret.
  final double caretWidth;

  /// Injectable plain-text clipboard boundary.
  final HomericClipboardAdapter clipboard;

  /// Receives typed clipboard rejection and failure feedback.
  final ValueChanged<HomericHostEvent>? onHostEvent;

  /// Optional toolbar request used by the desktop menu layer.
  final VoidCallback? onShowToolbar;

  @override
  State<HomericEditableParagraph> createState() =>
      _HomericEditableParagraphState();
}

class _HomericEditableParagraphState extends State<HomericEditableParagraph> {
  late FocusNode _focusNode;
  int _geometryPublicationSerial = 0;
  int? _dragAnchor;
  RenderHomericParagraph? _renderParagraph;
  int? _renderGeneration;
  ParagraphGeometry? _paragraphGeometry;
  int _hostEpoch = 0;
  late _EditableHostCommandDelegate _commandDelegate;
  late HomericEditorClipboard _clipboard;
  late final VoidCallback _semanticsCopy;
  late final VoidCallback _semanticsCut;
  late final VoidCallback _semanticsPaste;
  late final VoidCallback _semanticsSelectAll;
  BuildContext? _commandContext;

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
    _controller.addListener(_controllerChanged);
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
    final hostDependenciesChanged = controllerChanged ||
        sessionChanged ||
        blockChanged ||
        focusNodeChanged ||
        !identical(oldWidget.clipboard, widget.clipboard);
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
    if (hostDependenciesChanged) _renewHostBindings();
    if (hadFocus && _focusNode.hasFocus && hostDependenciesChanged) {
      if (_controller.document.indexOfBlockId(widget.blockId) != null) {
        if (_controller.activeBlockId != widget.blockId) {
          _relocate(0, 0);
        } else {
          _attachInput();
        }
      }
    }
  }

  @override
  void dispose() {
    _hostEpoch++;
    _clipboard.dispose();
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
      _focusNode.hasFocus &&
      _controller.activeBlockId == widget.blockId &&
      widget.inputSession.activeBlockId == widget.blockId;

  bool _attachInput() => widget.inputSession.attach(
        blockId: widget.blockId,
        commandDelegate: _commandDelegate,
      );

  void _validateSession() {
    if (!identical(widget.controller, widget.inputSession.controller)) {
      throw ArgumentError('inputSession must observe controller');
    }
  }

  void _controllerChanged() {
    if (mounted) setState(() {});
  }

  Block? get _block => _controller.document.blockById(widget.blockId);

  @override
  Widget build(BuildContext context) {
    final block = _block;
    if (block == null) return const SizedBox.shrink();
    final localSelection = _localSelection();
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
    final focused = _focusNode.hasFocus && localSelection != null;
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
    final composingColor = widget.composingColor ??
        (brightness == Brightness.dark
            ? const Color(0xFF9DB2FF)
            : const Color(0xFF3F51B5));
    final editingLayers = <PaintLayer>[
      ...widget.paintLayers,
      if (focused && !localSelection.isCollapsed)
        PaintLayer(
          range: DocRange(
            DocOffset(localSelection.start),
            DocOffset(localSelection.end),
          ),
          band: PaintBand.underlay,
          painter: solidWashPainter,
          spec: SolidWashSpec(selectionColor),
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
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              dragStartBehavior: DragStartBehavior.down,
              onTapDown: (details) =>
                  _placeCaret(geometry, details.localPosition),
              onPanStart: (details) =>
                  _startDrag(geometry, details.localPosition),
              onPanUpdate: (details) =>
                  _updateDrag(geometry, details.localPosition),
              onPanEnd: (_) => _dragAnchor = null,
              onPanCancel: () => _dragAnchor = null,
            ),
          ),
          if (caret != null)
            Positioned.fromRect(
              rect: Rect.fromLTWH(
                caret.left - widget.caretWidth / 2,
                caret.top,
                widget.caretWidth,
                caret.height,
              ),
              child: IgnorePointer(child: ColoredBox(color: caretColor)),
            ),
        ];
      },
    );

    final shortcuts = <ShortcutActivator, Intent>{
      const SingleActivator(LogicalKeyboardKey.tab):
          const _TraverseIntent(false),
      const SingleActivator(LogicalKeyboardKey.tab, shift: true):
          const _TraverseIntent(true),
    };
    final actions = <Type, Action<Intent>>{
      DoNothingAndStopPropagationTextIntent:
          DoNothingAction(consumesKey: false),
      _MoveCaretIntent: _HostAction<_MoveCaretIntent>(
        enabled: (_) => _canUseActions,
        invoke: _moveCaret,
      ),
      _TraverseIntent: _HostAction<_TraverseIntent>(
        invoke: (intent) => intent.backward
            ? _focusNode.previousFocus()
            : _focusNode.nextFocus(),
      ),
      DeleteCharacterIntent: _HostAction<DeleteCharacterIntent>(
        enabled: (_) => _canUseActions,
        invoke: (intent) => intent.forward
            ? _controller.deleteForward()
            : _controller.deleteBackward(),
      ),
      ExtendSelectionByCharacterIntent:
          _HostAction<ExtendSelectionByCharacterIntent>(
        enabled: (_) => _canUseActions,
        invoke: (intent) => _moveCaret(_MoveCaretIntent(
          intent.forward
              ? CaretMovementDirection.right
              : CaretMovementDirection.left,
          !intent.collapseSelection,
        )),
      ),
      ExtendSelectionVerticallyToAdjacentLineIntent:
          _HostAction<ExtendSelectionVerticallyToAdjacentLineIntent>(
        enabled: (_) => _canUseActions,
        invoke: (intent) => _moveCaret(_MoveCaretIntent(
          intent.forward
              ? CaretMovementDirection.down
              : CaretMovementDirection.up,
          !intent.collapseSelection,
        )),
      ),
      ExtendSelectionToNextWordBoundaryIntent:
          _HostAction<ExtendSelectionToNextWordBoundaryIntent>(
        enabled: (_) => _canUseActions,
        invoke: (intent) => _moveByWord(
          forward: intent.forward,
          collapseSelection: intent.collapseSelection,
        ),
      ),
      ExtendSelectionToNextWordBoundaryOrCaretLocationIntent:
          _HostAction<ExtendSelectionToNextWordBoundaryOrCaretLocationIntent>(
        enabled: (_) => _canUseActions,
        invoke: (intent) => _moveByWord(
          forward: intent.forward,
          collapseSelection: intent.collapseSelection,
          collapseAtReversal: intent.collapseAtReversal,
        ),
      ),
      DeleteToNextWordBoundaryIntent:
          _HostAction<DeleteToNextWordBoundaryIntent>(
        enabled: (_) => _canUseActions,
        invoke: (intent) => _deleteByWord(forward: intent.forward),
      ),
      CopySelectionTextIntent: _HostAction<CopySelectionTextIntent>(
        enabled: (_) => _canCopyOrCut,
        invoke: (intent) =>
            intent.collapseSelection ? _clipboard.cut() : _clipboard.copy(),
      ),
      PasteTextIntent: _HostAction<PasteTextIntent>(
        enabled: (_) => _canUseActions,
        invoke: (_) => _clipboard.paste(),
      ),
      SelectAllTextIntent: _HostAction<SelectAllTextIntent>(
        enabled: (_) => _canUseActions && block.contentLength > 0,
        invoke: (_) => _selectAll(),
      ),
      UndoTextIntent: _HostAction<UndoTextIntent>(
        enabled: (_) => _canUseActions && _controller.canUndo,
        invoke: (_) => _controller.undo(),
      ),
      RedoTextIntent: _HostAction<RedoTextIntent>(
        enabled: (_) => _canUseActions && _controller.canRedo,
        invoke: (_) => _controller.redo(),
      ),
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
      textDirection: widget.paragraphSpec.direction == ParagraphDirection.rtl
          ? TextDirection.rtl
          : TextDirection.ltr,
      onFocus: _focusNode.requestFocus,
      onTap: _focusNode.requestFocus,
      onSetText: _setSemanticsText,
      onSetSelection: _setSemanticsSelection,
      onCopy: _canCopyOrCut ? _semanticsCopy : null,
      onCut: _canCopyOrCut ? _semanticsCut : null,
      onPaste: _canUseActions ? _semanticsPaste : null,
      onSelectAll: _canUseActions && block.contentLength > 0
          ? _semanticsSelectAll
          : null,
      child: ExcludeSemantics(
        child: Shortcuts(
          shortcuts: shortcuts,
          child: DefaultTextEditingShortcuts(
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

  bool get _canUseActions =>
      _focusNode.hasFocus &&
      _controller.activeBlockId == widget.blockId &&
      _controller.composing == null;

  bool get _canCopyOrCut {
    final selection = _localSelection();
    return _canUseActions && selection != null && !selection.isCollapsed;
  }

  Object? _dispatchIntent(Intent intent) {
    final commandContext = _commandContext;
    return commandContext == null
        ? null
        : Actions.maybeInvoke(commandContext, intent);
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

  void _placeCaret(ParagraphGeometry geometry, Offset point) {
    if (!_isCurrentGeometry(geometry)) return;
    final hit = _caretForPoint(geometry, point);
    _dragAnchor = null;
    _relocate(hit.position, hit.position, affinity: hit.affinity);
  }

  void _startDrag(ParagraphGeometry geometry, Offset point) {
    if (!_isCurrentGeometry(geometry)) return;
    final hit = _caretForPoint(geometry, point);
    _dragAnchor = hit.position;
    _relocate(hit.position, hit.position, affinity: hit.affinity);
  }

  void _updateDrag(ParagraphGeometry geometry, Offset point) {
    final anchor = _dragAnchor;
    if (anchor == null || !_isCurrentGeometry(geometry)) return;
    final rect = geometry.blockRect.value;
    final clamped = Offset(
      point.dx.clamp(rect.left, rect.right),
      point.dy.clamp(rect.top, rect.bottom),
    );
    final hit = _caretForPoint(geometry, clamped);
    _relocate(anchor, hit.position, affinity: hit.affinity);
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
    final anchor = intent.extend ? local.anchor : result.position.value;
    _setLocalSelection(
      anchor,
      result.position.value,
      affinity: result.affinity,
      preferredX: result.preferredX,
      resetPreferredX: result.preferredX == null,
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
    } else {
      _dragAnchor = null;
      _renewHostBindings();
      widget.inputSession.blur();
    }
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

final class _TraverseIntent extends Intent {
  const _TraverseIntent(this.backward);

  final bool backward;
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
    state.widget.onShowToolbar?.call();
  }
}

const _selectAllSemanticsAction = CustomSemanticsAction(label: 'Select all');

final class _EditableSemantics extends SingleChildRenderObjectWidget {
  const _EditableSemantics({
    required this.value,
    required this.selection,
    required this.focused,
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
  final TextDirection textDirection;
  final VoidCallback onFocus;
  final VoidCallback onTap;
  final ValueChanged<String> onSetText;
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
    required TextDirection textDirection,
    required VoidCallback onFocus,
    required VoidCallback onTap,
    required ValueChanged<String> onSetText,
    required ValueChanged<TextSelection> onSetSelection,
    required VoidCallback? onCopy,
    required VoidCallback? onCut,
    required VoidCallback? onPaste,
    required VoidCallback? onSelectAll,
  })  : _value = value,
        _selection = selection,
        _focused = focused,
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
  TextDirection _textDirection;
  VoidCallback _onFocus;
  VoidCallback _onTap;
  ValueChanged<String> _onSetText;
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

  set onSetText(ValueChanged<String> value) {
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
      ..isTextField = true
      ..isReadOnly = false
      ..isMultiline = false
      ..isFocused = _focused
      ..value = _value
      ..textDirection = _textDirection
      ..onFocus = _onFocus
      ..onTap = _onTap
      ..onSetText = _onSetText
      ..onSetSelection = _onSetSelection;
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
