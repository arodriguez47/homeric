import 'package:flutter/widgets.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

import '../transform/transform_test_utils.dart';

/// Mirrors the journal host contract: literal source, live deriveDecorations,
/// layout-only resolveStyle with a paintStyler side channel, and paint layers
/// for highlight background.
final class _JournalPaintMap {
  _JournalPaintMap();

  final Map<int, TextStyle> resolved = <int, TextStyle>{};
  int paintCalls = 0;

  static const layoutOnly = TextStyle(fontSize: 14, color: Color(0xFF000000));

  static const markStyles = <String, TextStyle>{
    'heading1': TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
    'heading2': TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
    'heading3': TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
    'highlight': TextStyle(fontSize: 14, color: Color(0xFF000000)),
    'comment': TextStyle(fontSize: 14, color: Color(0xFF888888)),
  };

  static const highlightWash = SolidWashSpec(Color(0x33FFFF00));

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

/// Journal markdown decorations: hide ATX `#`, `==`, and `++` delimiters.
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

  final headingMatch = RegExp(r'^(#{1,6}) ').firstMatch(text);
  if (headingMatch != null) {
    final level = headingMatch.group(1)!.length;
    hideDelimiter(0, headingMatch.end);
    styleRange(headingMatch.end, text.length, 'heading$level');
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

List<PaintLayer> journalMarkdownPaintLayersForBlock(
  Block block,
  Iterable<Decoration> decorations,
) =>
    [
      for (final decoration in decorations)
        if (decoration.spec == 'highlight')
          PaintLayer(
            range: DocRange(
                DocOffset(decoration.start), DocOffset(decoration.end)),
            band: PaintBand.underlay,
            painter: solidWashPainter,
            spec: _JournalPaintMap.highlightWash,
          ),
    ];

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
                    derivePaintLayers: journalMarkdownPaintLayersForBlock,
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
  test(
    'substituting <comment> via ReplacementContent paints the tag — wrong host path',
    () {
      final block = para('b', '++comment++');
      final wrong = deriveViewText(block, [
        Decoration.replace(
          'b',
          0,
          11,
          replacementLength: 9,
          spec: const ReplacementText('<comment>'),
        ),
      ]);
      expect(
        wrong.viewText,
        '<comment>',
        reason: 'a host that replaces the span with ReplacementText paints '
            'the tag — Homeric does not rewrite ++ to <comment> on its own',
      );
    },
  );

  testWidgets('after space, hidden ATX # still paints heading weight/size', (
    tester,
  ) async {
    final controller = HomericEditorController(
      document: _document('# Heading '),
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

    expect(_paragraphRender(tester).source.viewText, 'Heading ');
    expect(paintMap.styleAtViewOffset(0)?.fontWeight, FontWeight.w700);
    expect(paintMap.styleAtViewOffset(0)?.fontSize, 28);

    paintMap.beginBuild();
    paintMap.paintCalls = 0;
    paintMap.paintedStyles.clear();
    controller.notifyListeners();
    await tester.pump();

    expect(
      paintMap.paintCalls,
      greaterThan(0),
      reason: 'paintStyler must run when the resolve map is refilled',
    );
    expect(
      paintMap.styleAtViewOffset(0)?.fontWeight,
      FontWeight.w700,
      reason: 'heading weight must survive hide-on-space host rebuilds',
    );
    expect(paintMap.styleAtViewOffset(0)?.fontSize, 28);
  });

  testWidgets(
    'after hide-on-leave, hidden ATX # still paints heading weight/size',
    (tester) async {
      final document = _document('## Subheading ');
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(document.positionAt(0, 12)),
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

      expect(_paragraphRender(tester).source.viewText, 'Subheading ');
      expect(paintMap.styleAtViewOffset(0)?.fontWeight, FontWeight.w700);
      expect(paintMap.styleAtViewOffset(0)?.fontSize, 24);

      // Caret enters the mark: reveal-on-touch shows the touched delimiter.
      controller.setSelection(
        HomericSelection.collapsed(document.positionAt(0, 1)),
      );
      paintMap.beginBuild();
      await tester.pump();
      expect(
        _paragraphRender(tester).source.viewText,
        isNot('Subheading '),
        reason: 'caret on a hidden delimiter must reveal it',
      );

      // Caret leaves the mark: hide-on-leave folds delimiters again.
      controller.setSelection(
        HomericSelection.collapsed(document.positionAt(0, 12)),
      );
      paintMap.beginBuild();
      paintMap.paintCalls = 0;
      paintMap.paintedStyles.clear();
      await tester.pump();

      expect(
        _paragraphRender(tester).source.viewText,
        'Subheading ',
        reason: 'hide-on-leave must fold delimiters back out of view text',
      );
      expect(paintMap.paintCalls, greaterThan(0));
      expect(paintMap.styleAtViewOffset(0)?.fontWeight, FontWeight.w700);
      expect(paintMap.styleAtViewOffset(0)?.fontSize, 24);
    },
  );

  testWidgets('after space, hidden == still paints highlight underlay', (
    tester,
  ) async {
    final controller = HomericEditorController(
      document: _document('==marked== '),
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
    expect(render.source.viewText, 'marked ');
    expect(render.paintLayers, hasLength(1));
    expect(
      (render.paintLayers.single.spec as SolidWashSpec).color,
      const Color(0x33FFFF00),
    );

    paintMap.beginBuild();
    controller.notifyListeners();
    await tester.pump();

    expect(_paragraphRender(tester).source.viewText, 'marked ');
    expect(_paragraphRender(tester).paintLayers, hasLength(1));
    expect(
      (_paragraphRender(tester).paintLayers.single.spec as SolidWashSpec).color,
      const Color(0x33FFFF00),
      reason: 'highlight underlay must survive hide-on-space host rebuilds',
    );
  });

  testWidgets(
    'after hide-on-leave, hidden == still paints highlight underlay',
    (tester) async {
      final document = _document('==marked== ');
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(document.positionAt(0, 11)),
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

      expect(_paragraphRender(tester).source.viewText, 'marked ');

      controller.setSelection(
        HomericSelection.collapsed(document.positionAt(0, 1)),
      );
      paintMap.beginBuild();
      await tester.pump();
      expect(
        _paragraphRender(tester).source.viewText,
        isNot('marked '),
        reason: 'caret on a hidden delimiter must reveal it',
      );

      // Caret leaves the mark: hide-on-leave folds delimiters again.
      controller.setSelection(
        HomericSelection.collapsed(document.positionAt(0, 11)),
      );
      paintMap.beginBuild();
      await tester.pump();

      expect(_paragraphRender(tester).source.viewText, 'marked ');
      expect(_paragraphRender(tester).paintLayers, hasLength(1));
      expect(
        (_paragraphRender(tester).paintLayers.single.spec as SolidWashSpec)
            .color,
        const Color(0x33FFFF00),
        reason: 'highlight underlay must survive hide-on-leave',
      );
    },
  );

  testWidgets(
    'after space, hidden ++ still paints comment style and keeps source',
    (tester) async {
      const literal = '++comment++ ';
      final controller = HomericEditorController(document: _document(literal));
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
      expect(
        controller.document.blocks.single.text,
        literal,
        reason: 'stored source must remain ++comment++, never rewritten',
      );
      expect(render.source.viewText, 'comment ');
      expect(
        render.source.viewText,
        isNot(contains('<comment>')),
        reason: 'hide-delimiter live preview must never paint XML-like tags',
      );
      expect(paintMap.styleAtViewOffset(0)?.color, const Color(0xFF888888));

      paintMap.beginBuild();
      paintMap.paintCalls = 0;
      paintMap.paintedStyles.clear();
      controller.notifyListeners();
      await tester.pump();

      expect(paintMap.paintCalls, greaterThan(0));
      expect(
        paintMap.styleAtViewOffset(0)?.color,
        const Color(0xFF888888),
        reason: 'comment style must survive hide-on-space host rebuilds',
      );
    },
  );

  testWidgets(
    'after hide-on-leave, hidden ++ still paints comment style and reveals on caret',
    (tester) async {
      const literal = '++comment++ ';
      final document = _document(literal);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(document.positionAt(0, 12)),
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

      expect(_paragraphRender(tester).source.viewText, 'comment ');
      expect(controller.document.blocks.single.text, literal);

      controller.setSelection(
        HomericSelection.collapsed(document.positionAt(0, 1)),
      );
      paintMap.beginBuild();
      await tester.pump();
      expect(
        _paragraphRender(tester).source.viewText,
        isNot('comment '),
        reason: 'caret on a hidden ++ delimiter must reveal it',
      );

      controller.setSelection(
        HomericSelection.collapsed(document.positionAt(0, 12)),
      );
      paintMap.beginBuild();
      paintMap.paintCalls = 0;
      paintMap.paintedStyles.clear();
      await tester.pump();

      expect(
        _paragraphRender(tester).source.viewText,
        'comment ',
        reason: 'hide-on-leave must fold ++ delimiters back out of view text',
      );
      expect(
        _paragraphRender(tester).source.viewText,
        isNot(contains('<comment>')),
      );
      expect(paintMap.paintCalls, greaterThan(0));
      expect(paintMap.styleAtViewOffset(0)?.color, const Color(0xFF888888));
    },
  );
}
