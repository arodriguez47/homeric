import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric/writing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const syntax = HomericSyntax();

  Block paragraph(String text) =>
      Block(id: 'b', type: 'paragraph', runs: [InlineRun(text)]);

  /// The hidden ranges [syntax] folds in [text] with the caret at [caret].
  List<(int, int)> hidden(String text, int? caret) => [
        for (final d in syntax.decorationsFor(paragraph(text), caret: caret))
          if (isMarkdownMarkHideDecoration(d)) (d.start, d.end),
      ];

  group('a paired mark holding the caret shows both delimiters', () {
    test('bold, italic, code and highlight', () {
      for (final text in const ['**hi** x', '*hi* x', '`hi` x', '==hi== x']) {
        final width = text.indexOf('h');
        // From just before the opening to inside the closing.
        for (var caret = 0; caret < text.indexOf(' '); caret++) {
          expect(hidden(text, caret), isEmpty, reason: '$text @$caret');
        }
        // Just after the closing, and away from it, both fold.
        for (final caret in [text.indexOf(' '), text.length, null]) {
          expect(hidden(text, caret), hasLength(2), reason: '$text @$caret');
        }
        expect(width, greaterThan(0));
      }
    });

    test('only the mark holding the caret shows', () {
      expect(hidden('**a** and **b**', 2), [(10, 12), (13, 15)]);
    });
  });

  group('keys at a block edge with only folded marks before them', () {
    HomericEditorController controllerFor(
      List<String> texts,
      int block,
      int caret,
    ) {
      final document = Document([
        for (var i = 0; i < texts.length; i++)
          Block(id: 'b$i', type: 'paragraph', runs: [InlineRun(texts[i])]),
      ]);
      final controller = HomericEditorController(
        document: document,
        selection:
            HomericSelection.collapsed(document.positionAt(block, caret)),
      );
      addTearDown(controller.dispose);
      addTearDown(
        HomericMarkDeletes(
          syntax: syntax,
          // A host that keeps marks drawn whatever the caret.
          revealCaret: (_) => null,
        ).installOn(controller),
      );
      return controller;
    }

    List<String> texts(HomericEditorController c) =>
        [for (final b in c.document.blocks) b.text];

    test('Backspace after a folded opening joins the block above', () {
      final controller = controllerFor(['One', '**Two** three'], 1, 2);
      expect(controller.deleteBackward(), isTrue);
      expect(texts(controller), ['One**Two** three']);
      // The caret keeps to the same letters: still before the T.
      expect(
        controller.blockOffsetForGlobalPosition(
          'b0',
          controller.selection!.head,
        ),
        5,
      );
      controller.undo();
      expect(texts(controller), ['One', '**Two** three']);
    });

    test('Delete after a folded closing joins the block below', () {
      // The mirror case: the closing folds with the caret after it, at
      // the block's end, so Delete there joins as it looks it should.
      final controller = controllerFor(['one *two*', 'Three'], 0, 9);
      expect(controller.deleteForward(), isTrue);
      expect(texts(controller), ['one *two*Three']);
    });

    test('the first block has nothing to join: the key does nothing', () {
      final controller = controllerFor(['**Two**'], 0, 2);
      controller.deleteBackward();
      expect(texts(controller), ['**Two**']);
    });
  });

  test('with the mark shown, Backspace after its opening unwraps it', () {
    final document = Document([
      Block(id: 'a', type: 'paragraph', runs: [InlineRun('One')]),
      Block(id: 'b', type: 'paragraph', runs: [InlineRun('**Two** x')]),
    ]);
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(1, 2)),
    );
    addTearDown(controller.dispose);
    addTearDown(HomericMarkDeletes(syntax: syntax).installOn(controller));
    controller.deleteBackward();
    expect(controller.document.blocks[1].text, 'Two x');
    // A second Backspace, at the start, joins the blocks.
    controller.deleteBackward();
    expect(controller.document.blocks.single.text, 'OneTwo x');
  });
}
