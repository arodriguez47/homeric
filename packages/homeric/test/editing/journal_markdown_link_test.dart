import 'package:flutter/widgets.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

import '../transform/transform_test_utils.dart';

/// Mirrors the journal host contract: literal source, live deriveDecorations,
/// layout-only resolveStyle with a paintStyler side channel.
final class _JournalPaintMap {
  _JournalPaintMap();

  final Map<int, TextStyle> resolved = <int, TextStyle>{};
  int paintCalls = 0;

  static const layoutOnly = TextStyle(fontSize: 14, color: Color(0xFF000000));

  static const markStyles = <String, TextStyle>{
    'link': TextStyle(
      fontSize: 14,
      color: Color(0xFF0066CC),
      decoration: TextDecoration.underline,
    ),
  };

  void beginBuild() => resolved.clear();

  TextStyle resolve(RunStyleContext run) {
    var style = layoutOnly;
    for (final decoration in run.decorations) {
      final mark = markStyles[decoration.spec];
      if (mark != null) style = mark;
    }
    resolved[run.viewStart] = style;
    return layoutOnly;
  }

  TextStyle paint(TextSegment<TextStyle> segment) {
    paintCalls += 1;
    final style = resolved[segment.viewStart] ?? segment.style;
    paintedStyles[segment.viewStart] = style;
    return style;
  }

  final Map<int, TextStyle> paintedStyles = <int, TextStyle>{};

  TextStyle? styleAtViewOffset(int offset) => paintedStyles[offset];
}

/// Journal markdown decorations: hide `[` / `](url)`, paint label as link.
List<Decoration> journalMarkdownDecorationsForBlock(Block block) {
  final text = block.text;
  final result = <Decoration>[];

  void hideDelimiter(int start, int end) {
    result.add(markdownMarkHideReplacement(block.id, start, end));
  }

  void styleRange(int start, int end, String spec) {
    if (end > start) {
      result.add(Decoration.inline(block.id, start, end, spec: spec));
    }
  }

  for (final match in RegExp(r'\[([^\]]+)\]\(([^)]+)\)').allMatches(text)) {
    final label = match.group(1)!;
    hideDelimiter(match.start, match.start + 1);
    hideDelimiter(match.start + 1 + label.length, match.end);
    styleRange(match.start + 1, match.start + 1 + label.length, 'link');
  }

  return result;
}

Document _document(String text) => Document([
      Block(
        id: 'b',
        type: 'paragraph',
        runs: [if (text.isNotEmpty) InlineRun(text)],
      ),
    ]);

Widget _documentHarness({
  required HomericEditorController controller,
  required HomericTextInputSession session,
  required _JournalPaintMap paintMap,
}) =>
    Directionality(
      textDirection: TextDirection.ltr,
      child: Localizations(
        locale: const Locale('en'),
        delegates: const <LocalizationsDelegate<dynamic>>[
          DefaultWidgetsLocalizations.delegate,
        ],
        child: Overlay(
          initialEntries: <OverlayEntry>[
            OverlayEntry(
              builder: (_) => SizedBox(
                width: 320,
                child: HomericEditableDocument.builder(
                  controller: controller,
                  inputSession: session,
                  cacheExtent: 0,
                  estimatedBlockHeight: 44,
                  blockBuilder: (context, block, focusNode) =>
                      HomericEditableParagraph(
                    controller: controller,
                    inputSession: session,
                    blockId: block.id,
                    focusNode: focusNode,
                    deriveDecorations: journalMarkdownDecorationsForBlock,
                    resolveStyle: paintMap.resolve,
                    paintStyler: paintMap.paint,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );

RenderHomericParagraph _paragraphRender(WidgetTester tester) =>
    tester.renderObject<RenderHomericParagraph>(
      find.descendant(
        of: find.byType(HomericEditableParagraph),
        matching: find.byType(HomericParagraph),
      ),
    );

ParagraphSource<TextStyle> _linkAfterSpaceSource(_JournalPaintMap paintMap) =>
    ParagraphSource.build(
      block: para('b', '[label](https://x.test) '),
      decorations: journalMarkdownDecorationsForBlock(
        para('b', '[label](https://x.test) '),
      ),
      resolveStyle: paintMap.resolve,
    );

void main() {
  testWidgets(
      'after space, hidden link marks still paint label as link via paintStyler',
      (tester) async {
    final controller = HomericEditorController(
      document: _document('[label](https://x.test) '),
    );
    final session = HomericTextInputSession(controller: controller);
    final paintMap = _JournalPaintMap();
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    paintMap.beginBuild();
    await tester.pumpWidget(_documentHarness(
      controller: controller,
      session: session,
      paintMap: paintMap,
    ));
    await tester.pump();

    expect(_paragraphRender(tester).source.viewText, 'label ');
    expect(
      paintMap.styleAtViewOffset(0)?.color,
      const Color(0xFF0066CC),
      reason: 'link label must paint with link color after hide-on-space',
    );
    expect(
      paintMap.styleAtViewOffset(0)?.decoration,
      TextDecoration.underline,
      reason: 'link label must paint underlined after hide-on-space',
    );

    paintMap.beginBuild();
    paintMap.paintCalls = 0;
    paintMap.paintedStyles.clear();
    controller.notifyListeners();
    await tester.pump();

    expect(paintMap.paintCalls, greaterThan(0),
        reason: 'paintStyler must run when the resolve map is refilled');
    expect(
      paintMap.styleAtViewOffset(0)?.color,
      const Color(0xFF0066CC),
      reason: 'link color must survive hide-on-space host rebuilds',
    );
  });

  testWidgets(
      'after hide-on-leave, hidden link marks still paint label as link',
      (tester) async {
    const literal = '[label](https://x.test) ';
    final document = _document(literal);
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(0, 23)),
    );
    final session = HomericTextInputSession(controller: controller);
    final paintMap = _JournalPaintMap();
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    paintMap.beginBuild();
    await tester.pumpWidget(_documentHarness(
      controller: controller,
      session: session,
      paintMap: paintMap,
    ));
    await tester.pump();

    final render = _paragraphRender(tester);
    expect(render.source.viewText, 'label ');
    expect(paintMap.styleAtViewOffset(0)?.color, const Color(0xFF0066CC));

    // Caret enters the mark: reveal-on-touch shows the touched delimiter.
    controller.setSelection(
      HomericSelection.collapsed(document.positionAt(0, 0)),
    );
    paintMap.beginBuild();
    await tester.pump();
    expect(_paragraphRender(tester).source.viewText, isNot('label '),
        reason: 'caret on a hidden delimiter must reveal it');

    // Caret leaves the mark: hide-on-leave folds delimiters again.
    controller.setSelection(
      HomericSelection.collapsed(document.positionAt(0, 23)),
    );
    paintMap.beginBuild();
    paintMap.paintCalls = 0;
    paintMap.paintedStyles.clear();
    await tester.pump();

    expect(_paragraphRender(tester).source.viewText, 'label ',
        reason:
            'hide-on-leave must fold link delimiters back out of view text');
    expect(paintMap.paintCalls, greaterThan(0),
        reason: 'paintStyler must run when the resolve map is refilled');
    expect(
      paintMap.styleAtViewOffset(0)?.color,
      const Color(0xFF0066CC),
      reason: 'link color must survive hide-on-leave',
    );
    expect(
      paintMap.styleAtViewOffset(0)?.decoration,
      TextDecoration.underline,
      reason: 'link underline must survive hide-on-leave',
    );
  });

  testWidgets(
      'layout-equal source update reshapes paintStyler glyphs for hidden link',
      (tester) async {
    final paintMap = _JournalPaintMap();
    paintMap.beginBuild();
    final source = _linkAfterSpaceSource(paintMap);
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        width: 200,
        child: HomericParagraph(source: source, paintStyler: paintMap.paint),
      ),
    ));
    await tester.pump();
    expect(paintMap.styleAtViewOffset(0)?.color, const Color(0xFF0066CC));

    final render = tester.renderObject<RenderHomericParagraph>(
      find.byType(HomericParagraph),
    );
    paintMap.beginBuild();
    paintMap.paintCalls = 0;
    paintMap.paintedStyles.clear();
    render.source = _linkAfterSpaceSource(paintMap);
    await tester.pump();

    expect(paintMap.paintCalls, greaterThan(0));
    expect(paintMap.styleAtViewOffset(0)?.color, const Color(0xFF0066CC));
  });
}
