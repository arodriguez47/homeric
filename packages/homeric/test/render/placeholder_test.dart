// Inline widget children via paragraph placeholders (U3): widget
// decorations rendered as real, measured RenderBox children positioned
// by the paragraph.
//
// Characterization pins use the FlutterTest font metrics: every glyph is
// a 1em box, ascent 0.75em / descent 0.25em — at fontSize 14 a glyph is
// 14px wide, a line is 14.0 tall, the alphabetic baseline sits at 10.5,
// and the text midline (for PlaceholderAlignment.middle) is 3.5px above
// the baseline, i.e. at y=7 in a 14px line. A middle-aligned chip of
// height h therefore spans [7 - h/2, 7 + h/2] while it fits in the line.

import 'package:flutter/rendering.dart' hide Decoration;
import 'package:flutter/widgets.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

const TextStyle style14 = TextStyle(fontSize: 14);

Block textBlock(String text) =>
    Block(id: 'b', type: 'paragraph', runs: [InlineRun(text)]);

ParagraphSource<TextStyle> sourceOf(
  String text, {
  TextStyle style = style14,
  Iterable<Decoration> decorations = const <Decoration>[],
}) {
  return ParagraphSource.build(
    block: textBlock(text),
    decorations: decorations,
    resolveStyle: (_) => style,
  );
}

/// Pumps [paragraph] inside a top-left aligned box of [width].
Widget harness(Widget paragraph, {double width = 100}) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: width, child: paragraph),
    ),
  );
}

RenderHomericParagraph renderOf(WidgetTester tester) =>
    tester.renderObject<RenderHomericParagraph>(find.byType(HomericParagraph));

/// A hit-testable chip: ColoredBox hit-tests opaquely, unlike a bare
/// SizedBox.
Widget chip({Key? key, double width = 20, double height = 10}) {
  return SizedBox(
    key: key,
    width: width,
    height: height,
    child: const ColoredBox(color: Color(0xFF00A000)),
  );
}

BoxHitTestResult hitAt(WidgetTester tester, Offset position) {
  final result = BoxHitTestResult();
  renderOf(tester).hitTest(result, position: position);
  return result;
}

Iterable<Object> targetsOf(BoxHitTestResult result) =>
    result.path.map((entry) => entry.target);

void main() {
  group('one chip child', () {
    testWidgets('renders at the slot placeholder box (offset == box topLeft)',
        (tester) async {
      const chipKey = Key('chip');
      final source = sourceOf(
        'ab',
        decorations: [Decoration.widget('b', 1, spec: 'chip')],
      );
      expect(source.viewText, 'a${objectReplacementCharacter}b');

      await tester.pumpWidget(harness(HomericParagraph(
        source: source,
        slotBuilder: (_) => chip(key: chipKey),
      )));

      final paragraph = renderOf(tester).layoutParagraph;
      final boxes = paragraph.getBoxesForPlaceholders();
      expect(boxes, hasLength(1));
      final box = boxes.single;
      // Between the glyphs: 20px wide after 'a' (14); middle-aligned
      // 10px chip spans [2, 12] in the 14px line.
      expect(box.left, 14);
      expect(box.right, 34);
      expect(box.top, 2);
      expect(box.bottom, 12);
      // The child's paint offset IS the box's top-left (checked through
      // applyPaintTransform via localToGlobal).
      expect(tester.getTopLeft(find.byKey(chipKey)), Offset(box.left, box.top));
      expect(tester.getSize(find.byKey(chipKey)), const Size(20, 10));
      // Glyphs after the slot start where the placeholder ends.
      expect(paragraph.getBoxesForRange(2, 3).single.left, 34);
      expect(
          tester.getSize(find.byType(HomericParagraph)), const Size(100, 14));
    });

    testWidgets('multi-char anchor folds to a single measured slot (Nexus #3)',
        (tester) async {
      const chipKey = Key('mention');
      final source = sourceOf(
        'x{{id}}y',
        decorations: [
          Decoration.replace('b', 1, 7, replacementLength: 0),
          Decoration.widget('b', 1, spec: 'mention'),
        ],
      );
      expect(source.viewText, 'x${objectReplacementCharacter}y');
      expect(source.slots, hasLength(1));

      await tester.pumpWidget(harness(HomericParagraph(
        source: source,
        slotBuilder: (slot) {
          expect(slot.spec, 'mention');
          return chip(key: chipKey);
        },
      )));

      final render = renderOf(tester);
      expect(render.childCount, 1);
      final boxes = render.layoutParagraph.getBoxesForPlaceholders();
      expect(boxes, hasLength(1));
      expect(boxes.single.left, 14);
      expect(boxes.single.right, 34);
      expect(tester.getTopLeft(find.byKey(chipKey)), const Offset(14, 2));
      // 'y' sits right after the single slot.
      expect(render.layoutParagraph.getBoxesForRange(2, 3).single.left, 34);
    });
  });

  group('baseline alignment', () {
    testWidgets('a baseline-aligned text-like chip sits on the text baseline',
        (tester) async {
      const chipKey = Key('chip');
      final source = sourceOf(
        'ab',
        decorations: [Decoration.widget('b', 1, spec: 'chip')],
      );
      await tester.pumpWidget(harness(HomericParagraph(
        source: source,
        slotAlignment: PlaceholderAlignment.baseline,
        slotBaseline: TextBaseline.alphabetic,
        // A text-like chip: fontSize 10 → 10x10 glyph, baseline 7.5.
        slotBuilder: (_) =>
            const Text('x', key: chipKey, style: TextStyle(fontSize: 10)),
      )));

      // Chip baseline (7.5 from its top) sits on the paragraph baseline
      // (10.5): top = 10.5 - 7.5 = 3. Line height stays 14 (chip descent
      // 2.5 < text descent 3.5).
      expect(tester.getTopLeft(find.byKey(chipKey)), const Offset(14, 3));
      expect(
          tester.getSize(find.byType(HomericParagraph)), const Size(100, 14));
      expect(renderOf(tester).layoutParagraph.alphabeticBaseline, 10.5);
    });

    test('baseline alignment without slotBaseline asserts', () {
      final source = sourceOf(
        'ab',
        decorations: [Decoration.widget('b', 1, spec: 'chip')],
      );
      expect(
        () => HomericParagraph(
          source: source,
          slotAlignment: PlaceholderAlignment.baseline,
          slotBuilder: (_) => chip(),
        ),
        throwsAssertionError,
      );
    });
  });

  group('slot positions', () {
    testWidgets('slot at block start', (tester) async {
      const chipKey = Key('chip');
      final source = sourceOf(
        'ab',
        decorations: [Decoration.widget('b', 0, spec: 'chip')],
      );
      expect(source.viewText, '${objectReplacementCharacter}ab');

      await tester.pumpWidget(harness(HomericParagraph(
        source: source,
        slotBuilder: (_) => chip(key: chipKey),
      )));

      final paragraph = renderOf(tester).layoutParagraph;
      expect(paragraph.getBoxesForPlaceholders().single.left, 0);
      expect(tester.getTopLeft(find.byKey(chipKey)), const Offset(0, 2));
      expect(paragraph.getBoxesForRange(1, 2).single.left, 20);
    });

    testWidgets('slot at block end (Nexus #4 footnote marker)', (tester) async {
      const chipKey = Key('fn');
      final source = sourceOf(
        'note',
        decorations: [Decoration.widget('b', 4, spec: 'fn')],
      );
      expect(source.viewText, 'note$objectReplacementCharacter');

      await tester.pumpWidget(harness(HomericParagraph(
        source: source,
        slotBuilder: (_) => chip(key: chipKey),
      )));

      final box =
          renderOf(tester).layoutParagraph.getBoxesForPlaceholders().single;
      expect(box.left, 4 * 14);
      expect(box.right, 4 * 14 + 20);
      expect(tester.getTopLeft(find.byKey(chipKey)), const Offset(56, 2));
    });

    testWidgets('two adjacent slots get distinct children and boxes',
        (tester) async {
      const firstKey = Key('w1');
      const secondKey = Key('w2');
      final source = sourceOf(
        'ab',
        decorations: [
          Decoration.widget('b', 1, spec: 'w1'),
          Decoration.widget('b', 1, spec: 'w2'),
        ],
      );
      expect(source.viewText,
          'a$objectReplacementCharacter${objectReplacementCharacter}b');

      await tester.pumpWidget(harness(HomericParagraph(
        source: source,
        slotBuilder: (slot) => slot.spec == 'w1'
            ? chip(key: firstKey, width: 20)
            : chip(key: secondKey, width: 30),
      )));

      final render = renderOf(tester);
      expect(render.childCount, 2);
      final boxes = render.layoutParagraph.getBoxesForPlaceholders();
      expect(boxes, hasLength(2));
      expect(boxes[0].left, 14);
      expect(boxes[0].right, 34);
      expect(boxes[1].left, 34);
      expect(boxes[1].right, 64);
      expect(tester.getTopLeft(find.byKey(firstKey)), const Offset(14, 2));
      expect(tester.getTopLeft(find.byKey(secondKey)), const Offset(34, 2));
      // 'b' follows the second slot.
      expect(render.layoutParagraph.getBoxesForRange(3, 4).single.left, 64);
    });

    testWidgets('slot inside a wrapped line lands on line 2', (tester) async {
      const chipKey = Key('chip');
      final source = sourceOf(
        'aaaa bb',
        decorations: [Decoration.widget('b', 7, spec: 'chip')],
      );

      // Width 70: 'aaaa ' fills line 1 (5 glyphs × 14); 'bb' + chip wrap
      // to line 2.
      await tester.pumpWidget(harness(
        HomericParagraph(
            source: source, slotBuilder: (_) => chip(key: chipKey)),
        width: 70,
      ));

      final render = renderOf(tester);
      expect(render.layoutParagraph.numberOfLines, 2);
      final box = render.layoutParagraph.getBoxesForPlaceholders().single;
      // Line 2 offsets: x after 'bb' (28), y = line 1 height (14) plus
      // the middle-aligned inset (2).
      expect(box.left, 28);
      expect(box.top, 16);
      expect(tester.getTopLeft(find.byKey(chipKey)), const Offset(28, 16));
      expect(tester.getSize(find.byType(HomericParagraph)), const Size(70, 28));
    });

    testWidgets('child taller than the line grows the line height',
        (tester) async {
      const chipKey = Key('tall');
      final source = sourceOf(
        'ab',
        decorations: [Decoration.widget('b', 1, spec: 'tall')],
      );
      await tester.pumpWidget(harness(HomericParagraph(
        source: source,
        slotBuilder: (_) => chip(key: chipKey, height: 30),
      )));

      // Middle-aligned 30px chip about the text midline (3.5 above the
      // baseline): ascent 3.5 + 15 = 18.5, descent 15 - 3.5 = 11.5 —
      // the line grows to exactly 30 and the baseline moves to 18.5.
      expect(
          tester.getSize(find.byType(HomericParagraph)), const Size(100, 30));
      final paragraph = renderOf(tester).layoutParagraph;
      expect(paragraph.height, 30);
      expect(paragraph.alphabeticBaseline, 18.5);
      final box = paragraph.getBoxesForPlaceholders().single;
      expect(box.top, 0);
      expect(box.bottom, 30);
      expect(tester.getTopLeft(find.byKey(chipKey)), const Offset(14, 0));
    });

    testWidgets('empty (zero-size) slot child does not crash', (tester) async {
      const chipKey = Key('empty');
      final source = sourceOf(
        'ab',
        decorations: [Decoration.widget('b', 1, spec: 'empty')],
      );
      await tester.pumpWidget(harness(HomericParagraph(
        source: source,
        slotBuilder: (_) => const SizedBox.shrink(key: chipKey),
      )));

      expect(tester.takeException(), isNull);
      // A zero-size placeholder: the line keeps its text metrics and 'b'
      // follows 'a' directly.
      expect(
          tester.getSize(find.byType(HomericParagraph)), const Size(100, 14));
      final paragraph = renderOf(tester).layoutParagraph;
      final box = paragraph.getBoxesForPlaceholders().single;
      expect(box.right - box.left, 0);
      expect(paragraph.getBoxesForRange(2, 3).single.left, 14);
      // Hit-testing and painting skip nothing and crash nowhere.
      expect(targetsOf(hitAt(tester, const Offset(7, 7))),
          contains(renderOf(tester)));
    });
  });

  group('hit testing', () {
    testWidgets('chip rect hits the child; adjacent glyphs hit text only',
        (tester) async {
      const chipKey = Key('chip');
      final source = sourceOf(
        'ab',
        decorations: [Decoration.widget('b', 1, spec: 'chip')],
      );
      await tester.pumpWidget(harness(HomericParagraph(
        source: source,
        slotBuilder: (_) => chip(key: chipKey),
      )));
      final render = renderOf(tester);
      final chipBox = tester.renderObject(find.descendant(
          of: find.byKey(chipKey), matching: find.byType(ColoredBox)));

      // Inside the chip rect [14, 2]–[34, 12]: the child is hit (and the
      // paragraph, as its ancestor).
      final onChip = hitAt(tester, const Offset(24, 7));
      expect(targetsOf(onChip), contains(chipBox));
      expect(targetsOf(onChip), contains(render));

      // On the 'a' glyph (x < 14) and the 'b' glyph (x > 34): text only —
      // the child is not in the path (partition pinned).
      for (final position in const [Offset(7, 7), Offset(40, 7)]) {
        final onText = hitAt(tester, position);
        expect(targetsOf(onText), contains(render));
        expect(targetsOf(onText), isNot(contains(chipBox)));
      }

      // In the slot's column but outside the chip vertically (below the
      // 10px chip): falls through to text.
      final belowChip = hitAt(tester, const Offset(24, 13));
      expect(targetsOf(belowChip), contains(render));
      expect(targetsOf(belowChip), isNot(contains(chipBox)));
    });
  });

  group('invalidation (slot dimensions are content-level)', () {
    testWidgets('width-only change keeps paragraph identity with children',
        (tester) async {
      const chipKey = Key('chip');
      final source = sourceOf(
        'ab',
        decorations: [Decoration.widget('b', 1, spec: 'chip')],
      );
      Widget build(double width) => harness(
            HomericParagraph(
                source: source, slotBuilder: (_) => chip(key: chipKey)),
            width: width,
          );

      await tester.pumpWidget(build(100));
      final render = renderOf(tester);
      final before = render.layoutParagraph;
      final generation = render.layoutGeneration;

      await tester.pumpWidget(build(90));
      // Children re-measured to the same size → same dimensions → the
      // paragraph is relaid, not rebuilt.
      expect(identical(render.layoutParagraph, before), isTrue);
      expect(render.layoutGeneration, generation + 1);
    });

    testWidgets('a child measuring to a new size rebuilds the paragraph',
        (tester) async {
      final source = sourceOf(
        'ab',
        decorations: [Decoration.widget('b', 1, spec: 'chip')],
      );
      Widget build(double chipWidth) => harness(HomericParagraph(
            source: source,
            slotBuilder: (_) => chip(width: chipWidth),
          ));

      await tester.pumpWidget(build(20));
      final render = renderOf(tester);
      final before = render.layoutParagraph;
      final generation = render.layoutGeneration;

      await tester.pumpWidget(build(24));
      expect(identical(render.layoutParagraph, before), isFalse,
          reason: 'slot dimension changes are content-level: rebuild');
      expect(render.layoutGeneration, generation + 1);
      expect(before.debugDisposed, isTrue);
      expect(render.layoutParagraph.getBoxesForPlaceholders().single.right, 38);
    });
  });

  group('count invariant (both ways)', () {
    testWidgets('fewer children than slots throws a descriptive error',
        (tester) async {
      final source = sourceOf(
        'ab',
        decorations: [
          Decoration.widget('b', 1, spec: 'w1'),
          Decoration.widget('b', 1, spec: 'w2'),
        ],
      );
      final child = RenderConstrainedBox(
          additionalConstraints: BoxConstraints.tight(const Size(10, 10)));
      final render = RenderHomericParagraph(source: source, children: [child]);
      expect(
        () => render.getMaxIntrinsicWidth(double.infinity),
        throwsA(isA<FlutterError>().having(
          (error) => error.message,
          'message',
          allOf(contains('slot child count mismatch'), contains('2 widget'),
              contains('1 inline child')),
        )),
      );
      render.removeAll();
      render.dispose();
      child.dispose();
    });

    testWidgets('childless slotDimensions mismatch still throws (U2 error)',
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
        throwsA(isA<FlutterError>().having((error) => error.message, 'message',
            contains('slot dimensions mismatch'))),
      );
      render.dispose();
    });
  });

  group('intrinsics and dry layout with children', () {
    testWidgets('dry queries never touch live paragraph or child layout',
        (tester) async {
      const chipKey = Key('chip');
      final source = sourceOf(
        'aaaa bb',
        decorations: [Decoration.widget('b', 7, spec: 'chip')],
      );
      await tester.pumpWidget(harness(HomericParagraph(
        source: source,
        slotBuilder: (_) => chip(key: chipKey),
      )));
      final render = renderOf(tester);
      final live = render.layoutParagraph;
      final generation = render.layoutGeneration;

      // Dry layout at width 70 wraps like the live test above: 2 lines.
      expect(render.getDryLayout(const BoxConstraints(maxWidth: 70)),
          const Size(70, 28));
      expect(
          render.getDryBaseline(
              const BoxConstraints(maxWidth: 100), TextBaseline.alphabetic),
          10.5);
      // Intrinsic widths: children measured as (intrinsic width, 0) —
      // 'aaaa bb' is 7 glyphs (98) + chip 20 = 118 max; min is the
      // longest unbreakable chunk 'bb' + chip = 48.
      expect(render.getMaxIntrinsicWidth(double.infinity), 118);
      expect(render.getMinIntrinsicWidth(double.infinity), 56);
      expect(render.getMinIntrinsicHeight(70), 28);

      // The live paragraph and the children were never disturbed.
      expect(identical(render.layoutParagraph, live), isTrue);
      expect(render.layoutGeneration, generation);
      expect(tester.getSize(find.byKey(chipKey)), const Size(20, 10));
      // Live layout at width 100: 'aaaa bb' + chip is 118px → 2 lines.
      expect(
          tester.getSize(find.byType(HomericParagraph)), const Size(100, 28));
    });
  });
}
