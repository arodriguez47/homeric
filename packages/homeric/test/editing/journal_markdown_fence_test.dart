import 'package:flutter/widgets.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

import '../transform/transform_test_utils.dart';

/// Mirrors the journal host contract: literal source, live deriveDecorations,
/// layout-only resolveStyle with a paintStyler side channel, and underlay
/// wash layers for fenced-code chrome.
final class _JournalPaintMap {
  _JournalPaintMap();

  final Map<int, TextStyle> resolved = <int, TextStyle>{};
  int paintCalls = 0;

  static const layoutOnly = TextStyle(fontSize: 14, color: Color(0xFF000000));

  static const markStyles = <String, TextStyle>{
    'code': TextStyle(
      fontSize: 14,
      fontFamily: 'monospace',
      color: Color(0xFF000000),
    ),
  };

  static const codeWash = SolidWashSpec(Color(0x22111111));

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

/// Journal markdown decorations: hide ``` fence lines, paint body as code.
///
/// Opening fence line is ` ```\n `; closing fence line is ` ``` `. Language
/// tags are covered in [journal_markdown_fence_language_test.dart].
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

  for (final match in RegExp(r'```\n([\s\S]*?)\n```').allMatches(text)) {
    hideDelimiter(match.start, match.start + 4);
    hideDelimiter(match.end - 4, match.end);
    styleRange(match.start + 4, match.end - 4, 'code');
  }

  return result;
}

/// Host-owned shaded chrome over the fenced body (same paint-layer path as
/// highlight washes). Homeric never invents this — dropping it on leave is a
/// host miss.
List<PaintLayer> journalMarkdownPaintLayersForBlock(
  Block block,
  Iterable<Decoration> decorations,
) =>
    [
      for (final decoration in decorations)
        if (decoration.spec == 'code')
          PaintLayer(
            range: DocRange(
                DocOffset(decoration.start), DocOffset(decoration.end)),
            band: PaintBand.underlay,
            painter: solidWashPainter,
            spec: _JournalPaintMap.codeWash,
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

void _expectHiddenFenceView(String viewText, {required String body}) {
  expect(viewText, body,
      reason: 'opening/closing fence lines must fold out of view text');
  expect(viewText.contains('```'), isFalse,
      reason: 'fence delimiters must not remain visible');
  expect(viewText.contains('...'), isFalse,
      reason: 'Homeric must not paint ellipsis stand-ins for hidden fences; '
          'that only appears when the host emits ReplacementText("...")');
}

void _expectCodeChrome(RenderHomericParagraph render) {
  expect(render.paintLayers, hasLength(1),
      reason: 'host-emitted code wash must stay after fence leave');
  expect(render.paintLayers.single.band, PaintBand.underlay);
  expect(
    (render.paintLayers.single.spec as SolidWashSpec).color,
    _JournalPaintMap.codeWash.color,
  );
}

/// Multi-line fence with trailing space (newline body, not inline `` `code` ``).
const _fenceLiteral = '```\nfoo\nbar\n``` ';

/// Prose above a fence — leave target for the reader repro (caret above fence).
const _fenceWithLineAbove = 'above\n```\nconst y = 2;\n``` ';

ParagraphSource<TextStyle> _fenceAfterSpaceSource(_JournalPaintMap paintMap) =>
    ParagraphSource.build(
      block: para('b', _fenceLiteral),
      decorations: journalMarkdownDecorationsForBlock(para('b', _fenceLiteral)),
      resolveStyle: paintMap.resolve,
    );

void main() {
  test(
    'substituting fences via ReplacementText("...") paints ellipsis — wrong host path',
    () {
      final block = para('b', '```\nconst y = 2;\n```');
      final wrong = deriveViewText(block, [
        Decoration.replace(
          'b',
          0,
          3,
          replacementLength: 3,
          spec: const ReplacementText('...'),
        ),
        Decoration.replace(
          'b',
          block.text.length - 3,
          block.text.length,
          replacementLength: 3,
          spec: const ReplacementText('...'),
        ),
      ]);
      expect(
        wrong.viewText,
        '...\nconst y = 2;\n...',
        reason: 'a host that replaces fence lines with ReplacementText("...") '
            'paints ellipsis stand-ins — Homeric does not invent that on leave',
      );
      expect(wrong.viewText.contains('...'), isTrue);
    },
  );

  test(
    'markdownMarkHideReplacement folds fence lines to empty — correct host path',
    () {
      final block = para('b', _fenceLiteral);
      final decorations = journalMarkdownDecorationsForBlock(block);
      expect(decorations.where(isMarkdownMarkHideDecoration), hasLength(2),
          reason: 'opening and closing fence hides must be zero-length '
              'markdownMarkHideReplacement');
      for (final hide in decorations.where(isMarkdownMarkHideDecoration)) {
        expect(hide.replacementLength, 0);
      }

      final source = ParagraphSource.build(
        block: block,
        decorations: decorations,
        resolveStyle: (_) => Object(),
      );
      _expectHiddenFenceView(source.viewText, body: 'foo\nbar ');
    },
  );

  testWidgets('after space, hidden fence lines fold and body paints as code',
      (tester) async {
    const literal = _fenceLiteral;
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
    _expectHiddenFenceView(
      _paragraphRender(tester).source.viewText,
      body: 'foo\nbar ',
    );
    expect(
      paintMap.styleAtViewOffset(0)?.fontFamily,
      'monospace',
      reason: 'fence body must paint monospaced after hide-on-space',
    );
    _expectCodeChrome(_paragraphRender(tester));

    paintMap.beginBuild();
    paintMap.paintCalls = 0;
    paintMap.paintedStyles.clear();
    controller.notifyListeners();
    await tester.pump();

    expect(paintMap.paintCalls, greaterThan(0),
        reason: 'paintStyler must run when the resolve map is refilled');
    _expectHiddenFenceView(
      _paragraphRender(tester).source.viewText,
      body: 'foo\nbar ',
    );
    expect(paintMap.styleAtViewOffset(0)?.fontFamily, 'monospace',
        reason: 'monospace must survive hide-on-space host rebuilds');
    _expectCodeChrome(_paragraphRender(tester));
  });

  testWidgets(
      'after hide-on-leave, hidden fence lines stay folded at trailing space',
      (tester) async {
    const literal = _fenceLiteral;
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

    _expectHiddenFenceView(
      _paragraphRender(tester).source.viewText,
      body: 'foo\nbar ',
    );
    expect(paintMap.styleAtViewOffset(0)?.fontFamily, 'monospace');
    _expectCodeChrome(_paragraphRender(tester));

    // Caret enters the opening fence line: reveal-on-touch shows it.
    controller.setSelection(
      HomericSelection.collapsed(document.positionAt(0, 0)),
    );
    paintMap.beginBuild();
    await tester.pump();
    expect(_paragraphRender(tester).source.viewText, isNot('foo\nbar '),
        reason: 'caret on a hidden fence line must reveal it');

    // Caret leaves to trailing space: hide-on-leave folds fence lines again.
    controller.setSelection(
      HomericSelection.collapsed(document.positionAt(0, literal.length)),
    );
    paintMap.beginBuild();
    paintMap.paintCalls = 0;
    paintMap.paintedStyles.clear();
    await tester.pump();

    _expectHiddenFenceView(
      _paragraphRender(tester).source.viewText,
      body: 'foo\nbar ',
    );
    expect(paintMap.paintCalls, greaterThan(0),
        reason: 'paintStyler must run when the resolve map is refilled');
    expect(paintMap.styleAtViewOffset(0)?.fontFamily, 'monospace',
        reason: 'monospace must survive hide-on-leave');
    _expectCodeChrome(_paragraphRender(tester));
  });

  testWidgets(
      'after leave to line above fence, hides stay empty (not ...) and chrome remains',
      (tester) async {
    const literal = _fenceWithLineAbove;
    final document = _document(literal);
    final fenceStart = literal.indexOf('```');
    final controller = HomericEditorController(
      document: document,
      // Start inside the opening fence so leave is observable.
      selection: HomericSelection.collapsed(document.positionAt(0, fenceStart)),
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

    expect(_paragraphRender(tester).source.viewText, contains('```'),
        reason: 'caret on opening fence must reveal delimiters');

    // Reader repro: leave the fence by moving caret to the line above.
    controller.setSelection(
      HomericSelection.collapsed(document.positionAt(0, 0)),
    );
    paintMap.beginBuild();
    paintMap.paintCalls = 0;
    paintMap.paintedStyles.clear();
    await tester.pump();

    _expectHiddenFenceView(
      _paragraphRender(tester).source.viewText,
      body: 'above\nconst y = 2; ',
    );
    expect(paintMap.paintCalls, greaterThan(0));
    expect(
      paintMap.styleAtViewOffset('above\n'.length)?.fontFamily,
      'monospace',
      reason: 'fence body must still paint as code after leave to line above',
    );
    _expectCodeChrome(_paragraphRender(tester));
  });

  testWidgets(
      'layout-equal source update reshapes paintStyler glyphs for hidden fence',
      (tester) async {
    final paintMap = _JournalPaintMap();
    paintMap.beginBuild();
    final source = _fenceAfterSpaceSource(paintMap);
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        width: 200,
        child: HomericParagraph(source: source, paintStyler: paintMap.paint),
      ),
    ));
    await tester.pump();
    expect(paintMap.styleAtViewOffset(0)?.fontFamily, 'monospace');

    final render = tester.renderObject<RenderHomericParagraph>(
      find.byType(HomericParagraph),
    );
    paintMap.beginBuild();
    paintMap.paintCalls = 0;
    paintMap.paintedStyles.clear();
    render.source = _fenceAfterSpaceSource(paintMap);
    await tester.pump();

    expect(paintMap.paintCalls, greaterThan(0));
    expect(paintMap.styleAtViewOffset(0)?.fontFamily, 'monospace');
  });
}
