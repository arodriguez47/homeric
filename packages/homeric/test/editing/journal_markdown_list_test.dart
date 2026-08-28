import 'package:flutter/services.dart';
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
    'listItem': TextStyle(fontSize: 14, color: Color(0xFF000000)),
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

/// HOM-36 host path: zero-length hide folds the markdown chrome out of view.
///
/// Hides `[markerStart, prefixEnd)` only — leading indent stays. Leaves no
/// visible list mark; see [journalMarkdownListVisibleMarkDecorations] for the
/// HOM-43 host contract.
List<Decoration> journalMarkdownDecorationsForBlock(Block block) {
  final text = block.text;
  final match = HomericMarkdownListPrefix.match(text);
  if (match == null) return const <Decoration>[];

  return <Decoration>[
    markdownMarkHideReplacement(block.id, match.markerStart, match.prefixEnd),
    if (match.prefixEnd < text.length)
      Decoration.inline(
        block.id,
        match.prefixEnd,
        text.length,
        spec: 'listItem',
      ),
  ];
}

/// HOM-43 host path: replace the markdown marker with a visible mark.
///
/// Replaces `[markerStart, markerEnd)` only so leading indent and the space
/// after the mark stay in view (`• item` / `  • item`).
List<Decoration> journalMarkdownListVisibleMarkDecorations(Block block) {
  final text = block.text;
  final match = HomericMarkdownListPrefix.match(text);
  if (match == null) return const <Decoration>[];

  return <Decoration>[
    Decoration.replace(
      block.id,
      match.markerStart,
      match.markerEnd,
      replacementLength: match.visibleMark.length,
      spec: ReplacementText(match.visibleMark),
    ),
    if (match.prefixEnd < text.length)
      Decoration.inline(
        block.id,
        match.prefixEnd,
        text.length,
        spec: 'listItem',
      ),
  ];
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
  List<Decoration> Function(Block block) deriveDecorations =
      journalMarkdownDecorationsForBlock,
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
                    deriveDecorations: deriveDecorations,
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

ParagraphSource<TextStyle> _bulletAfterSpaceSource(_JournalPaintMap paintMap) =>
    ParagraphSource.build(
      block: para('b', '- item '),
      decorations: journalMarkdownDecorationsForBlock(para('b', '- item ')),
      resolveStyle: paintMap.resolve,
    );

void main() {
  testWidgets('after space, hidden bullet marker folds prefix out of view text',
      (tester) async {
    const literal = '- item ';
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
    expect(_paragraphRender(tester).source.viewText, 'item ');
    expect(paintMap.styleAtViewOffset(0), isNotNull,
        reason: 'list body must still paint via inline style after hide');

    paintMap.beginBuild();
    paintMap.paintCalls = 0;
    paintMap.paintedStyles.clear();
    controller.notifyListeners();
    await tester.pump();

    expect(paintMap.paintCalls, greaterThan(0),
        reason: 'paintStyler must run when the resolve map is refilled');
    expect(_paragraphRender(tester).source.viewText, 'item ',
        reason: 'bullet prefix must stay hidden after hide-on-space rebuild');
  });

  testWidgets(
      'after hide-on-leave, hidden bullet marker stays folded at trailing space',
      (tester) async {
    const literal = '- item ';
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

    expect(_paragraphRender(tester).source.viewText, 'item ');

    // Caret enters the marker: reveal-on-touch shows the hidden prefix.
    controller.setSelection(
      HomericSelection.collapsed(document.positionAt(0, 0)),
    );
    paintMap.beginBuild();
    await tester.pump();
    expect(_paragraphRender(tester).source.viewText, isNot('item '),
        reason: 'caret on a hidden list marker must reveal it');

    // Caret leaves to trailing space: hide-on-leave folds the marker again.
    controller.setSelection(
      HomericSelection.collapsed(document.positionAt(0, literal.length)),
    );
    paintMap.beginBuild();
    paintMap.paintCalls = 0;
    paintMap.paintedStyles.clear();
    await tester.pump();

    expect(_paragraphRender(tester).source.viewText, 'item ',
        reason:
            'trailing-space caret must not re-reveal the bullet marker (HOM-35 class)');
    expect(paintMap.paintCalls, greaterThan(0));
    expect(paintMap.styleAtViewOffset(0), isNotNull,
        reason: 'list body style must survive hide-on-leave');
  });

  testWidgets(
      'after space, hidden ordered marker folds prefix out of view text',
      (tester) async {
    const literal = '1. item ';
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

    expect(controller.document.blocks.single.text, literal);
    expect(_paragraphRender(tester).source.viewText, 'item ');
    expect(paintMap.styleAtViewOffset(0), isNotNull);

    paintMap.beginBuild();
    paintMap.paintCalls = 0;
    paintMap.paintedStyles.clear();
    controller.notifyListeners();
    await tester.pump();

    expect(paintMap.paintCalls, greaterThan(0));
    expect(_paragraphRender(tester).source.viewText, 'item ',
        reason: 'ordered prefix must stay hidden after hide-on-space rebuild');
  });

  testWidgets(
      'after hide-on-leave, hidden ordered marker stays folded at trailing space',
      (tester) async {
    const literal = '1. item ';
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

    expect(_paragraphRender(tester).source.viewText, 'item ');

    controller.setSelection(
      HomericSelection.collapsed(document.positionAt(0, 1)),
    );
    paintMap.beginBuild();
    await tester.pump();
    expect(_paragraphRender(tester).source.viewText, isNot('item '),
        reason: 'caret on a hidden ordered marker must reveal it');

    controller.setSelection(
      HomericSelection.collapsed(document.positionAt(0, literal.length)),
    );
    paintMap.beginBuild();
    paintMap.paintCalls = 0;
    paintMap.paintedStyles.clear();
    await tester.pump();

    expect(_paragraphRender(tester).source.viewText, 'item ',
        reason:
            'trailing-space caret must not re-reveal the ordered marker (HOM-35 class)');
    expect(paintMap.paintCalls, greaterThan(0));
    expect(paintMap.styleAtViewOffset(0), isNotNull);
  });

  testWidgets('* marker uses the same hide path as -', (tester) async {
    const literal = '* item ';
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

    expect(_paragraphRender(tester).source.viewText, 'item ');
    expect(paintMap.styleAtViewOffset(0), isNotNull);
  });

  testWidgets(
      'Tab nests list item; Shift+Tab outdents; trailing space stays clean',
      (tester) async {
    const literal = '- item ';
    final document = _document(literal);
    final controller = HomericEditorController(
      document: document,
      selection:
          HomericSelection.collapsed(document.positionAt(0, literal.length)),
    );
    final session = HomericTextInputSession(controller: controller);
    final paintMap = _JournalPaintMap();
    final before = FocusNode();
    FocusNode? editorFocus;
    addTearDown(before.dispose);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    paintMap.beginBuild();
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Localizations(
        locale: const Locale('en'),
        delegates: const <LocalizationsDelegate<dynamic>>[
          DefaultWidgetsLocalizations.delegate,
        ],
        child: Overlay(
          initialEntries: <OverlayEntry>[
            OverlayEntry(
              builder: (_) => Column(
                children: [
                  Focus(
                    focusNode: before,
                    child: const SizedBox(width: 1, height: 1),
                  ),
                  SizedBox(
                    width: 320,
                    height: 120,
                    child: HomericEditableDocument.builder(
                      controller: controller,
                      inputSession: session,
                      cacheExtent: 0,
                      estimatedBlockHeight: 44,
                      blockBuilder: (context, block, focusNode) {
                        editorFocus = focusNode;
                        return HomericEditableParagraph(
                          controller: controller,
                          inputSession: session,
                          blockId: block.id,
                          focusNode: focusNode,
                          deriveDecorations: journalMarkdownDecorationsForBlock,
                          resolveStyle: paintMap.resolve,
                          paintStyler: paintMap.paint,
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ));
    await tester.pump();
    expect(editorFocus, isNotNull);
    editorFocus!.requestFocus();
    await tester.pump();
    controller.setSelection(
      HomericSelection.collapsed(
        controller.document.positionAt(0, literal.length),
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(controller.document.blocks.single.text, '  - item ',
        reason: 'Tab must nest via leading indent, not insert a tab char');
    expect(controller.selection!.isCollapsed, isTrue);
    expect(
      controller.blockOffsetForGlobalPosition(
        'b',
        controller.selection!.anchor,
      ),
      '  - item '.length,
      reason: 'trailing-space caret must track the nest delta',
    );
    paintMap.beginBuild();
    await tester.pump();
    expect(_paragraphRender(tester).source.viewText, '  item ',
        reason: 'nested marker folds; leading indent stays in view');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(controller.document.blocks.single.text, '- item ');
    expect(
      controller.blockOffsetForGlobalPosition(
        'b',
        controller.selection!.anchor,
      ),
      literal.length,
    );
    expect(before.hasFocus, isFalse,
        reason: 'outdent claims Shift+Tab when an indent level exists');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(controller.document.blocks.single.text, '- item ',
        reason: 'unindented list falls through to focus traversal');
    expect(before.hasFocus, isTrue);
  });

  testWidgets(
      'layout-equal source update reshapes paintStyler glyphs for hidden bullet',
      (tester) async {
    final paintMap = _JournalPaintMap();
    paintMap.beginBuild();
    final source = _bulletAfterSpaceSource(paintMap);
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        width: 200,
        child: HomericParagraph(source: source, paintStyler: paintMap.paint),
      ),
    ));
    await tester.pump();
    expect(paintMap.styleAtViewOffset(0), isNotNull);

    final render = tester.renderObject<RenderHomericParagraph>(
      find.byType(HomericParagraph),
    );
    paintMap.beginBuild();
    paintMap.paintCalls = 0;
    paintMap.paintedStyles.clear();
    render.source = _bulletAfterSpaceSource(paintMap);
    await tester.pump();

    expect(paintMap.paintCalls, greaterThan(0));
    expect(paintMap.styleAtViewOffset(0), isNotNull);
  });

  group('HOM-43 visible list mark via ReplacementContent', () {
    test('zero-length hide leaves no viewport mark; ReplacementText does', () {
      final block = para('b', '- item ');
      final emptyHide = deriveViewText(
        block,
        journalMarkdownDecorationsForBlock(block),
      );
      expect(emptyHide.viewText, 'item ',
          reason: 'HOM-36 empty hide folds the marker+space to nothing');

      final visible = deriveViewText(
        block,
        journalMarkdownListVisibleMarkDecorations(block),
      );
      expect(visible.viewText, '• item ',
          reason: 'host-emitted • keeps the space after the mark');

      final ordered = para('b', '1. item ');
      final orderedVisible = deriveViewText(
        ordered,
        journalMarkdownListVisibleMarkDecorations(ordered),
      );
      expect(orderedVisible.viewText, '1. item ',
          reason: 'host-emitted 1. keeps the space after the mark');
    });

    test('indented nested lines keep indent and paint • / N.', () {
      final nested = para('b', '  - item ');
      final match = HomericMarkdownListPrefix.match(nested.text);
      expect(match, isNotNull);
      expect(match!.indentLength, 2);
      expect(match.markerStart, 2);
      expect(match.markerEnd, 3);
      expect(match.prefixEnd, 4);

      final column0Only = RegExp(r'^[-*] ').firstMatch(nested.text);
      expect(column0Only, isNull,
          reason: 'adversary: column-0-only regex misses nested Tab indent');

      final hideNested = deriveViewText(
        nested,
        journalMarkdownDecorationsForBlock(nested),
      );
      expect(hideNested.viewText, '  item ',
          reason: 'empty hide must not fold the leading indent');

      final visible = deriveViewText(
        nested,
        journalMarkdownListVisibleMarkDecorations(nested),
      );
      expect(visible.viewText, '  • item ',
          reason: 'nested indent stays; • replaces only the dash');
      expect(visible.viewText.contains('-'), isFalse,
          reason: 'literal dash must not remain on screen after leave');

      final nestedOrdered = para('b', '  1. item ');
      final orderedVisible = deriveViewText(
        nestedOrdered,
        journalMarkdownListVisibleMarkDecorations(nestedOrdered),
      );
      expect(orderedVisible.viewText, '  1. item ');
    });

    testWidgets('after Tab nest and leave, • stays visible; dash does not',
        (tester) async {
      const literal = '- item ';
      final document = _document(literal);
      final controller = HomericEditorController(
        document: document,
        selection:
            HomericSelection.collapsed(document.positionAt(0, literal.length)),
      );
      final session = HomericTextInputSession(controller: controller);
      final paintMap = _JournalPaintMap();
      FocusNode? editorFocus;
      addTearDown(session.dispose);
      addTearDown(controller.dispose);

      paintMap.beginBuild();
      await tester.pumpWidget(Directionality(
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
                  height: 120,
                  child: HomericEditableDocument.builder(
                    controller: controller,
                    inputSession: session,
                    cacheExtent: 0,
                    estimatedBlockHeight: 44,
                    blockBuilder: (context, block, focusNode) {
                      editorFocus = focusNode;
                      return HomericEditableParagraph(
                        controller: controller,
                        inputSession: session,
                        blockId: block.id,
                        focusNode: focusNode,
                        deriveDecorations:
                            journalMarkdownListVisibleMarkDecorations,
                        resolveStyle: paintMap.resolve,
                        paintStyler: paintMap.paint,
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ));
      await tester.pump();
      editorFocus!.requestFocus();
      await tester.pump();
      controller.setSelection(
        HomericSelection.collapsed(
          controller.document.positionAt(0, literal.length),
        ),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      expect(controller.document.blocks.single.text, '  - item ');
      paintMap.beginBuild();
      await tester.pump();
      expect(_paragraphRender(tester).source.viewText, '  • item ',
          reason: 'after Tab nest + leave, indent stays and • replaces dash');
      expect(_paragraphRender(tester).source.viewText.contains('-'), isFalse);

      controller.setSelection(
        HomericSelection.collapsed(controller.document.positionAt(0, 2)),
      );
      paintMap.beginBuild();
      await tester.pump();
      expect(_paragraphRender(tester).source.viewText, '  - item ',
          reason: 'caret on the nested marker reveals literal indent+marker');

      controller.setSelection(
        HomericSelection.collapsed(
          controller.document.positionAt(0, '  - item '.length),
        ),
      );
      paintMap.beginBuild();
      await tester.pump();
      expect(_paragraphRender(tester).source.viewText, '  • item ',
          reason: 'trailing-space caret stays clean on nested list');
    });

    testWidgets(
        'after leave, • stays visible; trailing-space caret stays clean',
        (tester) async {
      const literal = '- item ';
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
        deriveDecorations: journalMarkdownListVisibleMarkDecorations,
      ));
      await tester.pump();

      expect(controller.document.blocks.single.text, literal,
          reason: 'stored source must remain literal markdown');
      expect(_paragraphRender(tester).source.viewText, '• item ',
          reason: 'after leave, a visible bullet replaces the hidden - ');
      expect(paintMap.styleAtViewOffset(2), isNotNull,
          reason: 'list body still paints via inline listItem style');

      controller.setSelection(
        HomericSelection.collapsed(document.positionAt(0, 0)),
      );
      paintMap.beginBuild();
      await tester.pump();
      expect(_paragraphRender(tester).source.viewText, literal,
          reason: 'caret on the prefix reveals literal markdown');

      controller.setSelection(
        HomericSelection.collapsed(document.positionAt(0, literal.length)),
      );
      paintMap.beginBuild();
      paintMap.paintCalls = 0;
      paintMap.paintedStyles.clear();
      await tester.pump();

      expect(_paragraphRender(tester).source.viewText, '• item ',
          reason:
              'trailing-space caret must not re-reveal; • stays in the viewport');
      expect(paintMap.paintCalls, greaterThan(0));
      expect(paintMap.styleAtViewOffset(2), isNotNull);
    });

    testWidgets(
        'after leave, 1. stays visible; trailing-space caret stays clean',
        (tester) async {
      const literal = '1. item ';
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
        deriveDecorations: journalMarkdownListVisibleMarkDecorations,
      ));
      await tester.pump();

      expect(_paragraphRender(tester).source.viewText, '1. item ',
          reason: 'after leave, a visible number replaces the hidden 1. ');
      expect(paintMap.styleAtViewOffset(3), isNotNull);

      controller.setSelection(
        HomericSelection.collapsed(document.positionAt(0, 1)),
      );
      paintMap.beginBuild();
      await tester.pump();
      expect(_paragraphRender(tester).source.viewText, literal,
          reason: 'caret on the ordered prefix reveals literal markdown');

      controller.setSelection(
        HomericSelection.collapsed(document.positionAt(0, literal.length)),
      );
      paintMap.beginBuild();
      paintMap.paintCalls = 0;
      paintMap.paintedStyles.clear();
      await tester.pump();

      expect(_paragraphRender(tester).source.viewText, '1. item ',
          reason:
              'trailing-space caret must not re-reveal; 1. stays in the viewport');
      expect(paintMap.paintCalls, greaterThan(0));
      expect(paintMap.styleAtViewOffset(3), isNotNull);
    });

    testWidgets('* prefix uses the same • replacement path as -',
        (tester) async {
      const literal = '* item ';
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
        deriveDecorations: journalMarkdownListVisibleMarkDecorations,
      ));
      await tester.pump();

      expect(_paragraphRender(tester).source.viewText, '• item ');
      expect(paintMap.styleAtViewOffset(2), isNotNull);
    });
  });
}
