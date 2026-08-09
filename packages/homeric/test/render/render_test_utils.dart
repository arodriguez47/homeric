// Shared test harness for the render-layer (U2-U6) test suites:
// `geometry_test.dart`, `paint_layers_test.dart`,
// `homeric_paragraph_test.dart`, `placeholder_test.dart`,
// `semantics_test.dart`, and `differential_test.dart` each independently
// defined the FlutterTest-font style constant, a single-block
// [ParagraphSource] builder, a pump-and-align widget harness, and a
// render-object lookup; this file is the one shared definition of each,
// mirroring `../transform/transform_test_utils.dart`'s pattern for the
// transform-layer suites.
//
// FlutterTest font metrics (pinned by every U2-U4 suite and reused here):
// every glyph — including U+FFFC and non-Latin code points, since the test
// font maps every code point to the same square glyph — is a 1em box; at
// fontSize 14 a glyph is 14px wide, a line is 14.0 tall, the alphabetic
// baseline sits at 10.5.

import 'package:flutter/widgets.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

import '../transform/transform_test_utils.dart';

/// The FlutterTest font's reference style.
const TextStyle style14 = TextStyle(fontSize: 14);

/// Builds a [ParagraphSource] over a single-block fixture (block id `'b'`,
/// paragraph type — the shape every render-layer suite's fixtures use).
ParagraphSource<TextStyle> sourceOf(
  String text, {
  TextStyle style = style14,
  Iterable<Decoration> decorations = const <Decoration>[],
  RevealState reveal = RevealState.none,
  BlockParagraphSpec spec = const BlockParagraphSpec(),
}) {
  return ParagraphSource.build(
    block: para('b', text),
    decorations: decorations,
    reveal: reveal,
    resolveStyle: (_) => style,
    spec: spec,
  );
}

/// Pumps [paragraph] inside a top-left aligned, directionality-wrapped box
/// of [width].
Widget harness(Widget paragraph, {double width = 200}) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: width, child: paragraph),
    ),
  );
}

/// The [RenderHomericParagraph] found by [finder], defaulting to the sole
/// [HomericParagraph] in the tree.
RenderHomericParagraph renderOf(WidgetTester tester, [Finder? finder]) =>
    tester.renderObject<RenderHomericParagraph>(
        finder ?? find.byType(HomericParagraph));
