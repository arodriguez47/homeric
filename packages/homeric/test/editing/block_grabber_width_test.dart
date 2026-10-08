import 'package:flutter/material.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

void main() {
  testWidgets('default blockGrabberWidth remains 44', (tester) async {
    final controller = HomericEditorController(
      document: Document([
        Block(id: 'a', type: 'paragraph', runs: [InlineRun('one')]),
        Block(id: 'b', type: 'paragraph', runs: [InlineRun('two')]),
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

    expect(document.blockGrabberWidth, kHomericBlockGrabberWidth);
    expect(document.blockGrabberWidth, 44);
    expect(find.text('⋮'), findsWidgets);
    expect(find.bySemanticsLabel(RegExp(r'Move block')), findsWidgets);
  });

  testWidgets('blockGrabberWidth 0 collapses column and skips semantics',
      (tester) async {
    final controller = HomericEditorController(
      document: Document([
        Block(id: 'a', type: 'paragraph', runs: [InlineRun('one')]),
        Block(id: 'b', type: 'paragraph', runs: [InlineRun('two')]),
      ]),
      selection: const HomericSelection.collapsed(1),
    );
    final session = HomericTextInputSession(controller: controller);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomericEditableDocument.builder(
            controller: controller,
            inputSession: session,
            blockGrabberWidth: 0,
            blockBuilder: (context, block, focusNode) =>
                HomericEditableParagraph(
              controller: controller,
              inputSession: session,
              blockId: block.id,
              focusNode: focusNode,
              resolveStyle: (_) => const TextStyle(fontSize: 14),
              baseStyle: const TextStyle(fontSize: 14),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('⋮'), findsNothing);
    expect(find.bySemanticsLabel(RegExp(r'Move block')), findsNothing);
  });
}
