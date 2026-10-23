// Glued slots (HomericGluedSlot): a mark between a word and its
// punctuation stays on that word's line.
//
// FlutterTest font at 14px: every glyph is 14 wide, a line 14 tall, the
// baseline at 10.5 and the text midline at y=7.

import 'package:flutter/widgets.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric/writing.dart';

import 'render_test_utils.dart';

class _Mark implements HomericGluedSlot {
  const _Mark();
}

Widget _chip(Key key) => SizedBox(
      key: key,
      width: 6,
      height: 6,
      child: const ColoredBox(color: Color(0xFFA00000)),
    );

/// Where each line starts, as view offsets.
List<int> _lineStarts(RenderHomericParagraph render) {
  final paragraph = render.layoutParagraph;
  final length = render.source.viewText.length;
  return <int>{
    for (var i = 0; i <= length; i++)
      paragraph.getLineBoundary(TextPosition(offset: i)).start,
  }.toList()
    ..sort();
}

void main() {
  // "ab cd" + mark + "." : 5 glyphs (70) + 6 + 14. At 80 wide the word and
  // its mark fit but the period doesn't.
  Future<RenderHomericParagraph> pump(
    WidgetTester tester,
    Object spec, {
    Key key = const Key('mark'),
  }) async {
    final source = sourceOf(
      'ab cd.',
      decorations: [Decoration.widget('b', 5, spec: spec)],
    );
    await tester.pumpWidget(harness(
      HomericParagraph(source: source, slotBuilder: (_) => _chip(key)),
      width: 80,
    ));
    return renderOf(tester);
  }

  testWidgets('a placeholder lets the period wrap on its own', (tester) async {
    final render = await pump(tester, 'plain');
    // Second line is just the period, after the slot (view offset 5).
    expect(_lineStarts(render), [0, 6]);
  });

  testWidgets('a glued mark takes its word and the period with it',
      (tester) async {
    final render = await pump(tester, const _Mark());
    // "cd", the mark and the period wrap together.
    expect(_lineStarts(render), [0, 3]);
    // One view unit, as a placeholder would be.
    expect(render.source.viewText.length, 7);
  });

  for (final spec in <Object>[
    const HomericFootnoteSpec('n'),
    const HomericAnnotationNoteSpec('note'),
  ]) {
    testWidgets('${spec.runtimeType} keeps its word and period together',
        (tester) async {
      final render = await pump(tester, spec);
      expect(_lineStarts(render), [0, 3]);
    });
  }

  testWidgets('a glued mark paints over its advance, centred on the line',
      (tester) async {
    final render = await pump(tester, const _Mark());
    final paragraph = render.layoutParagraph;
    // Second line: "cd" then the mark, then the period after its width.
    final markBox = tester.getRect(find.byKey(const Key('mark')));
    expect(markBox.left, 28);
    expect(markBox.width, 6);
    expect(markBox.center.dy, closeTo(14 + 7, 0.5));
    expect(paragraph.getBoxesForRange(6, 7).single.left, closeTo(34, 0.5));
    // Geometry agrees with the paint offset.
    expect(
      ParagraphGeometry(render).slotRectAt(0).value.topLeft,
      markBox.topLeft,
    );
  });

  testWidgets('a glued mark at a line end does not raise the line',
      (tester) async {
    final render = await pump(tester, const _Mark());
    expect(render.size.height, 28);
  });

  testWidgets('a line that holds only a glued mark keeps its height',
      (tester) async {
    final source = sourceOf(
      '',
      decorations: [Decoration.widget('b', 0, spec: const _Mark())],
    );
    await tester.pumpWidget(harness(
      HomericParagraph(
        source: source,
        slotBuilder: (_) => const SizedBox(width: 6, height: 20),
      ),
      width: 80,
    ));
    expect(renderOf(tester).size.height, greaterThanOrEqualTo(20));
  });

  testWidgets('a tall glued mark on a later line paints on that line',
      (tester) async {
    final source = sourceOf(
      'ab cd.',
      decorations: [Decoration.widget('b', 5, spec: const _Mark())],
    );
    await tester.pumpWidget(harness(
      HomericParagraph(
        source: source,
        slotBuilder: (_) =>
            const SizedBox(key: Key('mark'), width: 6, height: 20),
      ),
      width: 80,
    ));
    final render = renderOf(tester);
    final second = render.layoutParagraph.computeLineMetrics()[1];
    final lineTop = second.baseline - second.ascent;
    final markBox = tester.getRect(find.byKey(const Key('mark')));
    expect(markBox.top, greaterThanOrEqualTo(lineTop - 0.5));
    expect(
      ParagraphGeometry(render).slotRectAt(0).value.topLeft,
      markBox.topLeft,
    );
  });
}
