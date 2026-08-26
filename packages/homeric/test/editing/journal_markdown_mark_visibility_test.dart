import 'package:flutter/widgets.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

/// Journal markdown decorations using the library hide spec.
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

  final headingMatch = RegExp(r'^(#{1,6}) ').firstMatch(text);
  if (headingMatch != null) {
    final level = headingMatch.group(1)!.length;
    hideDelimiter(0, headingMatch.end);
    styleRange(headingMatch.end, text.length, 'heading$level');
  }

  for (final match in RegExp(r'\*\*(.+?)\*\*').allMatches(text)) {
    hideDelimiter(match.start, match.start + 2);
    hideDelimiter(match.end - 2, match.end);
    styleRange(match.start + 2, match.end - 2, 'bold');
  }

  for (final match
      in RegExp(r'(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)').allMatches(text)) {
    hideDelimiter(match.start, match.start + 1);
    hideDelimiter(match.end - 1, match.end);
    styleRange(match.start + 1, match.end - 1, 'italic');
  }

  for (final match in RegExp(r'==(.+?)==').allMatches(text)) {
    hideDelimiter(match.start, match.start + 2);
    hideDelimiter(match.end - 2, match.end);
    styleRange(match.start + 2, match.end - 2, 'highlight');
  }

  for (final match in RegExp(r'\+\+(.+?)\+\+').allMatches(text)) {
    hideDelimiter(match.start, match.start + 2);
    hideDelimiter(match.end - 2, match.end);
    styleRange(match.start + 2, match.end - 2, 'comment');
  }

  return result;
}

final class _JournalPaintMap {
  _JournalPaintMap();

  static const layoutOnly = TextStyle(fontSize: 14, color: Color(0xFF000000));

  static const markStyles = <String, TextStyle>{
    'bold': TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
    'heading1': TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
    'highlight': TextStyle(fontSize: 14, color: Color(0xFF000000)),
    'comment': TextStyle(fontSize: 14, color: Color(0xFF888888)),
  };

  final Map<int, TextStyle> resolved = <int, TextStyle>{};

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
    final style = resolved[segment.viewStart] ?? segment.style;
    paintedStyles[segment.viewStart] = style;
    return style;
  }

  final Map<int, TextStyle> paintedStyles = <int, TextStyle>{};
}

Document _document(String text) => Document([
      Block(
        id: 'b',
        type: 'paragraph',
        runs: [if (text.isNotEmpty) InlineRun(text)],
      ),
    ]);

Widget _harness({
  required HomericEditorController controller,
  required HomericTextInputSession session,
  required _JournalPaintMap paintMap,
  required MarkdownMarkVisibility visibility,
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
                    markdownMarkVisibility: visibility,
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

void main() {
  group('MarkdownMarkVisibility.livePreview (default)', () {
    testWidgets('hides ** and # delimiters after closing space',
        (tester) async {
      final controller = HomericEditorController(
        document: _document('**bold** '),
      );
      final session = HomericTextInputSession(controller: controller);
      final paintMap = _JournalPaintMap();
      addTearDown(session.dispose);
      addTearDown(controller.dispose);

      paintMap.beginBuild();
      await tester.pumpWidget(_harness(
        controller: controller,
        session: session,
        paintMap: paintMap,
        visibility: MarkdownMarkVisibility.livePreview,
      ));
      await tester.pump();

      expect(_paragraphRender(tester).source.viewText, 'bold ');
      expect(paintMap.paintedStyles[0]?.fontWeight, FontWeight.w700);
    });
  });

  group('MarkdownMarkVisibility.sourceVisible', () {
    testWidgets('keeps ** delimiters visible and still paints bold', (
      tester,
    ) async {
      const literal = '**bold** ';
      final controller = HomericEditorController(document: _document(literal));
      final session = HomericTextInputSession(controller: controller);
      final paintMap = _JournalPaintMap();
      addTearDown(session.dispose);
      addTearDown(controller.dispose);

      paintMap.beginBuild();
      await tester.pumpWidget(_harness(
        controller: controller,
        session: session,
        paintMap: paintMap,
        visibility: MarkdownMarkVisibility.sourceVisible,
      ));
      await tester.pump();

      expect(controller.document.blocks.single.text, literal);
      expect(_paragraphRender(tester).source.viewText, literal);
      expect(paintMap.paintedStyles[2]?.fontWeight, FontWeight.w700);
    });

    testWidgets('keeps ATX #, ==, and ++ marks visible with styles', (
      tester,
    ) async {
      const literal = '# Title ==x== ++note++ ';
      final controller = HomericEditorController(document: _document(literal));
      final session = HomericTextInputSession(controller: controller);
      final paintMap = _JournalPaintMap();
      addTearDown(session.dispose);
      addTearDown(controller.dispose);

      paintMap.beginBuild();
      await tester.pumpWidget(_harness(
        controller: controller,
        session: session,
        paintMap: paintMap,
        visibility: MarkdownMarkVisibility.sourceVisible,
      ));
      await tester.pump();

      expect(_paragraphRender(tester).source.viewText, literal);
      expect(paintMap.paintedStyles[2]?.fontSize, 28);
      expect(paintMap.paintedStyles[16]?.color, const Color(0xFF888888));
      expect(_paragraphRender(tester).source.viewText,
          isNot(contains('<comment>')));
    });
  });
}
