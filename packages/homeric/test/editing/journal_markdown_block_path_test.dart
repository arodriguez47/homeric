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
  TextStyle boldStyle = markStyles['bold']!;

  static const layoutOnly = TextStyle(fontSize: 14, color: Color(0xFF000000));

  static const markStyles = <String, TextStyle>{
    'bold': TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
    'italic': TextStyle(fontSize: 14, fontStyle: FontStyle.italic),
    'code': TextStyle(fontSize: 14, fontFamily: 'monospace'),
    'strike': TextStyle(fontSize: 14, decoration: TextDecoration.lineThrough),
    'link': TextStyle(fontSize: 14, color: Color(0xFF0000FF)),
  };

  void beginBuild() => resolved.clear();

  TextStyle resolve(RunStyleContext run) {
    var style = layoutOnly;
    for (final decoration in run.decorations) {
      final mark =
          decoration.spec == 'bold' ? boldStyle : markStyles[decoration.spec];
      if (mark != null) style = mark;
    }
    resolved[run.viewStart] = style;
    return layoutOnly;
  }

  TextStyle paint(TextSegment<TextStyle> segment) {
    paintCalls += 1;
    final style = resolved[segment.viewStart] ?? segment.style;
    lastPaintedWeight = style.fontWeight;
    lastPaintedStyle = style.fontStyle;
    return style;
  }

  FontWeight? lastPaintedWeight;
  FontStyle? lastPaintedStyle;
}

/// Journal markdown decorations: hide `**`/`*` delimiters, style all five marks.
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

  for (final match in RegExp(
    r'(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)',
  ).allMatches(text)) {
    hideDelimiter(match.start, match.start + 1);
    hideDelimiter(match.end - 1, match.end);
    styleRange(match.start + 1, match.end - 1, 'italic');
  }

  for (final match in RegExp(r'`([^`]+)`').allMatches(text)) {
    styleRange(match.start, match.end, 'code');
  }

  for (final match in RegExp(r'~~(.+?)~~').allMatches(text)) {
    styleRange(match.start, match.end, 'strike');
  }

  for (final match in RegExp(r'\[([^\]]+)\]\(([^)]+)\)').allMatches(text)) {
    styleRange(match.start, match.end, 'link');
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
    _withOverlay(
      SizedBox(
        width: 320,
        child: HomericEditableDocument.builder(
          controller: controller,
          inputSession: session,
          cacheExtent: 0,
          estimatedBlockHeight: 44,
          blockBuilder: (context, block, focusNode) => HomericEditableParagraph(
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
    );

Widget _withOverlay(Widget child) => Directionality(
      textDirection: TextDirection.ltr,
      child: Localizations(
        locale: const Locale('en'),
        delegates: const <LocalizationsDelegate<dynamic>>[
          DefaultWidgetsLocalizations.delegate,
        ],
        child: Overlay(
          initialEntries: <OverlayEntry>[OverlayEntry(builder: (_) => child)],
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

Future<void> _pumpDocument(
  WidgetTester tester, {
  required HomericEditorController controller,
  required HomericTextInputSession session,
  required _JournalPaintMap paintMap,
}) async {
  paintMap.beginBuild();
  await tester.pumpWidget(
    _documentHarness(
      controller: controller,
      session: session,
      paintMap: paintMap,
    ),
  );
  await tester.pump();
}

ParagraphSource<TextStyle> _boldSource(_JournalPaintMap paintMap) =>
    ParagraphSource.build(
      block: para('b', '**bold**'),
      decorations: journalMarkdownDecorationsForBlock(para('b', '**bold**')),
      resolveStyle: paintMap.resolve,
    );

void main() {
  testWidgets('deriveDecorations hides bold/italic delimiters in view text', (
    tester,
  ) async {
    final controller = HomericEditorController(
      document: _document('**bold** and *italic*'),
    );
    final session = HomericTextInputSession(controller: controller);
    final paintMap = _JournalPaintMap();
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    await _pumpDocument(
      tester,
      controller: controller,
      session: session,
      paintMap: paintMap,
    );

    expect(_paragraphRender(tester).source.viewText, 'bold and italic');
  });

  testWidgets('deriveDecorations keeps code/strike/link delimiters visible', (
    tester,
  ) async {
    final controller = HomericEditorController(
      document: _document('`code` ~~strike~~ [label](https://x.test)'),
    );
    final session = HomericTextInputSession(controller: controller);
    final paintMap = _JournalPaintMap();
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    await _pumpDocument(
      tester,
      controller: controller,
      session: session,
      paintMap: paintMap,
    );

    expect(
      _paragraphRender(tester).source.viewText,
      '`code` ~~strike~~ [label](https://x.test)',
    );
  });

  testWidgets(
    'layout-equal source samples unchanged paintStyler without relayout',
    (tester) async {
      final paintMap = _JournalPaintMap();
      paintMap.beginBuild();
      final source = _boldSource(paintMap);
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
      expect(paintMap.lastPaintedWeight, FontWeight.w700);

      final render = tester.renderObject<RenderHomericParagraph>(
        find.byType(HomericParagraph),
      );
      final generation = render.layoutGeneration;
      paintMap.beginBuild();
      paintMap.paintCalls = 0;
      paintMap.lastPaintedWeight = null;
      render.source = _boldSource(paintMap);
      await tester.pump();

      expect(paintMap.paintCalls, greaterThan(0));
      expect(paintMap.lastPaintedWeight, FontWeight.w700);
      expect(
        render.layoutGeneration,
        generation,
        reason: 'an unchanged style refresh must not schedule layout',
      );

      await tester.pump();
      expect(
        render.layoutGeneration,
        generation,
        reason: 'the unchanged style refresh must not leave a layout loop',
      );
    },
  );

  testWidgets(
    'layout-equal source relayouts once when side-channel metrics change',
    (tester) async {
      final paintMap = _JournalPaintMap();
      paintMap.beginBuild();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 200,
            child: HomericParagraph(
              source: _boldSource(paintMap),
              paintStyler: paintMap.paint,
            ),
          ),
        ),
      );
      await tester.pump();

      final render = tester.renderObject<RenderHomericParagraph>(
        find.byType(HomericParagraph),
      );
      final generation = render.layoutGeneration;
      final height = render.layoutParagraph.height;

      paintMap.boldStyle = const TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w700,
      );
      paintMap.beginBuild();
      render.source = _boldSource(paintMap);
      await tester.pump();

      expect(render.layoutGeneration, generation + 1);
      expect(render.layoutParagraph.height, greaterThan(height));

      await tester.pump();
      expect(
        render.layoutGeneration,
        generation + 1,
        reason:
            'the refreshed style snapshot must stop the layout feedback loop',
      );
    },
  );

  testWidgets(
    'layout-equal controller notify still paints journal mark styles via paintStyler',
    (tester) async {
      final controller = HomericEditorController(
        document: _document('**bold**'),
      );
      final session = HomericTextInputSession(controller: controller);
      final paintMap = _JournalPaintMap();
      addTearDown(session.dispose);
      addTearDown(controller.dispose);

      await _pumpDocument(
        tester,
        controller: controller,
        session: session,
        paintMap: paintMap,
      );

      expect(_paragraphRender(tester).source.viewText, 'bold');
      expect(paintMap.lastPaintedWeight, FontWeight.w700);
      final generation = _paragraphRender(tester).layoutGeneration;

      paintMap.paintCalls = 0;
      paintMap.lastPaintedWeight = null;
      paintMap.beginBuild();
      controller.notifyListeners();
      await tester.pump();

      expect(
        paintMap.paintCalls,
        greaterThan(0),
        reason: 'paintStyler must run when the resolve map is refilled',
      );
      expect(
        paintMap.lastPaintedWeight,
        FontWeight.w700,
        reason: 'bold weight must paint after a layout-equal source update',
      );
      expect(_paragraphRender(tester).layoutGeneration, generation);

      await tester.pump();
      expect(
        _paragraphRender(tester).layoutGeneration,
        generation,
        reason: 'the document geometry callback must not restart layout',
      );
    },
  );
}
