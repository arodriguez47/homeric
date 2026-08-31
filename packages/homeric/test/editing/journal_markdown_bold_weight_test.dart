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
    'bold': TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
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
    paintedWeights[segment.viewStart] = style.fontWeight;
    return style;
  }

  final Map<int, FontWeight?> paintedWeights = <int, FontWeight?>{};

  FontWeight? weightAtViewOffset(int offset) => paintedWeights[offset];
}

/// Journal markdown decorations: hide `**` delimiters, paint bold on the inner word.
List<Decoration> journalMarkdownDecorationsForBlock(Block block) {
  final text = block.text;
  final result = <Decoration>[];

  void hideDelimiter(int start, int end) {
    result.add(
      Decoration.replace(
        block.id,
        start,
        end,
        replacementLength: 0,
        spec: 'hide',
      ),
    );
  }

  void styleRange(int start, int end, String spec) {
    if (end > start) {
      result.add(Decoration.inline(block.id, start, end, spec: spec));
    }
  }

  for (final match in RegExp(r'\*\*(.+?)\*\*').allMatches(text)) {
    hideDelimiter(match.start, match.start + 2);
    hideDelimiter(match.end - 2, match.end);
    styleRange(match.start + 2, match.end - 2, 'bold');
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

ParagraphSource<TextStyle> _boldAfterSpaceSource(_JournalPaintMap paintMap) =>
    ParagraphSource.build(
      block: para('b', '**bold** '),
      decorations: journalMarkdownDecorationsForBlock(para('b', '**bold** ')),
      resolveStyle: paintMap.resolve,
    );

void main() {
  testWidgets(
    'after space, hidden ** still paints bold weight via paintStyler',
    (tester) async {
      final controller = HomericEditorController(
        document: _document('**bold** '),
      );
      final session = HomericTextInputSession(controller: controller);
      final paintMap = _JournalPaintMap();
      addTearDown(session.dispose);
      addTearDown(controller.dispose);

      paintMap.beginBuild();
      await tester.pumpWidget(
        _documentHarness(
          controller: controller,
          session: session,
          paintMap: paintMap,
        ),
      );
      await tester.pump();

      expect(_paragraphRender(tester).source.viewText, 'bold ');
      expect(paintMap.weightAtViewOffset(0), FontWeight.w700);

      paintMap.beginBuild();
      paintMap.paintCalls = 0;
      paintMap.paintedWeights.clear();
      controller.notifyListeners();
      await tester.pump();

      expect(
        paintMap.paintCalls,
        greaterThan(0),
        reason: 'paintStyler must run when the resolve map is refilled',
      );
      expect(
        paintMap.weightAtViewOffset(0),
        FontWeight.w700,
        reason: 'bold weight must survive hide-on-space host rebuilds',
      );
    },
  );

  testWidgets(
    'after hide-on-leave, hidden ** still paints bold weight via paintStyler',
    (tester) async {
      final document = _document('**bold** ');
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(document.positionAt(0, 9)),
      );
      final session = HomericTextInputSession(controller: controller);
      final paintMap = _JournalPaintMap();
      addTearDown(session.dispose);
      addTearDown(controller.dispose);

      paintMap.beginBuild();
      await tester.pumpWidget(
        _documentHarness(
          controller: controller,
          session: session,
          paintMap: paintMap,
        ),
      );
      await tester.pump();

      final render = _paragraphRender(tester);
      expect(render.source.viewText, 'bold ');
      expect(paintMap.weightAtViewOffset(0), FontWeight.w700);

      // Caret enters the mark: reveal-on-touch shows the touched delimiter.
      controller.setSelection(
        HomericSelection.collapsed(document.positionAt(0, 1)),
      );
      paintMap.beginBuild();
      await tester.pump();
      expect(
        _paragraphRender(tester).source.viewText,
        isNot('bold '),
        reason: 'caret on a hidden delimiter must reveal it',
      );

      // Caret leaves the mark: hide-on-leave folds delimiters again.
      controller.setSelection(
        HomericSelection.collapsed(document.positionAt(0, 9)),
      );
      paintMap.beginBuild();
      paintMap.paintCalls = 0;
      paintMap.paintedWeights.clear();
      await tester.pump();

      expect(
        _paragraphRender(tester).source.viewText,
        'bold ',
        reason: 'hide-on-leave must fold delimiters back out of view text',
      );
      expect(
        paintMap.paintCalls,
        greaterThan(0),
        reason: 'paintStyler must run when the resolve map is refilled',
      );
      expect(
        paintMap.weightAtViewOffset(0),
        FontWeight.w700,
        reason: 'bold weight must survive hide-on-leave',
      );
    },
  );

  testWidgets(
    'layout-equal source update reshapes paintStyler glyphs for hidden bold',
    (tester) async {
      final paintMap = _JournalPaintMap();
      paintMap.beginBuild();
      final source = _boldAfterSpaceSource(paintMap);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 200,
            child: HomericParagraph(
              source: source,
              paintStyler: paintMap.paint,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(paintMap.weightAtViewOffset(0), FontWeight.w700);

      final render = tester.renderObject<RenderHomericParagraph>(
        find.byType(HomericParagraph),
      );
      paintMap.beginBuild();
      paintMap.paintCalls = 0;
      paintMap.paintedWeights.clear();
      render.source = _boldAfterSpaceSource(paintMap);
      await tester.pump();

      expect(paintMap.paintCalls, greaterThan(0));
      expect(paintMap.weightAtViewOffset(0), FontWeight.w700);
    },
  );
}
