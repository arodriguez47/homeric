// Decoration paint layers (U5): range-driven underlay/overlay painting
// resolved through U4's ParagraphGeometry in the same paint() call as the
// text — no frame lag, paint order pinned, spec-only changes paint-only.
//
// FlutterTest font metrics (pinned by the U2/U3/U4 suites and reused
// here): every glyph is a 1em box; at fontSize 14 a glyph is 14px wide, a
// line is 14.0 tall.

import 'dart:io' show Platform;

import 'package:flutter/widgets.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

import 'render_test_utils.dart';

/// A spy [RenderHomericParagraph] that counts [markNeedsSemanticsUpdate]
/// calls, mirroring `semantics_test.dart`'s spy — used here to pin that a
/// paint-layer spec change (e.g. an animated dim amount ticking) never
/// marks semantics dirty (R9 extended to U5, per the plan).
class _SpyRenderHomericParagraph extends RenderHomericParagraph {
  _SpyRenderHomericParagraph({
    required super.source,
    super.paintLayers,
  });

  int semanticsUpdateCount = 0;

  @override
  void markNeedsSemanticsUpdate() {
    semanticsUpdateCount += 1;
    super.markNeedsSemanticsUpdate();
  }
}

/// The [HomericParagraph] wrapper for [_SpyRenderHomericParagraph]. A
/// fixed, non-null [textScaler] sidesteps the ambient-[MediaQuery]
/// fallback, matching `semantics_test.dart`'s rationale.
class _SpyHomericParagraph extends HomericParagraph {
  _SpyHomericParagraph({
    required super.source,
    required this.captured,
    super.paintLayers,
  }) : super(textScaler: TextScaler.noScaling);

  final List<_SpyRenderHomericParagraph> captured;

  @override
  RenderHomericParagraph createRenderObject(BuildContext context) {
    final render = _SpyRenderHomericParagraph(
      source: source,
      paintLayers: paintLayers,
    );
    captured.add(render);
    return render;
  }
}

void main() {
  group('value semantics', () {
    test('PaintLayer compares by range/band/spec value and painter identity',
        () {
      final range = DocRange(DocOffset.zero, const DocOffset(3));
      const spec = SolidWashSpec(Color(0xFFFF0000));
      final a = PaintLayer(
          range: range,
          band: PaintBand.underlay,
          painter: solidWashPainter,
          spec: spec);
      final b = PaintLayer(
          range: DocRange(DocOffset.zero, const DocOffset(3)),
          band: PaintBand.underlay,
          painter: solidWashPainter,
          spec: const SolidWashSpec(Color(0xFFFF0000)));
      final differentSpec = PaintLayer(
          range: range,
          band: PaintBand.underlay,
          painter: solidWashPainter,
          spec: const SolidWashSpec(Color(0xFF00FF00)));
      final differentPainter = PaintLayer(
          range: range,
          band: PaintBand.underlay,
          painter: underlinePainter,
          spec: spec);

      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(differentSpec)));
      expect(a, isNot(equals(differentPainter)));
    });

    test('SolidWashSpec and UnderlineSpec compare by value', () {
      expect(const SolidWashSpec(Color(0xFFFF0000)),
          const SolidWashSpec(Color(0xFFFF0000)));
      expect(const SolidWashSpec(Color(0xFFFF0000)),
          isNot(const SolidWashSpec(Color(0xFF00FF00))));
      expect(const UnderlineSpec(Color(0xFF000000), thickness: 2),
          const UnderlineSpec(Color(0xFF000000), thickness: 2));
      expect(const UnderlineSpec(Color(0xFF000000), thickness: 2),
          isNot(const UnderlineSpec(Color(0xFF000000), thickness: 1)));
    });
  });

  group('wash rects equal U4 range rects (happy path)', () {
    testWidgets('a plain range washes exactly its resolved rect',
        (tester) async {
      final source = sourceOf('abcd');
      final range = DocRange(const DocOffset(1), const DocOffset(3));
      final layer = PaintLayer(
        range: range,
        band: PaintBand.underlay,
        painter: solidWashPainter,
        spec: const SolidWashSpec(Color(0xFFFF0000)),
      );

      await tester.pumpWidget(
          harness(HomericParagraph(source: source, paintLayers: [layer])));

      final geometry = ParagraphGeometry(renderOf(tester));
      final expected = geometry.rectsForRange(range).value;
      expect(expected, hasLength(1));

      expect(
        renderOf(tester),
        paints
          ..rect(
              rect: expected.single.toRect(), color: const Color(0xFFFF0000)),
      );
    });
  });

  group('paint order (R3, pinned)', () {
    testWidgets(
        'underlay paints before the glyphs; overlay paints after, '
        'regardless of layer registration order', (tester) async {
      final source = sourceOf('ab');
      final fullRange = DocRange(DocOffset.zero, const DocOffset(2));
      final overlay = PaintLayer(
        range: fullRange,
        band: PaintBand.overlay,
        painter: underlinePainter,
        spec: const UnderlineSpec(Color(0xFF00FF00)),
      );
      final underlay = PaintLayer(
        range: fullRange,
        band: PaintBand.underlay,
        painter: solidWashPainter,
        spec: const SolidWashSpec(Color(0xFF0000FF)),
      );

      // Overlay listed first: registration order must not affect the
      // pinned band ordering.
      await tester.pumpWidget(harness(
          HomericParagraph(source: source, paintLayers: [overlay, underlay])));

      expect(
        renderOf(tester),
        paints
          ..rect(color: const Color(0xFF0000FF))
          ..paragraph()
          ..line(color: const Color(0xFF00FF00)),
      );
    });

    testWidgets('golden: decorated paragraph (underlay wash + overlay line)',
        (tester) async {
      final source = sourceOf('hello homeric',
          style: const TextStyle(fontSize: 14, color: Color(0xFF000000)));
      final wash = PaintLayer(
        range: DocRange(DocOffset.zero, const DocOffset(5)),
        band: PaintBand.underlay,
        painter: solidWashPainter,
        spec: const SolidWashSpec(Color(0x33FFD400)),
      );
      final underline = PaintLayer(
        range: DocRange(const DocOffset(6), const DocOffset(13)),
        band: PaintBand.overlay,
        painter: underlinePainter,
        spec: const UnderlineSpec(Color(0xFFFF0000), thickness: 2),
      );

      await tester.pumpWidget(RepaintBoundary(
        child: harness(
            HomericParagraph(source: source, paintLayers: [wash, underline])),
      ));
      await expectLater(
        find.byType(RepaintBoundary),
        matchesGoldenFile('goldens/paint_layers_decorated.png'),
      );
    }, skip: !Platform.isMacOS); // Golden generated on macOS (plan guard).
  });

  group('range spanning a slot (U3 integration)', () {
    testWidgets(
        'a range that spans across the slot paints fragment-correct rects, '
        'including the slot', (tester) async {
      final source = sourceOf(
        'ab',
        decorations: [Decoration.widget('b', 1, spec: 'chip')],
      );
      expect(source.viewText, 'a${objectReplacementCharacter}b');

      final layer = PaintLayer(
        range: DocRange(DocOffset.zero, const DocOffset(2)),
        band: PaintBand.underlay,
        painter: solidWashPainter,
        spec: const SolidWashSpec(Color(0xFFFF00FF)),
      );
      await tester.pumpWidget(
          harness(HomericParagraph(source: source, paintLayers: [layer])));

      // Three un-merged fragments: 'a', the slot placeholder, 'b' — never
      // one box spanning the whole range (U4's fragment-correct contract).
      expect(renderOf(tester), paintsExactlyCountTimes(#drawRect, 3));
    });

    testWidgets(
        'a range that stops right at the slot excludes it (not painted)',
        (tester) async {
      final source = sourceOf(
        'ab',
        decorations: [Decoration.widget('b', 1, spec: 'chip')],
      );
      final layer = PaintLayer(
        // [0, 1): ends exactly at the widget's doc anchor, so the
        // backward-associating end edge stays before it — the slot is
        // not "explicitly included".
        range: DocRange(DocOffset.zero, const DocOffset(1)),
        band: PaintBand.underlay,
        painter: solidWashPainter,
        spec: const SolidWashSpec(Color(0xFFFF00FF)),
      );
      await tester.pumpWidget(
          harness(HomericParagraph(source: source, paintLayers: [layer])));

      expect(renderOf(tester), paintsExactlyCountTimes(#drawRect, 1));
    });
  });

  group('zero-length range (edge case)', () {
    testWidgets('a collapsed range paints nothing — a no-op, not an error',
        (tester) async {
      final source = sourceOf('abcd');
      final layer = PaintLayer(
        range: DocRange.collapsed(const DocOffset(2)),
        band: PaintBand.underlay,
        painter: solidWashPainter,
        spec: const SolidWashSpec(Color(0xFFFF0000)),
      );

      await tester.pumpWidget(
          harness(HomericParagraph(source: source, paintLayers: [layer])));

      expect(renderOf(tester), paintsExactlyCountTimes(#drawRect, 0));
      expect(tester.takeException(), isNull);
    });
  });

  group('hidden-delimiter range (view-space painting)', () {
    testWidgets(
        'a layer over the whole document range paints only the visible '
        'text — rects follow view space, not the doc-length width',
        (tester) async {
      final source = sourceOf('**bold**', decorations: [
        Decoration.replace('b', 0, 2, replacementLength: 0),
        Decoration.replace('b', 6, 8, replacementLength: 0),
        Decoration.inline('b', 2, 6, spec: 'bold'),
      ]);
      expect(source.viewText, 'bold', reason: 'sanity: delimiters fold away');

      // The layer's doc range spans all 8 document characters, including
      // both hidden delimiter runs.
      final layer = PaintLayer(
        range: DocRange(DocOffset.zero, const DocOffset(8)),
        band: PaintBand.underlay,
        painter: solidWashPainter,
        spec: const SolidWashSpec(Color(0xFF00FFFF)),
      );
      await tester.pumpWidget(
          harness(HomericParagraph(source: source, paintLayers: [layer])));

      // 4 visible glyphs ('bold') at 14px each = 56px — never the
      // 8-character doc length's worth of width.
      expect(
        renderOf(tester),
        paints
          ..rect(
              rect: const Rect.fromLTRB(0, 0, 56, 14),
              color: const Color(0xFF00FFFF)),
      );
    });
  });

  group('spec-only changes are paint-only (R9 extended to U5)', () {
    testWidgets(
        'an animated spec change (dim 0.3 -> 0.6) repaints without '
        'relayout and without a semantics update', (tester) async {
      final captured = <_SpyRenderHomericParagraph>[];
      final source = sourceOf('hello');
      final range = DocRange(DocOffset.zero, const DocOffset(5));
      PaintLayer dimLayer(double amount) => PaintLayer(
            range: range,
            band: PaintBand.underlay,
            painter: solidWashPainter,
            spec: SolidWashSpec(Color.fromRGBO(0, 0, 0, amount)),
          );

      await tester.pumpWidget(harness(_SpyHomericParagraph(
        source: source,
        captured: captured,
        paintLayers: [dimLayer(0.3)],
      )));
      final render = captured.single;
      final beforeParagraph = render.layoutParagraph;
      final beforeGeneration = render.layoutGeneration;
      final semanticsBefore = render.semanticsUpdateCount;

      await tester.pumpWidget(harness(_SpyHomericParagraph(
        source: source,
        captured: captured,
        paintLayers: [dimLayer(0.6)],
      )));

      expect(captured.single, same(render), reason: 'same render object');
      expect(render.layoutParagraph, same(beforeParagraph),
          reason: 'a spec-only change must not rebuild the ui.Paragraph');
      expect(render.layoutGeneration, beforeGeneration,
          reason: 'a spec-only change must not relayout');
      expect(render.semanticsUpdateCount, semanticsBefore,
          reason: 'a spec-only change must not mark semantics dirty');

      // It does actually repaint with the new spec value.
      expect(
        tester.renderObject<RenderHomericParagraph>(
            find.byType(_SpyHomericParagraph)),
        paints..rect(color: const Color.fromRGBO(0, 0, 0, 0.6)),
      );
    });

    testWidgets('re-supplying an equal paint layer list is a no-op',
        (tester) async {
      final source = sourceOf('hello');
      final layer = PaintLayer(
        range: DocRange(DocOffset.zero, const DocOffset(5)),
        band: PaintBand.underlay,
        painter: solidWashPainter,
        spec: const SolidWashSpec(Color(0xFF000000)),
      );
      await tester.pumpWidget(
          harness(HomericParagraph(source: source, paintLayers: [layer])));
      final render = renderOf(tester);
      final before = render.layoutParagraph;
      final generation = render.layoutGeneration;

      // A different List instance, value-equal PaintLayer.
      final equalLayer = PaintLayer(
        range: DocRange(DocOffset.zero, const DocOffset(5)),
        band: PaintBand.underlay,
        painter: solidWashPainter,
        spec: const SolidWashSpec(Color(0xFF000000)),
      );
      await tester.pumpWidget(
          harness(HomericParagraph(source: source, paintLayers: [equalLayer])));

      expect(render.layoutParagraph, same(before));
      expect(render.layoutGeneration, generation);
    });
  });
}
