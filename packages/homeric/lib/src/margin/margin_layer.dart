/// A document-level margin of host notes beside a [HomericEditableDocument].
///
/// This is Homeric's optional presentation module: it is built only on the
/// document's published geometry capability and the pure placement solver,
/// and no core directory imports it. The host owns note content, records and
/// policy; the layer owns where each note sits and in which form.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals, mapEquals;
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../editing/editable_document.dart';
import '../editing/editor_controller.dart' show BlockTextRange;
import 'margin_layout_memory.dart';
import 'margin_layout_solver.dart';

/// One host note shown in a [HomericMarginLayer].
///
/// The layer calls [fullBuilder] more than once per frame (it measures the
/// full form before deciding which form to show), so builders must be pure:
/// no [GlobalKey]s, and no [FocusNode] or controller shared with another
/// widget.
@immutable
final class HomericMarginNote {
  /// Creates a note anchored to [range] inside block [blockId].
  const HomericMarginNote({
    required this.id,
    required this.blockId,
    required this.range,
    required this.fullBuilder,
    required this.compactBuilder,
    this.semanticsLabel,
    this.paintSourceIndicator = false,
  });

  /// Host identifier, unique within one layer.
  final String id;

  /// Canonical id of the block holding [range].
  final String blockId;

  /// Block-local range the note refers to. The note sits beside the range's
  /// first visual line, or beside its start caret when the range is hidden.
  final BlockTextRange range;

  /// Builds the complete note. It is laid out at the layer's note width with
  /// unbounded height.
  final WidgetBuilder fullBuilder;

  /// Builds the one-line preview shown when the note's paragraph is crowded.
  /// It is laid out at exactly the note width by the layer's line height and
  /// clipped, so it should ellipsise its own text.
  final WidgetBuilder compactBuilder;

  /// Accessible label of the note's button. When null, the note's own
  /// content is its label.
  final String? semanticsLabel;

  /// Whether the layer underlines [range] in the prose, for hosts whose
  /// document carries no mark of their own for it.
  final bool paintSourceIndicator;
}

/// Signature of [HomericMarginLayer.onNoteActivated]: the activated note and
/// the form it rests in.
///
/// [form] is the resting form even while the note is shown expanded, so a
/// host can tell a compact preview, which it would expand, from a full note,
/// which it might open for editing.
typedef HomericMarginNoteActivated = void Function(
  String noteId,
  MarginNoteForm form,
);

/// A not-yet-saved note being written beside a pending range.
///
/// The layer keeps one composer's state across rebuilds while the host
/// supplies the *same* composer again, and builds a fresh one when the host
/// supplies a *different* one; see [id].
@immutable
final class HomericMarginComposer {
  /// Creates a composer anchored to [range] inside block [blockId].
  const HomericMarginComposer({
    this.id,
    required this.blockId,
    required this.range,
    required this.builder,
    this.semanticsLabel,
  });

  /// Host identity of this composer, for example the id of the note being
  /// edited or of the draft being written.
  ///
  /// Two composers are the same composer when their ids are equal; when
  /// both ids are null, when their [blockId] and [range] are equal. Supplying
  /// a different composer in place of the current one disposes the current
  /// one's widgets and builds the new one in a fresh focus scope, which takes
  /// focus. Removing the composer returns focus to where it was before the
  /// first composer of the run opened.
  final Object? id;

  /// Canonical id of the block holding [range].
  final String blockId;

  /// Block-local range the new note will refer to.
  final BlockTextRange range;

  /// Builds the host's editor, for example a text field with
  /// `autofocus: true`. Each composer, as identified by [id], is built inside
  /// its own focus scope, and its state lives until the host supplies a
  /// different composer or none.
  final WidgetBuilder builder;

  /// Accessible label of the composer region.
  final String? semanticsLabel;
}

/// Places host notes in a margin beside a [HomericEditableDocument].
///
/// Mount it as a later sibling of the editor in a [Stack] covering the
/// editor's viewport, typically `Positioned.fill`: the layer's bounds are
/// the viewport that expanded notes are clamped to, and it must paint after
/// the editor because each block's notes follow that block's
/// [HomericMountedBlockGeometry.layerLink]. Horizontal geometry is in the
/// layer's own coordinates: notes start [marginLeft] from the layer's left
/// edge and are [noteWidth] wide.
///
/// Scrolling and block movement are tracked at composite time, in the frame
/// they happen. Positions inside a block and collisions between blocks are
/// re-solved after each [HomericEditableDocumentState.documentGeometryChanges]
/// notice, so a line reflow inside an annotated block lands one frame after
/// the text. Block positions relative to the layer are read only once a
/// frame has completed, never while building: the layer may be built inside
/// an ancestor's layout callback, where ancestors are not laid out yet. A
/// rebuild therefore places notes with the positions of the last completed
/// frame and corrects any difference in the next one. Placement follows
/// [solveMarginLayout] through a
/// [MarginLayoutMemory], so notes that stay mounted never change form or
/// position when a neighbouring block mounts or unmounts.
///
/// The layer never changes the editor's layout. Empty margin space is
/// transparent to pointers; forwarding scroll gestures over the margin to
/// the editor is the host's job.
class HomericMarginLayer extends StatefulWidget {
  /// Creates a margin layer for the document behind [documentKey].
  const HomericMarginLayer({
    super.key,
    required this.documentKey,
    required this.notes,
    required this.marginLeft,
    required this.noteWidth,
    required this.lineHeight,
    this.gap = kMarginNoteGap,
    this.maxShiftLines = kMarginMaxShiftLines,
    this.maxFullLines = kMarginMaxFullLines,
    this.expandedNoteId,
    this.composer,
    this.onNoteActivated,
    this.onDismissed,
    this.viewportPadding = const EdgeInsets.all(8),
    this.minTapTargetHeight = 44,
    this.expandedPadding = const EdgeInsets.all(8),
    this.expandedFrameBuilder,
    this.expandedDecoration = const BoxDecoration(
      color: Color(0xFFFFFFFF),
      boxShadow: <BoxShadow>[
        BoxShadow(color: Color(0x33000000), blurRadius: 6),
      ],
    ),
    this.connectorColor = const Color(0x664A6FA5),
    this.connectorWidth = 1,
    this.sourceUnderlineColor = const Color(0x804A6FA5),
    this.sourceUnderlineThickness = 1,
    this.sourceTintColor = const Color(0x264A6FA5),
    this.focusColor = const Color(0x994A6FA5),
    this.hoverScale = 1.04,
  })  : assert(noteWidth > 0),
        assert(lineHeight > 0),
        assert(minTapTargetHeight >= 0);

  /// Key of the [HomericEditableDocument] whose blocks the notes follow.
  final GlobalKey<HomericEditableDocumentState> documentKey;

  /// Notes to place, in any order; ids must be unique. Notes whose block is
  /// not mounted, or whose range is outside the block, are not built.
  final List<HomericMarginNote> notes;

  /// Distance from the layer's left edge to the notes' left edge.
  final double marginLeft;

  /// Width every note is laid out at.
  final double noteWidth;

  /// Height of one note line in logical pixels, already text-scaled. It is
  /// the unit of the solver thresholds and the height of a compact preview.
  final double lineHeight;

  /// Vertical gap between consecutive notes; see [solveMarginLayout].
  final double gap;

  /// Maximum shift, in [lineHeight]s, before a group compacts.
  final double maxShiftLines;

  /// Maximum full-form height, in [lineHeight]s, before a group compacts.
  final double maxFullLines;

  /// Note shown in full on top of its neighbours, at its resting position
  /// and clamped inside the viewport. It takes focus when set; when cleared,
  /// focus returns to where it was before.
  final String? expandedNoteId;

  /// Optional composer for a not-yet-saved note. It is shown on top, takes
  /// focus when supplied or when replaced by a different composer (see
  /// [HomericMarginComposer.id]), and returns focus, when removed, to where
  /// it was before the first composer opened.
  final HomericMarginComposer? composer;

  /// Called when a note is activated by tap, Enter, Space or the semantics
  /// tap action, with the form the note rests in. An expanded note is
  /// activated the same ways: a tap on it that no descendant claims, such as
  /// a button inside [HomericMarginNote.fullBuilder], activates it, and a
  /// drag scrolls it instead.
  final HomericMarginNoteActivated? onNoteActivated;

  /// Called on Escape or on a tap outside while a note is expanded or the
  /// composer is open. The host clears [expandedNoteId] or [composer].
  final VoidCallback? onDismissed;

  /// Insets from the layer's edges that expanded notes and the composer
  /// stay inside. The keyboard inset is added to the bottom.
  final EdgeInsets viewportPadding;

  /// Minimum height of a resting note's tap target. Targets grow around the
  /// note without moving it and stop halfway to a neighbour.
  final double minTapTargetHeight;

  /// Padding between an expanded note's or the composer's frame and its
  /// content. The content keeps the note's resting position and width.
  final EdgeInsets expandedPadding;

  /// Frame painted behind an expanded note and the composer, which cover
  /// neighbouring notes. Ignored when [expandedFrameBuilder] is set.
  final Decoration expandedDecoration;

  /// Builds the frame around an expanded note's or the composer's padded
  /// content, for frames a [Decoration] cannot express, such as a blurred
  /// backdrop. The result must size itself to `child`.
  final Widget Function(BuildContext context, Widget child)?
      expandedFrameBuilder;

  /// Colour of the line from a displaced note to its source line.
  final Color connectorColor;

  /// Stroke width of the connector.
  final double connectorWidth;

  /// Colour of the underline painted under the range of notes with
  /// [HomericMarginNote.paintSourceIndicator].
  final Color sourceUnderlineColor;

  /// Thickness of that underline.
  final double sourceUnderlineThickness;

  /// Tint painted over the range of the focused or expanded note and of the
  /// composer.
  final Color sourceTintColor;

  /// Colour of the focus outline around a focused resting note.
  final Color focusColor;

  /// Scale of a resting note under a mouse pointer, grown from its left
  /// edge. A hovered note also shows its source tint and a stronger
  /// connector. Use 1 for no growth.
  final double hoverScale;

  @override
  State<HomericMarginLayer> createState() => HomericMarginLayerState();
}

/// State of a [HomericMarginLayer]; reach it through a [GlobalKey] to move
/// keyboard focus into the margin or to ask how a note is placed.
///
/// Notes are placed during the layer's layout, so the answers describe the
/// last laid-out frame. After changing [HomericMarginLayer.notes], or
/// revealing a note's block, call [focusNote] and [formOf] from a post-frame
/// callback.
class HomericMarginLayerState extends State<HomericMarginLayer> {
  HomericEditableDocumentState? _document;
  final MarginLayoutMemory _memory = MarginLayoutMemory();
  final _MeasureSink _sink = _MeasureSink();
  final Map<String, FocusNode> _focusNodes = <String, FocusNode>{};
  final Map<String, GlobalKey> _shellKeys = <String, GlobalKey>{};
  final FocusNode _layerNode = FocusNode(
    debugLabel: 'HomericMarginLayer',
    canRequestFocus: false,
    skipTraversal: true,
  );
  FocusScopeNode _composerScope = _newComposerScope();

  /// Bumped when the host replaces the composer with a different one, so
  /// the replacement is built fresh.
  int _composerGeneration = 0;
  FocusNode? _focusBeforeExpansion;
  FocusNode? _focusBeforeComposer;

  /// Set while a new composer waits to take focus; the composer is not in
  /// the tree during a geometry hold, so focus is requested once it is.
  bool _composerFocusPending = false;
  _Presentation? _last;
  _FrameGeometry? _geometry;
  bool _geometryReadScheduled = false;
  Map<String, MarginNoteForm> _forms = const <String, MarginNoteForm>{};
  PointerDownEvent? _lastOutsideTap;

  /// Id of the note holding keyboard focus, if any.
  String? get focusedNoteId {
    for (final entry in _focusNodes.entries) {
      if (entry.value.hasFocus) return entry.key;
    }
    return null;
  }

  /// Moves keyboard focus to note [noteId]. Returns false, and does
  /// nothing, when the note is not placed in the last laid-out frame: for
  /// example because its block is not mounted, its range is outside the
  /// block, or it was added since that frame. Call it from a post-frame
  /// callback after changing notes.
  ///
  /// Focus leaves the editor's input session; the editor's selection is
  /// kept.
  bool focusNote(String noteId) {
    if (!_forms.containsKey(noteId)) return false;
    final node = _focusNodes[noteId];
    final context = node?.context;
    if (node == null || context == null || !context.mounted) return false;
    node.requestFocus();
    return true;
  }

  /// The form note [noteId] rests in as placed in the last laid-out frame,
  /// or null when it is not placed there; see [focusNote] for why.
  ///
  /// An expanded note reports its resting form, which is what the margin
  /// shows again once [HomericMarginLayer.expandedNoteId] is cleared.
  MarginNoteForm? formOf(String noteId) => _forms[noteId];

  @override
  void initState() {
    super.initState();
    if (widget.expandedNoteId != null) _expansionChanged(null);
    if (widget.composer != null) _composerChanged(null);
  }

  @override
  void didUpdateWidget(HomericMarginLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expandedNoteId != widget.expandedNoteId) {
      _expansionChanged(oldWidget.expandedNoteId);
    }
    final oldComposer = oldWidget.composer;
    final newComposer = widget.composer;
    if ((oldComposer == null) != (newComposer == null)) {
      _composerChanged(oldComposer);
    } else if (oldComposer != null &&
        newComposer != null &&
        !_sameComposer(oldComposer, newComposer)) {
      _composerSwapped();
    }
    final ids = <String>{for (final note in widget.notes) note.id};
    final removed = <FocusNode>[];
    _focusNodes.removeWhere((id, node) {
      if (ids.contains(id)) return false;
      removed.add(node);
      return true;
    });
    _shellKeys.removeWhere((id, _) => !ids.contains(id));
    if (removed.isNotEmpty) {
      // Their Focus widgets unmount at the end of this frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final node in removed) {
          node.dispose();
        }
      });
    }
  }

  @override
  void dispose() {
    _detachDocument();
    for (final node in _focusNodes.values) {
      node.dispose();
    }
    _layerNode.dispose();
    _composerScope.dispose();
    super.dispose();
  }

  void _expansionChanged(String? previous) {
    final next = widget.expandedNoteId;
    if (next != null) {
      if (previous == null) {
        _focusBeforeExpansion = FocusManager.instance.primaryFocus;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || widget.expandedNoteId != next) return;
        final node = _focusNodes[next];
        if (node != null && node.context != null && !_focusWithin(node)) {
          node.requestFocus();
        }
      });
      return;
    }
    final before = _focusBeforeExpansion;
    _focusBeforeExpansion = null;
    final collapsed = previous == null ? null : _focusNodes[previous];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final focusIsLost = _focusIsNowhere();
      if (!focusIsLost && (collapsed == null || !_focusWithin(collapsed))) {
        return;
      }
      _restoreFocus(before);
    });
  }

  void _composerChanged(HomericMarginComposer? previous) {
    if (widget.composer != null) {
      if (!_focusWithin(_composerScope)) {
        _focusBeforeComposer = FocusManager.instance.primaryFocus;
      }
      _composerFocusPending = true;
      _focusComposerWhenBuilt();
      return;
    }
    _composerFocusPending = false;
    final before = _focusBeforeComposer;
    _focusBeforeComposer = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_focusIsNowhere() || _focusWithin(_layerNode)) {
        _restoreFocus(before);
      }
    });
  }

  static FocusScopeNode _newComposerScope() =>
      FocusScopeNode(debugLabel: 'HomericMarginLayer composer');

  static bool _sameComposer(HomericMarginComposer a, HomericMarginComposer b) {
    if (a.id != null || b.id != null) return a.id == b.id;
    return a.blockId == b.blockId && a.range == b.range;
  }

  /// The host replaced the composer with a different one: build it fresh in
  /// a new scope and give it focus. Where focus returns once the composer
  /// is removed stays what it was before the first composer opened.
  void _composerSwapped() {
    final retired = _composerScope;
    _composerScope = _newComposerScope();
    _composerGeneration++;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // The retired scope's widgets unmounted at the end of this frame.
      retired.dispose();
    });
    _composerFocusPending = true;
    _focusComposerWhenBuilt();
  }

  void _focusComposerWhenBuilt() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.composer == null || !_composerFocusPending) {
        return;
      }
      // Still held back: _present asks again once the composer is built.
      if (_composerScope.context == null) return;
      _composerFocusPending = false;
      if (!_focusWithin(_composerScope)) _composerScope.requestFocus();
    });
  }

  bool _focusWithin(FocusNode node) {
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null) return false;
    return identical(primary, node) || primary.ancestors.contains(node);
  }

  bool _focusIsNowhere() {
    final primary = FocusManager.instance.primaryFocus;
    return primary == null ||
        primary.context == null ||
        primary is FocusScopeNode && primary.focusedChild == null;
  }

  void _restoreFocus(FocusNode? node) {
    if (node == null || node.context == null || !node.canRequestFocus) return;
    node.requestFocus();
  }

  void _attachDocument() {
    final document = widget.documentKey.currentState;
    if (identical(document, _document)) return;
    _detachDocument();
    _document = document;
    _geometry = null;
    document?.documentGeometryChanges.addListener(_geometryChanged);
  }

  void _detachDocument() {
    final document = _document;
    if (document != null && document.mounted) {
      document.documentGeometryChanges.removeListener(_geometryChanged);
    }
    _document = null;
  }

  void _geometryChanged() {
    if (!mounted) return;
    // The document notifies outside the frame's build and layout, so the
    // positions it signals can be read now.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      _scheduleGeometryRead();
      return;
    }
    _readGeometry();
    setState(() {});
  }

  /// Reads block positions after this frame completes, and rebuilds when
  /// they differ from the ones this frame was built with.
  ///
  /// Build never reads them itself: a build can run inside an ancestor's
  /// layout callback, and walking to the root then crosses render objects
  /// that are mid-layout or, when just inserted, not laid out at all.
  void _scheduleGeometryRead() {
    if (_geometryReadScheduled) return;
    _geometryReadScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _geometryReadScheduled = false;
      if (!mounted) return;
      final previous = _geometry;
      _readGeometry();
      if (!_FrameGeometry.same(previous, _geometry)) setState(() {});
    }, debugLabel: 'HomericMarginLayer.readGeometry');
  }

  /// Captures the layer-space origin of every mounted block and the layer's
  /// global bottom. Only call it while no frame is being built or laid out.
  void _readGeometry() {
    _attachDocument();
    final document = _document;
    if (document == null || !document.mounted) {
      _geometry = null;
      return;
    }
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !_laidOutToRoot(box)) return;
    // One transform for every block: a transform shared by the editor and
    // the layer, such as a host's page transition, cancels out.
    final toLayer = Matrix4.tryInvert(box.getTransformTo(null));
    if (toLayer == null) return;
    final geometry = document.documentGeometry;
    final origins = <String, Offset>{};
    for (final blockId in geometry.mountedBlockIds ?? const <String>[]) {
      final origin = geometry.block(blockId)?.globalOrigin;
      if (origin == null) continue;
      final local = MatrixUtils.transformPoint(toLayer, origin);
      if (local.isFinite) origins[blockId] = local;
    }
    _geometry = _FrameGeometry(
      document: document,
      blockOrigins: origins,
      layerBottom: box.localToGlobal(Offset(0, box.size.height)).dy,
    );
  }

  static bool _laidOutToRoot(RenderObject node) {
    RenderObject? current = node;
    while (current != null) {
      if (current is RenderBox && !current.hasSize) return false;
      current = current.parent;
    }
    return true;
  }

  FocusNode _focusNodeFor(String id) =>
      _focusNodes[id] ??= FocusNode(debugLabel: 'HomericMarginLayer note $id');

  GlobalKey _shellKeyFor(String id) =>
      _shellKeys[id] ??= GlobalKey(debugLabel: 'HomericMarginLayer note $id');

  void _activate(String id) {
    final form = _forms[id];
    if (form != null) widget.onNoteActivated?.call(id, form);
  }

  bool get _dismissible =>
      widget.expandedNoteId != null || widget.composer != null;

  void _dismiss() {
    if (_dismissible) widget.onDismissed?.call();
  }

  void _outsideTap(PointerDownEvent event) {
    // Expanded note and composer share one tap region group; report each
    // outside tap once.
    if (identical(event, _lastOutsideTap)) return;
    _lastOutsideTap = event;
    _dismiss();
  }

  KeyEventResult _noteKey(String id, FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape && _dismissible) {
      _dismiss();
      return KeyEventResult.handled;
    }
    if (!node.hasPrimaryFocus) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      _activate(id);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _composerKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      _dismiss();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _noteFocusChanged(bool _) {
    // The focused note's source range is tinted and its outline drawn.
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    assert(() {
      final ids = <String>{};
      for (final note in widget.notes) {
        if (!ids.add(note.id)) {
          throw FlutterError('HomericMarginLayer: duplicate note id '
              '"${note.id}".');
        }
      }
      return true;
    }());
    _attachDocument();
    final snapshot = _collect(context);
    _scheduleGeometryRead();
    return Focus(
      focusNode: _layerNode,
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      child: _MarginStage(
        sink: _sink,
        measurer: ExcludeFocus(
          child: ExcludeSemantics(
            child: TickerMode(
              enabled: false,
              child: IgnorePointer(
                child: _Measurer(
                  sink: _sink,
                  width: widget.noteWidth,
                  children: <Widget>[
                    for (final note in snapshot.measured)
                      _MeasureSlot(
                        id: note.id,
                        child: Builder(builder: note.fullBuilder),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        presenter: _Presenter(
          builder: (context, constraints) => _present(
            snapshot,
            (constraints as _PresenterConstraints).heights,
            constraints.biggest,
          ),
        ),
      ),
    );
  }

  /// Gathers every input that comes from the editor, at build time.
  ///
  /// Block-local geometry comes from the document's current capability;
  /// where each block sits in the layer comes from [_geometry], read after
  /// the last completed frame. Nothing here walks the render tree.
  _Snapshot _collect(BuildContext context) {
    final document = _document;
    final frame = _geometry;
    if (document == null ||
        !document.mounted ||
        frame == null ||
        !identical(frame.document, document)) {
      return const _Snapshot.empty();
    }
    final media = MediaQuery.maybeOf(context);
    final geometry = document.documentGeometry;
    final mounted = geometry.mountedBlockIds ?? const <String>[];
    final notesByBlock = <String, List<HomericMarginNote>>{};
    for (final note in widget.notes) {
      (notesByBlock[note.blockId] ??= <HomericMarginNote>[]).add(note);
    }
    final composer = widget.composer;
    final blocks = <_BlockInputs>[];
    final measured = <HomericMarginNote>[];
    final pending = <String>{};
    _ComposerInputs? composerInputs;
    for (final blockId in mounted) {
      final notes = notesByBlock[blockId];
      final hasComposer = composer?.blockId == blockId;
      if (notes == null && !hasComposer) continue;
      if (notes != null) measured.addAll(notes);
      final block = geometry.block(blockId);
      final link = block?.layerLink;
      final origin = frame.blockOrigins[blockId];
      final rect = block?.blockRect;
      if (block == null || link == null || origin == null || rect == null) {
        // Mounted, but its geometry for this document revision is not laid
        // out yet, or it mounted after the last completed frame; the
        // document signals once it lays out.
        pending.add(blockId);
        continue;
      }
      final placement = _BlockPlacement(
        blockId: blockId,
        link: link,
        dx: widget.marginLeft - origin.dx,
        top: origin.dy,
        right: rect.right,
      );
      final inputs = <_NoteInputs>[];
      for (final note in notes ?? const <HomericMarginNote>[]) {
        final anchor = _anchorFor(block, note.range);
        if (anchor != null) {
          inputs.add(_NoteInputs(note, anchor.anchor, anchor.rects));
        }
      }
      if (inputs.isNotEmpty) blocks.add(_BlockInputs(placement, inputs));
      if (hasComposer) {
        final anchor = _anchorFor(block, composer!.range);
        if (anchor != null) {
          composerInputs = _ComposerInputs(
            composer: composer,
            block: placement,
            blockIndex: mounted.indexOf(blockId),
            anchor: anchor.anchor,
            rects: anchor.rects,
          );
        }
      }
    }
    final last = _last;
    final hold = last != null &&
        (pending.any(last.blockIds.contains) ||
            (composer != null &&
                composerInputs == null &&
                pending.contains(composer.blockId)));
    final controller = document.widget.controller;
    final mountedSet = mounted.toSet();
    final viewInsets = media?.viewInsets.bottom ?? 0;
    final screenHeight = media?.size.height;
    final keyboardOverlap = screenHeight == null || viewInsets <= 0
        ? 0.0
        : math.max(0.0, frame.layerBottom - (screenHeight - viewInsets));
    return _Snapshot(
      blocks: blocks,
      measured: measured,
      composer: composerInputs,
      hold: hold,
      mounted: mountedSet,
      blockOrder: <String, int>{
        for (var index = 0; index < mounted.length; index++)
          mounted[index]: index,
      },
      isUnmounted: (blockId) =>
          !mountedSet.contains(blockId) &&
          controller.document.indexOfBlockId(blockId) != null,
      keyboardOverlap: keyboardOverlap,
    );
  }

  static ({Rect anchor, List<Rect> rects})? _anchorFor(
    HomericMountedBlockGeometry block,
    BlockTextRange range,
  ) {
    final rects = block.rectsForRange(range);
    if (rects == null) return null;
    final anchor =
        rects.isNotEmpty ? rects.first : block.caretRect(range.start);
    if (anchor == null || !anchor.isFinite) return null;
    return (anchor: anchor, rects: rects);
  }

  /// Runs during layout, once full-form heights are measured and the
  /// layer's [size] for this frame is known.
  Widget _present(
    _Snapshot snapshot,
    Map<String, double> heights,
    Size size,
  ) {
    final notesById = <String, HomericMarginNote>{
      for (final note in widget.notes) note.id: note,
    };
    final _Presentation presentation;
    if (snapshot.hold) {
      presentation = _last!.retain(snapshot.mounted, notesById);
    } else {
      presentation = _solve(snapshot, heights, notesById);
      _last = presentation;
    }
    if (_composerFocusPending && presentation.composer != null) {
      _focusComposerWhenBuilt();
    }
    final padding = widget.viewportPadding;
    final viewport = (
      top: padding.top,
      bottom: size.height - padding.bottom - snapshot.keyboardOverlap,
      maxHeight: math.max(
        widget.lineHeight,
        size.height - padding.vertical - snapshot.keyboardOverlap,
      ),
    );
    return _build(presentation, viewport, notesById);
  }

  _Presentation _solve(
    _Snapshot snapshot,
    Map<String, double> heights,
    Map<String, HomericMarginNote> notesById,
  ) {
    final inputsById = <String, _NoteInputs>{};
    final blocksById = <String, _BlockInputs>{};
    final solverInput = <MarginBlockInput>[];
    for (final block in snapshot.blocks) {
      blocksById[block.placement.blockId] = block;
      final notes = <MarginNoteInput>[];
      for (final input in block.notes) {
        final height = heights[input.note.id];
        if (height == null) continue;
        inputsById[input.note.id] = input;
        notes.add(MarginNoteInput(
          id: input.note.id,
          anchorTop: block.placement.top + input.anchor.top,
          rangeStart: input.note.range.start,
          fullHeight: height,
          compactHeight: widget.lineHeight,
        ));
      }
      solverInput.add(MarginBlockInput(
        blockId: block.placement.blockId,
        top: block.placement.top,
        notes: notes,
      ));
    }
    final placements = _memory.solve(
      solverInput,
      lineHeight: widget.lineHeight,
      gap: widget.gap,
      maxShiftLines: widget.maxShiftLines,
      maxFullLines: widget.maxFullLines,
      isUnmounted: snapshot.isUnmounted,
    );

    // Tap targets grow around each note without moving it, and stop halfway
    // to the neighbouring note in the column.
    final ordered = [...placements]..sort((a, b) => a.top.compareTo(b.top));
    final hitTops = <String, double>{};
    final hitBottoms = <String, double>{};
    for (var index = 0; index < ordered.length; index++) {
      final placement = ordered[index];
      final pad =
          math.max(0.0, (widget.minTapTargetHeight - placement.height) / 2);
      var top = placement.top - pad;
      var bottom = placement.bottom + pad;
      if (index > 0) {
        final previous = ordered[index - 1];
        top = math.max(top, (previous.bottom + placement.top) / 2);
      }
      if (index + 1 < ordered.length) {
        final next = ordered[index + 1];
        bottom = math.min(bottom, (placement.bottom + next.top) / 2);
      }
      hitTops[placement.id] = math.min(top, placement.top);
      hitBottoms[placement.id] = math.max(bottom, placement.bottom);
    }

    final groups = <String, _PlacedGroup>{};
    for (var index = 0; index < placements.length; index++) {
      final placement = placements[index];
      final block = blocksById[placement.blockId]!.placement;
      final input = inputsById[placement.id]!;
      final group =
          groups[placement.blockId] ??= _PlacedGroup(block, <_PlacedNote>[]);
      group.notes.add(_PlacedNote(
        id: placement.id,
        order: index,
        form: placement.form,
        top: placement.blockRelativeTop,
        height: placement.height,
        hitTop: hitTops[placement.id]! - block.top,
        hitBottom: hitBottoms[placement.id]! - block.top,
        anchor: input.anchor,
        rects: input.rects,
      ));
    }

    final composer = snapshot.composer;
    _PlacedComposer? placedComposer;
    if (composer != null) {
      final composerOrder = _composerOrder(snapshot, composer, placements);
      placedComposer = _PlacedComposer(
        block: composer.block,
        anchor: composer.anchor,
        rects: composer.rects,
        order: composerOrder,
      );
    }
    return _Presentation(groups.values.toList(), placedComposer);
  }

  static double _composerOrder(
    _Snapshot snapshot,
    _ComposerInputs composer,
    List<MarginNotePlacement> placements,
  ) {
    var before = 0;
    final composerTop = composer.block.top + composer.anchor.top;
    for (final placement in placements) {
      final blockIndex = snapshot.blockOrder[placement.blockId] ?? 0;
      if (blockIndex < composer.blockIndex ||
          blockIndex == composer.blockIndex &&
              placement.anchorTop <= composerTop) {
        before++;
      }
    }
    return before - 0.5;
  }

  Widget _build(
    _Presentation presentation,
    _Viewport viewport,
    Map<String, HomericMarginNote> notesById,
  ) {
    final forms = <String, MarginNoteForm>{};
    final expandedId = widget.expandedNoteId;
    final focusedId = focusedNoteId;
    final indicators = <Widget>[];
    final followers = <Widget>[];
    Widget? overlay;

    final indicatorRects =
        <String, ({List<Rect> underline, List<Rect> tint})>{};
    void addIndicator(String blockId, List<Rect> underline, List<Rect> tint) {
      final current = indicatorRects[blockId];
      indicatorRects[blockId] = (
        underline: <Rect>[...?current?.underline, ...underline],
        tint: <Rect>[...?current?.tint, ...tint],
      );
    }

    final links = <String, _BlockPlacement>{};
    for (final group in presentation.groups) {
      links[group.block.blockId] = group.block;
      final slots = <Widget>[];
      for (final placed in group.notes) {
        final note = notesById[placed.id];
        if (note == null) continue;
        forms[placed.id] = placed.form;
        final hovered = placed.id == _hoveredNoteId;
        final active =
            placed.id == expandedId || placed.id == focusedId || hovered;
        addIndicator(
          group.block.blockId,
          note.paintSourceIndicator ? placed.rects : const <Rect>[],
          active ? placed.rects : const <Rect>[],
        );
        if (placed.displaced) {
          slots.add(_CanvasSlot(
            left: 0,
            top: 0,
            width: 0,
            height: 0,
            child: IgnorePointer(
              child: CustomPaint(
                key: ValueKey<String>('homeric-margin-connector-${placed.id}'),
                painter: _ConnectorPainter(
                  from: Offset(
                    -2,
                    placed.top + math.min(widget.lineHeight, placed.height) / 2,
                  ),
                  to: Offset(
                    math.min(group.block.right - group.block.dx, -6),
                    placed.anchor.center.dy,
                  ),
                  // A hovered note's connector comes forward with it.
                  color: hovered
                      ? widget.connectorColor.withValues(
                          alpha: math.min(1, widget.connectorColor.a * 2),
                        )
                      : widget.connectorColor,
                  width: widget.connectorWidth + (hovered ? 0.5 : 0),
                ),
              ),
            ),
          ));
        }
        final expanded = placed.id == expandedId;
        slots.add(_CanvasSlot(
          left: 0,
          top: placed.hitTop,
          width: widget.noteWidth,
          height: placed.hitBottom - placed.hitTop,
          child:
              expanded ? const SizedBox.shrink() : _restingNote(note, placed),
        ));
        if (expanded) {
          overlay = _overlayFollower(
            block: group.block,
            top: placed.top,
            viewport: viewport,
            child: _shell(
              note,
              placed.order.toDouble(),
              expanded: true,
              child: _expandedCard(note),
            ),
          );
        }
      }
      followers.add(CompositedTransformFollower(
        key: ValueKey<String>('homeric-margin-group-${group.block.blockId}'),
        link: group.block.link,
        showWhenUnlinked: false,
        offset: Offset(group.block.dx, 0),
        child: _MarginCanvas(children: slots),
      ));
    }

    final composer = presentation.composer;
    final composerWidget = widget.composer;
    Widget? composerOverlay;
    if (composer != null && composerWidget != null) {
      links[composer.block.blockId] = composer.block;
      addIndicator(composer.block.blockId, const <Rect>[], composer.rects);
      composerOverlay = _overlayFollower(
        block: composer.block,
        top: composer.anchor.top,
        viewport: viewport,
        child: FocusTraversalOrder(
          order: NumericFocusOrder(composer.order),
          child: _composerCard(composerWidget),
        ),
      );
    }

    for (final entry in indicatorRects.entries) {
      final rects = entry.value;
      if (rects.underline.isEmpty && rects.tint.isEmpty) continue;
      indicators.add(CompositedTransformFollower(
        link: links[entry.key]!.link,
        showWhenUnlinked: false,
        child: CustomPaint(
          key: ValueKey<String>('homeric-margin-source-${entry.key}'),
          painter: _SourcePainter(
            underline: rects.underline,
            tint: rects.tint,
            underlineColor: widget.sourceUnderlineColor,
            underlineThickness: widget.sourceUnderlineThickness,
            tintColor: widget.sourceTintColor,
          ),
        ),
      ));
    }

    _forms = forms;
    return ClipRect(
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: IgnorePointer(child: Stack(children: indicators)),
          ),
          Positioned.fill(
            child: FocusTraversalGroup(
              policy: OrderedTraversalPolicy(),
              child: Stack(
                children: <Widget>[
                  ...followers,
                  if (overlay != null) overlay,
                  if (composerOverlay != null) composerOverlay,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _shell(
    HomericMarginNote note,
    double order, {
    required bool expanded,
    required Widget child,
  }) {
    final node = _focusNodeFor(note.id);
    return FocusTraversalOrder(
      key: _shellKeyFor(note.id),
      order: NumericFocusOrder(order),
      child: Focus(
        focusNode: node,
        onKeyEvent: (node, event) => _noteKey(note.id, node, event),
        onFocusChange: _noteFocusChanged,
        // One semantics node per note, carrying focus with the button.
        includeSemantics: false,
        child: Semantics(
          container: true,
          button: true,
          focusable: true,
          focused: node.hasFocus,
          expanded: expanded,
          label: note.semanticsLabel,
          onTap: () => _activate(note.id),
          child: ExcludeSemantics(
            excluding: note.semanticsLabel != null,
            child: child,
          ),
        ),
      ),
    );
  }

  Widget _restingNote(HomericMarginNote note, _PlacedNote placed) {
    final focused = _focusNodes[note.id]?.hasFocus ?? false;
    final full = placed.form == MarginNoteForm.full;
    Widget content = SizedBox(
      key: ValueKey<String>('homeric-margin-note-${note.id}'),
      width: widget.noteWidth,
      height: placed.height,
      child: full
          ? Builder(builder: note.fullBuilder)
          : ClipRect(child: Builder(builder: note.compactBuilder)),
    );
    // Under the pointer a note leans forward a little: slightly larger from
    // its left edge, so its first letters stay on their line.
    content = AnimatedScale(
      scale: _hoveredNoteId == note.id ? widget.hoverScale : 1,
      alignment: Alignment.centerLeft,
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      child: content,
    );
    if (focused) {
      content = DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: Border.all(color: widget.focusColor),
          borderRadius: const BorderRadius.all(Radius.circular(2)),
        ),
        child: content,
      );
    }
    return _shell(
      note,
      placed.order.toDouble(),
      expanded: false,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => _setHovered(note.id),
        onExit: (_) => _clearHovered(note.id),
        child: GestureDetector(
          key: ValueKey<String>('homeric-margin-target-${note.id}'),
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTap: () => _activate(note.id),
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              Positioned(
                left: 0,
                top: placed.top - placed.hitTop,
                width: widget.noteWidth,
                height: placed.height,
                child: content,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String? _hoveredNoteId;

  void _setHovered(String noteId) {
    if (_hoveredNoteId == noteId || !mounted) return;
    setState(() => _hoveredNoteId = noteId);
  }

  void _clearHovered(String noteId) {
    if (_hoveredNoteId != noteId || !mounted) return;
    setState(() => _hoveredNoteId = null);
  }

  Widget _expandedFrame({required Key key, required Widget child}) {
    final builder = widget.expandedFrameBuilder;
    return builder == null
        ? DecoratedBox(
            key: key,
            decoration: widget.expandedDecoration,
            child: child,
          )
        : KeyedSubtree(
            key: key,
            child: Builder(builder: (context) => builder(context, child)),
          );
  }

  /// Like a resting note, a tap on the expanded note activates it: the tap
  /// recognizer is the outermost one, so descendants that claim the tap,
  /// such as a host button, win it, and the scroll view's drag wins a drag.
  Widget _expandedCard(HomericMarginNote note) => TapRegion(
        groupId: this,
        onTapOutside: _outsideTap,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTap: () => _activate(note.id),
          child: _expandedFrame(
            key: ValueKey<String>('homeric-margin-expanded-${note.id}'),
            child: Padding(
              padding: widget.expandedPadding,
              child: SingleChildScrollView(
                child: SizedBox(
                  width: widget.noteWidth,
                  child: Builder(builder: note.fullBuilder),
                ),
              ),
            ),
          ),
        ),
      );

  Widget _composerCard(HomericMarginComposer composer) => TapRegion(
        groupId: this,
        onTapOutside: _outsideTap,
        child: FocusScope(
          key: ValueKey<int>(_composerGeneration),
          node: _composerScope,
          onKeyEvent: _composerKey,
          child: Semantics(
            container: true,
            label: composer.semanticsLabel,
            child: _expandedFrame(
              key: const ValueKey<String>('homeric-margin-composer'),
              child: Padding(
                padding: widget.expandedPadding,
                child: SingleChildScrollView(
                  child: SizedBox(
                    width: widget.noteWidth,
                    child: Builder(builder: composer.builder),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

  /// Places [child] over the margin at block-relative [top], with its
  /// content aligned to the resting note and its frame clamped inside the
  /// viewport.
  Widget _overlayFollower({
    required _BlockPlacement block,
    required double top,
    required _Viewport viewport,
    required Widget child,
  }) {
    final padding = widget.expandedPadding;
    return CompositedTransformFollower(
      link: block.link,
      showWhenUnlinked: false,
      offset: Offset(block.dx, 0),
      child: _MarginCanvas(
        children: <Widget>[
          _CanvasSlot(
            left: -padding.left,
            top: top - padding.top,
            width: widget.noteWidth + padding.horizontal,
            maxHeight: viewport.maxHeight,
            clampTop: viewport.top - block.top,
            clampBottom: viewport.bottom - block.top,
            child: child,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Inputs and solved presentation.

/// Where the mounted blocks sat in the layer at the end of a completed frame.
final class _FrameGeometry {
  const _FrameGeometry({
    required this.document,
    required this.blockOrigins,
    required this.layerBottom,
  });

  final HomericEditableDocumentState document;

  /// Link origin of each mounted block, in the layer's coordinates.
  final Map<String, Offset> blockOrigins;

  /// Global y of the layer's bottom edge, for the keyboard inset.
  final double layerBottom;

  static const double _tolerance = 0.01;

  static bool same(_FrameGeometry? a, _FrameGeometry? b) {
    if (a == null || b == null) return identical(a, b);
    if (!identical(a.document, b.document) ||
        (a.layerBottom - b.layerBottom).abs() > _tolerance ||
        a.blockOrigins.length != b.blockOrigins.length) {
      return false;
    }
    for (final entry in a.blockOrigins.entries) {
      final other = b.blockOrigins[entry.key];
      if (other == null ||
          (other.dx - entry.value.dx).abs() > _tolerance ||
          (other.dy - entry.value.dy).abs() > _tolerance) {
        return false;
      }
    }
    return true;
  }
}

/// Vertical bounds, in the layer, that overlays stay inside.
typedef _Viewport = ({double top, double bottom, double maxHeight});

final class _BlockPlacement {
  const _BlockPlacement({
    required this.blockId,
    required this.link,
    required this.dx,
    required this.top,
    required this.right,
  });

  final String blockId;
  final LayerLink link;

  /// Follower x offset that puts block-local x = [dx] at the margin's left.
  final double dx;

  /// Top of the block in the layer when read, the solver's shared space.
  final double top;

  /// Block-local right edge of the block.
  final double right;
}

final class _NoteInputs {
  const _NoteInputs(this.note, this.anchor, this.rects);

  final HomericMarginNote note;
  final Rect anchor;
  final List<Rect> rects;
}

final class _BlockInputs {
  const _BlockInputs(this.placement, this.notes);

  final _BlockPlacement placement;
  final List<_NoteInputs> notes;
}

final class _ComposerInputs {
  const _ComposerInputs({
    required this.composer,
    required this.block,
    required this.blockIndex,
    required this.anchor,
    required this.rects,
  });

  final HomericMarginComposer composer;
  final _BlockPlacement block;
  final int blockIndex;
  final Rect anchor;
  final List<Rect> rects;
}

final class _Snapshot {
  const _Snapshot({
    required this.blocks,
    required this.measured,
    required this.composer,
    required this.hold,
    required this.mounted,
    required this.blockOrder,
    required this.isUnmounted,
    required this.keyboardOverlap,
  });

  const _Snapshot.empty()
      : blocks = const <_BlockInputs>[],
        measured = const <HomericMarginNote>[],
        composer = null,
        hold = false,
        mounted = const <String>{},
        blockOrder = const <String, int>{},
        isUnmounted = _never,
        keyboardOverlap = 0;

  static bool _never(String _) => false;

  final List<_BlockInputs> blocks;
  final List<HomericMarginNote> measured;
  final _ComposerInputs? composer;

  /// Whether a block placed last time is mounted but has no geometry for
  /// the current document revision yet. The last placements are kept for
  /// this frame; the document signals once the block lays out.
  final bool hold;
  final Set<String> mounted;
  final Map<String, int> blockOrder;
  final bool Function(String blockId) isUnmounted;

  /// Height of the layer's bottom covered by the keyboard.
  final double keyboardOverlap;
}

final class _PlacedNote {
  const _PlacedNote({
    required this.id,
    required this.order,
    required this.form,
    required this.top,
    required this.height,
    required this.hitTop,
    required this.hitBottom,
    required this.anchor,
    required this.rects,
  });

  final String id;
  final int order;
  final MarginNoteForm form;

  /// Block-relative vertical extent of the note and of its tap target.
  final double top;
  final double height;
  final double hitTop;
  final double hitBottom;

  /// Block-local source geometry.
  final Rect anchor;
  final List<Rect> rects;

  bool get displaced => top > anchor.top;
}

final class _PlacedGroup {
  const _PlacedGroup(this.block, this.notes);

  final _BlockPlacement block;
  final List<_PlacedNote> notes;
}

final class _PlacedComposer {
  const _PlacedComposer({
    required this.block,
    required this.anchor,
    required this.rects,
    required this.order,
  });

  final _BlockPlacement block;
  final Rect anchor;
  final List<Rect> rects;
  final double order;
}

final class _Presentation {
  _Presentation(this.groups, this.composer)
      : blockIds = <String>{
          for (final group in groups) group.block.blockId,
          if (composer != null) composer.block.blockId,
        };

  final List<_PlacedGroup> groups;
  final _PlacedComposer? composer;
  final Set<String> blockIds;

  /// This presentation limited to blocks still mounted and notes the host
  /// still supplies.
  _Presentation retain(
    Set<String> mounted,
    Map<String, HomericMarginNote> notes,
  ) =>
      _Presentation(
        <_PlacedGroup>[
          for (final group in groups)
            if (mounted.contains(group.block.blockId))
              _PlacedGroup(group.block, <_PlacedNote>[
                for (final note in group.notes)
                  if (notes.containsKey(note.id)) note,
              ]),
        ],
        composer != null && mounted.contains(composer!.block.blockId)
            ? composer
            : null,
      );
}

// ---------------------------------------------------------------------------
// Painters.

final class _ConnectorPainter extends CustomPainter {
  const _ConnectorPainter({
    required this.from,
    required this.to,
    required this.color,
    required this.width,
  });

  final Offset from;
  final Offset to;
  final Color color;
  final double width;

  /// Largest radius of the elbow's two corners.
  static const double _corner = 4;

  /// An elbow: out from the note, up or down a riser midway across the gap,
  /// then on to the source line. Both corners are rounded; when the two ends
  /// are level it is a straight line.
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = width
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    final rise = to.dy - from.dy;
    final run = to.dx - from.dx;
    if (rise.abs() < 0.5 || run.abs() < 0.5) {
      canvas.drawLine(from, to, paint);
      return;
    }
    final riserX = from.dx + run / 2;
    final radius = math.min(_corner, math.min(rise.abs(), run.abs() / 2) / 2);
    final h = run.sign * radius;
    final v = rise.sign * radius;
    final path = Path()
      ..moveTo(from.dx, from.dy)
      ..lineTo(riserX - h, from.dy)
      ..quadraticBezierTo(riserX, from.dy, riserX, from.dy + v)
      ..lineTo(riserX, to.dy - v)
      ..quadraticBezierTo(riserX, to.dy, riserX + h, to.dy)
      ..lineTo(to.dx, to.dy);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_ConnectorPainter oldDelegate) =>
      oldDelegate.from != from ||
      oldDelegate.to != to ||
      oldDelegate.color != color ||
      oldDelegate.width != width;
}

final class _SourcePainter extends CustomPainter {
  const _SourcePainter({
    required this.underline,
    required this.tint,
    required this.underlineColor,
    required this.underlineThickness,
    required this.tintColor,
  });

  final List<Rect> underline;
  final List<Rect> tint;
  final Color underlineColor;
  final double underlineThickness;
  final Color tintColor;

  @override
  void paint(Canvas canvas, Size size) {
    final tintPaint = Paint()..color = tintColor;
    for (final rect in tint) {
      canvas.drawRect(rect, tintPaint);
    }
    final underlinePaint = Paint()..color = underlineColor;
    for (final rect in underline) {
      canvas.drawRect(
        Rect.fromLTRB(
          rect.left,
          rect.bottom - underlineThickness,
          rect.right,
          rect.bottom,
        ),
        underlinePaint,
      );
    }
  }

  @override
  bool shouldRepaint(_SourcePainter oldDelegate) =>
      !listEquals(oldDelegate.underline, underline) ||
      !listEquals(oldDelegate.tint, tint) ||
      oldDelegate.underlineColor != underlineColor ||
      oldDelegate.underlineThickness != underlineThickness ||
      oldDelegate.tintColor != tintColor;
}

// ---------------------------------------------------------------------------
// Measure, then present: full forms are laid out off-stage first so the
// solver can choose each group's form in the same layout pass.

final class _MeasureSink {
  Map<String, double> heights = const <String, double>{};
}

/// Lays out the measurer, then the presenter with the measured heights.
/// Only the presenter paints, hit-tests and contributes semantics.
class _MarginStage extends MultiChildRenderObjectWidget {
  _MarginStage({
    required this.sink,
    required Widget measurer,
    required Widget presenter,
  }) : super(children: <Widget>[measurer, presenter]);

  final _MeasureSink sink;

  @override
  MultiChildRenderObjectElement createElement() => _MarginStageElement(this);

  @override
  _RenderMarginStage createRenderObject(BuildContext context) =>
      _RenderMarginStage(sink);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderMarginStage renderObject,
  ) {
    renderObject.sink = sink;
  }
}

class _MarginStageElement extends MultiChildRenderObjectElement {
  _MarginStageElement(_MarginStage super.widget);

  /// The measurer is never shown, like an [Offstage] child.
  @override
  void debugVisitOnstageChildren(ElementVisitor visitor) {
    if (children.length > 1) visitor(children.last);
  }
}

final class _StageParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderMarginStage extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, _StageParentData> {
  _RenderMarginStage(this.sink);

  _MeasureSink sink;

  RenderBox? get _presenter =>
      firstChild == null ? null : childAfter(firstChild!);

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _StageParentData) {
      child.parentData = _StageParentData();
    }
  }

  @override
  void performLayout() {
    size = constraints.biggest;
    final measurer = firstChild;
    if (measurer == null) return;
    // parentUsesSize keeps a re-measured note from stopping at a relayout
    // boundary: this stage must lay out again to hand the presenter the
    // new heights.
    measurer.layout(const BoxConstraints(), parentUsesSize: true);
    _presenter?.layout(_PresenterConstraints(size, sink.heights));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final presenter = _presenter;
    if (presenter != null) context.paintChild(presenter, offset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      _presenter?.hitTest(result, position: position) ?? false;

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    final presenter = _presenter;
    if (presenter != null) visitor(presenter);
  }
}

final class _MeasureParentData extends ContainerBoxParentData<RenderBox> {
  String? id;
}

class _MeasureSlot extends ParentDataWidget<_MeasureParentData> {
  const _MeasureSlot({required this.id, required super.child});

  final String id;

  @override
  void applyParentData(RenderObject renderObject) {
    final parentData = renderObject.parentData! as _MeasureParentData;
    if (parentData.id != id) {
      parentData.id = id;
      renderObject.parent?.markNeedsLayout();
    }
  }

  @override
  Type get debugTypicalAncestorWidgetClass => _Measurer;
}

class _Measurer extends MultiChildRenderObjectWidget {
  const _Measurer({
    required this.sink,
    required this.width,
    required super.children,
  });

  final _MeasureSink sink;
  final double width;

  @override
  _RenderMeasurer createRenderObject(BuildContext context) =>
      _RenderMeasurer(sink, width);

  @override
  void updateRenderObject(BuildContext context, _RenderMeasurer renderObject) {
    renderObject
      ..sink = sink
      ..width = width;
  }
}

class _RenderMeasurer extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, _MeasureParentData> {
  _RenderMeasurer(this.sink, this._width);

  _MeasureSink sink;

  double get width => _width;
  double _width;
  set width(double value) {
    if (value == _width) return;
    _width = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _MeasureParentData) {
      child.parentData = _MeasureParentData();
    }
  }

  @override
  void performLayout() {
    final heights = <String, double>{};
    var child = firstChild;
    while (child != null) {
      final parentData = child.parentData! as _MeasureParentData;
      child.layout(
        BoxConstraints.tightFor(width: _width),
        parentUsesSize: true,
      );
      final id = parentData.id;
      if (id != null) heights[id] = child.size.height;
      child = parentData.nextSibling;
    }
    sink.heights = heights;
    size = constraints.smallest;
  }

  @override
  void paint(PaintingContext context, Offset offset) {}

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) => false;

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {}
}

/// Tight constraints that also carry the measured full-form heights, so a
/// new measurement re-runs the presenter's builder.
final class _PresenterConstraints extends BoxConstraints {
  _PresenterConstraints(super.size, this.heights) : super.tight();

  final Map<String, double> heights;

  @override
  bool operator ==(Object other) =>
      other is _PresenterConstraints &&
      other.minWidth == minWidth &&
      other.maxWidth == maxWidth &&
      other.minHeight == minHeight &&
      other.maxHeight == maxHeight &&
      mapEquals(other.heights, heights);

  @override
  int get hashCode => Object.hash(
        minWidth,
        maxWidth,
        minHeight,
        maxHeight,
        Object.hashAllUnordered(
          heights.entries.map((entry) => Object.hash(entry.key, entry.value)),
        ),
      );
}

class _Presenter extends AbstractLayoutBuilder<BoxConstraints> {
  const _Presenter({required this.builder});

  @override
  final Widget Function(BuildContext context, BoxConstraints constraints)
      builder;

  @override
  _RenderPresenter createRenderObject(BuildContext context) =>
      _RenderPresenter();
}

class _RenderPresenter extends RenderBox
    with
        RenderObjectWithChildMixin<RenderBox>,
        RenderObjectWithLayoutCallbackMixin,
        RenderAbstractLayoutBuilderMixin<BoxConstraints, RenderBox> {
  @override
  void performLayout() {
    runLayoutCallback();
    size = constraints.biggest;
    child?.layout(BoxConstraints.tight(size));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child != null) context.paintChild(child, offset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      child?.hitTest(result, position: position) ?? false;
}

// ---------------------------------------------------------------------------
// A zero-size canvas that places children at explicit offsets. It hit-tests
// its children wherever they are, because notes extend past a block.

final class _CanvasParentData extends ContainerBoxParentData<RenderBox> {
  double left = 0;
  double top = 0;
  double width = 0;
  double? height;
  double? maxHeight;
  double? clampTop;
  double? clampBottom;
}

class _CanvasSlot extends ParentDataWidget<_CanvasParentData> {
  const _CanvasSlot({
    required this.left,
    required this.top,
    required this.width,
    this.height,
    this.maxHeight,
    this.clampTop,
    this.clampBottom,
    required super.child,
  });

  final double left;
  final double top;
  final double width;

  /// Tight height, or natural height up to [maxHeight] when null.
  final double? height;
  final double? maxHeight;

  /// When both are set, the child's top is moved so that it lies within
  /// [clampTop, clampBottom] where it fits, preferring [clampTop].
  final double? clampTop;
  final double? clampBottom;

  @override
  void applyParentData(RenderObject renderObject) {
    final parentData = renderObject.parentData! as _CanvasParentData;
    if (parentData.left == left &&
        parentData.top == top &&
        parentData.width == width &&
        parentData.height == height &&
        parentData.maxHeight == maxHeight &&
        parentData.clampTop == clampTop &&
        parentData.clampBottom == clampBottom) {
      return;
    }
    parentData
      ..left = left
      ..top = top
      ..width = width
      ..height = height
      ..maxHeight = maxHeight
      ..clampTop = clampTop
      ..clampBottom = clampBottom;
    renderObject.parent?.markNeedsLayout();
  }

  @override
  Type get debugTypicalAncestorWidgetClass => _MarginCanvas;
}

class _MarginCanvas extends MultiChildRenderObjectWidget {
  const _MarginCanvas({required super.children});

  @override
  _RenderMarginCanvas createRenderObject(BuildContext context) =>
      _RenderMarginCanvas();
}

class _RenderMarginCanvas extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _CanvasParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _CanvasParentData> {
  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _CanvasParentData) {
      child.parentData = _CanvasParentData();
    }
  }

  @override
  void performLayout() {
    var child = firstChild;
    while (child != null) {
      final data = child.parentData! as _CanvasParentData;
      final height = data.height;
      child.layout(
        BoxConstraints(
          minWidth: data.width,
          maxWidth: data.width,
          minHeight: height ?? 0,
          maxHeight: height ?? data.maxHeight ?? double.infinity,
        ),
        parentUsesSize: true,
      );
      var top = data.top;
      final clampTop = data.clampTop;
      final clampBottom = data.clampBottom;
      if (clampTop != null && clampBottom != null) {
        top =
            math.max(clampTop, math.min(top, clampBottom - child.size.height));
      }
      data.offset = Offset(data.left, top);
      child = data.nextSibling;
    }
    size = constraints.smallest;
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!hitTestChildren(result, position: position)) return false;
    result.add(BoxHitTestEntry(this, position));
    return true;
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
