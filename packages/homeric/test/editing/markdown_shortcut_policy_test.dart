import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

void main() {
  group('HomericMarkdownShortcutPolicy', () {
    test('converts **bold** into a bold run attribute', () {
      final controller = HomericEditorController(
        document: Document([
          Block(id: 'b', type: 'paragraph', runs: [InlineRun('**bold*')]),
        ]),
        // Caret after the first closing star.
        selection: HomericSelection.collapsed(
          Document([
            Block(id: 'b', type: 'paragraph', runs: [InlineRun('**bold*')]),
          ]).positionAt(0, 7),
        ),
      );
      addTearDown(controller.dispose);
      const HomericMarkdownShortcutPolicy().installOn(controller);

      expect(controller.replaceSelection('*'), isTrue);
      final block = controller.document.blocks.single;
      expect(block.text, 'bold');
      expect(block.runs.single.attributes['bold'], isTrue);
    });

    test('converts *italic* into an italic run attribute', () {
      final document = Document([
        Block(id: 'b', type: 'paragraph', runs: [InlineRun('*itali')]),
      ]);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(document.positionAt(0, 6)),
      );
      addTearDown(controller.dispose);
      const HomericMarkdownShortcutPolicy().installOn(controller);

      expect(controller.replaceSelection('*'), isTrue);
      expect(controller.document.blocks.single.text, 'itali');
      expect(
        controller.document.blocks.single.runs.single.attributes['italic'],
        isTrue,
      );
    });

    test('converts `code` into a code run attribute', () {
      final document = Document([
        Block(id: 'b', type: 'paragraph', runs: [InlineRun('`code')]),
      ]);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(document.positionAt(0, 5)),
      );
      addTearDown(controller.dispose);
      const HomericMarkdownShortcutPolicy().installOn(controller);

      expect(controller.replaceSelection('`'), isTrue);
      expect(controller.document.blocks.single.text, 'code');
      expect(
        controller.document.blocks.single.runs.single.attributes['code'],
        isTrue,
      );
    });

    test('does nothing when the policy is not installed (journal-safe default)',
        () {
      final document = Document([
        Block(id: 'b', type: 'paragraph', runs: [InlineRun('**bold*')]),
      ]);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(document.positionAt(0, 7)),
      );
      addTearDown(controller.dispose);

      expect(controller.replaceSelection('*'), isTrue);
      expect(controller.document.blocks.single.text, '**bold**');
      expect(controller.document.blocks.single.runs.single.attributes, isEmpty);
    });
  });
}
