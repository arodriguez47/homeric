import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric/writing.dart';

Document _doc(List<String> lines) => Document([
      for (var i = 0; i < lines.length; i++)
        Block(id: 'l$i', type: 'paragraph', runs: [InlineRun(lines[i])]),
    ]);

List<String> _text(Document doc) => [for (final b in doc.blocks) b.text];

const _outline = [
  'There were several things', // l0
  '- A form of constraint', // l1
  '  - I want short content', // l2
  '    - Supernotes did this', // l3
  '    - Hemingway helped', // l4
  '- Less friction', // l5
  '  - No titles', // l6
  '  Words under the bullet', // l7
  '- Beautiful typography', // l8
];

void main() {
  group('a family', () {
    test('is a line and the lines after it that start further in', () {
      final doc = _doc(_outline);
      expect(HomericBlockFamily.idsOf(doc, 'l1'), ['l1', 'l2', 'l3', 'l4']);
      expect(HomericBlockFamily.idsOf(doc, 'l2'), ['l2', 'l3', 'l4']);
      expect(HomericBlockFamily.idsOf(doc, 'l3'), ['l3']);
      expect(HomericBlockFamily.idsOf(doc, 'l5'), ['l5', 'l6', 'l7'],
          reason: 'a paragraph indented to the words is a child');
      expect(HomericBlockFamily.idsOf(doc, 'l0'), ['l0'],
          reason: 'bullets at the margin are siblings, not children');
      expect(HomericBlockFamily.hasChildren(doc, 'l8'), isFalse);
    });

    test('indented paragraphs carry deeper paragraphs', () {
      final doc = _doc(['One', '  two', '    three', '  four', 'five']);
      expect(HomericBlockFamily.idsOf(doc, 'l0'), ['l0', 'l1', 'l2', 'l3']);
      expect(HomericBlockFamily.idsOf(doc, 'l1'), ['l1', 'l2']);
    });

    test('blank lines inside go along; blank lines after stay', () {
      final doc = _doc(['- a', '', '  - b', '', '- c']);
      expect(HomericBlockFamily.idsOf(doc, 'l0'), ['l0', 'l1', 'l2']);
    });

    test('headings and quotes start at the margin', () {
      final doc = _doc(['## Title', '  indented', '> quote', '  under']);
      expect(HomericBlockFamily.idsOf(doc, 'l0'), ['l0', 'l1']);
      expect(HomericBlockFamily.idsOf(doc, 'l2'), ['l2', 'l3']);
    });
  });

  group('a step', () {
    test('down goes past the next family whole', () {
      final doc = _doc(_outline);
      final tx = HomericBlockFamily.step(doc, 'l1', 1)!;
      expect(_text(tx.doc), [
        'There were several things',
        '- Less friction',
        '  - No titles',
        '  Words under the bullet',
        '- A form of constraint',
        '  - I want short content',
        '    - Supernotes did this',
        '    - Hemingway helped',
        '- Beautiful typography',
      ]);
    });

    test('up goes above the sibling, never among its children', () {
      final doc = _doc(_outline);
      final tx = HomericBlockFamily.step(doc, 'l5', -1)!;
      expect(_text(tx.doc), [
        'There were several things',
        '- Less friction',
        '  - No titles',
        '  Words under the bullet',
        '- A form of constraint',
        '  - I want short content',
        '    - Supernotes did this',
        '    - Hemingway helped',
        '- Beautiful typography',
      ]);
    });

    test('a child steps among its siblings with its own children', () {
      final doc = _doc(_outline);
      final tx = HomericBlockFamily.step(doc, 'l4', -1)!;
      expect(_text(tx.doc).sublist(3, 5),
          ['    - Hemingway helped', '    - Supernotes did this']);
    });

    test('the last family cannot go down, the first cannot go up', () {
      final doc = _doc(_outline);
      expect(HomericBlockFamily.step(doc, 'l8', 1), isNull);
      expect(HomericBlockFamily.step(doc, 'l0', -1), isNull);
      expect(HomericBlockFamily.step(doc, 'l5', 1), isNotNull);
    });
  });

  group('a drop', () {
    test('above a line takes the family there', () {
      final doc = _doc(_outline);
      final tx = HomericBlockFamily.toIndex(doc, 'l5', 0)!;
      expect(_text(tx.doc).take(4), [
        '- Less friction',
        '  - No titles',
        '  Words under the bullet',
        'There were several things',
      ]);
    });

    test('below a line takes it there; inside itself is no move', () {
      final doc = _doc(_outline);
      final tx = HomericBlockFamily.toIndex(doc, 'l1', 8)!;
      expect(_text(tx.doc).last, '    - Hemingway helped');
      expect(_text(tx.doc)[5], '- A form of constraint');
      expect(HomericBlockFamily.toIndex(doc, 'l1', 3), isNull);
    });
  });

  group('in the editor', () {
    testWidgets('⌘⇧↓ moves a bullet with its children, as one undo step',
        (tester) async {
      final document = _doc(_outline);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(document.positionAt(1, 3)),
      );
      final session = HomericTextInputSession(controller: controller);
      addTearDown(session.dispose);
      addTearDown(controller.dispose);
      final key = GlobalKey<HomericEditableDocumentState>();
      await tester.pumpWidget(MaterialApp(
        home: Material(
          child: SizedBox(
            width: 500,
            height: 600,
            child: HomericEditableDocument.builder(
              key: key,
              controller: controller,
              inputSession: session,
              onMoveBlock: HomericBlockFamily.onMoveBlock,
              estimatedBlockHeight: 44,
              blockBuilder: (context, block, focusNode) =>
                  HomericEditableParagraph(
                controller: controller,
                inputSession: session,
                blockId: block.id,
                focusNode: focusNode,
                resolveStyle: (_) => const TextStyle(fontSize: 16),
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
      expect(key.currentState!.moveBlockBy('l1', 1), isTrue);
      expect(_text(controller.document)[1], '- Less friction');
      expect(_text(controller.document)[4], '- A form of constraint');
      expect(_text(controller.document)[7], '    - Hemingway helped');
      expect(controller.activeBlockId, 'l1', reason: 'the caret goes along');
      expect(controller.undo(), isTrue);
      expect(_text(controller.document), _outline);
      expect(key.currentState!.moveBlockBy('l8', -1), isTrue,
          reason: 'a line with nothing under it moves one line');
      expect(_text(controller.document)[7], '- Beautiful typography');
    });
  });
}
