import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

void main() {
  group('committed change events', () {
    test('selection-only transitions do not emit committed changes', () async {
      final document = _document(['abc']);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(document.positionAt(0, 0)),
      );
      final changes = <HomericCommittedChange>[];
      controller.committedChanges.listen(changes.add);

      expect(
        controller.setSelection(
          HomericSelection.collapsed(document.positionAt(0, 2)),
        ),
        isTrue,
      );

      expect(changes, isEmpty);
    });

    test('one canonical mutation emits one mapped post-commit event', () {
      final document = _document(['abc']);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(document.positionAt(0, 1)),
      );
      final changes = <HomericCommittedChange>[];
      controller.committedChanges.listen(changes.add);

      expect(controller.replaceSelection('XY'), isTrue);

      expect(changes, hasLength(1));
      final change = changes.single;
      expect(change.before, same(document));
      expect(change.after, same(controller.document));
      expect(change.origin, HomericCommitOrigin.textInput);
      expect(change.contentRevision, controller.contentRevision);
      expect(change.documentRevision, controller.documentRevision);
      expect(change.mapping.map(document.positionAt(0, 3)),
          controller.document.positionAt(0, 5));
      expect(change.changes.touchedBlockIds, ['a']);
    });

    test('undo and redo each emit one history-origin event', () {
      final document = _document(['abc']);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(document.positionAt(0, 1)),
      );
      final changes = <HomericCommittedChange>[];
      controller.committedChanges.listen(changes.add);
      controller.replaceSelection('X');

      expect(controller.undo(), isTrue);
      expect(controller.redo(), isTrue);

      expect(changes.map((change) => change.origin), [
        HomericCommitOrigin.textInput,
        HomericCommitOrigin.undo,
        HomericCommitOrigin.redo,
      ]);
      expect(changes[1].mapping.map(changes[0].after.size), document.size);
      expect(changes[2].mapping.map(document.size), changes[0].after.size);
    });
  });

  group('read-only controller policy', () {
    test('entering read-only commits composition then rejects every mutation',
        () {
      final document = _document(['ab', 'cd']);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(document.positionAt(0, 1)),
      );
      controller.applyBlockEditBatch(
        blockId: 'a',
        edits: const [CanonicalTextEdit(1, 1, 'x')],
        selection: const BlockTextSelection.collapsed(2),
        composing: const BlockTextRange(1, 2),
      );
      expect(controller.composing, isNotNull);

      expect(controller.setReadOnly(true), isTrue);
      final frozen = controller.document;
      expect(controller.isReadOnly, isTrue);
      expect(controller.composing, isNull);
      expect(controller.canUndo, isTrue,
          reason: 'accepted composition remains one history unit');

      final transaction = Transaction(frozen)
        ..insertText(frozen.positionAt(0, 0), '!');
      final move = BlockMoveRequest(
        blockId: 'a',
        targetIndex: 1,
        documentRevision: controller.documentRevision,
        previousBlockId: null,
        nextBlockId: 'b',
      );
      final replacementDecorations =
          DecorationSet.of([Decoration.inline('a', 0, 1)]);

      expect(controller.replaceSelection('!'), isFalse);
      expect(controller.deleteBackward(), isFalse);
      expect(controller.insertParagraphBreak(), isFalse);
      expect(controller.moveBlock(move), isFalse);
      expect(controller.applyTransaction(transaction), isFalse);
      expect(controller.replaceDecorations(replacementDecorations), isFalse);
      expect(controller.undo(), isFalse);
      expect(controller.redo(), isFalse);
      expect(controller.document, same(frozen));

      expect(
        controller.setSelection(
          HomericSelection.collapsed(frozen.positionAt(1, 1)),
        ),
        isTrue,
        reason: 'selection and copy remain available in read-only mode',
      );
    });
  });

  group('block and range mutation policy', () {
    test('all document mutation paths fail closed when they touch a block', () {
      var blockOpaque = true;
      final document = _document(['aa', 'bb', 'cc']);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection(
          anchor: document.positionAt(0, 1),
          head: document.positionAt(1, 1),
        ),
        mutationPolicy: (request) =>
            !blockOpaque || !request.touchedBlockIds.contains('b'),
      );
      final changes = <HomericCommittedChange>[];
      controller.committedChanges.listen(changes.add);

      expect(controller.replaceSelectionStructurally('x'), isFalse);
      expect(controller.document, same(document));

      controller.setSelection(
        HomericSelection.collapsed(document.positionAt(1, 0)),
      );
      expect(controller.deleteBackward(), isFalse,
          reason: 'a boundary join touches both adjacent blocks');

      controller.setSelection(
        HomericSelection.collapsed(document.positionAt(1, 1)),
      );
      expect(
        controller.moveBlock(BlockMoveRequest(
          blockId: 'b',
          targetIndex: 2,
          documentRevision: controller.documentRevision,
          previousBlockId: 'a',
          nextBlockId: 'c',
        )),
        isFalse,
      );

      final transaction = Transaction(document)
        ..insertText(document.positionAt(1, 1), '!');
      expect(controller.applyTransaction(transaction), isFalse);
      expect(changes, isEmpty);

      blockOpaque = false;
      expect(controller.applyTransaction(transaction), isTrue);
      expect(controller.undo(), isTrue);
      blockOpaque = true;
      expect(controller.redo(), isFalse,
          reason: 'history cannot reapply a mutation into an opaque block');
    });
  });

  group('ordered command interception', () {
    test('first handled command stops precedence and remains one undo unit',
        () {
      final document = _document(['ab']);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(document.positionAt(0, 1)),
      );
      final order = <String>[];
      final changes = <HomericCommittedChange>[];
      controller.committedChanges.listen(changes.add);
      controller.addCommandInterceptor((command) {
        order.add('first:${command.kind.name}');
        return HomericCommandInterception.ignored;
      });
      controller.addCommandInterceptor((command) {
        order.add('second:${command.kind.name}');
        final transaction = Transaction(command.controller.document)
          ..insertText(command.controller.selection!.head, '!');
        expect(command.controller.applyTransaction(transaction), isTrue);
        return HomericCommandInterception.handled;
      });
      controller.addCommandInterceptor((command) {
        order.add('unreachable');
        return HomericCommandInterception.rejected('late');
      });

      expect(controller.insertParagraphBreak(), isTrue);

      expect(order, ['first:preBreak', 'second:preBreak']);
      expect(controller.document.blocks.single.text, 'a!b');
      expect(changes, hasLength(1));
      expect(changes.single.origin, HomericCommitOrigin.externalTransaction);
      expect(controller.undo(), isTrue);
      expect(controller.document, same(document));
    });

    test('typed rejection stops the built-in command without a commit', () {
      final document = _document(['ab']);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(document.positionAt(0, 1)),
      );
      controller.addCommandInterceptor((command) =>
          command.kind == HomericCommandKind.preDelete
              ? HomericCommandInterception.rejected(#opaque)
              : HomericCommandInterception.ignored);

      expect(controller.deleteBackward(), isFalse);
      expect(controller.document, same(document));
      expect(controller.canUndo, isFalse);
      expect(controller.lastCommandRejection?.reason, #opaque);
    });

    test('ignored or rejected interceptors cannot mutate then continue', () {
      final document = _document(['ab']);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(document.positionAt(0, 1)),
      );
      controller.addCommandInterceptor((command) {
        command.controller.setSelection(
          HomericSelection.collapsed(document.positionAt(0, 0)),
        );
        return HomericCommandInterception.rejected(#afterMutation);
      });

      expect(controller.insertParagraphBreak, throwsStateError);
      expect(controller.document, same(document));
      expect(controller.canUndo, isFalse);
    });
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
