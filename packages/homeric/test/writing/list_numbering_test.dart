import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric/writing.dart';

Block _block(String text, {String id = 'b'}) =>
    Block(id: id, type: 'paragraph', runs: [InlineRun(text)]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// A controller over [lines], one block each (`l0`, `l1`, …), the caret
  /// at [caret] of line [line] (the last line's end when null), with list
  /// nesting and numbering installed as Sprintnotes installs them.
  HomericEditorController controllerFor(
    List<String> lines, {
    int? line,
    int? caret,
    bool numbering = true,
  }) {
    final document = Document([
      for (var i = 0; i < lines.length; i++) _block(lines[i], id: 'l$i'),
    ]);
    final at = line ?? lines.length - 1;
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(
        document.positionAt(at, caret ?? lines[at].length),
      ),
    );
    final stopNesting = const HomericListNesting().installOn(controller);
    final stopNumbering = numbering
        ? const HomericListNumbering().installOn(controller)
        : homericWritingNoop;
    addTearDown(() {
      stopNumbering();
      stopNesting();
      controller.dispose();
    });
    return controller;
  }

  List<String> linesOf(HomericEditorController controller) =>
      [for (final block in controller.document.blocks) block.text];

  (String, int) caretOf(HomericEditorController controller) {
    final head = controller.selection!.head;
    final at = controller.document.resolve(head) as InlinePosition;
    return (at.block.id, at.offset);
  }

  const seven = [
    '1. Universal quick capture',
    '2. Spaced repetition',
    '3. Multiple ways to interact',
    '4. Markdown-esque typing',
    '5. Soft word limits',
    '6. Backlinks and tags',
    '7. Surface related ideas',
  ];

  group('HomericListNumbering', () {
    test('Enter in the middle renumbers the items after it', () {
      // The report: Enter after item 6 of 7 wrote a second 7.
      final controller = controllerFor(seven, line: 5);
      controller.insertParagraphBreak();
      controller.replaceSelection('test');
      expect(linesOf(controller).map((l) => l.split(' ').first), [
        '1.',
        '2.',
        '3.',
        '4.',
        '5.',
        '6.',
        '7.',
        '8.',
      ]);
      expect(linesOf(controller)[6], '7. test');
      expect(linesOf(controller)[7], '8. Surface related ideas');
      expect(caretOf(controller).$2, '7. test'.length);
    });

    test('Enter at the start of an item\'s words pushes the rest down', () {
      final controller = controllerFor(seven, line: 5, caret: 3);
      controller.insertParagraphBreak();
      expect(linesOf(controller).sublist(5), [
        '6. ',
        '7. Backlinks and tags',
        '8. Surface related ideas',
      ]);
    });

    test('without the feature the old numbers stay, as reported', () {
      final controller = controllerFor(seven, line: 5, numbering: false);
      controller.insertParagraphBreak();
      expect(linesOf(controller)[6], '7. ');
      expect(linesOf(controller)[7], '7. Surface related ideas');
    });

    test('Enter on an empty item in the middle leaves the list there', () {
      final controller = controllerFor(
        ['1. one', '2. two', '3. ', '4. four', '5. five'],
        line: 2,
      );
      controller.insertParagraphBreak();
      // The lines below keep counting where they were: 4, 5.
      expect(
          linesOf(controller), ['1. one', '2. two', '', '4. four', '5. five']);
    });

    test('unlisting the first item makes the next one 1', () {
      final controller = controllerFor(
        ['1. one', '2. two', '3. three'],
        line: 0,
        caret: 3,
      );
      controller.deleteBackward();
      expect(linesOf(controller), ['one', '1. two', '2. three']);
      expect(controller.canUndo, isTrue);
      controller.undo();
      expect(linesOf(controller), ['1. one', '2. two', '3. three']);
    });

    test('deleting an item joins the rest up in order', () {
      // Backspace at the start of item 2's words unlists it, a second joins
      // it into item 1.
      final controller = controllerFor(
        ['1. one', '2. two', '3. three', '4. four'],
        line: 1,
        caret: 3,
      );
      controller.deleteBackward();
      controller.deleteBackward();
      expect(linesOf(controller), ['1. onetwo', '2. three', '3. four']);
    });

    test('a selection across items deletes them and renumbers', () {
      final document = Document([
        _block('1. one', id: 'l0'),
        _block('2. two', id: 'l1'),
        _block('3. three', id: 'l2'),
        _block('4. four', id: 'l3'),
      ]);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection(
          anchor: document.positionAt(0, 6),
          head: document.positionAt(2, 8),
        ),
      );
      final stop = const HomericListNumbering().installOn(controller);
      addTearDown(() {
        stop();
        controller.dispose();
      });
      controller.deleteBackward();
      expect(linesOf(controller), ['1. one', '2. four']);
    });

    test('moving an item renumbers, and Undo puts it back in one step', () {
      final controller = controllerFor(
        ['1. one', '2. two', '3. three'],
        line: 2,
      );
      final moved = controller.moveBlock(BlockMoveRequest(
        blockId: 'l2',
        targetIndex: 0,
        documentRevision: controller.documentRevision,
        previousBlockId: 'l1',
        nextBlockId: null,
      ));
      expect(moved, isTrue);
      expect(linesOf(controller), ['1. three', '2. one', '3. two']);
      controller.undo();
      expect(linesOf(controller), ['1. one', '2. two', '3. three']);
      controller.redo();
      expect(linesOf(controller), ['1. three', '2. one', '3. two']);
    });

    test('a line moved to the head of another list takes its start', () {
      final controller = controllerFor(
        ['1. a', '2. b', '3. c', 'between', '1. d', '2. e'],
        line: 0,
      );
      final tx = Transaction(controller.document)..moveBlock('l2', 3);
      expect(controller.applyTransaction(tx), isTrue);
      expect(linesOf(controller), [
        '1. a',
        '2. b',
        'between',
        '1. c',
        '2. d',
        '3. e',
      ]);
    });

    test('a first line moved into another list leaves its list at 1', () {
      final controller = controllerFor(
        ['1. a', '2. b', '3. c', 'between', '1. d', '2. e'],
        line: 0,
      );
      final tx = Transaction(controller.document)..moveBlock('l0', 5);
      expect(controller.applyTransaction(tx), isTrue);
      expect(linesOf(controller), [
        '1. b',
        '2. c',
        'between',
        '1. d',
        '2. e',
        '3. a',
      ]);
    });

    test('deleting the whole first line keeps the list at 1', () {
      final document = Document([
        _block('1. one', id: 'l0'),
        _block('2. two', id: 'l1'),
        _block('3. three', id: 'l2'),
      ]);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection(
          anchor: document.positionAt(0, 0),
          head: document.positionAt(1, 0),
        ),
      );
      final stop = const HomericListNumbering().installOn(controller);
      addTearDown(() {
        stop();
        controller.dispose();
      });
      controller.deleteBackward();
      expect(linesOf(controller), ['1. two', '2. three']);
    });

    test('a host transaction (drag by the handle) renumbers too', () {
      final controller = controllerFor(
        ['1. one', '2. two', '3. three'],
        line: 0,
      );
      final tx = Transaction(controller.document)..moveBlock('l0', 2);
      expect(controller.applyTransaction(tx), isTrue);
      expect(linesOf(controller), ['1. two', '2. three', '3. one']);
      controller.undo();
      expect(linesOf(controller), ['1. one', '2. two', '3. three']);
    });

    test('nesting starts a new list at 1 and closes the gap above', () {
      final controller = controllerFor(
        ['1. one', '2. two', '3. three'],
        line: 1,
        caret: 3,
      );
      controller.replaceSelection(' ');
      expect(linesOf(controller), ['1. one', '  1. two', '2. three']);
      expect(caretOf(controller), ('l1', 5));
      // And back out again.
      controller.deleteBackward();
      expect(linesOf(controller), ['1. one', '2. two', '3. three']);
    });

    test('nested lists count on their own and survive their parent list', () {
      final controller = controllerFor([
        '1. one',
        '  1. a',
        '  2. b',
        '2. two',
        '  1. c',
      ], line: 2);
      controller.insertParagraphBreak();
      controller.replaceSelection('x');
      expect(linesOf(controller), [
        '1. one',
        '  1. a',
        '  2. b',
        '  3. x',
        '2. two',
        '  1. c',
      ]);
    });

    test('a paragraph indented under an item stays inside the list', () {
      final controller = controllerFor([
        '1. one',
        '  more about one',
        '3. two',
      ], line: 0);
      controller.replaceSelection('!');
      expect(linesOf(controller)[2], '2. two');
    });

    test('a plain paragraph or a bullet ends the list', () {
      final controller = controllerFor([
        '1. one',
        'between',
        '1. again',
        '- bullet',
        '1. and again',
      ], line: 0);
      controller.replaceSelection('!');
      expect(linesOf(controller), [
        '1. one!',
        'between',
        '1. again',
        '- bullet',
        '1. and again',
      ]);
    });

    test('a list may start past 1, and the first number sets the rest', () {
      final controller = controllerFor(['3. c', '3. d'], line: 1);
      controller.replaceSelection('!');
      expect(linesOf(controller), ['3. c', '4. d!']);
      // Editing the first number renumbers the rest from it.
      final edited = controllerFor(['1. a', '2. b'], line: 0, caret: 1);
      edited.applyBlockEditBatch(
        blockId: 'l0',
        edits: const [CanonicalTextEdit(0, 1, '5')],
        selection: const BlockTextSelection.collapsed(1),
      );
      expect(linesOf(edited), ['5. a', '6. b']);
    });

    test('pasted lines with lazy numbers count in order', () {
      final controller = controllerFor(['1. one', '2. '], line: 1);
      controller.replaceSelectionStructurally('a\n1. b\n1. c');
      expect(linesOf(controller), ['1. one', '2. a', '3. b', '4. c']);
    });

    test('the caret stays put when a number grows a digit', () {
      final lines = [for (var i = 1; i <= 9; i++) '$i. item $i'];
      final controller = controllerFor(lines, line: 0);
      controller.insertParagraphBreak();
      expect(linesOf(controller).last, '10. item 9');
      expect(caretOf(controller), (controller.document.blocks[1].id, 3));
      controller.replaceSelection('new');
      expect(linesOf(controller)[1], '2. new');
    });

    test('Undo after Enter is one step', () {
      final controller = controllerFor(seven, line: 5);
      controller.insertParagraphBreak();
      controller.undo();
      expect(linesOf(controller), seven);
      expect(controller.canUndo, isFalse);
    });

    test('a list already out of order is put right by the next edit', () {
      final controller = controllerFor(
        ['1. one', '2. two', '7. three', '7. four'],
        line: 0,
      );
      controller.replaceSelection('!');
      expect(linesOf(controller), ['1. one!', '2. two', '3. three', '4. four']);
    });

    test('an open composition is left alone until it ends', () {
      final controller = controllerFor(['1. one', '1. two'], line: 1);
      controller.applyBlockEditBatch(
        blockId: 'l1',
        edits: const [CanonicalTextEdit(6, 6, 'o')],
        selection: const BlockTextSelection.collapsed(7),
        composing: const BlockTextRange(6, 7),
      );
      expect(linesOf(controller), ['1. one', '1. twoo']);
      controller.applyBlockEditBatch(
        blockId: 'l1',
        selection: const BlockTextSelection.collapsed(7),
      );
      controller.replaceSelection('!');
      expect(linesOf(controller), ['1. one', '2. twoo!']);
    });

    test('lines the host refuses are never renumbered', () {
      final document = Document([
        _block('1. one', id: 'l0'),
        _block(
          '1. code',
          id: 'l1',
        ),
      ]);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(document.positionAt(0, 6)),
      );
      final stop = HomericListNumbering(accepts: (b) => b.id != 'l1')
          .installOn(controller);
      addTearDown(() {
        stop();
        controller.dispose();
      });
      controller.replaceSelection('!');
      expect(linesOf(controller), ['1. one!', '1. code']);
    });

    test('isActive false leaves numbers as typed', () {
      final document = Document([
        _block('1. one', id: 'l0'),
        _block('1. two', id: 'l1'),
      ]);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(document.positionAt(0, 6)),
      );
      final stop =
          HomericListNumbering(isActive: () => false).installOn(controller);
      addTearDown(() {
        stop();
        controller.dispose();
      });
      controller.replaceSelection('!');
      expect(linesOf(controller), ['1. one!', '1. two']);
    });

    test('is in the standard kit', () {
      expect(HomericWritingKit.standard().has('listNumbering'), isTrue);
    });
  });
}
