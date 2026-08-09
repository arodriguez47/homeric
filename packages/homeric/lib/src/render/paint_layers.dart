/// Decoration paint layers (U5) — range-driven underlay/overlay painting
/// resolved through U4's [ParagraphGeometry] in the same `paint()` call as
/// the text.
///
/// A [PaintLayer] is `(doc range, opaque paint spec, band)`; [PaintBand]
/// pins the paint order the plan requires (R3): every underlay paints
/// before the paragraph's glyphs and placeholder children, every overlay
/// paints after. [paintLayerBand] — called twice by
/// [RenderHomericParagraph.paint], once per band, with a freshly
/// constructed [ParagraphGeometry] — is what wires that ordering in: it
/// resolves rects **now**, against the live layout, never a rect cached
/// from a prior frame or build (super_text_layout's "same-frame decoration"
/// lesson the plan cites — in-`RenderBox` layers get this for free by
/// construction, no separate compositing pass to lag behind).
///
/// Spec interpretation is a callback contract, not a closed hierarchy
/// ([LayerPainter]), so consumer-specific payloads — Nexus's animated
/// focus-dim amount, a resolved mention color, an annotation's
/// wash-or-underline choice — all fit as [PaintLayer.spec] values without
/// this file knowing about any of them. Two reference painters
/// ([solidWashPainter], [underlinePainter]) cover the common cases and
/// back the playground (U7).
///
/// Changing [RenderHomericParagraph.paintLayers] is paint-only by
/// construction: the setter compares the new list by value (see
/// [PaintLayer]'s equality) and, on a real change, calls only
/// `markNeedsPaint()` — never `markNeedsLayout()` (no `ui.Paragraph`
/// rebuild is even needed; layers paint on the canvas around the existing
/// paragraph) and never `markNeedsSemanticsUpdate()` (a decoration's paint
/// spec, however it animates, is not accessibility content — R9's
/// "paint-only changes never reshape" extended to the U5 band, verified
/// against U6's semantics dirty-tracking in `paint_layers_test.dart`).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import 'paragraph_geometry.dart';

/// Which side of the paragraph's glyphs (and placeholder children) a
/// [PaintLayer] paints on. The ordering is pinned, not a per-layer choice:
/// every [underlay] layer paints before the text and every [overlay]
/// layer paints after, regardless of layer registration order.
enum PaintBand {
  /// Painted before the paragraph's glyphs and placeholder children —
  /// e.g. a focus-dim scrim, a mention background, an annotation wash.
  underlay,

  /// Painted after the paragraph's glyphs and placeholder children —
  /// e.g. an underline, an annotation mark riding above the text.
  overlay,
}

/// Interprets one [PaintLayer]'s opaque [PaintLayer.spec] against a single
/// resolved fragment [rect], drawing on [canvas].
///
/// Called once per fragment rect a layer's document range resolves to
/// (U4's fragment-correct boxes — a range spanning a slot or a bidi
/// boundary never gets one merged rect). [rect] is already in the
/// caller's paint coordinate space (the paragraph's [Offset] origin has
/// been applied).
typedef LayerPainter = void Function(Canvas canvas, Rect rect, Object? spec);

/// One decoration paint layer: a document [range] resolved through U4's
/// [ParagraphGeometry], an opaque [spec] interpreted by [painter], and
/// which [band] it paints in.
///
/// A collapsed [range], or one whose visible content is empty (e.g. it
/// falls entirely inside a hidden delimiter run), resolves to zero rects
/// and paints nothing — a no-op, never an error (see [paintLayerBand]).
///
/// Value-equal on [range], [band], [spec], and [painter] (by identity,
/// like [PaintOnlyStyler] elsewhere in this library) — the equality
/// [RenderHomericParagraph.paintLayers]'s setter uses to detect a real
/// change versus an equivalent re-derivation.
@immutable
final class PaintLayer {
  /// Creates a paint layer over [range], drawn by [painter] in [band],
  /// with the opaque [spec] payload [painter] interprets.
  const PaintLayer({
    required this.range,
    required this.band,
    required this.painter,
    this.spec,
  });

  /// The document range this layer paints over.
  final DocRange range;

  /// Which paint band this layer belongs to.
  final PaintBand band;

  /// Interprets [spec] against each resolved fragment rect.
  final LayerPainter painter;

  /// The opaque payload [painter] interprets — a color, an animated
  /// amount, a richer value object. This file never inspects it.
  final Object? spec;

  @override
  bool operator ==(Object other) =>
      other is PaintLayer &&
      other.range == range &&
      other.band == band &&
      identical(other.painter, painter) &&
      other.spec == spec;

  @override
  int get hashCode => Object.hash(range, band, identityHashCode(painter), spec);

  @override
  String toString() =>
      'PaintLayer(${band.name}, $range${spec == null ? '' : ', spec: $spec'})';
}

/// Paints every layer in [layers] whose [PaintLayer.band] is [band],
/// resolving each one's rects through [geometry] right now.
///
/// [geometry] must be constructed fresh by the caller for this paint —
/// never held across frames or builds — so every rect reflects the
/// paragraph's current layout generation (R9). Each layer's document
/// range becomes zero or more fragment rects via
/// [ParagraphGeometry.rectsForRange] (bidi runs and slot placeholders
/// never merge into a neighboring fragment: a range spanning a slot
/// paints the surrounding text fragments correctly without ever washing
/// the slot itself unless the range explicitly includes it), each shifted
/// by [origin] into the caller's paint coordinates and handed to the
/// layer's [PaintLayer.painter] with its [PaintLayer.spec].
///
/// A layer whose range is collapsed, or whose visible content is empty
/// (e.g. entirely inside a hidden delimiter run), contributes no rects
/// and is silently skipped.
void paintLayerBand(
  Canvas canvas,
  Offset origin,
  ParagraphGeometry geometry,
  List<PaintLayer> layers,
  PaintBand band,
) {
  for (final layer in layers) {
    if (layer.band != band || layer.range.isCollapsed) {
      continue;
    }
    final boxes = geometry.rectsForRange(layer.range).value;
    for (final box in boxes) {
      layer.painter(canvas, box.toRect().shift(origin), layer.spec);
    }
  }
}

// --- Reference painters --------------------------------------------------

/// Reference spec for [solidWashPainter]: fill the rect with [color].
@immutable
final class SolidWashSpec {
  /// Creates a wash spec painting solid [color].
  const SolidWashSpec(this.color);

  /// The fill color. Callers that animate a dim amount fold it into this
  /// color (e.g. `baseColor.withOpacity(amount)`) — the spec itself is
  /// just the color to paint this frame.
  final Color color;

  @override
  bool operator ==(Object other) =>
      other is SolidWashSpec && other.color == color;

  @override
  int get hashCode => color.hashCode;

  @override
  String toString() => 'SolidWashSpec($color)';
}

/// A reference [LayerPainter]: fills [rect] with [SolidWashSpec.color] —
/// the background-wash case (focus dim, mention highlight, annotation
/// wash all fit this shape; only the color, possibly animated frame to
/// frame, differs). [spec] must be a [SolidWashSpec].
void solidWashPainter(Canvas canvas, Rect rect, Object? spec) {
  final wash = spec! as SolidWashSpec;
  canvas.drawRect(rect, Paint()..color = wash.color);
}

/// Reference spec for [underlinePainter]: a line of [color], [thickness]
/// thick, [gap] below the fragment's bottom edge.
@immutable
final class UnderlineSpec {
  /// Creates an underline spec.
  const UnderlineSpec(this.color, {this.thickness = 1.0, this.gap = 1.0});

  /// The line color.
  final Color color;

  /// The stroke width.
  final double thickness;

  /// Vertical offset below the fragment rect's bottom edge.
  final double gap;

  @override
  bool operator ==(Object other) =>
      other is UnderlineSpec &&
      other.color == color &&
      other.thickness == thickness &&
      other.gap == gap;

  @override
  int get hashCode => Object.hash(color, thickness, gap);

  @override
  String toString() =>
      'UnderlineSpec($color, thickness: $thickness, gap: $gap)';
}

/// A reference [LayerPainter]: draws a horizontal line spanning [rect]'s
/// width, [UnderlineSpec.gap] below its bottom edge — the annotation-
/// underline case. [spec] must be an [UnderlineSpec].
void underlinePainter(Canvas canvas, Rect rect, Object? spec) {
  final underline = spec! as UnderlineSpec;
  final y = rect.bottom + underline.gap;
  canvas.drawLine(
    Offset(rect.left, y),
    Offset(rect.right, y),
    Paint()
      ..color = underline.color
      ..strokeWidth = underline.thickness,
  );
}
