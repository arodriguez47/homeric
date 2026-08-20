import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

void main() {
  test('accepts forward and reverse cross-block directional selections', () {
    final document = _document(['one', '', 'three']);
    final controller = HomericEditorController(document: document);
    var notifications = 0;
    controller.addListener(() => notifications++);

    final reverse = HomericSelection(
      anchor: document.positionAt(2, 3),
      head: document.positionAt(0, 1),
      affinity: HomericCaretAffinity.upstream,
    );
    expect(controller.setSelection(reverse), isTrue);
    expect(controller.selection, reverse);
    expect(controller.selection!.isForward, isFalse);
    expect(controller.activeBlockId, 'a');
    expect(notifications, 1);

    final emptyHead = HomericSelection(
      anchor: document.positionAt(0, 2),
      head: document.positionAt(1, 0),
    );
    expect(controller.setSelection(emptyHead), isTrue);
    expect(controller.activeBlockId, 'b');
  });

  test('paragraph break preserves leading id and creates exact trailing id',
      () {
    final document = _document(['abcd']);
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(0, 2)),
    );
    var notifications = 0;
    controller.addListener(() => notifications++);

    expect(
      controller.insertParagraphBreak(trailingBlockId: 'trailing'),
      isTrue,
    );
    expect(controller.document.blocks.map((block) => block.id), [
      'a',
      'trailing',
    ]);
    expect(controller.document.blocks.map((block) => block.text), ['ab', 'cd']);
    expect(
        controller.selection,
        HomericSelection.collapsed(
          controller.document.positionAt(1, 0),
        ));
    expect(notifications, 1);

    expect(controller.undo(), isTrue);
    expect(controller.document, same(document));
    expect(controller.redo(), isTrue);
    expect(controller.document.blocks[1].id, 'trailing');
  });

  test('paragraph break pins start, middle, and end identity/caret outcomes',
      () {
    for (final fixture in <({int offset, List<String> text})>[
      (offset: 0, text: ['', 'abcd']),
      (offset: 2, text: ['ab', 'cd']),
      (offset: 4, text: ['abcd', '']),
    ]) {
      final document = _document(['abcd']);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(
          document.positionAt(0, fixture.offset),
        ),
      );

      expect(
        controller.insertParagraphBreak(trailingBlockId: 'tail'),
        isTrue,
      );
      expect(
        controller.document.blocks.map((block) => block.text),
        fixture.text,
      );
      expect(
          controller.document.blocks.map((block) => block.id), ['a', 'tail']);
      expect(
        controller.selection,
        HomericSelection.collapsed(controller.document.positionAt(1, 0)),
      );
    }
  });

  test(
      'reverse expanded paragraph break replaces once and retains direction history',
      () {
    final document = _document(['abc', 'def']);
    final before = HomericSelection(
      anchor: document.positionAt(1, 2),
      head: document.positionAt(0, 1),
      affinity: HomericCaretAffinity.upstream,
    );
    final controller = HomericEditorController(
      document: document,
      selection: before,
    );

    expect(
      controller.insertParagraphBreak(trailingBlockId: 'new'),
      isTrue,
    );
    expect(controller.document.blocks.map((block) => block.id), ['a', 'new']);
    expect(controller.document.blocks.map((block) => block.text), ['a', 'f']);
    expect(
        controller.selection,
        HomericSelection.collapsed(
          controller.document.positionAt(1, 0),
        ));
    expect(controller.undo(), isTrue);
    expect(controller.selection, before);
  });

  test('boundary Backspace and Delete preserve the declared survivor id', () {
    final backwardDocument = _document(['ab', 'cd']);
    final backward = HomericEditorController(
      document: backwardDocument,
      selection: HomericSelection.collapsed(backwardDocument.positionAt(1, 0)),
    );
    expect(backward.deleteBackward(), isTrue);
    expect(backward.document.blocks.single.id, 'a');
    expect(backward.document.blocks.single.text, 'abcd');
    expect(backward.selection,
        HomericSelection.collapsed(backward.document.positionAt(0, 2)));

    final forwardDocument = _document(['ab', 'cd']);
    final forward = HomericEditorController(
      document: forwardDocument,
      selection: HomericSelection.collapsed(forwardDocument.positionAt(0, 2)),
    );
    expect(forward.deleteForward(), isTrue);
    expect(forward.document.blocks.single.id, 'a');
    expect(forward.document.blocks.single.text, 'abcd');

    final edge = HomericEditorController(
      document: _document(['only']),
      selection: const HomericSelection.collapsed(1),
    );
    var notifications = 0;
    edge.addListener(() => notifications++);
    expect(edge.deleteBackward(), isFalse);
    expect(notifications, 0);
  });

  test('multiline replacement preserves empty segments in one history unit',
      () {
    final document = _document(['abc', 'def']);
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection(
        anchor: document.positionAt(0, 1),
        head: document.positionAt(1, 2),
      ),
    );
    var notifications = 0;
    controller.addListener(() => notifications++);

    expect(controller.replaceSelectionStructurally('X\n\nY'), isTrue);
    expect(controller.document.blocks.map((block) => block.text), [
      'aX',
      '',
      'Yf',
    ]);
    expect(controller.document.blocks.first.id, 'a');
    expect(
        controller.document.blocks.map((block) => block.id).toSet().length, 3);
    expect(
        controller.selection,
        HomericSelection.collapsed(
          controller.document.positionAt(2, 1),
        ));
    expect(notifications, 1);
    expect(controller.undo(), isTrue);
    expect(controller.document, same(document));
    expect(notifications, 2);
  });

  test('collapsed and local reverse multiline replacement keep separators', () {
    for (final reverse in [false, true]) {
      final document = _document(['abcd']);
      final selection = reverse
          ? HomericSelection(
              anchor: document.positionAt(0, 3),
              head: document.positionAt(0, 1),
            )
          : HomericSelection.collapsed(document.positionAt(0, 2));
      final controller = HomericEditorController(
        document: document,
        selection: selection,
      );

      expect(controller.replaceSelectionStructurally('X\n\nY'), isTrue);
      expect(
        controller.document.blocks.map((block) => block.text),
        reverse ? ['aX', '', 'Yd'] : ['abX', '', 'Ycd'],
      );
      expect(controller.document.blocks.first.id, 'a');
      expect(controller.document.blockCount, 3);
    }
  });

  test('cross-block hidden targets reveal before one structural mutation', () {
    final document = _document(['**a', 'b**']);
    final targets = <CanonicalEditTarget>[];
    late HomericEditorController controller;
    controller = HomericEditorController(
      document: document,
      decorations: DecorationSet.of([
        Decoration.replace('a', 0, 2, replacementLength: 0),
        Decoration.replace('b', 1, 3, replacementLength: 0),
      ]),
      selection: HomericSelection(
        anchor: document.positionAt(0, 1),
        head: document.positionAt(1, 2),
      ),
      onBeforeCanonicalMutation: (target) {
        expect(controller.document, same(document));
        targets.add(target);
      },
    );

    expect(controller.replaceSelectionStructurally('x'), isTrue);
    expect(targets.toSet(), {
      const CanonicalEditTarget('a', 0, 2),
      const CanonicalEditTarget('b', 1, 3),
    });
  });

  test('structural commands remain inert during composition', () {
    final document = _document(['abc']);
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(0, 1)),
    );
    expect(
      controller.applyBlockEditBatch(
        blockId: 'a',
        selection: const BlockTextSelection.collapsed(1),
        composing: const BlockTextRange.collapsed(1),
      ),
      isTrue,
    );
    final revision = controller.documentRevision;

    expect(controller.insertParagraphBreak(), isFalse);
    expect(controller.replaceSelectionStructurally('x\ny'), isFalse);
    expect(controller.document, same(document));
    expect(controller.documentRevision, revision);
  });

  test('reorder validates document revision and neighbor witnesses', () {
    final document = _document(['a', 'b', 'c']);
    final selection = HomericSelection(
      anchor: document.positionAt(1, 1),
      head: document.positionAt(1, 0),
      affinity: HomericCaretAffinity.upstream,
    );
    final controller = HomericEditorController(
      document: document,
      decorations: DecorationSet.of([Decoration.inline('b', 0, 1)]),
      selection: selection,
    );
    final request = BlockMoveRequest(
      blockId: 'b',
      targetIndex: 2,
      documentRevision: controller.documentRevision,
      previousBlockId: 'a',
      nextBlockId: 'c',
    );

    expect(controller.moveBlock(request), isTrue);
    expect(
        controller.document.blocks.map((block) => block.id), ['a', 'c', 'b']);
    expect(controller.activeBlockId, 'b');
    expect(controller.selection!.isForward, isFalse);
    expect(controller.selection!.affinity, HomericCaretAffinity.upstream);
    expect(controller.decorations.forBlock('b').single.start, 0);
    expect(controller.documentRevision, 1);

    expect(controller.moveBlock(request), isFalse,
        reason: 'the captured revision is stale');
    expect(controller.undo(), isTrue);
    expect(controller.document, same(document));
    expect(controller.selection, selection);
    expect(controller.decorations.forBlock('b').single.start, 0);
    expect(controller.redo(), isTrue);
    expect(
        controller.document.blocks.map((block) => block.id), ['a', 'c', 'b']);
  });

  test('reorder rejects neighbor drift and same-position requests silently',
      () {
    final document = _document(['a', 'b', 'c']);
    final controller = HomericEditorController(document: document);
    var notifications = 0;
    controller.addListener(() => notifications++);

    expect(
      controller.moveBlock(const BlockMoveRequest(
        blockId: 'b',
        targetIndex: 2,
        documentRevision: 0,
        previousBlockId: null,
        nextBlockId: 'c',
      )),
      isFalse,
    );
    expect(
      controller.moveBlock(const BlockMoveRequest(
        blockId: 'b',
        targetIndex: 1,
        documentRevision: 0,
        previousBlockId: 'a',
        nextBlockId: 'c',
      )),
      isFalse,
    );
    expect(controller.document, same(document));
    expect(controller.documentRevision, 0);
    expect(notifications, 0);
  });
}

Document _document(List<String> texts) => Document([
      for (var index = 0; index < texts.length; index++)
        Block(
          id: String.fromCharCode('a'.codeUnitAt(0) + index),
          type: 'paragraph',
          runs: texts[index].isEmpty ? const [] : [InlineRun(texts[index])],
        ),
    ]);
