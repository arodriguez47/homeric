/// HomericParagraph: the render-layer lifecycle core (U2) — a [RenderBox]
/// owning exactly one live `ui.Paragraph` per block — plus inline widget
/// children for `widget` decoration slots (U3).
///
/// The render object consumes a [ParagraphSource] whose style handles are
/// painting-layer [TextStyle]s: that is the builder-input adapter from
/// U1's generic output to `dart:ui` — each run's [TextStyle] becomes a
/// `ui.TextStyle` **at build time** via [TextStyle.getTextStyle], which
/// applies the current [TextScaler] by scaling font sizes
/// (`TextScaler.scale`). A raw `ui.TextStyle` handle could not do this:
/// it is write-only, so a scaler change could never re-derive it.
///
/// Invalidation matrix (mirroring the framework's proven triggers):
///
/// * content / style / direction / strut / [TextScaler] change →
///   rebuild + relayout (the paragraph is dropped and rebuilt);
/// * width-only change → relayout of the **same** `ui.Paragraph`
///   (identity stable, observable via [RenderHomericParagraph.layoutParagraph]);
/// * slot dimension change (an inline child measured to a new size) →
///   content-level: rebuild + relayout, detected during `performLayout`;
/// * paint-only changes ([RenderHomericParagraph.paintStyler], the U5
///   repaint band) → deferred rebuild inside `paint()` with a
///   layout-identity assert — never inside layout;
/// * decoration paint layers ([RenderHomericParagraph.paintLayers], also
///   U5 — see `paint_layers.dart`) → `markNeedsPaint()` only: rects are
///   resolved fresh every `paint()` call through the U4 geometry service,
///   so there is nothing to rebuild or relayout, and a spec-only change
///   (e.g. an animated dim amount) never marks semantics dirty either;
/// * system font change → caches dropped + relayout
///   ([RelayoutWhenSystemFontsChangeMixin]).
///
/// The matrix reads outward too: **every** relayout — and nothing else —
/// dispatches [RenderHomericParagraph.onGeometryChanged] exactly once,
/// deferred out of the layout phase. Paint-only rows above never reach
/// `performLayout`, so an animated dim ticking `paintLayers` every frame
/// cannot turn into a rebuild; and with no callback installed the signal
/// costs one branch per layout.
///
/// Inline widget children (U3) follow the framework's placeholder dance,
/// copied — not mixin-reused, because
/// `RenderInlineChildrenContainerDefaults` assumes `PlaceholderSpan`
/// parent data and Homeric has no `InlineSpan` tree:
///
/// 1. children are laid out **once**, before text layout, with
///    `BoxConstraints(maxWidth: wrapWidth)` only (unconstrained height —
///    no feedback loop, children are never re-laid-out after the
///    paragraph is);
/// 2. their sizes (plus a baseline via `getDistanceToBaseline` /
///    `getDryBaseline`, only for baseline alignment) become
///    [PlaceholderDimensions] → `addPlaceholder(w, h, alignment,
///    scale: 1.0)` in view-text order — `scale` is always 1.0; any
///    [TextScaler] concern belongs to the child's own build;
/// 3. after paragraph layout, `getBoxesForPlaceholders` yields one box
///    per placeholder in `addPlaceholder` order; each child's paint
///    offset is its box's top-left, stored in parent data — a missing
///    box (fewer boxes than children; future ellipsis) leaves the
///    offset null and the child is skipped in paint and hit-testing.
///
/// Empty view text (e.g. a whole-block replace) has **no** caret-capable
/// line on this engine: a paragraph with no text lays out with
/// `numberOfLines == 0`, an empty `computeLineMetrics()`, and a null
/// `getLineMetricsAt(0)` (pinned by test). We therefore adopt the
/// framework's **space-glyph layout template** fallback — a separate
/// single-`' '` paragraph in the block's base style supplies line height
/// and baseline — rather than a strut-based one, matching
/// `TextPainter._createLayoutTemplate`.
///
/// Provenance (framework sources read, not copied):
///
/// * `flutter/lib/src/rendering/paragraph.dart` (`RenderParagraph`,
///   `TextParentData`, `RenderInlineChildrenContainerDefaults`): the
///   property-setter invalidation table, the separate-intrinsics-painter
///   pattern (intrinsic/dry queries must never clobber the live layout),
///   the inline-children dance (`layoutInlineChildren` →
///   `positionInlineChildren` → `paintInlineChildren` /
///   `hitTestInlineChildren` / `defaultApplyPaintTransform`, including
///   the nullable parent-data offset and the intrinsic-width children
///   measured as `Size(child.get{Min,Max}IntrinsicWidth(∞), 0.0)`),
///   `systemFontsDidChange`, and the dispose discipline.
/// * `flutter/lib/src/painting/text_painter.dart` (`TextPainter`,
///   `PlaceholderDimensions`): the deferred paint-only rebuild
///   (`_rebuildParagraphForPaint`), the infinite-max-width second layout
///   pass, and the space-glyph layout template for empty-text metrics.
/// * `flutter/lib/src/widgets/widget_span.dart` (`WidgetSpan.build`):
///   the `addPlaceholder` call shape (dimensions + alignment + baseline
///   + baselineOffset).
/// * `flutter/lib/src/widgets/size_changed_layout_notifier.dart`
///   (`_RenderSizeChangedWithCallback`): the notify-from-`performLayout`
///   shape, read and deliberately **not** followed — it dispatches
///   synchronously and skips the initial layout, and its own class doc
///   names the resulting "backwards dependency in the frame pipeline".
/// * `flutter/lib/src/widgets/text_selection.dart`
///   (`SelectionOverlay.markNeedsBuild`) and
///   `flutter/lib/src/widgets/overlay.dart` (`OverlayEntry.remove`): the
///   `schedulerPhase == persistentCallbacks → addPostFrameCallback`
///   deferral used instead, for [onGeometryChanged]. `RenderEditable`'s
///   `selectionStartInViewport` is the precedent for a render object
///   publishing a change signal an overlay consumes.
library;

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../view/view_map.dart';
import 'paint_layers.dart';
import 'paragraph_geometry.dart';
import 'paragraph_source.dart';

part 'paragraph_overlay.dart';

/// A paint-only per-run style adjustment — U5's repaint band.
///
/// Applied to every text run when the `ui.Paragraph` is (re)built; returns
/// the [TextStyle] to render [segment] with (typically
/// `segment.style.copyWith(color: …)`).
///
/// Contract: the returned style may differ from `segment.style` **only in
/// paint-affecting fields** (color, decoration color, shadows…). Changing
/// layout-affecting fields (font size, weight, family, height…) from a
/// paint-only styler violates the deferred-rebuild contract and trips a
/// layout-identity assert during paint. Stylers are compared by identity:
/// pass the same function instance while nothing changed.
typedef PaintOnlyStyler = TextStyle Function(TextSegment<TextStyle> segment);

/// Builds the inline child widget for one slot of a [HomericParagraph].
///
/// Called once per slot per widget build, in slot-index (view-text)
/// order; the slot's stable identity is [SlotSegment.spec].
typedef SlotWidgetBuilder = Widget Function(SlotSegment<TextStyle> slot);

/// Announces that [RenderHomericParagraph]'s geometry is available and
/// current: once when a paragraph is first laid out, and once after every
/// relayout.
///
/// This is the subscription half of the U4 geometry service. Every query
/// on [ParagraphGeometry] is stamped with a layout generation and asserts
/// when read against a newer one — but a consumer painting overlays from
/// our geometry had no way to *observe* that generation, so it could only
/// re-place its overlays when something else happened to rebuild it.
/// Positioned overlays (footnote markers, hover and tap targets) therefore
/// never mounted at all, while inline slot children — which are inside the
/// paragraph rather than derived from its geometry — rendered on the first
/// build.
///
/// [generation] is [RenderHomericParagraph.layoutGeneration] at dispatch.
/// Stamp any geometry-derived response with it and drop the response when
/// a newer generation arrives, rather than painting it.
///
/// [paragraph] is the render object, deliberately not a
/// [ParagraphGeometry]: that class is contractually constructed fresh per
/// query burst (it memoizes, and asserts if held across a relayout), so an
/// instance handed over here and queried during the consumer's next build
/// would be exactly the stale-held-instance case its guard exists to
/// catch. Construct `ParagraphGeometry(paragraph)` at the point of use.
///
/// The signal is 1:1 with the layout generation advancing — "geometry is
/// new", not "rects moved". Suppressing fires where nothing visibly moved
/// would silently break [GeometryResult.isStale] for held results.
typedef GeometryChangedCallback = void Function(
    RenderHomericParagraph paragraph, int generation);

/// Parent data for [RenderHomericParagraph]'s inline slot children.
///
/// Mirrors the framework's `TextParentData`: not a [BoxParentData],
/// because a child may have **no** paint offset for the current layout
/// (its placeholder box is missing — e.g. ellipsized away in a future
/// unit), which a nullable [offset] expresses and a `BoxParentData`
/// cannot.
class HomericSlotParentData extends ParentData
    with ContainerParentDataMixin<RenderBox> {
  /// The offset at which to paint the child within the paragraph, or
  /// null when the child has no placeholder box this layout — such a
  /// child is skipped in paint and hit-testing.
  Offset? get offset => _offset;
  Offset? _offset;

  @override
  void detach() {
    _offset = null;
    super.detach();
  }

  @override
  String toString() => offset == null
      ? 'not positioned; ${super.toString()}'
      : 'offset: '
          '$offset; ${super.toString()}';
}

/// Tags a widget slot's semantics subtree with its slot index so
/// [RenderHomericParagraph]'s semantics delegate can attribute the
/// child's own accessibility configuration(s) to the correct reading
/// position among the text runs (U6, R6).
///
/// Mirrors `RichText`'s inline-widget tagging: `WidgetSpan.build`
/// (`flutter/lib/src/widgets/widget_span.dart`) wraps every placeholder
/// child in `Semantics(tagForChildren: PlaceholderSpanIndexSemanticsTag(index))`
/// so `RenderParagraph`'s `childConfigurationsDelegate`
/// (`flutter/lib/src/rendering/paragraph.dart`) can find which merged-up
/// child configuration(s) belong to which placeholder — read, not
/// copied. Homeric has no `InlineSpan` tree to attach a tag to a span,
/// so [HomericParagraph] wraps each slot widget in the equivalent
/// `Semantics(tagForChildren: ...)` annotation instead.
@immutable
class HomericSlotIndexSemanticsTag extends SemanticsTag {
  /// Creates a tag for the slot at [index] (its [SlotSegment.slotIndex],
  /// i.e. its `addPlaceholder` order).
  const HomericSlotIndexSemanticsTag(this.index)
      : super('HomericSlotIndexSemanticsTag($index)');

  /// The slot's ordinal.
  final int index;

  @override
  bool operator ==(Object other) =>
      other is HomericSlotIndexSemanticsTag && other.index == index;

  @override
  int get hashCode => Object.hash(HomericSlotIndexSemanticsTag, index);
}

/// The render box owning one live `ui.Paragraph` for a block's
/// [ParagraphSource], with one inline [RenderBox] child per widget slot.
///
/// Layout happens at the wrap width (the incoming max width constraint);
/// alignment is expressed exclusively through `ui.ParagraphStyle`
/// ([textAlign] + the source's direction), so painting is a single
/// `drawParagraph` at the box origin (plus the slot children at their
/// placeholder boxes) with no paint-offset arithmetic.
///
/// Children correspond 1:1, in order, to the source's slots; the count
/// invariant is enforced both ways (children == slots == placeholders
/// emitted). A childless render object falls back to [slotDimensions] /
/// [provisionalSlotDimensions] so slots still occupy space (the U2
/// behavior).
class RenderHomericParagraph extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, HomericSlotParentData>,
        RelayoutWhenSystemFontsChangeMixin {
  /// Creates the render object. See the property setters for invalidation
  /// semantics.
  RenderHomericParagraph({
    required ParagraphSource<TextStyle> source,
    TextStyle? baseStyle,
    TextAlign textAlign = TextAlign.start,
    TextScaler textScaler = TextScaler.noScaling,
    List<Size>? slotDimensions,
    ui.PlaceholderAlignment slotAlignment = ui.PlaceholderAlignment.middle,
    TextBaseline? slotBaseline,
    PaintOnlyStyler? paintStyler,
    List<PaintLayer> paintLayers = const <PaintLayer>[],
    ParagraphSource<Object?>? semanticsSource,
    GeometryChangedCallback? onGeometryChanged,
    List<RenderBox>? children,
  })  : assert(_checkSlotBaseline(slotAlignment, slotBaseline)),
        _source = source,
        _baseStyle = baseStyle,
        _textAlign = textAlign,
        _textScaler = textScaler,
        _slotDimensions = slotDimensions,
        _slotAlignment = slotAlignment,
        _slotBaseline = slotBaseline,
        _paintStyler = paintStyler,
        _paintLayers = paintLayers,
        _underlayLayers = List<PaintLayer>.unmodifiable(
            paintLayers.where((layer) => layer.band == PaintBand.underlay)),
        _overlayLayers = List<PaintLayer>.unmodifiable(
            paintLayers.where((layer) => layer.band == PaintBand.overlay)),
        _semanticsSource = semanticsSource,
        // Initializer-list assignment deliberately bypasses the setter's
        // catch-up branch: nothing has been laid out yet, and the first
        // performLayout dispatches on its own.
        _onGeometryChanged = onGeometryChanged {
    addAll(children);
  }

  /// Fixed provisional placeholder dimensions, used for slots when the
  /// render object has no inline children and no [slotDimensions].
  ///
  /// Slots must still occupy real space so every other glyph's geometry
  /// is correct; real children replace these with measured sizes.
  static const Size provisionalSlotDimensions = Size(14.0, 14.0);

  /// Shared baseline-requirement check for both [RenderHomericParagraph]'s
  /// and [HomericParagraph]'s constructors (fix for duplicated asserts):
  /// [baseline] is required whenever [alignment] is one of the
  /// baseline-relative [ui.PlaceholderAlignment]s. Always returns `true` —
  /// intended for `assert(_checkSlotBaseline(...))` so the check (and its
  /// message) is elided outside debug builds like any other assert.
  static bool _checkSlotBaseline(
      ui.PlaceholderAlignment alignment, TextBaseline? baseline) {
    assert(!_requiresBaseline(alignment) || baseline != null,
        'slotBaseline is required for $alignment slot alignment');
    return true;
  }

  static bool _requiresBaseline(ui.PlaceholderAlignment alignment) =>
      switch (alignment) {
        ui.PlaceholderAlignment.baseline ||
        ui.PlaceholderAlignment.aboveBaseline ||
        ui.PlaceholderAlignment.belowBaseline =>
          true,
        ui.PlaceholderAlignment.top ||
        ui.PlaceholderAlignment.bottom ||
        ui.PlaceholderAlignment.middle =>
          false,
      };

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! HomericSlotParentData) {
      child.parentData = HomericSlotParentData();
    }
  }

  // --- Inputs -----------------------------------------------------------

  /// The block's builder inputs (U1 output with painting-layer styles).
  ///
  /// Compared **by content** (view text, segments with their resolved
  /// styles, slots, [ViewMap], block spec), so re-deriving an identical
  /// source is a no-op and the live paragraph keeps its identity. Any
  /// difference — content, per-run style, direction, line height, strut —
  /// drops the paragraph: rebuild + relayout.
  ///
  /// Note [BlockParagraphSpec] compares its strut passthrough by identity;
  /// reuse (or `const`-construct) the [StrutStyle] instance across builds
  /// to avoid spurious rebuilds.
  ParagraphSource<TextStyle> get source => _source;
  ParagraphSource<TextStyle> _source;
  set source(ParagraphSource<TextStyle> value) {
    if (_paragraphSourceEquals(_source, value)) {
      _source = value;
      return;
    }
    _source = value;
    _markNeedsRebuild();
    if (_semanticsSource == null) {
      // No independent semantics derivation: source doubles as the
      // semantics source (see its doc), so a real content change here is
      // also a semantic content change (R6 — "not on every paint-only
      // change"; paintStyler's own setter never reaches this branch).
      markNeedsSemanticsUpdate();
    }
  }

  /// The block's base style: the `ui.ParagraphStyle`-level default font
  /// (so empty view text still sizes correctly) and the root style every
  /// run's style inherits from. Change → rebuild + relayout.
  TextStyle? get baseStyle => _baseStyle;
  TextStyle? _baseStyle;
  set baseStyle(TextStyle? value) {
    if (_baseStyle == value) {
      return;
    }
    _baseStyle = value;
    _markNeedsRebuild();
  }

  /// Horizontal alignment, applied via `ui.ParagraphStyle` only (glyph
  /// positions come out of the engine already aligned within the wrap
  /// width). Change → rebuild + relayout.
  TextAlign get textAlign => _textAlign;
  TextAlign _textAlign;
  set textAlign(TextAlign value) {
    if (_textAlign == value) {
      return;
    }
    _textAlign = value;
    _markNeedsRebuild();
  }

  /// The text scaler, applied by scaling font sizes at paragraph build
  /// time ([TextStyle.getTextStyle] calls `TextScaler.scale`). Change →
  /// rebuild + relayout.
  ///
  /// Slot children are **not** scaled by the render object: a chip
  /// widget that should track the text scale reads its own
  /// [MediaQuery]; its measured size then already reflects the scale.
  TextScaler get textScaler => _textScaler;
  TextScaler _textScaler;
  set textScaler(TextScaler value) {
    if (_textScaler == value) {
      return;
    }
    _textScaler = value;
    _markNeedsRebuild();
  }

  /// Per-slot placeholder dimensions in slot-index order for a
  /// **childless** render object, or null for
  /// [provisionalSlotDimensions] everywhere. Ignored while inline
  /// children are attached — measured child sizes always win. Change →
  /// rebuild + relayout.
  ///
  /// A non-null list whose length disagrees with the source's slot count
  /// throws a descriptive [FlutterError] at build time.
  List<Size>? get slotDimensions => _slotDimensions;
  List<Size>? _slotDimensions;
  set slotDimensions(List<Size>? value) {
    if (listEquals(_slotDimensions, value)) {
      return;
    }
    _slotDimensions = value;
    _markNeedsRebuild();
  }

  /// How slot placeholders align vertically with the surrounding text
  /// (every slot of the block shares one alignment). Change → rebuild +
  /// relayout.
  ///
  /// Defaults to [ui.PlaceholderAlignment.middle]; the baseline-relative
  /// alignments require [slotBaseline].
  ui.PlaceholderAlignment get slotAlignment => _slotAlignment;
  ui.PlaceholderAlignment _slotAlignment;
  set slotAlignment(ui.PlaceholderAlignment value) {
    if (_slotAlignment == value) {
      return;
    }
    _slotAlignment = value;
    _markNeedsRebuild();
  }

  /// The text baseline slot placeholders align to, required by (and only
  /// meaningful for) the baseline-relative [slotAlignment]s. Change →
  /// rebuild + relayout.
  TextBaseline? get slotBaseline => _slotBaseline;
  TextBaseline? _slotBaseline;
  set slotBaseline(TextBaseline? value) {
    if (_slotBaseline == value) {
      return;
    }
    _slotBaseline = value;
    _markNeedsRebuild();
  }

  /// The paint-only repaint band (U5). Change → deferred rebuild in
  /// `paint()`; never a relayout ([layoutGeneration] is untouched and the
  /// deferred rebuild asserts layout identity).
  PaintOnlyStyler? get paintStyler => _paintStyler;
  PaintOnlyStyler? _paintStyler;
  set paintStyler(PaintOnlyStyler? value) {
    if (identical(_paintStyler, value)) {
      return;
    }
    _paintStyler = value;
    if (_paragraph == null) {
      // Not built yet: the next build picks the styler up.
      return;
    }
    _rebuildForPaint = true;
    markNeedsPaint();
  }

  /// Range-driven decoration paint layers (U5): underlay/overlay rects
  /// resolved through the U4 [ParagraphGeometry] service fresh every
  /// `paint()` call — see `paint_layers.dart`'s library doc for the paint-
  /// order guarantee and the same-frame-resolution rationale.
  ///
  /// Compared by value (each [PaintLayer]'s own equality — range, band,
  /// spec, painter identity), so a spec-only change (e.g. an animated dim
  /// amount ticking) is detected without a full source re-derivation.
  /// Change → `markNeedsPaint()` **only**: unlike [paintStyler], this
  /// never touches the `ui.Paragraph` at all (layers paint on the canvas
  /// around the existing paragraph), so there is no rebuild, no relayout,
  /// and — deliberately, since a decoration's paint spec is never
  /// accessibility content — no [markNeedsSemanticsUpdate].
  List<PaintLayer> get paintLayers => _paintLayers;
  List<PaintLayer> _paintLayers;

  /// [_paintLayers] filtered to [PaintBand.underlay], precomputed once per
  /// assignment (constructor or setter) rather than re-filtered on every
  /// `paint()` call — `paint()` runs once per frame while an assignment is
  /// comparatively rare.
  List<PaintLayer> _underlayLayers;

  /// [_paintLayers] filtered to [PaintBand.overlay]. See [_underlayLayers].
  List<PaintLayer> _overlayLayers;

  set paintLayers(List<PaintLayer> value) {
    if (listEquals(_paintLayers, value)) {
      return;
    }
    _paintLayers = value;
    _underlayLayers = List<PaintLayer>.unmodifiable(
        value.where((layer) => layer.band == PaintBand.underlay));
    _overlayLayers = List<PaintLayer>.unmodifiable(
        value.where((layer) => layer.band == PaintBand.overlay));
    markNeedsPaint();
  }

  /// An independently-derived paragraph source used **only** to build the
  /// accessibility label and widget-slot reading order (U6, R6); falls
  /// back to [source] when null.
  ///
  /// Semantics must track **document** semantics, not paint-time view
  /// geometry (R6, "semantics label = document text"): a hidden
  /// delimiter that [source] excludes because a decoration always folds
  /// it away reads identically whether or not it is ever revealed, but a
  /// delimiter [source] excludes only because reveal-on-selection (R10)
  /// happens to be off right now must **still** be excluded from the
  /// label even while a differently-derived [source] (reveal on, for
  /// editing) paints the raw delimiters — reveal state must never make
  /// the label flicker. Supply a `semanticsSource` built with
  /// `RevealState.none` (regardless of the paint-time reveal state)
  /// whenever the block's decorations are reveal-sensitive; a block that
  /// never uses reveal can omit this and let [source] serve both roles.
  ///
  /// A real (non-hiding) `replace` decoration's substituted text — e.g.
  /// an aside marker's replacement content — is not reveal-sensitive and
  /// already reads as ordinary prose in either derivation: it neither
  /// vanishes nor leaks the raw document delimiters it replaces.
  ///
  /// Compared by content exactly like [source] (view text, segments,
  /// slots, spec) — a content-identical re-derivation is a no-op. Change
  /// → [markNeedsSemanticsUpdate], never a relayout.
  ParagraphSource<Object?>? get semanticsSource => _semanticsSource;
  ParagraphSource<Object?>? _semanticsSource;
  set semanticsSource(ParagraphSource<Object?>? value) {
    if (_paragraphSourceEquals(_semanticsSource, value)) {
      _semanticsSource = value;
      return;
    }
    _semanticsSource = value;
    markNeedsSemanticsUpdate();
  }

  /// Called once after every layout, when this paragraph's geometry is
  /// available and current. See [GeometryChangedCallback].
  ///
  /// **This setter invalidates nothing.** Unlike every other property on
  /// this class it calls none of [markNeedsLayout], [markNeedsPaint], or
  /// [markNeedsSemanticsUpdate] — installing an observer must never change
  /// what is observed.
  ///
  /// It does one thing beyond assignment: on the null → non-null
  /// transition, when a paragraph is *already* laid out, it schedules a
  /// catch-up dispatch. A consumer whose overlay builder only becomes
  /// non-null on a later build would otherwise install the callback with
  /// no relayout following it and wait for an unrelated edit — the bug
  /// this whole seam exists to fix, in miniature. A consumer passing a
  /// freshly-built closure every build is unaffected: the previous value
  /// was non-null, so nothing is scheduled.
  ///
  /// Only one observer is supported, which is deliberate — the single
  /// owner of a [HomericParagraph] is the consumer's own block widget, and
  /// a callback delivered through `createRenderObject` needs no
  /// [GlobalKey] and survives a render-object swap without the consumer
  /// holding (or leaking) a subscription. If a second observer is ever
  /// genuinely needed, a lazily-allocated `ValueListenable<int>` can be
  /// added on the same private dispatch point without breaking this.
  GeometryChangedCallback? get onGeometryChanged => _onGeometryChanged;
  GeometryChangedCallback? _onGeometryChanged;
  set onGeometryChanged(GeometryChangedCallback? value) {
    final wasSilent = _onGeometryChanged == null;
    _onGeometryChanged = value;
    if (wasSilent && value != null && hasSize && !debugNeedsLayout) {
      _scheduleGeometryNotification();
    }
  }

  // --- Paragraph caches ---------------------------------------------------

  ui.Paragraph? _paragraph;
  ui.Paragraph? _intrinsicsParagraph;
  ui.Paragraph? _lineTemplate;
  List<PlaceholderDimensions>? _liveDimensions;
  List<PlaceholderDimensions>? _intrinsicsDimensions;
  bool _rebuildForPaint = false;
  int _layoutGeneration = 0;
  bool _geometryNotificationScheduled = false;
  bool _disposed = false;

  /// Content equality for a [ParagraphSource] of any style-handle type
  /// (view text, spec, [ViewMap], segments) — shared by [source] and
  /// [semanticsSource], which otherwise differ only in null-handling
  /// (non-nullable vs. nullable). Dart's covariant generics let a
  /// non-nullable `ParagraphSource<TextStyle>` pass here wherever a
  /// `ParagraphSource<Object?>?` is expected.
  static bool _paragraphSourceEquals<S>(
      ParagraphSource<S>? a, ParagraphSource<S>? b) {
    if (identical(a, b)) {
      return true;
    }
    if (a == null || b == null) {
      return false;
    }
    return a.viewText == b.viewText &&
        a.spec == b.spec &&
        a.viewMap == b.viewMap &&
        listEquals(a.segments, b.segments);
  }

  void _markNeedsRebuild() {
    _dropParagraphs();
    markNeedsLayout();
  }

  /// Dispatches [onGeometryChanged], deferring out of the layout phase.
  ///
  /// A listener's natural reaction is to rebuild something, and the
  /// framework forbids mutating render objects during
  /// `PipelineOwner.flushLayout` (`RenderObject._debugCanPerformMutations`
  /// asserts) — so firing straight from `performLayout` would assert the
  /// moment a consumer touched anything outside our subtree. The
  /// framework's own synchronous-from-layout notifier
  /// (`_RenderSizeChangedWithCallback`) documents the same hazard as a
  /// "backwards dependency in the frame pipeline" and sidesteps it by
  /// skipping the *initial* layout — the opposite of what this signal must
  /// do, since mounting first-build overlays is the whole point.
  ///
  /// So we use the framework's other idiom for the same problem
  /// (`SelectionOverlay.markNeedsBuild`, `OverlayEntry.remove`): inside a
  /// frame, hop to a post-frame callback; otherwise fire synchronously.
  /// This costs no latency — geometry follows layout, which follows build,
  /// so a consumer's `setState` lands in the next frame either way.
  void _scheduleGeometryNotification() {
    if (_onGeometryChanged == null) {
      // Nobody listens: no closure, no allocation, no post-frame
      // registration. This branch is the whole cost of the feature for
      // the paragraphs that never opt in.
      return;
    }
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_geometryNotificationScheduled) {
        // Two layouts in one frame dispatch once, at the final
        // generation — see _dispatchGeometryChanged.
        return;
      }
      _geometryNotificationScheduled = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _geometryNotificationScheduled = false;
        _dispatchGeometryChanged();
      }, debugLabel: 'RenderHomericParagraph.onGeometryChanged');
      return;
    }
    _dispatchGeometryChanged();
  }

  void _dispatchGeometryChanged() {
    if (_disposed) {
      // A post-frame callback cannot be cancelled once registered; this
      // guard is the cancellation. Without it a queued dispatch would
      // hand over a render object whose layoutParagraph asserts
      // use-after-dispose.
      return;
    }
    // Read live, not at schedule time, so a coalesced double-layout
    // reports the generation a ParagraphGeometry built now would capture.
    _onGeometryChanged?.call(this, _layoutGeneration);
  }

  void _dropParagraphs() {
    _paragraph?.dispose();
    _paragraph = null;
    _liveDimensions = null;
    _intrinsicsParagraph?.dispose();
    _intrinsicsParagraph = null;
    _intrinsicsDimensions = null;
    _lineTemplate?.dispose();
    _lineTemplate = null;
    _rebuildForPaint = false;
  }

  ui.ParagraphStyle _paragraphStyle() {
    final spec = _source.spec;
    final strut = spec.strut;
    assert(
        strut == null || strut is StrutStyle,
        'BlockParagraphSpec.strut must be a painting-layer StrutStyle at '
        'the render layer; got ${strut.runtimeType}');
    final heightBehavior = spec.textHeightBehavior;
    assert(
        heightBehavior == null || heightBehavior is ui.TextHeightBehavior,
        'BlockParagraphSpec.textHeightBehavior must be a dart:ui '
        'TextHeightBehavior at the render layer; got '
        '${heightBehavior.runtimeType}');
    // TextStyle.getParagraphStyle folds the base font, height, direction,
    // and strut into a ui.ParagraphStyle, scaling font sizes through the
    // TextScaler (flutter/lib/src/painting/text_style.dart).
    return (_baseStyle ?? const TextStyle()).getParagraphStyle(
      textAlign: _textAlign,
      textDirection: switch (spec.direction) {
        ParagraphDirection.ltr => TextDirection.ltr,
        ParagraphDirection.rtl => TextDirection.rtl,
      },
      textScaler: _textScaler,
      height: spec.lineHeight,
      strutStyle: strut as StrutStyle?,
      textHeightBehavior: heightBehavior as ui.TextHeightBehavior?,
    );
  }

  // --- Slot dimensions ------------------------------------------------------

  PlaceholderDimensions _placeholderFor(Size size, double? baselineOffset) {
    assert(!_requiresBaseline(_slotAlignment) || _slotBaseline != null,
        'slotBaseline is required for $_slotAlignment slot alignment');
    return PlaceholderDimensions(
      size: size,
      alignment: _slotAlignment,
      baseline: _slotBaseline,
      baselineOffset: baselineOffset,
    );
  }

  /// The children, in slot order, with the child↔slot count invariant
  /// enforced (the other direction — placeholders emitted == slots — is
  /// asserted in [_buildParagraph]).
  List<RenderBox> _slotChildren() {
    final children = <RenderBox>[];
    for (var child = firstChild; child != null; child = childAfter(child)) {
      children.add(child);
    }
    if (children.length != _source.slots.length) {
      throw FlutterError.fromParts(<DiagnosticsNode>[
        ErrorSummary('HomericParagraph slot child count mismatch.'),
        ErrorDescription(
            'The paragraph source derives ${_source.slots.length} widget '
            'slot(s) for view text ${Error.safeToString(_source.viewText)}, '
            'but ${children.length} inline child(ren) are attached.'),
        ErrorHint('Provide exactly one child per slot in slot-index order '
            '(e.g. via HomericParagraph.slotBuilder), or none to fall back '
            'to slotDimensions.'),
      ]);
    }
    return children;
  }

  /// Childless fallback: [slotDimensions] (count-checked) or
  /// [provisionalSlotDimensions].
  List<PlaceholderDimensions> _externalDimensions() {
    final source = _source;
    final dims = _slotDimensions;
    if (dims != null && dims.length != source.slots.length) {
      throw FlutterError.fromParts(<DiagnosticsNode>[
        ErrorSummary('HomericParagraph slot dimensions mismatch.'),
        ErrorDescription(
            'The paragraph source derives ${source.slots.length} widget '
            'slot(s) for view text ${Error.safeToString(source.viewText)}, '
            'but slotDimensions supplies ${dims.length} entr'
            '${dims.length == 1 ? 'y' : 'ies'}.'),
        ErrorHint('Provide exactly one Size per slot in slot-index order, or '
            'null to use the provisional dimensions.'),
      ]);
    }
    return <PlaceholderDimensions>[
      for (var i = 0; i < source.slots.length; i++)
        _placeholderFor(dims?[i] ?? provisionalSlotDimensions, null),
    ];
  }

  /// Really lays the children out (width-only constraint, one pass) and
  /// returns their measured placeholder dimensions. `performLayout` only.
  List<PlaceholderDimensions> _measureChildren(double maxWidth) {
    final constraints = BoxConstraints(maxWidth: maxWidth);
    return <PlaceholderDimensions>[
      for (final child in _slotChildren()) _measureChild(child, constraints),
    ];
  }

  PlaceholderDimensions _measureChild(
      RenderBox child, BoxConstraints constraints) {
    child.layout(constraints, parentUsesSize: true);
    final baselineOffset = _slotAlignment == ui.PlaceholderAlignment.baseline
        ? child.getDistanceToBaseline(_slotBaseline!)
        : null;
    return _placeholderFor(child.size, baselineOffset);
  }

  /// Dry-measures the children (never mutates their layout) for
  /// intrinsic-height, dry-layout, and dry-baseline queries.
  List<PlaceholderDimensions> _dryMeasureChildren(double maxWidth) {
    final constraints = BoxConstraints(maxWidth: maxWidth);
    return <PlaceholderDimensions>[
      for (final child in _slotChildren())
        _placeholderFor(
          child.getDryLayout(constraints),
          _slotAlignment == ui.PlaceholderAlignment.baseline
              ? child.getDryBaseline(constraints, _slotBaseline!)
              : null,
        ),
    ];
  }

  /// Children as width-only dimensions for intrinsic-width queries: the
  /// height is irrelevant on a single unbounded line, so it is faked as
  /// 0.0 — RenderParagraph.computeM{in,ax}IntrinsicWidth's dummy.
  List<PlaceholderDimensions> _intrinsicWidthDimensions(
      double Function(RenderBox child) widthOf) {
    return <PlaceholderDimensions>[
      for (final child in _slotChildren())
        _placeholderFor(Size(widthOf(child), 0.0), null),
    ];
  }

  List<PlaceholderDimensions> _dryDimensions(double maxWidth) =>
      childCount > 0 ? _dryMeasureChildren(maxWidth) : _externalDimensions();

  // --- Paragraph build ------------------------------------------------------

  /// Builds a fresh `ui.Paragraph` from [source] — the
  /// `pushStyle`/`addText`/`addPlaceholder` loop over U1's segments, with
  /// one [PlaceholderDimensions] per slot in slot-index order.
  ui.Paragraph _buildParagraph(List<PlaceholderDimensions> dimensions) {
    final source = _source;
    assert(dimensions.length == source.slots.length);
    final builder = ui.ParagraphBuilder(_paragraphStyle());
    final base = _baseStyle;
    if (base != null) {
      // Root style: per-run styles push on top of it and the engine
      // merges nested styles (the TextSpan.build pattern).
      builder.pushStyle(base.getTextStyle(textScaler: _textScaler));
    }
    for (final segment in source.segments) {
      switch (segment) {
        case final TextSegment<TextStyle> text:
          final style = _paintStyler?.call(text) ?? text.style;
          builder.pushStyle(style.getTextStyle(textScaler: _textScaler));
          builder.addText(text.text);
          builder.pop();
        case final SlotSegment<TextStyle> slot:
          final dims = dimensions[slot.slotIndex];
          // scale: 1.0 always — placeholder sizes are real measured
          // pixels; the TextScaler never multiplies them again
          // (WidgetSpan.build's addPlaceholder shape).
          builder.addPlaceholder(
            dims.size.width,
            dims.size.height,
            dims.alignment,
            scale: 1.0,
            baseline: dims.baseline,
            baselineOffset: dims.baselineOffset,
          );
      }
    }
    assert(
        builder.placeholderCount == source.slots.length,
        'ParagraphSource invariant violated: ${source.slots.length} '
        'slot(s) but ${builder.placeholderCount} placeholder(s) emitted');
    return builder.build();
  }

  /// The space-glyph layout template: a one-space paragraph in the base
  /// style, laid out at infinite width. Supplies line height and baseline
  /// when the live paragraph has no lines (empty view text) — the
  /// framework's own empty-text fallback (TextPainter's layout template).
  ui.Paragraph get _template {
    final existing = _lineTemplate;
    if (existing != null) {
      return existing;
    }
    final builder = ui.ParagraphBuilder(_paragraphStyle());
    builder.pushStyle((_baseStyle ?? const TextStyle())
        .getTextStyle(textScaler: _textScaler));
    builder.addText(' ');
    return _lineTemplate = builder.build()
      ..layout(const ui.ParagraphConstraints(width: double.infinity));
  }

  /// Lays [paragraph] out at [maxWidth] and returns its natural size.
  ///
  /// An infinite max width gets a second pass at the max intrinsic width,
  /// so ParagraphStyle-driven alignment always works against a finite
  /// width (TextPainter's adjusted-max-width dance).
  Size _layoutAt(ui.Paragraph paragraph, double maxWidth) {
    paragraph.layout(ui.ParagraphConstraints(width: maxWidth));
    if (!maxWidth.isFinite) {
      paragraph
          .layout(ui.ParagraphConstraints(width: paragraph.maxIntrinsicWidth));
    }
    return Size(paragraph.width, paragraph.height);
  }

  // --- Render-layer internal surface (U4 geometry service) ---------------

  /// The layout generation: incremented on every relayout of the live
  /// paragraph. Geometry results (U4) are stamped with this so stale
  /// reads become asserts. Paint-only rebuilds do not increment it.
  int get layoutGeneration => _layoutGeneration;

  /// The live, laid-out `ui.Paragraph`.
  ///
  /// Render-layer internal: consumed by the U4 geometry service (and
  /// tests, as the paragraph-identity debug hook). Not part of homeric's
  /// stable public API. Never call `layout` or `dispose` on it.
  @internal
  ui.Paragraph get layoutParagraph {
    assert(!_disposed, 'layoutParagraph used after dispose()');
    assert(!debugNeedsLayout,
        'layoutParagraph read while layout is dirty — query after layout');
    return _paragraph!;
  }

  /// The source's document↔view offset map, for same-library geometry
  /// callers (U4). Render-layer internal.
  @internal
  ViewMap get viewMap => _source.viewMap;

  /// The height of one line in the base style — the caret-capable line
  /// height for empty view text, from the space-glyph template.
  double get preferredLineHeight => _template.height;

  /// The alphabetic baseline of one line in the base style — the
  /// caret-capable baseline for empty view text.
  double get preferredLineBaseline => _template.getLineMetricsAt(0)!.baseline;

  /// The ideographic baseline of one line in the base style — the
  /// [TextBaseline.ideographic] counterpart of [preferredLineBaseline] for
  /// empty view text. `ui.LineMetrics` (unlike `ui.Paragraph` itself) has no
  /// per-line ideographic field, so this reads the single-line template's
  /// paragraph-level [ui.Paragraph.ideographicBaseline] instead of a line
  /// metric — equivalent for a one-line template.
  double get preferredLineIdeographicBaseline => _template.ideographicBaseline;

  /// The cached intrinsics/dry-layout paragraph, if built.
  @visibleForTesting
  ui.Paragraph? get debugIntrinsicsParagraph => _intrinsicsParagraph;

  /// The cached space-glyph line template, if built.
  @visibleForTesting
  ui.Paragraph? get debugLineTemplate => _lineTemplate;

  // --- Layout -------------------------------------------------------------

  @override
  void performLayout() {
    // Children first, one pass, width-only constraint — they are never
    // re-laid-out after the text is (no feedback loop).
    final dimensions = childCount > 0
        ? _measureChildren(constraints.maxWidth)
        : _externalDimensions();
    var paragraph = _paragraph;
    if (paragraph != null && !listEquals(dimensions, _liveDimensions)) {
      // A slot changed size: content-level change, rebuild.
      paragraph.dispose();
      _paragraph = paragraph = null;
    }
    if (paragraph == null) {
      _paragraph = paragraph = _buildParagraph(dimensions);
      // A fresh build already reflects the current paintStyler.
      _rebuildForPaint = false;
    }
    _liveDimensions = dimensions;
    final natural = _layoutAt(paragraph, constraints.maxWidth);
    _layoutGeneration += 1;
    size = constraints.constrain(natural);
    _positionChildren(paragraph);
    // Last, not at the generation bump above: `size` and the children's
    // paint offsets are only settled here, and blockRect/slotRectAt read
    // both. This is the sole dispatch site in the class, which is what
    // makes "a paint-only change never notifies" structural rather than a
    // promise — paintStyler and paintLayers end in markNeedsPaint() and
    // never reach performLayout at all.
    _scheduleGeometryNotification();
  }

  /// Stamps each child's paint offset from `getBoxesForPlaceholders`
  /// (boxes come back in `addPlaceholder` order — slot-index order).
  /// Children beyond the boxes get a null offset and are skipped in
  /// paint/hit-test (RenderInlineChildrenContainerDefaults.
  /// positionInlineChildren's contract).
  void _positionChildren(ui.Paragraph paragraph) {
    if (childCount == 0) {
      return;
    }
    final boxes = paragraph.getBoxesForPlaceholders();
    var index = 0;
    for (var child = firstChild; child != null; child = childAfter(child)) {
      final parentData = child.parentData! as HomericSlotParentData;
      parentData._offset = index < boxes.length
          ? Offset(boxes[index].left, boxes[index].top)
          : null;
      index += 1;
    }
  }

  /// The separate intrinsics paragraph: intrinsic and dry queries must
  /// never clobber the live paragraph's layout (RenderParagraph's
  /// documented trap — its `_textIntrinsics` painter). Rebuilt only when
  /// the requested placeholder dimensions differ from the cached ones.
  ui.Paragraph _intrinsicsFor(List<PlaceholderDimensions> dimensions) {
    final cached = _intrinsicsParagraph;
    if (cached != null && listEquals(_intrinsicsDimensions, dimensions)) {
      return cached;
    }
    cached?.dispose();
    _intrinsicsDimensions = dimensions;
    return _intrinsicsParagraph = _buildParagraph(dimensions);
  }

  @override
  double computeMinIntrinsicWidth(double height) {
    final dimensions = childCount > 0
        ? _intrinsicWidthDimensions(
            (child) => child.getMinIntrinsicWidth(double.infinity))
        : _externalDimensions();
    final paragraph = _intrinsicsFor(dimensions)
      ..layout(const ui.ParagraphConstraints(width: double.infinity));
    return paragraph.minIntrinsicWidth;
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    final dimensions = childCount > 0
        ? _intrinsicWidthDimensions(
            (child) => child.getMaxIntrinsicWidth(double.infinity))
        : _externalDimensions();
    final paragraph = _intrinsicsFor(dimensions)
      ..layout(const ui.ParagraphConstraints(width: double.infinity));
    return paragraph.maxIntrinsicWidth;
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      _layoutAt(_intrinsicsFor(_dryDimensions(width)), width).height;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _layoutAt(_intrinsicsFor(_dryDimensions(width)), width).height;

  @override
  @protected
  Size computeDryLayout(covariant BoxConstraints constraints) =>
      constraints.constrain(_layoutAt(
          _intrinsicsFor(_dryDimensions(constraints.maxWidth)),
          constraints.maxWidth));

  @override
  double? computeDryBaseline(
      covariant BoxConstraints constraints, TextBaseline baseline) {
    final paragraph = _intrinsicsFor(_dryDimensions(constraints.maxWidth));
    _layoutAt(paragraph, constraints.maxWidth);
    if (paragraph.numberOfLines == 0) {
      return switch (baseline) {
        TextBaseline.alphabetic => preferredLineBaseline,
        TextBaseline.ideographic => preferredLineIdeographicBaseline,
      };
    }
    return switch (baseline) {
      TextBaseline.alphabetic => paragraph.alphabeticBaseline,
      TextBaseline.ideographic => paragraph.ideographicBaseline,
    };
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) {
    assert(!debugNeedsLayout);
    final paragraph = _paragraph!;
    // Empty view text has no lines on this engine; the space-glyph
    // template keeps the block caret-capable (baseline + line height).
    if (paragraph.numberOfLines == 0) {
      return switch (baseline) {
        TextBaseline.alphabetic => preferredLineBaseline,
        TextBaseline.ideographic => preferredLineIdeographicBaseline,
      };
    }
    return switch (baseline) {
      TextBaseline.alphabetic => paragraph.alphabeticBaseline,
      TextBaseline.ideographic => paragraph.ideographicBaseline,
    };
  }

  // --- Paint --------------------------------------------------------------

  @override
  void paint(PaintingContext context, Offset offset) {
    var paragraph = _paragraph!;
    if (_rebuildForPaint) {
      // Deferred paint-only rebuild: the engine has no in-place attribute
      // update, so the paragraph is recreated here — never during layout
      // (TextPainter.paint's _rebuildParagraphForPaint path). Slot
      // dimensions are the live ones: a paint-only change cannot resize
      // children.
      final rebuilt = _buildParagraph(_liveDimensions!)
        ..layout(ui.ParagraphConstraints(width: paragraph.width));
      assert(() {
        if (rebuilt.width != paragraph.width ||
            rebuilt.height != paragraph.height ||
            rebuilt.numberOfLines != paragraph.numberOfLines) {
          final was = '${paragraph.width}×${paragraph.height} '
              '(${paragraph.numberOfLines} lines)';
          final became = '${rebuilt.width}×${rebuilt.height} '
              '(${rebuilt.numberOfLines} lines)';
          rebuilt.dispose();
          throw FlutterError.fromParts(<DiagnosticsNode>[
            ErrorSummary(
                'A paint-only style change altered the paragraph layout.'),
            ErrorDescription('Layout was $was but rebuilt to $became.'),
            ErrorHint('paintStyler may only change paint-affecting fields '
                '(color, decoration color, shadows…). Layout-affecting '
                'changes (font size, weight, family, height…) must go '
                'through the source instead.'),
          ]);
        }
        return true;
      }());
      paragraph.dispose();
      _paragraph = paragraph = rebuilt;
      _rebuildForPaint = false;
    }
    // U5 paint order (pinned, not a per-layer choice): underlays < glyphs
    // + placeholder children < overlays. The geometry service is
    // constructed fresh for this paint call — see paint_layers.dart's
    // library doc — so every layer's rects reflect the paragraph that is
    // about to be drawn, never a rect resolved against a prior frame.
    final geometry = _paintLayers.isEmpty ? null : ParagraphGeometry(this);
    if (geometry != null) {
      paintLayerBand(context.canvas, offset, geometry, _underlayLayers,
          PaintBand.underlay);
    }
    context.canvas.drawParagraph(paragraph, offset);
    // Children paint after the glyphs, at their placeholder boxes; a
    // null offset means no box this layout — skipped.
    for (var child = firstChild; child != null; child = childAfter(child)) {
      final parentData = child.parentData! as HomericSlotParentData;
      final childOffset = parentData.offset;
      if (childOffset != null) {
        context.paintChild(child, offset + childOffset);
      }
    }
    if (geometry != null) {
      paintLayerBand(
          context.canvas, offset, geometry, _overlayLayers, PaintBand.overlay);
    }
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    // Children first, at their placeholder boxes; positions outside every
    // child fall through to the text (hitTestSelf). Null-offset children
    // are skipped (no box this layout).
    for (var child = firstChild; child != null; child = childAfter(child)) {
      final parentData = child.parentData! as HomericSlotParentData;
      final childOffset = parentData.offset;
      if (childOffset == null) {
        continue;
      }
      final isHit = result.addWithPaintOffset(
        offset: childOffset,
        position: position,
        hitTest: (BoxHitTestResult result, Offset transformed) =>
            child!.hitTest(result, position: transformed),
      );
      if (isHit) {
        return true;
      }
    }
    return false;
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    // A null offset means the child is not painted this layout: zero the
    // transform to mark it invisible
    // (RenderInlineChildrenContainerDefaults.defaultApplyPaintTransform).
    final parentData = child.parentData! as HomericSlotParentData;
    final childOffset = parentData.offset;
    if (childOffset == null) {
      transform.setZero();
    } else {
      transform.translateByDouble(childOffset.dx, childOffset.dy, 0, 1);
    }
  }

  // --- Semantics (U6) ------------------------------------------------------

  /// The effective source for the accessibility label and slot reading
  /// order: [semanticsSource] when supplied, else [source] (see
  /// [semanticsSource]'s doc for when to supply one).
  ParagraphSource<Object?> get _effectiveSemanticsSource =>
      _semanticsSource ?? _source;

  TextDirection get _semanticsTextDirection =>
      switch (_effectiveSemanticsSource.spec.direction) {
        ParagraphDirection.ltr => TextDirection.ltr,
        ParagraphDirection.rtl => TextDirection.rtl,
      };

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    // Framework pattern (read, not copied): RenderParagraph
    // (flutter/lib/src/rendering/paragraph.dart) picks one of three
    // semantics tiers per span — plain attributedLabel, merge-up via
    // childConfigurationsDelegate, or an explicit assembleSemanticsNode
    // — depending on whether a span has a gesture recognizer or a widget
    // placeholder. Homeric is read-only (R4): no recognizers, ever, so
    // only the middle tier is reachable. With zero widget slots it
    // degrades to exactly one merged-up text config, which is
    // equivalent to setting `attributedLabel` directly but keeps every
    // build on one code path. No text-field flags are set anywhere:
    // this is read-only static text semantics (R6).
    //
    // isSemanticBoundary keeps this block's semantics node from being
    // elided when it has no text of its own (a block that is only a
    // widget slot): without it, a sole widget child's own semantics
    // fragment has real geometry and nothing here needs to borrow this
    // render object's, so it bubbles past this node entirely and
    // attaches to a distant ancestor instead of this block.
    config.isSemanticBoundary = true;
    config.childConfigurationsDelegate = _describeSemanticsChildren;
  }

  /// Walks the effective semantics source's segments in view-text order,
  /// merging contiguous text runs into one [AttributedString] label per
  /// run of text and pairing each widget slot with its own child's
  /// accessibility configuration(s) — found via
  /// [HomericSlotIndexSemanticsTag], the tagged-child lookup
  /// `RenderParagraph` uses for `WidgetSpan` children (read, not
  /// copied). A hidden delimiter contributes no text at all (it is
  /// absent from the effective source's segments by construction — see
  /// [semanticsSource]); a widget slot's placeholder character
  /// contributes no text either — it is not prose, and the slot's own
  /// child supplies whatever the screen reader should say about it.
  ChildSemanticsConfigurationsResult _describeSemanticsChildren(
    List<SemanticsConfiguration> childConfigs,
  ) {
    final builder = ChildSemanticsConfigurationsResultBuilder();
    final direction = _semanticsTextDirection;
    final label = StringBuffer();
    var childIndex = 0;
    var slotIndex = 0;

    void flushLabel() {
      if (label.isNotEmpty) {
        builder.markAsMergeUp(SemanticsConfiguration()
          ..textDirection = direction
          ..attributedLabel = AttributedString(label.toString()));
        label.clear();
      }
    }

    for (final segment in _effectiveSemanticsSource.segments) {
      switch (segment) {
        case final TextSegment<Object?> text:
          label.write(text.text);
        case SlotSegment<Object?>():
          flushLabel();
          final tag = HomericSlotIndexSemanticsTag(slotIndex);
          while (childIndex < childConfigs.length &&
              childConfigs[childIndex].tagsChildrenWith(tag)) {
            builder.markAsMergeUp(childConfigs[childIndex]);
            childIndex += 1;
          }
          slotIndex += 1;
      }
    }
    flushLabel();
    return builder.build();
  }

  // --- Lifecycle ------------------------------------------------------------

  @override
  void systemFontsDidChange() {
    // The mixin marks needs-layout (deferring while detached); glyph
    // metrics may all have changed, so every cached paragraph is stale.
    super.systemFontsDidChange();
    _dropParagraphs();
  }

  @override
  void dispose() {
    _disposed = true;
    _onGeometryChanged = null;
    _dropParagraphs();
    super.dispose();
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(StringProperty('viewText', _source.viewText))
      ..add(DiagnosticsProperty<TextStyle>('baseStyle', _baseStyle,
          defaultValue: null))
      ..add(EnumProperty<TextAlign>('textAlign', _textAlign))
      ..add(DiagnosticsProperty<TextScaler>('textScaler', _textScaler,
          defaultValue: TextScaler.noScaling))
      ..add(EnumProperty<ui.PlaceholderAlignment>(
          'slotAlignment', _slotAlignment,
          defaultValue: ui.PlaceholderAlignment.middle))
      ..add(EnumProperty<TextBaseline>('slotBaseline', _slotBaseline,
          defaultValue: null))
      ..add(IntProperty('layoutGeneration', _layoutGeneration))
      ..add(IntProperty('paintLayers', _paintLayers.length, defaultValue: 0))
      ..add(FlagProperty('semanticsSource',
          value: _semanticsSource != null,
          ifTrue: 'independent of source',
          ifFalse: 'reuses source'))
      ..add(FlagProperty('onGeometryChanged',
          value: _onGeometryChanged != null,
          ifTrue: 'observed',
          ifFalse: 'unobserved'));
  }
}

/// Renders one block's [ParagraphSource] through [RenderHomericParagraph],
/// with one inline child widget per `widget` decoration slot.
///
/// Rebuild it with a freshly derived [source] each build (styles are
/// resolved per build, R7); an unchanged derivation is cheap — the render
/// object compares sources by content and keeps its paragraph.
///
/// Slot children come from [slotBuilder], invoked once per slot in
/// view-text order; each child is laid out width-only against the wrap
/// width, and its measured size becomes the slot's placeholder box. With
/// no [slotBuilder], slots keep their provisional dimensions (the U2
/// behavior).
///
/// The wrap width comes from the incoming layout constraints. The
/// effective [TextScaler] is, in order: [textScaler], the source spec's
/// scaler passthrough, the ambient [MediaQuery], or none — MediaQuery
/// lookups live here, never in the render object.
///
/// ## Placing overlays from geometry
///
/// Anything positioned *from* the paragraph rather than *inside* it —
/// footnote markers, hover and tap targets, a caret — cannot be placed on
/// the first build, because geometry does not exist until after layout.
/// Prefer `ParagraphOverlay`, which owns this subscription and structurally
/// keeps overlay content out of paragraph layout. Take [onGeometryChanged]
/// directly only when integrating with an existing overlay host.
///
/// ```dart
/// ParagraphOverlay(
///   paragraph: HomericParagraph(source: source),
///   slotLayoutRevision: null,
///   overlayBuilder: (context, geometry) => [
///     Positioned.fromRect(
///       rect: geometry.caretRect(anchor).value,
///       child: const _Marker(),
///     ),
///   ],
/// )
/// ```
///
/// A hand-rolled listener must keep overlay children layout-neutral. A child
/// that participates in the surrounding layout can change this paragraph's
/// own constraints and create a genuine relayout → notify → rebuild loop.
class HomericParagraph extends MultiChildRenderObjectWidget {
  /// Creates a paragraph view over [source].
  ///
  /// [slotBaseline] is required when [slotAlignment] is one of the
  /// baseline-relative alignments (typically
  /// `PlaceholderAlignment.baseline` + `TextBaseline.alphabetic` for
  /// text-like chips).
  HomericParagraph({
    super.key,
    required this.source,
    this.baseStyle,
    this.textAlign = TextAlign.start,
    this.textScaler,
    this.slotBuilder,
    this.slotAlignment = ui.PlaceholderAlignment.middle,
    this.slotBaseline,
    this.paintStyler,
    this.paintLayers = const <PaintLayer>[],
    this.semanticsSource,
    this.onGeometryChanged,
  })  : assert(RenderHomericParagraph._checkSlotBaseline(
            slotAlignment, slotBaseline)),
        super(children: _slotChildren(source, slotBuilder));

  static List<Widget> _slotChildren(
      ParagraphSource<TextStyle> source, SlotWidgetBuilder? slotBuilder) {
    if (slotBuilder == null || source.slots.isEmpty) {
      return const <Widget>[];
    }
    return <Widget>[
      for (final slot in source.slots)
        // Tags the slot's semantics subtree with its slot index (U6, R6)
        // so the render object's childConfigurationsDelegate can merge
        // the child's own accessibility configuration(s) into the
        // reading order at the right position — see
        // HomericSlotIndexSemanticsTag's doc.
        Semantics(
          tagForChildren: HomericSlotIndexSemanticsTag(slot.slotIndex),
          child: slotBuilder(slot),
        ),
    ];
  }

  /// The block's builder inputs (U1 output, styles resolved this build).
  final ParagraphSource<TextStyle> source;

  /// The block's base/default style. See
  /// [RenderHomericParagraph.baseStyle].
  final TextStyle? baseStyle;

  /// Horizontal alignment within the wrap width.
  final TextAlign textAlign;

  /// Explicit text scaler, overriding the spec passthrough and the
  /// ambient [MediaQuery].
  final TextScaler? textScaler;

  /// Builds the inline child for each widget slot, in view-text order.
  ///
  /// Null → no children; slots occupy
  /// [RenderHomericParagraph.provisionalSlotDimensions].
  final SlotWidgetBuilder? slotBuilder;

  /// Vertical alignment of slot placeholders within their line. See
  /// [RenderHomericParagraph.slotAlignment].
  final ui.PlaceholderAlignment slotAlignment;

  /// The baseline for baseline-relative [slotAlignment]s. See
  /// [RenderHomericParagraph.slotBaseline].
  final TextBaseline? slotBaseline;

  /// Paint-only repaint band (U5 seam). See [PaintOnlyStyler].
  final PaintOnlyStyler? paintStyler;

  /// Decoration paint layers (U5). See
  /// [RenderHomericParagraph.paintLayers].
  final List<PaintLayer> paintLayers;

  /// An independently-derived semantics source (U6, R6). See
  /// [RenderHomericParagraph.semanticsSource].
  final ParagraphSource<Object?>? semanticsSource;

  /// Called after every layout, once geometry is available and current —
  /// the subscription half of the U4 geometry service. See
  /// [GeometryChangedCallback] and
  /// [RenderHomericParagraph.onGeometryChanged].
  final GeometryChangedCallback? onGeometryChanged;

  HomericParagraph _observedBy(GeometryChangedCallback observer) =>
      HomericParagraph(
        key: key,
        source: source,
        baseStyle: baseStyle,
        textAlign: textAlign,
        textScaler: textScaler,
        slotBuilder: slotBuilder,
        slotAlignment: slotAlignment,
        slotBaseline: slotBaseline,
        paintStyler: paintStyler,
        paintLayers: paintLayers,
        semanticsSource: semanticsSource,
        onGeometryChanged: observer,
      );

  TextScaler _resolveTextScaler(BuildContext context) {
    final specScaler = source.spec.textScaler;
    return textScaler ??
        (specScaler is TextScaler ? specScaler : null) ??
        MediaQuery.maybeTextScalerOf(context) ??
        TextScaler.noScaling;
  }

  @override
  RenderHomericParagraph createRenderObject(BuildContext context) {
    return RenderHomericParagraph(
      source: source,
      baseStyle: baseStyle,
      textAlign: textAlign,
      textScaler: _resolveTextScaler(context),
      slotAlignment: slotAlignment,
      slotBaseline: slotBaseline,
      paintStyler: paintStyler,
      paintLayers: paintLayers,
      semanticsSource: semanticsSource,
      onGeometryChanged: onGeometryChanged,
    );
  }

  @override
  void updateRenderObject(
      BuildContext context, RenderHomericParagraph renderObject) {
    renderObject
      // First in the cascade: it invalidates nothing, and its catch-up
      // dispatch coalesces with any relayout the rest of the cascade
      // triggers in this same frame.
      ..onGeometryChanged = onGeometryChanged
      ..source = source
      ..baseStyle = baseStyle
      ..textAlign = textAlign
      ..textScaler = _resolveTextScaler(context)
      ..slotAlignment = slotAlignment
      ..slotBaseline = slotBaseline
      ..paintStyler = paintStyler
      ..paintLayers = paintLayers
      ..semanticsSource = semanticsSource;
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(StringProperty('viewText', source.viewText))
      ..add(DiagnosticsProperty<TextStyle>('baseStyle', baseStyle,
          defaultValue: null))
      ..add(EnumProperty<TextAlign>('textAlign', textAlign,
          defaultValue: TextAlign.start))
      ..add(DiagnosticsProperty<TextScaler>('textScaler', textScaler,
          defaultValue: null))
      ..add(EnumProperty<ui.PlaceholderAlignment>(
          'slotAlignment', slotAlignment,
          defaultValue: ui.PlaceholderAlignment.middle))
      ..add(EnumProperty<TextBaseline>('slotBaseline', slotBaseline,
          defaultValue: null))
      ..add(IntProperty('paintLayers', paintLayers.length, defaultValue: 0))
      ..add(FlagProperty('semanticsSource',
          value: semanticsSource != null,
          ifTrue: 'independent of source',
          ifFalse: 'reuses source'))
      ..add(FlagProperty('onGeometryChanged',
          value: onGeometryChanged != null,
          ifTrue: 'observed',
          ifFalse: 'unobserved'));
  }
}
