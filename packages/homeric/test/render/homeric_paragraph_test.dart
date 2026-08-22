// HomericParagraph (U2): render-box lifecycle core — build, layout,
// paint, dispose, and the full invalidation matrix.
//
// Characterization tests pin exact sizes/baselines using the FlutterTest
// font metrics: every glyph is a 1em box, ascent 0.75em / descent 0.25em,
// so at fontSize 14 a glyph is 14px wide, a line is exactly 14.0 tall and
// the alphabetic baseline sits at 10.5.
//
// System-font-change coverage drives the real notification path: a
// `flutter/system` platform message with `{'type': 'fontsChange'}`, which
// PaintingBinding routes to systemFonts listeners and, through
// RelayoutWhenSystemFontsChangeMixin, into the render object.

import 'dart:io' show Directory, File, Platform;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

import 'render_test_utils.dart';

Future<void> sendFontsChangeMessage(WidgetTester tester) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.system.name,
    SystemChannels.system.codec
        .encodeMessage(<String, dynamic>{'type': 'fontsChange'}),
    (_) {},
  );
}

void main() {
  test('owned production geometry paths have no runtime debug layout gates',
      () {
    final packageRoot =
        File('lib/src/render/homeric_paragraph.dart').existsSync()
            ? Directory.current.path
            : '${Directory.current.path}/packages/homeric';
    const paths = <String>[
      'lib/src/render/paragraph_geometry.dart',
      'lib/src/render/homeric_paragraph.dart',
      'lib/src/render/paragraph_overlay.dart',
      'lib/src/editing/editable_paragraph.dart',
    ];
    for (final path in paths) {
      final runtimeReads = File('$packageRoot/$path')
          .readAsLinesSync()
          .where((line) =>
              line.contains('debugNeedsLayout') &&
              !line.trimLeft().startsWith('assert('))
          .toList();
      expect(runtimeReads, isEmpty,
          reason: '$path must use release-safe geometry readiness');
    }
  });

  group('characterization (FlutterTest font metrics)', () {
    testWidgets('known text at fontSize 14 has exactly computable size',
        (tester) async {
      await tester
          .pumpWidget(harness(HomericParagraph(source: sourceOf('hello'))));
      // One line: height exactly 14.0; width is the wrap width (layout
      // happens at wrap width; alignment lives in ParagraphStyle).
      expect(
          tester.getSize(find.byType(HomericParagraph)), const Size(200, 14));
      final render = renderOf(tester);
      expect(render.layoutParagraph.numberOfLines, 1);
      expect(render.layoutParagraph.alphabeticBaseline, 10.5);
    });

    testWidgets('wrapping text stacks exact line heights', (tester) async {
      // 'aaaa bbbb' at width 70: 'aaaa ' fills the line (5 glyphs × 14),
      // 'bbbb' wraps — two lines of 14.
      await tester.pumpWidget(
          harness(HomericParagraph(source: sourceOf('aaaa bbbb')), width: 70));
      expect(tester.getSize(find.byType(HomericParagraph)), const Size(70, 28));
      expect(renderOf(tester).layoutParagraph.numberOfLines, 2);
    });

    testWidgets('baseline is exactly 10.5 at fontSize 14', (tester) async {
      await tester.pumpWidget(harness(Baseline(
        baseline: 30,
        baselineType: TextBaseline.alphabetic,
        child: HomericParagraph(source: sourceOf('hello')),
      )));
      // Baseline positions the child so its alphabetic baseline sits at
      // y=30: top = 30 - 10.5.
      expect(tester.getTopLeft(find.byType(HomericParagraph)).dy, 19.5);
    });

    testWidgets(
        'ideographic baseline positions the child at the ideographic metric, '
        'not the alphabetic one', (tester) async {
      await tester.pumpWidget(harness(Baseline(
        baseline: 30,
        baselineType: TextBaseline.ideographic,
        child: HomericParagraph(source: sourceOf('hello')),
      )));
      final ideographic = renderOf(tester).layoutParagraph.ideographicBaseline;
      // Distinct from the alphabetic metric (10.5) on this font, so this
      // exercises the ideographic branch rather than a shared fallback.
      expect(ideographic, isNot(10.5));
      expect(tester.getTopLeft(find.byType(HomericParagraph)).dy,
          30 - ideographic);
    });

    testWidgets('alignment comes from ParagraphStyle, not paint offsets',
        (tester) async {
      // Center-aligned 'ab' (28px) in 100px: glyphs sit at x=36 inside
      // the paragraph itself — no paint-offset arithmetic anywhere.
      await tester.pumpWidget(harness(
        HomericParagraph(source: sourceOf('ab'), textAlign: TextAlign.center),
        width: 100,
      ));
      final boxes = renderOf(tester).layoutParagraph.getBoxesForRange(0, 2);
      expect(boxes, hasLength(1));
      expect(boxes.single.left, 36);
      expect(boxes.single.right, 64);
    });

    testWidgets('RTL block direction aligns start to the right edge',
        (tester) async {
      const spec = BlockParagraphSpec(direction: ParagraphDirection.rtl);
      await tester.pumpWidget(harness(
        HomericParagraph(source: sourceOf('abc', spec: spec)),
        width: 100,
      ));
      final boxes = renderOf(tester).layoutParagraph.getBoxesForRange(0, 3);
      expect(boxes.single.right, 100);
      expect(boxes.single.left, 100 - 3 * 14);
    });

    testWidgets('golden: paragraph paints', (tester) async {
      await tester.pumpWidget(RepaintBoundary(
        child: harness(HomericParagraph(
          source: sourceOf('hello homeric',
              style: const TextStyle(fontSize: 14, color: Color(0xFF000000))),
        )),
      ));
      await expectLater(
        find.byType(RepaintBoundary),
        matchesGoldenFile('goldens/homeric_paragraph_hello.png'),
      );
    }, skip: !Platform.isMacOS); // Golden generated on macOS (plan guard).
  });

  group('dry layout, dry baseline, intrinsics (separate paragraph)', () {
    testWidgets('dry and intrinsic queries never touch the live paragraph',
        (tester) async {
      await tester
          .pumpWidget(harness(HomericParagraph(source: sourceOf('aaaa bbbb'))));
      final render = renderOf(tester);
      final live = render.layoutParagraph;
      final generation = render.layoutGeneration;

      expect(render.getDryLayout(const BoxConstraints(maxWidth: 70)),
          const Size(70, 28));
      expect(render.getDryLayout(const BoxConstraints(maxWidth: 200)),
          const Size(200, 14));
      expect(
          render.getDryBaseline(
              const BoxConstraints(maxWidth: 200), TextBaseline.alphabetic),
          10.5);
      // Ideographic dry baseline must match the live paragraph's
      // ideographic metric (same content/style/width), not silently fall
      // through to the alphabetic one.
      expect(
          render.getDryBaseline(
              const BoxConstraints(maxWidth: 200), TextBaseline.ideographic),
          render.layoutParagraph.ideographicBaseline);
      // FlutterTest metrics: longest word 'aaaa'/'bbbb' = 56, full run
      // 9 glyphs = 126.
      expect(render.getMinIntrinsicWidth(double.infinity), 56);
      expect(render.getMaxIntrinsicWidth(double.infinity), 126);
      expect(render.getMinIntrinsicHeight(70), 28);
      expect(render.getMaxIntrinsicHeight(70), 28);

      // The live paragraph was never relaid or replaced: dry/intrinsic
      // queries ran on the dedicated intrinsics paragraph
      // (RenderParagraph's documented two-painter pattern).
      expect(identical(render.layoutParagraph, live), isTrue);
      expect(render.layoutGeneration, generation);
      expect(render.debugIntrinsicsParagraph, isNotNull);
      expect(identical(render.debugIntrinsicsParagraph, live), isFalse);
      // Live layout still answers for the real wrap width.
      expect(
          tester.getSize(find.byType(HomericParagraph)), const Size(200, 14));
    });
  });

  group('empty view text (whole-block replace)', () {
    // Engine probe, pinned: an empty ui.Paragraph lays out with ZERO
    // lines — no line metrics, no baseline — so a caret-capable line
    // must come from a fallback. We adopt the framework's space-glyph
    // layout template (TextPainter._createLayoutTemplate), not a
    // strut-based fallback.
    ParagraphSource<TextStyle> emptySource() => sourceOf(
          'abcd',
          decorations: [
            Decoration.replace('b', 0, 4, replacementLength: 0),
          ],
        );

    testWidgets('engine yields no lines for empty text (probe pin)',
        (tester) async {
      await tester.pumpWidget(harness(HomericParagraph(source: emptySource())));
      final paragraph = renderOf(tester).layoutParagraph;
      expect(paragraph.numberOfLines, 0);
      expect(paragraph.computeLineMetrics(), isEmpty);
    });

    testWidgets('block keeps full line height and a caret-capable baseline',
        (tester) async {
      await tester.pumpWidget(harness(Baseline(
        baseline: 30,
        baselineType: TextBaseline.alphabetic,
        child: HomericParagraph(source: emptySource()),
      )));
      // Height: the engine reports the base font's line height even with
      // zero lines; baseline: space-glyph template (30 - 10.5 = 19.5).
      expect(
          tester.getSize(find.byType(HomericParagraph)), const Size(200, 14));
      expect(tester.getTopLeft(find.byType(HomericParagraph)).dy, 19.5);

      final render = renderOf(tester);
      expect(render.preferredLineHeight, 14);
      expect(render.preferredLineBaseline, 10.5);
      expect(render.debugLineTemplate, isNotNull);
    });

    testWidgets(
        'ideographic queries on an empty block use the ideographic '
        'template metric, not the alphabetic fallback', (tester) async {
      await tester.pumpWidget(harness(Baseline(
        baseline: 30,
        baselineType: TextBaseline.ideographic,
        child: HomericParagraph(source: emptySource()),
      )));
      final render = renderOf(tester);
      final ideographic = render.preferredLineIdeographicBaseline;
      expect(ideographic, isNot(render.preferredLineBaseline));
      // The Baseline ancestor's positioning proves
      // computeDistanceToActualBaseline actually used the ideographic
      // metric for TextBaseline.ideographic, not a shared alphabetic
      // fallback.
      expect(tester.getTopLeft(find.byType(HomericParagraph)).dy,
          30 - ideographic);
    });
  });

  // The outward half of the matrix — which of these triggers dispatch
  // onGeometryChanged, and which must not — lives in
  // `geometry_signal_test.dart`.
  group('invalidation matrix', () {
    testWidgets('release-safe geometry readiness follows layout invalidation',
        (tester) async {
      await tester
          .pumpWidget(harness(HomericParagraph(source: sourceOf('hello'))));
      final render = renderOf(tester);

      expect(render.hasCurrentGeometry, isTrue);
      render.markNeedsLayout();
      expect(render.hasCurrentGeometry, isFalse,
          reason: 'runtime readiness cannot depend on a debug-only getter');
      await tester.pump();
      expect(render.hasCurrentGeometry, isTrue);
    });

    testWidgets('width-only change relayouts the SAME paragraph',
        (tester) async {
      final source = sourceOf('hello');
      await tester.pumpWidget(harness(HomericParagraph(source: source)));
      final render = renderOf(tester);
      final before = render.layoutParagraph;
      final generation = render.layoutGeneration;

      await tester
          .pumpWidget(harness(HomericParagraph(source: source), width: 160));
      expect(identical(render.layoutParagraph, before), isTrue,
          reason: 'width-only change must not rebuild the paragraph');
      expect(render.layoutGeneration, generation + 1);
      expect(
          tester.getSize(find.byType(HomericParagraph)), const Size(160, 14));
    });

    testWidgets('re-deriving an equal source is a no-op (identity stable)',
        (tester) async {
      await tester
          .pumpWidget(harness(HomericParagraph(source: sourceOf('hello'))));
      final render = renderOf(tester);
      final before = render.layoutParagraph;
      final generation = render.layoutGeneration;

      // A fresh derivation of identical inputs (new instance, equal
      // content) — the per-build re-derive path must stay cheap.
      await tester
          .pumpWidget(harness(HomericParagraph(source: sourceOf('hello'))));
      expect(identical(render.layoutParagraph, before), isTrue);
      expect(render.layoutGeneration, generation);
    });

    testWidgets('content change rebuilds and relayouts', (tester) async {
      await tester
          .pumpWidget(harness(HomericParagraph(source: sourceOf('hello'))));
      final render = renderOf(tester);
      final before = render.layoutParagraph;
      final generation = render.layoutGeneration;

      await tester
          .pumpWidget(harness(HomericParagraph(source: sourceOf('help'))));
      expect(identical(render.layoutParagraph, before), isFalse);
      expect(render.layoutGeneration, generation + 1);
    });

    testWidgets('per-run style change rebuilds and relayouts', (tester) async {
      await tester
          .pumpWidget(harness(HomericParagraph(source: sourceOf('hello'))));
      final render = renderOf(tester);
      final before = render.layoutParagraph;

      await tester.pumpWidget(harness(HomericParagraph(
          source: sourceOf('hello', style: const TextStyle(fontSize: 28)))));
      expect(identical(render.layoutParagraph, before), isFalse);
      expect(
          tester.getSize(find.byType(HomericParagraph)), const Size(200, 28));
    });

    testWidgets('direction change rebuilds and relayouts', (tester) async {
      await tester
          .pumpWidget(harness(HomericParagraph(source: sourceOf('abc'))));
      final render = renderOf(tester);
      final before = render.layoutParagraph;

      const rtl = BlockParagraphSpec(direction: ParagraphDirection.rtl);
      await tester.pumpWidget(
          harness(HomericParagraph(source: sourceOf('abc', spec: rtl))));
      expect(identical(render.layoutParagraph, before), isFalse);
    });

    testWidgets('strut change rebuilds and relayouts', (tester) async {
      await tester
          .pumpWidget(harness(HomericParagraph(source: sourceOf('abc'))));
      final render = renderOf(tester);
      final before = render.layoutParagraph;

      // Forced strut at 20: line height becomes exactly 20 (FlutterTest
      // strut ascent 15 / descent 5).
      const strut = StrutStyle(fontSize: 20, forceStrutHeight: true);
      const spec = BlockParagraphSpec(strut: strut);
      await tester.pumpWidget(
          harness(HomericParagraph(source: sourceOf('abc', spec: spec))));
      expect(identical(render.layoutParagraph, before), isFalse);
      expect(
          tester.getSize(find.byType(HomericParagraph)), const Size(200, 20));
    });

    testWidgets(
        'textHeightBehavior suppresses first-ascent/last-descent '
        'leading', (tester) async {
      // The passthrough exists for consumers that render some blocks through
      // Homeric and some through another widget: Flutter's own `RichText`
      // takes a `TextHeightBehavior`, so a consumer that cannot supply one
      // here disagrees with itself on every vertical metric. `lineHeight`
      // alone cannot express "lay out at 1.5 but do not pad the outer edges".
      const tall = TextStyle(fontSize: 20, height: 1.5);

      await tester.pumpWidget(harness(HomericParagraph(
        source: sourceOf('abc', style: tall),
        baseStyle: tall,
      )));
      // Default: the 1.5 multiplier pads both outer edges — 20 * 1.5.
      expect(tester.getSize(find.byType(HomericParagraph)).height, 30);

      const spec = BlockParagraphSpec(
        textHeightBehavior: TextHeightBehavior(
          applyHeightToFirstAscent: false,
          applyHeightToLastDescent: false,
        ),
      );
      await tester.pumpWidget(harness(HomericParagraph(
        source: sourceOf('abc', style: tall, spec: spec),
        baseStyle: tall,
      )));
      // Suppressed: the single line falls back to the font's own ascent +
      // descent (FlutterTest: 0.75em + 0.25em = 1em = 20).
      expect(tester.getSize(find.byType(HomericParagraph)).height, 20);
    });

    testWidgets('a textHeightBehavior change rebuilds and relayouts',
        (tester) async {
      const tall = TextStyle(fontSize: 20, height: 1.5);
      await tester.pumpWidget(harness(HomericParagraph(
        source: sourceOf('abc', style: tall),
        baseStyle: tall,
      )));
      final render = renderOf(tester);
      final before = render.layoutParagraph;

      const spec = BlockParagraphSpec(
        textHeightBehavior: TextHeightBehavior(
          applyHeightToFirstAscent: false,
        ),
      );
      await tester.pumpWidget(harness(HomericParagraph(
        source: sourceOf('abc', style: tall, spec: spec),
        baseStyle: tall,
      )));

      // A paragraph-style input, so it must rebuild — not merely repaint.
      expect(identical(render.layoutParagraph, before), isFalse);
    });

    testWidgets('TextScaler change rebuilds and relayouts', (tester) async {
      final source = sourceOf('hello');
      await tester.pumpWidget(MediaQuery(
        data: const MediaQueryData(),
        child: harness(HomericParagraph(source: source)),
      ));
      final render = renderOf(tester);
      final before = render.layoutParagraph;
      final generation = render.layoutGeneration;

      // The widget reads the ambient MediaQuery — lookups live in the
      // widget, not the render object.
      await tester.pumpWidget(MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: harness(HomericParagraph(source: source)),
      ));
      expect(identical(render.layoutParagraph, before), isFalse);
      expect(render.layoutGeneration, generation + 1);
      // Font sizes scaled at build time: line height doubles to 28.
      expect(
          tester.getSize(find.byType(HomericParagraph)), const Size(200, 28));
    });

    testWidgets('spec TextScaler passthrough is honored by the widget',
        (tester) async {
      const spec = BlockParagraphSpec(textScaler: TextScaler.linear(2));
      await tester.pumpWidget(
          harness(HomericParagraph(source: sourceOf('hello', spec: spec))));
      expect(
          tester.getSize(find.byType(HomericParagraph)), const Size(200, 28));
    });

    testWidgets('system font change drops the cache and relayouts',
        (tester) async {
      await tester
          .pumpWidget(harness(HomericParagraph(source: sourceOf('hello'))));
      final render = renderOf(tester);
      final before = render.layoutParagraph;
      final generation = render.layoutGeneration;

      await sendFontsChangeMessage(tester);
      // RelayoutWhenSystemFontsChangeMixin defers systemFontsDidChange to
      // the next frame's transient-callbacks phase; the relayout happens
      // within that same frame.
      await tester.pump();

      expect(identical(render.layoutParagraph, before), isFalse,
          reason: 'stale glyph metrics: the paragraph must be rebuilt');
      expect(render.layoutGeneration, generation + 1);
      expect(before.debugDisposed, isTrue);
    });
  });

  group('paint-only changes (deferred rebuild, U5 repaint band)', () {
    testWidgets('paintStyler change rebuilds in paint, never in layout',
        (tester) async {
      final source = sourceOf('hello');
      await tester.pumpWidget(harness(HomericParagraph(source: source)));
      final render = renderOf(tester);
      final before = render.layoutParagraph;
      final generation = render.layoutGeneration;

      TextStyle dim(TextSegment<TextStyle> segment) =>
          segment.style.copyWith(color: const Color(0x80000000));
      await tester.pumpWidget(
          harness(HomericParagraph(source: source, paintStyler: dim)));

      // No relayout happened…
      expect(render.layoutGeneration, generation);
      expect(
          tester.getSize(find.byType(HomericParagraph)), const Size(200, 14));
      // …but paint() swapped in a freshly built paragraph and disposed
      // the old one (TextPainter's deferred-rebuild pattern).
      expect(identical(render.layoutParagraph, before), isFalse);
      expect(before.debugDisposed, isTrue);
    });

    testWidgets('a layout-affecting paintStyler trips the identity assert',
        (tester) async {
      final source = sourceOf('hello');
      await tester.pumpWidget(harness(HomericParagraph(source: source)));

      TextStyle illegal(TextSegment<TextStyle> segment) =>
          segment.style.copyWith(fontSize: 28);
      await tester.pumpWidget(
          harness(HomericParagraph(source: source, paintStyler: illegal)));

      final exception = tester.takeException();
      expect(exception, isA<FlutterError>());
      expect('$exception', contains('paint-only style change'));
    });
  });

  group('placeholder slots (provisional, U3 seam)', () {
    testWidgets('a slot occupies provisional space at the right offset',
        (tester) async {
      final source = sourceOf(
        'ab',
        decorations: [Decoration.widget('b', 1, spec: 'chip')],
      );
      expect(source.viewText, 'a${objectReplacementCharacter}b');

      await tester
          .pumpWidget(harness(HomericParagraph(source: source), width: 100));
      final paragraph = renderOf(tester).layoutParagraph;

      // Provisional 14×14 placeholder between the glyphs: offsets after
      // the slot stay correct for U3 to slot real children in.
      final boxes = paragraph.getBoxesForPlaceholders();
      expect(boxes, hasLength(1));
      expect(boxes.single.left, 14);
      expect(boxes.single.right, 28);
      final after = paragraph.getBoxesForRange(2, 3);
      expect(after.single.left, 28);
      expect(
          tester.getSize(find.byType(HomericParagraph)), const Size(100, 14));
    });

    testWidgets('slot dimension count mismatch throws a descriptive error',
        (tester) async {
      final source = sourceOf(
        'ab',
        decorations: [Decoration.widget('b', 1, spec: 'chip')],
      );
      final render = RenderHomericParagraph(
        source: source,
        slotDimensions: const [Size(10, 10), Size(10, 10)],
      );
      expect(
        () => render.getMaxIntrinsicWidth(double.infinity),
        throwsA(isA<FlutterError>().having(
          (error) => error.message,
          'message',
          allOf(contains('slot dimensions mismatch'), contains('1 widget'),
              contains('2 entries')),
        )),
      );
      render.dispose();
    });
  });

  group('lifecycle', () {
    testWidgets('dispose() disposes live, intrinsics, and template paragraphs',
        (tester) async {
      await tester
          .pumpWidget(harness(HomericParagraph(source: sourceOf('hello'))));
      final render = renderOf(tester);
      final live = render.layoutParagraph;
      render.getMaxIntrinsicWidth(double.infinity); // builds intrinsics
      expect(render.preferredLineHeight, 14); // builds the template
      final intrinsics = render.debugIntrinsicsParagraph!;
      final template = render.debugLineTemplate!;

      await tester.pumpWidget(const SizedBox());

      expect(live.debugDisposed, isTrue);
      expect(intrinsics.debugDisposed, isTrue);
      expect(template.debugDisposed, isTrue);
    });

    testWidgets('use after dispose asserts', (tester) async {
      await tester
          .pumpWidget(harness(HomericParagraph(source: sourceOf('hello'))));
      final render = renderOf(tester);
      await tester.pumpWidget(const SizedBox());
      expect(() => render.layoutParagraph, throwsAssertionError);
    });

    testWidgets('geometry surface for U4: generation, paragraph, view map',
        (tester) async {
      final source = sourceOf(
        'abcd',
        decorations: [Decoration.replace('b', 0, 2, replacementLength: 0)],
      );
      await tester.pumpWidget(harness(HomericParagraph(source: source)));
      final render = renderOf(tester);
      expect(render.layoutGeneration, 1);
      expect(render.viewMap, same(source.viewMap));
      expect(render.viewMap.docToView(3), 1);
      expect(render.layoutParagraph.numberOfLines, 1);
    });
  });
}
