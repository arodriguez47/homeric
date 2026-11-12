// Line markers the host draws elsewhere (a hung bullet or number, a to-do's
// box, a quote's bar) stay folded while a selection covers them, so the
// line never shows the drawn mark and its source side by side. Inline
// marks (`**`, `## `) still show their source under a selection, and a
// caret inside any marker still shows it as typed.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric/writing.dart';

const _syntax = HomericSyntax(hangingLists: true, hangingTodos: true);

void main() {
  setUp(TextInputConnection.debugResetId);

  Future<String> viewText(
    WidgetTester tester,
    String text, {
    int? from,
    int? to,
    HomericSyntax syntax = _syntax,
  }) async {
    final controller = HomericEditorController(
      document: Document([
        Block(id: 'b', type: 'paragraph', runs: [InlineRun(text)]),
      ]),
    );
    final session = HomericTextInputSession(controller: controller);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    if (from != null) {
      controller.setSelection(HomericSelection(
        anchor: controller.globalPositionForBlockOffset('b', from),
        head: controller.globalPositionForBlockOffset('b', to ?? from),
      ));
    }
    int? caret() {
      final s = controller.selection;
      if (s == null || !s.isCollapsed) return null;
      return controller.blockOffsetForGlobalPosition('b', s.head);
    }

    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        width: 600,
        child: HomericEditableParagraph(
          controller: controller,
          inputSession: session,
          blockId: 'b',
          resolveStyle: (_) => const TextStyle(fontSize: 14),
          deriveDecorations: (b) => syntax.decorationsFor(b, caret: caret()),
        ),
      ),
    ));
    await tester.pump();
    return tester
        .renderObject<RenderHomericParagraph>(find.byType(HomericParagraph))
        .source
        .viewText;
  }

  group('a selection over the whole line keeps the marker folded', () {
    for (final (text, words) in [
      ('- Markdown-esque typing', 'Markdown-esque typing'),
      ('1. Numbered line', 'Numbered line'),
      ('  - Nested line', 'Nested line'),
      ('- [ ] A to-do', 'A to-do'),
      ('> A quote', 'A quote'),
    ]) {
      testWidgets(text, (tester) async {
        expect(await viewText(tester, text), words);
        expect(
          await viewText(tester, text, from: 0, to: text.length),
          words,
        );
      });
    }
  });

  testWidgets('an unhung bullet stays a bullet under a selection',
      (tester) async {
    const syntax = HomericSyntax();
    const text = '- Bullet line';
    final shown = await viewText(tester, text, syntax: syntax);
    expect(shown, isNot(startsWith('-')));
    expect(
      await viewText(tester, text, from: 0, to: text.length, syntax: syntax),
      shown,
    );
  });

  testWidgets('a to-do on a later line keeps its box folded', (tester) async {
    const text = 'Plan\n- [ ] A to-do';
    final shown = await viewText(tester, text);
    expect(shown, isNot(contains('[ ]')));
    expect(await viewText(tester, text, from: 0, to: text.length), shown);
  });

  testWidgets('a selection ending at a line start keeps its marker folded',
      (tester) async {
    // In a document, a selection from the line above that ends at the
    // quote's start reaches the quote as a collapsed piece at offset 0.
    final controller = HomericEditorController(
      document: Document([
        Block(id: 'a', type: 'paragraph', runs: [InlineRun('Above')]),
        Block(id: 'b', type: 'paragraph', runs: [InlineRun('> A quote')]),
      ]),
    );
    final session = HomericTextInputSession(controller: controller);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    controller.setSelection(HomericSelection(
      anchor: controller.globalPositionForBlockOffset('a', 0),
      head: controller.globalPositionForBlockOffset('b', 0),
    ));
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Localizations(
        locale: const Locale('en'),
        delegates: const <LocalizationsDelegate<dynamic>>[
          DefaultWidgetsLocalizations.delegate,
        ],
        child: Overlay(initialEntries: [
          OverlayEntry(
            builder: (_) => SizedBox(
              width: 600,
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
                  resolveStyle: (_) => const TextStyle(fontSize: 14),
                  deriveDecorations: (b) => _syntax.decorationsFor(b),
                ),
              ),
            ),
          ),
        ]),
      ),
    ));
    await tester.pump();
    final paragraph = find.byType(HomericParagraph).last;
    expect(
      tester.renderObject<RenderHomericParagraph>(paragraph).source.viewText,
      'A quote',
    );
  });

  testWidgets('a caret inside a quote marker still shows it', (tester) async {
    expect(await viewText(tester, '> A quote', from: 0), '> A quote');
  });

  testWidgets('a caret inside a hung marker still shows it', (tester) async {
    expect(await viewText(tester, '- A line', from: 0), '- A line');
  });

  testWidgets('selected bold and heading marks still show their source',
      (tester) async {
    const bold = 'Some **bold** words';
    expect(await viewText(tester, bold), 'Some bold words');
    expect(await viewText(tester, bold, from: 0, to: bold.length), bold);
    const heading = '## A heading';
    expect(await viewText(tester, heading), 'A heading');
    expect(
      await viewText(tester, heading, from: 0, to: heading.length),
      heading,
    );
  });
}
