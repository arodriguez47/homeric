// Standard text-editing conventions a writer expects from a native text view:
// line deletes (Cmd+Backspace on macOS), paragraph jumps (Option+Up/Down),
// word deletes that join paragraphs at an edge, and Ctrl+T transpose. Driven
// through the AppKit selectors Flutter maps onto the same intents its default
// shortcuts produce, so one path covers keyboard and native menus.
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

const _style = TextStyle(fontSize: 14);

void main() {
  Future<HomericEditorController> pumpEditor(
    WidgetTester tester,
    List<String> texts, {
    required int block,
    required int offset,
  }) async {
    TextInputConnection.debugResetId();
    final document = Document(<Block>[
      for (var index = 0; index < texts.length; index++)
        Block(
          id: 'block-$index',
          type: 'paragraph',
          runs: <InlineRun>[InlineRun(texts[index])],
        ),
    ]);
    final controller = HomericEditorController(document: document);
    final session = HomericTextInputSession(controller: controller);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
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
                width: 500,
                height: 300,
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
                    resolveStyle: (_) => _style,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ));
    await tester.pump();
    await tester.tap(find.byKey(ValueKey('homeric-editable-block-$block')));
    controller.setSelection(
      HomericSelection.collapsed(controller.document.positionAt(block, offset)),
    );
    await tester.pump();
    return controller;
  }

  Future<void> send(WidgetTester tester, String selector) async {
    final message = const JSONMessageCodec().encodeMessage(<String, Object?>{
      'method': 'TextInputClient.performSelectors',
      'args': <Object?>[
        1,
        <String>[selector],
      ],
    });
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/textinput',
      message,
      (_) {},
    );
    await tester.pump();
  }

  List<String> texts(HomericEditorController controller) =>
      controller.document.blocks.map((block) => block.text).toList();

  testWidgets('Cmd+Backspace deletes back to the start of the line',
      (tester) async {
    final controller = await pumpEditor(tester, <String>['alpha beta gamma'],
        block: 0, offset: 10);

    await send(tester, 'deleteToBeginningOfLine:');

    expect(texts(controller), <String>[' gamma']);
    expect(
      controller.selection,
      HomericSelection.collapsed(controller.document.positionAt(0, 0)),
    );
  });

  testWidgets('Cmd+Backspace at a paragraph start joins the previous one',
      (tester) async {
    final controller = await pumpEditor(tester, <String>['alpha', 'beta'],
        block: 1, offset: 0);

    await send(tester, 'deleteToBeginningOfLine:');

    expect(texts(controller), <String>['alphabeta']);
  });

  testWidgets('Ctrl+K deletes to the end of the line', (tester) async {
    final controller =
        await pumpEditor(tester, <String>['alpha beta'], block: 0, offset: 5);

    await send(tester, 'deleteToEndOfParagraph:');

    expect(texts(controller), <String>['alpha']);
  });

  testWidgets('Option+Backspace at a paragraph start joins the previous one',
      (tester) async {
    final controller = await pumpEditor(tester, <String>['alpha', 'beta'],
        block: 1, offset: 0);

    await send(tester, 'deleteWordBackward:');

    expect(texts(controller), <String>['alphabeta']);
  });

  testWidgets('Option+Backspace mid-paragraph still deletes one word',
      (tester) async {
    final controller =
        await pumpEditor(tester, <String>['alpha beta'], block: 0, offset: 10);

    await send(tester, 'deleteWordBackward:');

    expect(texts(controller), <String>['alpha ']);
  });

  testWidgets('Option+Down moves to the paragraph end, then into the next',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final controller = await pumpEditor(tester, <String>['alpha beta', 'gamma'],
        block: 0, offset: 2);

    Future<void> optionDown() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
    }

    await optionDown();
    expect(controller.selection!.head, controller.document.positionAt(0, 10));

    await optionDown();
    expect(controller.selection!.head, controller.document.positionAt(1, 0));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Option+Shift+Up extends to the paragraph start', (tester) async {
    final controller =
        await pumpEditor(tester, <String>['alpha beta'], block: 0, offset: 7);

    await send(tester, 'moveParagraphBackwardAndModifySelection:');

    expect(controller.selection!.anchor, controller.document.positionAt(0, 7));
    expect(controller.selection!.head, controller.document.positionAt(0, 0));
  });

  testWidgets('Ctrl+T swaps the characters around the caret', (tester) async {
    final controller =
        await pumpEditor(tester, <String>['teh'], block: 0, offset: 2);

    await send(tester, 'transpose:');

    expect(texts(controller), <String>['the']);
    expect(
      controller.selection,
      HomericSelection.collapsed(controller.document.positionAt(0, 3)),
    );
  });

  testWidgets('Ctrl+T at the paragraph end swaps the last two characters',
      (tester) async {
    final controller =
        await pumpEditor(tester, <String>['hte'], block: 0, offset: 3);

    await send(tester, 'transpose:');

    expect(texts(controller), <String>['het']);
  });
}
