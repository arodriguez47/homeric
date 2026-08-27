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
    'italic': TextStyle(fontSize: 14, fontStyle: FontStyle.italic),
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

/// Journal markdown decorations: hide `*` / `_` delimiters, paint inner text as italic.
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

  for (final match
      in RegExp(r'(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)').allMatches(text)) {
    hideDelimiter(match.start, match.start + 1);
    hideDelimiter(match.end - 1, match.end);
    styleRange(match.start + 1, match.end - 1, 'italic');
  }

  for (final match
      in RegExp(r'(?<!_)_(?!_)(.+?)(?<!_)_(?!_)').allMatches(text)) {
    hideDelimiter(match.start, match.start + 1);
    hideDelimiter(match.end - 1, match.end);
    styleRange(match.start + 1, match.end - 1, 'italic');
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

ParagraphSource<TextStyle> _italicAfterSpaceSource(
  _JournalPaintMap paintMap,
  String literal,
) =>
    ParagraphSource.build(
      block: para('b', literal),
      decorations: journalMarkdownDecorationsForBlock(para('b', literal)),
      resolveStyle: paintMap.resolve,
    );

void main() {
  group('*italic*', () {
    testWidgets(
        'after space, hidden asterisks fold delimiters and inner text paints italic',
        (tester) async {
      const literal = '*italic* ';
      final controller = HomericEditorController(document: _document(literal));
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

      expect(controller.document.blocks.single.text, literal,
          reason: 'stored source must remain literal markdown');
      expect(_paragraphRender(tester).source.viewText, 'italic ');
      expect(
        paintMap.styleAtViewOffset(0)?.fontStyle,
        FontStyle.italic,
        reason: 'italic inner text must paint italic after hide-on-space',
      );

      paintMap.beginBuild();
      paintMap.paintCalls = 0;
      paintMap.paintedStyles.clear();
      controller.notifyListeners();
      await tester.pump();

      expect(paintMap.paintCalls, greaterThan(0),
          reason: 'paintStyler must run when the resolve map is refilled');
      expect(_paragraphRender(tester).source.viewText, 'italic ',
          reason: 'asterisks must stay hidden after hide-on-space rebuild');
      expect(paintMap.styleAtViewOffset(0)?.fontStyle, FontStyle.italic,
          reason: 'italic must survive hide-on-space host rebuilds');
    });

    testWidgets(
        'after hide-on-leave, hidden asterisks stay folded at trailing space',
        (tester) async {
      const literal = '*italic* ';
      final document = _document(literal);
      final controller = HomericEditorController(
        document: document,
        selection:
            HomericSelection.collapsed(document.positionAt(0, literal.length)),
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

      expect(_paragraphRender(tester).source.viewText, 'italic ');
      expect(paintMap.styleAtViewOffset(0)?.fontStyle, FontStyle.italic);

      // Caret enters the mark: reveal-on-touch shows the touched delimiter.
      controller.setSelection(
        HomericSelection.collapsed(document.positionAt(0, 0)),
      );
      paintMap.beginBuild();
      await tester.pump();
      expect(_paragraphRender(tester).source.viewText, isNot('italic '),
          reason: 'caret on a hidden asterisk must reveal it');

      // Caret leaves to trailing space: hide-on-leave folds delimiters again.
      controller.setSelection(
        HomericSelection.collapsed(document.positionAt(0, literal.length)),
      );
      paintMap.beginBuild();
      paintMap.paintCalls = 0;
      paintMap.paintedStyles.clear();
      await tester.pump();

      expect(_paragraphRender(tester).source.viewText, 'italic ',
          reason:
              'trailing-space caret must not re-reveal asterisks (HOM-35 class)');
      expect(paintMap.paintCalls, greaterThan(0),
          reason: 'paintStyler must run when the resolve map is refilled');
      expect(paintMap.styleAtViewOffset(0)?.fontStyle, FontStyle.italic,
          reason: 'italic must survive hide-on-leave');
    });

    testWidgets(
        'layout-equal source update reshapes paintStyler glyphs for hidden italic',
        (tester) async {
      const literal = '*italic* ';
      final paintMap = _JournalPaintMap();
      paintMap.beginBuild();
      final source = _italicAfterSpaceSource(paintMap, literal);
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 200,
          child: HomericParagraph(source: source, paintStyler: paintMap.paint),
        ),
      ));
      await tester.pump();
      expect(paintMap.styleAtViewOffset(0)?.fontStyle, FontStyle.italic);

      final render = tester.renderObject<RenderHomericParagraph>(
        find.byType(HomericParagraph),
      );
      paintMap.beginBuild();
      paintMap.paintCalls = 0;
      paintMap.paintedStyles.clear();
      render.source = _italicAfterSpaceSource(paintMap, literal);
      await tester.pump();

      expect(paintMap.paintCalls, greaterThan(0));
      expect(paintMap.styleAtViewOffset(0)?.fontStyle, FontStyle.italic);
    });
  });

  group('_italic_', () {
    testWidgets(
        'after space, hidden underscores fold delimiters and inner text paints italic',
        (tester) async {
      const literal = '_italic_ ';
      final controller = HomericEditorController(document: _document(literal));
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

      expect(controller.document.blocks.single.text, literal,
          reason: 'stored source must remain literal markdown');
      expect(_paragraphRender(tester).source.viewText, 'italic ');
      expect(
        paintMap.styleAtViewOffset(0)?.fontStyle,
        FontStyle.italic,
        reason: 'italic inner text must paint italic after hide-on-space',
      );

      paintMap.beginBuild();
      paintMap.paintCalls = 0;
      paintMap.paintedStyles.clear();
      controller.notifyListeners();
      await tester.pump();

      expect(paintMap.paintCalls, greaterThan(0),
          reason: 'paintStyler must run when the resolve map is refilled');
      expect(_paragraphRender(tester).source.viewText, 'italic ',
          reason: 'underscores must stay hidden after hide-on-space rebuild');
      expect(paintMap.styleAtViewOffset(0)?.fontStyle, FontStyle.italic,
          reason: 'italic must survive hide-on-space host rebuilds');
    });

    testWidgets(
        'after hide-on-leave, hidden underscores stay folded at trailing space',
        (tester) async {
      const literal = '_italic_ ';
      final document = _document(literal);
      final controller = HomericEditorController(
        document: document,
        selection:
            HomericSelection.collapsed(document.positionAt(0, literal.length)),
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

      expect(_paragraphRender(tester).source.viewText, 'italic ');
      expect(paintMap.styleAtViewOffset(0)?.fontStyle, FontStyle.italic);

      // Caret enters the mark: reveal-on-touch shows the touched delimiter.
      controller.setSelection(
        HomericSelection.collapsed(document.positionAt(0, 0)),
      );
      paintMap.beginBuild();
      await tester.pump();
      expect(_paragraphRender(tester).source.viewText, isNot('italic '),
          reason: 'caret on a hidden underscore must reveal it');

      // Caret leaves to trailing space: hide-on-leave folds delimiters again.
      controller.setSelection(
        HomericSelection.collapsed(document.positionAt(0, literal.length)),
      );
      paintMap.beginBuild();
      paintMap.paintCalls = 0;
      paintMap.paintedStyles.clear();
      await tester.pump();

      expect(_paragraphRender(tester).source.viewText, 'italic ',
          reason:
              'trailing-space caret must not re-reveal underscores (HOM-35 class)');
      expect(paintMap.paintCalls, greaterThan(0),
          reason: 'paintStyler must run when the resolve map is refilled');
      expect(paintMap.styleAtViewOffset(0)?.fontStyle, FontStyle.italic,
          reason: 'italic must survive hide-on-leave');
    });

    testWidgets(
        'layout-equal source update reshapes paintStyler glyphs for hidden italic',
        (tester) async {
      const literal = '_italic_ ';
      final paintMap = _JournalPaintMap();
      paintMap.beginBuild();
      final source = _italicAfterSpaceSource(paintMap, literal);
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 200,
          child: HomericParagraph(source: source, paintStyler: paintMap.paint),
        ),
      ));
      await tester.pump();
      expect(paintMap.styleAtViewOffset(0)?.fontStyle, FontStyle.italic);

      final render = tester.renderObject<RenderHomericParagraph>(
        find.byType(HomericParagraph),
      );
      paintMap.beginBuild();
      paintMap.paintCalls = 0;
      paintMap.paintedStyles.clear();
      render.source = _italicAfterSpaceSource(paintMap, literal);
      await tester.pump();

      expect(paintMap.paintCalls, greaterThan(0));
      expect(paintMap.styleAtViewOffset(0)?.fontStyle, FontStyle.italic);
    });
  });
}
