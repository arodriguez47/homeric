import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric/writing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const syntax = HomericSyntax();

  /// A controller over one paragraph of [text] with the caret at [caret],
  /// running mark deletes that reveal source with [revealCaret].
  HomericEditorController controllerFor(
    String text,
    int caret, {
    int? Function(String blockId)? revealCaret,
  }) {
    final document = Document([
      Block(id: 'b', type: 'paragraph', runs: [InlineRun(text)]),
    ]);
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(0, caret)),
    );
    addTearDown(controller.dispose);
    addTearDown(
      HomericMarkDeletes(
        syntax: syntax,
        revealCaret: revealCaret,
      ).installOn(controller),
    );
    return controller;
  }

  String textOf(HomericEditorController controller) =>
      controller.document.blocks.single.text;

  int caretOf(HomericEditorController controller) =>
      controller.selection!.head - controller.document.positionAt(0, 0);

  group('Backspace after a folded mark', () {
    test('takes the last highlighted letter, not a hidden =', () {
      final controller = controllerFor('a ==hi== b', 8);
      controller.deleteBackward();
      expect(textOf(controller), 'a ==h== b');
      expect(caretOf(controller), 7);
      controller.deleteBackward();
      // The last letter takes its emptied mark with it.
      expect(textOf(controller), 'a  b');
      expect(caretOf(controller), 2);
    });

    test('steps over bold, italic and code alike', () {
      for (final (text, after) in const [
        ('**hi**', '**h**'),
        ('*hi*', '*h*'),
        ('`hi`', '`h`'),
      ]) {
        final controller = controllerFor(text, text.length);
        controller.deleteBackward();
        expect(textOf(controller), after, reason: text);
      }
    });

    test('a drawn aside\'s only letter takes the aside with it', () {
      // A host that keeps a mark drawn (reveal caret null) at its end.
      final controller = controllerFor(
        '++x++',
        5,
        revealCaret: (_) => null,
      );
      controller.deleteBackward();
      expect(textOf(controller), '');
    });

    test('a drawn annotation loses its last word letter, note kept', () {
      final controller = controllerFor(
        'See {{tool|note}}',
        17,
        revealCaret: (_) => null,
      );
      controller.deleteBackward();
      expect(textOf(controller), 'See {{too|note}}');
      expect(caretOf(controller), 16);
    });
  });

  group('Backspace on a shown mark', () {
    test('takes both delimiters and keeps the words', () {
      // The caret inside the closing `==` shows it.
      final controller = controllerFor('a ==hi== b', 7);
      controller.deleteBackward();
      expect(textOf(controller), 'a hi b');
      expect(caretOf(controller), 4);
    });

    test('an annotation shown as source becomes its words', () {
      // Hosts that show an annotation's source with the caret after it.
      final controller = controllerFor('See {{tool|note}} now', 17);
      controller.deleteBackward();
      expect(textOf(controller), 'See tool now');
      expect(caretOf(controller), 8);
    });

    test('one undo brings the mark back', () {
      final controller = controllerFor('a ==hi== b', 7);
      controller.deleteBackward();
      expect(textOf(controller), 'a hi b');
      controller.undo();
      expect(textOf(controller), 'a ==hi== b');
    });
  });

  group('Delete before a mark', () {
    test('a shown opening goes with its closing', () {
      // The caret at the opening `==` shows it.
      final controller = controllerFor('a ==hi== b', 2);
      controller.deleteForward();
      expect(textOf(controller), 'a hi b');
      expect(caretOf(controller), 2);
    });
  });

  test('plain text deletes as before', () {
    final controller = controllerFor('plain words', 5);
    controller.deleteBackward();
    expect(textOf(controller), 'plai words');
  });

  test('homericMarkPairs finds each paired mark', () {
    final block = Block(
      id: 'b',
      type: 'paragraph',
      runs: [InlineRun('==h== ++a++ ~~s~~ {{w|n}}')],
    );
    expect(
        homericMarkPairs(syntax, block),
        containsAll(const [
          HomericMarkPair(0, 2, 3, 5),
          HomericMarkPair(6, 8, 9, 11),
          HomericMarkPair(12, 14, 15, 17),
          HomericMarkPair(18, 20, 21, 25),
        ]));
  });
}
