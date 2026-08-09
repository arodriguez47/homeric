/// HomericParagraph: the render-layer lifecycle core (U2) — a [RenderBox]
/// owning exactly one live `ui.Paragraph` per block, plus a minimal
/// leaf widget wrapper.
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
/// * paint-only changes ([RenderHomericParagraph.paintStyler], the U5
///   repaint band) → deferred rebuild inside `paint()` with a
///   layout-identity assert — never inside layout;
/// * system font change → caches dropped + relayout
///   ([RelayoutWhenSystemFontsChangeMixin]).
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
/// * `flutter/lib/src/rendering/paragraph.dart` (`RenderParagraph`): the
///   property-setter invalidation table, the separate-intrinsics-painter
///   pattern (intrinsic/dry queries must never clobber the live layout),
///   `systemFontsDidChange`, and the dispose discipline.
/// * `flutter/lib/src/painting/text_painter.dart` (`TextPainter`): the
///   deferred paint-only rebuild (`_rebuildParagraphForPaint`), the
///   infinite-max-width second layout pass, and the space-glyph layout
///   template for empty-text metrics.
library;

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../view/view_map.dart';
import 'paragraph_source.dart';

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

/// The render box owning one live `ui.Paragraph` for a block's
/// [ParagraphSource].
///
/// Layout happens at the wrap width (the incoming max width constraint);
/// alignment is expressed exclusively through `ui.ParagraphStyle`
/// ([textAlign] + the source's direction), so painting is a single
/// `drawParagraph` at the box origin with no paint-offset arithmetic.
class RenderHomericParagraph extends RenderBox
    with RelayoutWhenSystemFontsChangeMixin {
  /// Creates the render object. See the property setters for invalidation
  /// semantics.
  RenderHomericParagraph({
    required ParagraphSource<TextStyle> source,
    TextStyle? baseStyle,
    TextAlign textAlign = TextAlign.start,
    TextScaler textScaler = TextScaler.noScaling,
    List<Size>? slotDimensions,
    PaintOnlyStyler? paintStyler,
  })  : _source = source,
        _baseStyle = baseStyle,
        _textAlign = textAlign,
        _textScaler = textScaler,
        _slotDimensions = slotDimensions,
        _paintStyler = paintStyler;

  /// Fixed provisional placeholder dimensions for widget slots until U3
  /// measures real render children into them.
  ///
  /// Slots must still occupy real space so every other glyph's geometry is
  /// correct; U3 replaces these with measured [PlaceholderDimensions]-style
  /// values (scaled by the [textScaler] at child-measure time) through
  /// [slotDimensions].
  static const Size provisionalSlotDimensions = Size(14.0, 14.0);

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
    if (_sourceEquals(_source, value)) {
      _source = value;
      return;
    }
    _source = value;
    _markNeedsRebuild();
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
  TextScaler get textScaler => _textScaler;
  TextScaler _textScaler;
  set textScaler(TextScaler value) {
    if (_textScaler == value) {
      return;
    }
    _textScaler = value;
    _markNeedsRebuild();
  }

  /// Per-slot placeholder dimensions in slot-index order, or null for
  /// [provisionalSlotDimensions] everywhere — the U3 seam: inline children
  /// will be measured and fed through here. Change → rebuild + relayout.
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

  // --- Paragraph caches ---------------------------------------------------

  ui.Paragraph? _paragraph;
  ui.Paragraph? _intrinsicsParagraph;
  ui.Paragraph? _lineTemplate;
  bool _rebuildForPaint = false;
  int _layoutGeneration = 0;
  bool _disposed = false;

  static bool _sourceEquals(
      ParagraphSource<TextStyle> a, ParagraphSource<TextStyle> b) {
    return identical(a, b) ||
        (a.viewText == b.viewText &&
            a.spec == b.spec &&
            a.viewMap == b.viewMap &&
            listEquals(a.segments, b.segments));
  }

  void _markNeedsRebuild() {
    _dropParagraphs();
    markNeedsLayout();
  }

  void _dropParagraphs() {
    _paragraph?.dispose();
    _paragraph = null;
    _intrinsicsParagraph?.dispose();
    _intrinsicsParagraph = null;
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
    );
  }

  /// Builds a fresh `ui.Paragraph` from [source] — the
  /// `pushStyle`/`addText`/`addPlaceholder` loop over U1's segments.
  ui.Paragraph _buildParagraph() {
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
          final size = dims?[slot.slotIndex] ?? provisionalSlotDimensions;
          // scale: 1.0 always — the TextScaler is applied to the
          // dimensions themselves (U3), never to the placeholder scale.
          builder.addPlaceholder(
              size.width, size.height, ui.PlaceholderAlignment.bottom,
              scale: 1.0);
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
  ui.Paragraph get layoutParagraph {
    assert(!_disposed, 'layoutParagraph used after dispose()');
    assert(!debugNeedsLayout,
        'layoutParagraph read while layout is dirty — query after layout');
    return _paragraph!;
  }

  /// The source's document↔view offset map, for same-library geometry
  /// callers (U4). Render-layer internal.
  ViewMap get viewMap => _source.viewMap;

  /// The height of one line in the base style — the caret-capable line
  /// height for empty view text, from the space-glyph template.
  double get preferredLineHeight => _template.height;

  /// The alphabetic baseline of one line in the base style — the
  /// caret-capable baseline for empty view text.
  double get preferredLineBaseline => _template.getLineMetricsAt(0)!.baseline;

  /// The cached intrinsics/dry-layout paragraph, if built.
  @visibleForTesting
  ui.Paragraph? get debugIntrinsicsParagraph => _intrinsicsParagraph;

  /// The cached space-glyph line template, if built.
  @visibleForTesting
  ui.Paragraph? get debugLineTemplate => _lineTemplate;

  // --- Layout -------------------------------------------------------------

  @override
  void performLayout() {
    if (_paragraph == null) {
      _paragraph = _buildParagraph();
      // A fresh build already reflects the current paintStyler.
      _rebuildForPaint = false;
    }
    final natural = _layoutAt(_paragraph!, constraints.maxWidth);
    _layoutGeneration += 1;
    size = constraints.constrain(natural);
  }

  /// The separate intrinsics paragraph: intrinsic and dry queries must
  /// never clobber the live paragraph's layout (RenderParagraph's
  /// documented trap — its `_textIntrinsics` painter).
  ui.Paragraph get _intrinsics => _intrinsicsParagraph ??= _buildParagraph();

  @override
  double computeMinIntrinsicWidth(double height) {
    final paragraph = _intrinsics
      ..layout(const ui.ParagraphConstraints(width: double.infinity));
    return paragraph.minIntrinsicWidth;
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    final paragraph = _intrinsics
      ..layout(const ui.ParagraphConstraints(width: double.infinity));
    return paragraph.maxIntrinsicWidth;
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      _layoutAt(_intrinsics, width).height;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _layoutAt(_intrinsics, width).height;

  @override
  @protected
  Size computeDryLayout(covariant BoxConstraints constraints) =>
      constraints.constrain(_layoutAt(_intrinsics, constraints.maxWidth));

  @override
  double? computeDryBaseline(
      covariant BoxConstraints constraints, TextBaseline baseline) {
    final paragraph = _intrinsics;
    _layoutAt(paragraph, constraints.maxWidth);
    return paragraph.numberOfLines == 0
        ? preferredLineBaseline
        : paragraph.alphabeticBaseline;
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) {
    assert(!debugNeedsLayout);
    final paragraph = _paragraph!;
    // Empty view text has no lines on this engine; the space-glyph
    // template keeps the block caret-capable (baseline + line height).
    return paragraph.numberOfLines == 0
        ? preferredLineBaseline
        : paragraph.alphabeticBaseline;
  }

  // --- Paint --------------------------------------------------------------

  @override
  void paint(PaintingContext context, Offset offset) {
    var paragraph = _paragraph!;
    if (_rebuildForPaint) {
      // Deferred paint-only rebuild: the engine has no in-place attribute
      // update, so the paragraph is recreated here — never during layout
      // (TextPainter.paint's _rebuildParagraphForPaint path).
      final rebuilt = _buildParagraph()
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
    context.canvas.drawParagraph(paragraph, offset);
  }

  @override
  bool hitTestSelf(Offset position) => true;

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
      ..add(IntProperty('layoutGeneration', _layoutGeneration));
  }
}

/// Renders one block's [ParagraphSource] through [RenderHomericParagraph].
///
/// A minimal leaf widget: inline widget children arrive in U3. Rebuild it
/// with a freshly derived [source] each build (styles are resolved per
/// build, R7); an unchanged derivation is cheap — the render object
/// compares sources by content and keeps its paragraph.
///
/// The wrap width comes from the incoming layout constraints. The
/// effective [TextScaler] is, in order: [textScaler], the source spec's
/// scaler passthrough, the ambient [MediaQuery], or none — MediaQuery
/// lookups live here, never in the render object.
class HomericParagraph extends LeafRenderObjectWidget {
  /// Creates a paragraph view over [source].
  const HomericParagraph({
    super.key,
    required this.source,
    this.baseStyle,
    this.textAlign = TextAlign.start,
    this.textScaler,
    this.slotDimensions,
    this.paintStyler,
  });

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

  /// Per-slot placeholder dimensions (U3 seam). See
  /// [RenderHomericParagraph.slotDimensions].
  final List<Size>? slotDimensions;

  /// Paint-only repaint band (U5 seam). See [PaintOnlyStyler].
  final PaintOnlyStyler? paintStyler;

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
      slotDimensions: slotDimensions,
      paintStyler: paintStyler,
    );
  }

  @override
  void updateRenderObject(
      BuildContext context, RenderHomericParagraph renderObject) {
    renderObject
      ..source = source
      ..baseStyle = baseStyle
      ..textAlign = textAlign
      ..textScaler = _resolveTextScaler(context)
      ..slotDimensions = slotDimensions
      ..paintStyler = paintStyler;
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
          defaultValue: null));
  }
}
