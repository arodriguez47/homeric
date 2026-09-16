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
    'code': TextStyle(
      fontSize: 14,
      fontFamily: 'monospace',
      color: Color(0xFF000000),
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

/// Journal markdown decorations: hide the whole opening fence line including
/// the language info string (` ```dart\n `), hide the closing fence line, and
/// paint the body as code. Same hide path as bare fences (HOM-40).
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

  // Opening fence line: ``` + optional info string + newline.
  for (final match in RegExp(r'```[^\n]*\n([\s\S]*?)\n```').allMatches(text)) {
    final openingEnd = text.indexOf('\n', match.start) + 1;
    hideDelimiter(match.start, openingEnd);
    hideDelimiter(match.end - 4, match.end);
    styleRange(openingEnd, match.end - 4, 'code');
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

/// Fenced block with language tag and trailing space.
const _fenceLiteral = '```dart\nfoo\nbar\n``` ';

void main() {
  test('host hide covering ```dart\\n folds the language tag from view text',
      () {
    final block = para('b', _fenceLiteral);
    final decorations = journalMarkdownDecorationsForBlock(block);
    final source = ParagraphSource.build(
      block: block,
      decorations: decorations,
      resolveStyle: (_) => Object(),
    );

    expect(block.text, _fenceLiteral,
        reason: 'stored source must remain literal markdown');
    expect(source.viewText, 'foo\nbar ',
        reason: 'language tag must fold with the opening fence line');
    expect(source.viewText.contains('dart'), isFalse);
    expect(source.viewText.contains('```'), isFalse);
  });

  testWidgets(
      'after leave, ```dart language tag hides with fence; body paints as code',
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

    expect(controller.document.blocks.single.text, literal,
        reason: 'stored source must remain literal markdown');
    expect(_paragraphRender(tester).source.viewText, 'foo\nbar ',
        reason: 'opening fence + language tag and closing fence must fold');
    expect(
      paintMap.styleAtViewOffset(0)?.fontFamily,
      'monospace',
      reason: 'fence body must paint monospaced after hide-on-leave',
    );

    // Caret on the language tag: reveal-on-touch shows the opening line.
    controller.setSelection(
      HomericSelection.collapsed(document.positionAt(0, 3)),
    );
    paintMap.beginBuild();
    await tester.pump();
    expect(_paragraphRender(tester).source.viewText, contains('dart'),
        reason: 'caret on the language tag must reveal the opening fence line');

    // Caret leaves to trailing space: hide-on-leave folds tag with fence.
    controller.setSelection(
      HomericSelection.collapsed(document.positionAt(0, literal.length)),
    );
    paintMap.beginBuild();
    paintMap.paintCalls = 0;
    paintMap.paintedStyles.clear();
    await tester.pump();

    expect(_paragraphRender(tester).source.viewText, 'foo\nbar ',
        reason:
            'trailing-space caret must not re-reveal fence or language tag');
    expect(_paragraphRender(tester).source.viewText.contains('dart'), isFalse);
    expect(paintMap.paintCalls, greaterThan(0),
        reason: 'paintStyler must run when the resolve map is refilled');
    expect(paintMap.styleAtViewOffset(0)?.fontFamily, 'monospace',
        reason: 'monospace must survive hide-on-leave with language tag');
  });
}
