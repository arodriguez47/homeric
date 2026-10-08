import 'package:flutter/material.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

void main() {
  testWidgets('compact preset collapses grabber and uses tight padding',
      (tester) async {
    final controller = HomericEditorController(
      document: Document([
        Block(id: 'a', type: 'paragraph', runs: [InlineRun('card')]),
      ]),
      selection: const HomericSelection.collapsed(1),
    );
    final session = HomericTextInputSession(controller: controller);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    late HomericEditableDocument document;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              document = HomericEditableDocument.compact(
                controller: controller,
                inputSession: session,
                blockBuilder: (context, block, focusNode) => Padding(
                  padding: kHomericCompactParagraphInsets,
                  child: HomericEditableParagraph(
                    controller: controller,
                    inputSession: session,
                    blockId: block.id,
                    focusNode: focusNode,
                    resolveStyle: (_) => const TextStyle(fontSize: 14),
                    baseStyle: const TextStyle(fontSize: 14),
                  ),
                ),
              );
              return document;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(document.blockGrabberWidth, 0);
    expect(document.padding, kHomericCompactDocumentPadding);
    expect(find.text('⋮'), findsNothing);
  });

  testWidgets('default builder keeps 44px grabber (Nexus-compatible)',
      (tester) async {
    final controller = HomericEditorController(
      document: Document([
        Block(id: 'a', type: 'paragraph', runs: [InlineRun('default')]),
      ]),
      selection: const HomericSelection.collapsed(1),
    );
    final session = HomericTextInputSession(controller: controller);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    late HomericEditableDocument document;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              document = HomericEditableDocument.builder(
                controller: controller,
                inputSession: session,
                blockBuilder: (context, block, focusNode) =>
                    HomericEditableParagraph(
                  controller: controller,
                  inputSession: session,
                  blockId: block.id,
                  focusNode: focusNode,
                  resolveStyle: (_) => const TextStyle(fontSize: 14),
                  baseStyle: const TextStyle(fontSize: 14),
                ),
              );
              return document;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(document.blockGrabberWidth, 44);
    expect(find.text('⋮'), findsOneWidget);
  });
}
