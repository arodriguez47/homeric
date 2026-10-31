// A sunk drop cap beside every inline format: line two never starts
// mid-word, and nothing a mark paints (a highlight, an underline, an
// aside's wash) covers the empty room the letter holds open.
//
// The host measures where line two starts after each layout and hands it
// back as HomericDropCapLayout.lineTwo; these tests run that loop the way
// Sprintnotes does, and lay out frames from stale answers an edit leaves
// behind (mid-word, with or without line one's filler).
//
// FlutterTest font at 14px: every glyph 14 wide, a line 14 tall.

import 'dart:math' as math;

import 'package:flutter/widgets.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric/writing.dart';

import '../render/render_test_utils.dart';
import '../transform/transform_test_utils.dart';

const double _indent = 42;

const _syntax = HomericSyntax.all;
const _paint = HomericSyntaxPaint(
  commentWash: Color(0x14000000),
  commentWashFill: 0.6,
);

Widget _slot(SlotSegment<TextStyle> slot) {
  final spec = slot.spec;
  if (spec is HomericGapSpec) return SizedBox(width: spec.width, height: 1);
  return const SizedBox(width: 10, height: 8);
}

/// Lays [text] out with its drop cap at [lineTwo], as a host would.
Future<(RenderHomericParagraph, List<Decoration>)> _pump(
  WidgetTester tester,
  String text,
  HomericDropCapLayout layout, {
  required double width,
}) async {
  final decorations =
      _syntax.decorationsFor(para('b', text), dropCap: layout).toList();
  await tester.pumpWidget(harness(
    HomericParagraph(
      source: sourceOf(text, decorations: decorations),
      slotBuilder: _slot,
    ),
    width: width,
  ));
  return (renderOf(tester), decorations);
}

/// Where line two starts and the filler line one needs, measured from
/// [render] the way Sprintnotes' surface measures it.
HomericDropCapLayout _measure(
  RenderHomericParagraph render,
  int letterEnd,
  double width,
) {
  final g = ParagraphGeometry(render);
  double? lineOne;
  int? lineTwo;
  var right = 0.0;
  for (var o = letterEnd; o < g.docLength; o++) {
    final rects = [
      for (final b
          in g.inkRectsForRange(DocRange(DocOffset(o), DocOffset(o + 1))).value)
        if (b.bottom - b.top > 2) b.toRect(),
    ];
    if (rects.isEmpty) continue;
    lineOne ??= rects.first.top;
    if (rects.first.top > lineOne + 7) {
      lineTwo = o;
      break;
    }
    right = math.max(right, rects.map((r) => r.right).reduce(math.max));
  }
  final room = width - right;
  return HomericDropCapLayout(
    indent: _indent,
    lineTwo: lineTwo,
    fill: lineTwo != null && room >= _indent
        ? (room - _indent / 2).floorToDouble()
        : 0,
  );
}

/// Lays [text] out until the measured layout stops changing.
Future<(RenderHomericParagraph, List<Decoration>, HomericDropCapLayout)>
    _settle(WidgetTester tester, String text, double width) async {
  final letterEnd = HomericNoteMarks.dropCap.firstMatch(text)!.end;
  var layout = const HomericDropCapLayout(indent: _indent);
  for (var i = 0; i < 6; i++) {
    final (render, decorations) =
        await _pump(tester, text, layout, width: width);
    final next = _measure(render, letterEnd, width);
    if (next == layout) return (render, decorations, layout);
    layout = next;
  }
  fail('the drop cap layout of "$text" never settled');
}

/// The words each laid-out line shows, slots dropped.
List<String> _lines(RenderHomericParagraph render) {
  final view = render.source.viewText;
  final p = render.layoutParagraph;
  final bounds = <TextRange>{
    for (var i = 0; i < view.length; i++)
      p.getLineBoundary(TextPosition(offset: i)),
  }.toList()
    ..sort((a, b) => a.start.compareTo(b.start));
  return [
    for (final b in bounds)
      view.substring(b.start, b.end).replaceAll('\uFFFC', '').trim(),
  ];
}

/// The gap slots' rects: the drop cap's empty room.
List<Rect> _gaps(RenderHomericParagraph render) {
  final g = ParagraphGeometry(render);
  return [
    for (final slot in render.source.slots)
      if (slot.spec is HomericGapSpec)
        if (g.slotRectAt(slot.slotIndex).value case final r when r.width > 1) r,
  ];
}

/// Every rect a mark's paint layer covers.
List<Rect> _painted(RenderHomericParagraph render, List<Decoration> ds) {
  final g = ParagraphGeometry(render);
  return [
    for (final layer in _paint.layersFor(ds))
      for (final b in switch (layer.fit) {
        PaintLayerFit.ink => g.inkRectsForRange(layer.range).value,
        PaintLayerFit.line => g.rectsForRange(layer.range).value,
        PaintLayerFit.inkLine =>
          joinLineBoxes(g.inkRectsForRange(layer.range).value),
      })
        b.toRect(),
  ];
}

bool _overlaps(Rect a, Rect b) =>
    a.left < b.right - 0.5 &&
    b.left < a.right - 0.5 &&
    a.top < b.bottom - 0.5 &&
    b.top < a.bottom - 0.5;

void main() {
  // Each format wraps "I Voted", which lands on line one's end at the
  // widths below, beside a drop cap three glyphs wide.
  const lead = '^^I think that people wear ';
  const cases = <String, String>{
    'highlight': '$lead==I Voted== pins are liberal.',
    'bold': '$lead**I Voted** pins are liberal.',
    'italic': '$lead*I Voted* pins are liberal.',
    'strike': '$lead~~I Voted~~ pins are liberal.',
    'aside': '$lead++I Voted++ pins are liberal.',
    'code': '$lead`I Voted` pins are liberal.',
    'link': '$lead[I Voted](https://x.y) pins are liberal.',
    'wiki link': '$lead[[I Voted]] pins are liberal.',
    'footnote': '${lead}I Voted^[a pin] pins are liberal.',
    'annotation': '$lead{{I Voted|a pin}} pins are liberal.',
    'highlight over the wrap and on': '$lead==I Voted pins are== liberal.',
    'highlight from line one on': '^^I ==think that people '
        'wear I Voted== pins are liberal.',
    'nested bold in highlight': '$lead==I **Voted**== pins are liberal.',
  };

  final plain = RegExp(r'[^\w\s.]');
  String words(String s) =>
      s.replaceAll(plain, '').replaceAll(RegExp(r'\s+'), ' ').trim();

  void expectWholeAndUnpainted(
    RenderHomericParagraph render,
    List<Decoration> decorations,
  ) {
    // The lines read the paragraph's words in order, none split.
    final lines = _lines(render);
    final view = render.source.viewText;
    final all = words(view.replaceAll('\uFFFC', ''));
    expect(words(lines.join(' ')), all, reason: lines.join(' / '));
    // The drop cap's room only ever stands before a word, never inside one.
    for (final slot in render.source.slots) {
      final i = slot.viewOffset;
      if (slot.spec is! HomericGapSpec || i == 0) continue;
      expect(view[i - 1].trim().isEmpty || view[i - 1] == '\uFFFC', isTrue,
          reason: 'room inside "${view.substring(i - 3, i + 3)}"');
    }
    for (final gap in _gaps(render)) {
      for (final r in _painted(render, decorations)) {
        expect(_overlaps(gap, r), isFalse,
            reason: 'paint $r covers the drop cap room $gap');
      }
    }
  }

  // 29 to 32 glyphs a line, so the marked words land on the wrap in every
  // way: whole on line one, whole on line two, or across it.
  const widths = <double>[406, 420, 434, 448];

  for (final MapEntry(key: name, value: text) in cases.entries) {
    testWidgets('$name: settles with whole words and unpainted room',
        (tester) async {
      for (final width in widths) {
        final (render, decorations, layout) =
            await _settle(tester, text, width);
        expect(layout.lineTwo, isNotNull, reason: 'the text wraps');
        expectWholeAndUnpainted(render, decorations);
      }
    });

    // Every frame, even one laid out from a line two measured before an
    // edit (anywhere around the wrap, with any filler), keeps words whole.
    testWidgets('$name: a stale line two never splits a word', (tester) async {
      for (final width in widths) {
        for (var o = lead.length - 6; o < lead.length + 12; o++) {
          for (final fill in const <double>[0, 7, 28, 90]) {
            final (render, decorations) = await _pump(
              tester,
              text,
              HomericDropCapLayout(indent: _indent, lineTwo: o, fill: fill),
              width: width,
            );
            expectWholeAndUnpainted(render, decorations);
          }
        }
      }
    });
  }

  testWidgets('a word longer than line two keeps the engine\'s break',
      (tester) async {
    const text = '^^Isupercalifragilisticexpialidocious'
        'supercalifragilisticexpialidocious end';
    final (render, _, layout) = await _settle(tester, text, 420);
    // The engine breaks the long word itself; its slots stay at that
    // break rather than jumping back onto line one.
    expect(layout.lineTwo, greaterThan(3));
    expect(render.layoutParagraph.computeLineMetrics().length, greaterThan(2));
  });
}
