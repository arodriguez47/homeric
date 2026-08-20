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

    test('boundary joins expose direction while local deletion does not', () {
      final document = _document(['ab', 'cd']);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(document.positionAt(1, 0)),
      );
      addTearDown(controller.dispose);
      final directions = <bool?>[];
      controller.addCommandInterceptor((command) {
        if (command.kind == HomericCommandKind.preDelete) {
          directions.add(command.forward);
          return HomericCommandInterception.rejected(#captured);
        }
        return HomericCommandInterception.ignored;
      });

      expect(controller.deleteBackward(), isFalse);
      controller.setSelection(HomericSelection.collapsed(
        document.positionAt(0, document.blocks.first.contentLength),
      ));
      expect(controller.deleteForward(), isFalse);
      expect(controller.deleteBackward(), isFalse);

      expect(directions, <bool?>[false, true, null]);
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

  group('prepared commands', () {
    test('multiple stages publish one final state and explicit caret', () {
      final document = _document(['abcd']);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(document.positionAt(0, 2)),
      );
      final split = Transaction(document);
      final trailingId = split.splitBlock(document.positionAt(0, 2));
      final typed = Transaction(split.doc)
        ..insertText(split.doc.positionAt(1, 0), '> ');
      final finalSelection = HomericSelection.collapsed(
        typed.doc.positionAt(1, 2),
      );
      final events = <HomericCommittedChange>[];
      var notifications = 0;
      controller.committedChanges.listen(events.add);
      controller.addListener(() => notifications++);

      expect(
        controller.applyPreparedCommand(HomericPreparedCommand(
          stages: <Transaction>[split, typed],
          selection: finalSelection,
        )),
        isTrue,
      );

      expect(trailingId, controller.document.blocks.last.id);
      expect(controller.document.blocks.map((block) => block.text),
          <String>['ab', '> cd']);
      expect(controller.selection, finalSelection);
      expect(notifications, 1);
      expect(events, hasLength(1));
      expect(events.single.before, same(document));
      expect(events.single.after, same(typed.doc));
      expect(events.single.origin, HomericCommitOrigin.externalTransaction);
    });

    test('history-only checkpoint is preflight-visible but not published', () {
      final document = _document(['+']);
      late Document literal;
      late Document converted;
      final preflightHistory = <Document>[];
      final preflightMutations = <HomericRetainedHistoryMutation>[];
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(document.positionAt(0, 1)),
        mutationPolicy: (request) {
          preflightHistory.addAll(request.retainedHistoryDocuments);
          preflightMutations.addAll(request.retainedHistoryMutations);
          return true;
        },
      );
      final completeLiteral = Transaction(document)
        ..insertText(document.positionAt(0, 1), '+');
      literal = completeLiteral.doc;
      final conversion = Transaction(literal)
        ..deleteRange(literal.positionAt(0, 0), literal.positionAt(0, 2))
        ..setBlockType('a', 'aside');
      converted = conversion.doc;
      final events = <HomericCommittedChange>[];
      var notifications = 0;
      controller.committedChanges.listen(events.add);
      controller.addListener(() => notifications++);

      expect(
        controller.applyPreparedCommand(HomericPreparedCommand(
          stages: <Transaction>[completeLiteral, conversion],
          selection: HomericSelection.collapsed(converted.positionAt(0, 0)),
          undoCheckpoint: HomericPreparedUndoCheckpoint(
            stage: 0,
            selection: HomericSelection.collapsed(literal.positionAt(0, 2)),
          ),
        )),
        isTrue,
      );

      expect(preflightHistory, <Document>[literal]);
      expect(preflightMutations, hasLength(1));
      expect(preflightMutations.single.before, same(document));
      expect(preflightMutations.single.after, same(literal));
      expect(preflightMutations.single.changes.touchedBlockIds, <String>['a']);
      expect(preflightMutations.single.mapping, isNot(isA<Mapping>()),
          reason: 'retained descriptors expose only a read-only mappable');
      expect(
        preflightMutations.single.mapping.map(document.positionAt(0, 1)),
        literal.positionAt(0, 2),
      );
      expect(events, hasLength(1));
      expect(notifications, 1);
      expect(controller.document, same(converted));

      expect(controller.undo(), isTrue);
      expect(controller.document, same(literal));
      expect(controller.selection,
          HomericSelection.collapsed(literal.positionAt(0, 2)));
      expect(controller.redo(), isTrue);
      expect(controller.document, same(converted));
    });

    test('construction freezes every prepared transaction stage', () {
      final document = _document(['abc']);
      final source = Transaction(document)
        ..insertText(document.positionAt(0, 1), 'X');
      final captured = source.doc;
      final command = HomericPreparedCommand(
        stages: <Transaction>[source],
        selection: HomericSelection.collapsed(captured.positionAt(0, 2)),
      );
      source.insertText(source.doc.positionAt(0, 2), 'Y');
      final controller = HomericEditorController(document: document);
      HomericCommittedChange? event;
      controller.committedChanges.listen((change) => event = change);

      expect(command.stageCount, 1);
      expect(controller.applyPreparedCommand(command), isTrue);
      expect(controller.document, same(captured));
      expect(controller.document.blocks.single.text, 'aXbc');
      expect(event!.after, same(captured));
      expect(
        event!.mapping.map(document.positionAt(0, 3)),
        captured.positionAt(0, 4),
      );
    });

    test('rejection and invalid prepared state are completely inert', () {
      final document = _document(['abc']);
      final retained = Transaction(document)
        ..insertText(document.positionAt(0, 3), '!');
      final finalStage = Transaction(retained.doc)
        ..setBlockType('a', 'heading');
      var policyCalls = 0;
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(document.positionAt(0, 3)),
        mutationPolicy: (request) {
          policyCalls++;
          expect(request.retainedHistoryDocuments, <Document>[retained.doc]);
          return false;
        },
      );
      var notifications = 0;
      final events = <HomericCommittedChange>[];
      controller.addListener(() => notifications++);
      controller.committedChanges.listen(events.add);
      final command = HomericPreparedCommand(
        stages: <Transaction>[retained, finalStage],
        selection: HomericSelection.collapsed(finalStage.doc.positionAt(0, 4)),
        undoCheckpoint: HomericPreparedUndoCheckpoint(
          stage: 0,
          selection: HomericSelection.collapsed(retained.doc.positionAt(0, 4)),
        ),
      );

      expect(controller.applyPreparedCommand(command), isFalse);
      expect(policyCalls, 1);
      expect(controller.document, same(document));
      expect(controller.canUndo, isFalse);
      expect(controller.documentRevision, 0);
      expect(notifications, 0);
      expect(events, isEmpty);

      final staleController = HomericEditorController(document: document);
      final advance = Transaction(document)
        ..insertText(document.positionAt(0, 0), '?');
      expect(staleController.applyTransaction(advance), isTrue);
      expect(staleController.applyPreparedCommand(command), isFalse);
      expect(staleController.document, same(advance.doc));

      final composingController = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(document.positionAt(0, 1)),
      );
      expect(
        composingController.applyBlockEditBatch(
          blockId: 'a',
          selection: const BlockTextSelection.collapsed(1),
          composing: const BlockTextRange.collapsed(1),
        ),
        isTrue,
      );
      final composingRevision = composingController.stateRevision;
      expect(composingController.applyPreparedCommand(command), isFalse);
      expect(composingController.stateRevision, composingRevision);

      final readOnlyController = HomericEditorController(
        document: document,
        readOnly: true,
      );
      expect(readOnlyController.applyPreparedCommand(command), isFalse);
      expect(readOnlyController.stateRevision, 0);

      final invalidController = HomericEditorController(document: document);
      expect(
        invalidController.applyPreparedCommand(HomericPreparedCommand(
          stages: <Transaction>[retained, finalStage],
          selection: const HomericSelection.collapsed(999),
        )),
        isFalse,
      );
      expect(invalidController.stateRevision, 0);

      final wrongBase = Transaction(document)..setBlockType('a', 'quote');
      expect(
        invalidController.applyPreparedCommand(HomericPreparedCommand(
          stages: <Transaction>[retained, wrongBase],
          selection: HomericSelection.collapsed(wrongBase.doc.positionAt(0, 3)),
        )),
        isFalse,
      );
      expect(invalidController.stateRevision, 0);
    });

    test('history checkpoint participates in max-depth pruning', () {
      final document = _document(['+']);
      final literal = Transaction(document)
        ..insertText(document.positionAt(0, 1), '+');
      final conversion = Transaction(literal.doc)..setBlockType('a', 'aside');
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(document.positionAt(0, 1)),
        maxUndoDepth: 1,
      );

      expect(
        controller.applyPreparedCommand(HomericPreparedCommand(
          stages: <Transaction>[literal, conversion],
          selection:
              HomericSelection.collapsed(conversion.doc.positionAt(0, 2)),
          undoCheckpoint: HomericPreparedUndoCheckpoint(
            stage: 0,
            selection: HomericSelection.collapsed(literal.doc.positionAt(0, 2)),
          ),
        )),
        isTrue,
      );

      expect(controller.undo(), isTrue);
      expect(controller.document, same(literal.doc));
      expect(controller.undo(), isFalse,
          reason: 'the older pre-command state was pruned');
    });

    test('checkpoint preflight retains exact structural descriptors', () {
      final document = _document(['abcd']);
      HomericRetainedHistoryMutation? retained;
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(document.positionAt(0, 2)),
        mutationPolicy: (request) {
          retained = request.retainedHistoryMutations.single;
          return true;
        },
      );
      final split = Transaction(document);
      final trailingId = split.splitBlock(document.positionAt(0, 2));
      final decorate = Transaction(split.doc)
        ..setBlockType(trailingId, 'aside');

      expect(
        controller.applyPreparedCommand(HomericPreparedCommand(
          stages: <Transaction>[split, decorate],
          selection: HomericSelection.collapsed(decorate.doc.positionAt(1, 0)),
          undoCheckpoint: HomericPreparedUndoCheckpoint(
            stage: 0,
            selection: HomericSelection.collapsed(split.doc.positionAt(1, 0)),
          ),
        )),
        isTrue,
      );

      expect(retained!.before, same(document));
      expect(retained!.after, same(split.doc));
      expect(retained!.changes.structural, hasLength(1));
      expect(retained!.changes.structural.single, isA<BlockSplit>());
      final structural = retained!.changes.structural.single as BlockSplit;
      expect(structural.sourceId, 'a');
      expect(structural.trailingId, trailingId);
      expect(structural.sourceOffset, 2);
    });

    test('explicit final composition remains one history group', () {
      final document = _document(['abc']);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(document.positionAt(0, 1)),
      );
      final prepared = Transaction(document)
        ..insertText(document.positionAt(0, 1), 'X');
      final events = <HomericCommittedChange>[];
      controller.committedChanges.listen(events.add);

      expect(
        controller.applyPreparedCommand(HomericPreparedCommand(
          stages: <Transaction>[prepared],
          selection: HomericSelection.collapsed(prepared.doc.positionAt(0, 2)),
          composing: HomericTextRange(
            prepared.doc.positionAt(0, 1),
            prepared.doc.positionAt(0, 2),
          ),
        )),
        isTrue,
      );
      expect(controller.composing, isNotNull);
      expect(controller.canUndo, isFalse,
          reason: 'the active composition has not closed its history group');
      final publishedMapping = events.single.mapping;

      expect(
        controller.applyBlockEditBatch(
          blockId: 'a',
          edits: const <CanonicalTextEdit>[CanonicalTextEdit(2, 2, 'Y')],
          selection: const BlockTextSelection.collapsed(3),
          composing: const BlockTextRange(1, 3),
        ),
        isTrue,
      );
      expect(
        publishedMapping.map(document.positionAt(0, 3)),
        prepared.doc.positionAt(0, 4),
        reason: 'later composition edits must not mutate the published map',
      );
      expect(
        controller.applyBlockEditBatch(
          blockId: 'a',
          selection: const BlockTextSelection.collapsed(3),
        ),
        isTrue,
      );
      expect(controller.canUndo, isTrue);
      expect(controller.undo(), isTrue);
      expect(controller.document, same(document));
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
