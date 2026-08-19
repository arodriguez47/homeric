import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

void main() {
  group('HomericEditorController selection and coordinates', () {
    test('owns directional selection, affinity, and preferred x', () {
      final doc = _document(['abcd']);
      final controller = HomericEditorController(
        document: doc,
        selection: HomericSelection(
          anchor: doc.positionAt(0, 3),
          head: doc.positionAt(0, 1),
          affinity: HomericCaretAffinity.upstream,
        ),
      );

      expect(controller.selection!.isForward, isFalse);
      expect(controller.selection!.affinity, HomericCaretAffinity.upstream);
      expect(controller.preferredX, isNull);
      expect(controller.setPreferredX(42), isTrue);
      expect(controller.preferredX, 42);
      expect(controller.resetPreferredX(), isTrue);
      expect(controller.preferredX, isNull);
    });

    test('converts only positions in the requested block', () {
      final doc = _document(['one', 'two']);
      final controller = HomericEditorController(document: doc);

      expect(controller.globalPositionForBlockOffset('b', 2),
          doc.positionAt(1, 2));
      expect(
        controller.blockOffsetForGlobalPosition('b', doc.positionAt(1, 2)),
        2,
      );
      expect(
        () => controller.blockOffsetForGlobalPosition(
          'a',
          doc.positionAt(1, 2),
        ),
        throwsArgumentError,
      );
    });

    test('invalid cross-block selection is rejected without partial state', () {
      final doc = _document(['one', 'two']);
      final initial = HomericSelection.collapsed(doc.positionAt(0, 1));
      final controller = HomericEditorController(
        document: doc,
        selection: initial,
      );
      var notifications = 0;
      controller.addListener(() => notifications++);

      expect(
        controller.setSelection(HomericSelection(
          anchor: doc.positionAt(0, 1),
          head: doc.positionAt(1, 1),
        )),
        isFalse,
      );
      expect(controller.selection, initial);
      expect(notifications, 0);
    });

    test('out-of-range selection is rejected as a value, not thrown', () {
      final doc = _document(['one']);
      final initial = HomericSelection.collapsed(doc.positionAt(0, 1));
      final controller = HomericEditorController(
        document: doc,
        selection: initial,
      );

      expect(
        () => controller.setSelection(
          HomericSelection.collapsed(doc.size + 1),
        ),
        returnsNormally,
      );
      expect(
        controller.setSelection(HomericSelection.collapsed(doc.size + 1)),
        isFalse,
      );
      expect(controller.selection, initial);
    });

    test('selection and preferred x update atomically', () {
      final doc = _document(['one']);
      final controller = HomericEditorController(
        document: doc,
        selection: HomericSelection.collapsed(doc.positionAt(0, 0)),
      );
      var notifications = 0;
      controller.addListener(() => notifications++);

      expect(
        controller.setSelection(
          HomericSelection.collapsed(doc.positionAt(0, 1)),
          preferredX: 24,
        ),
        isTrue,
      );
      expect(controller.preferredX, 24);
      expect(notifications, 1);

      expect(
        controller.setSelection(controller.selection, resetPreferredX: true),
        isTrue,
      );
      expect(controller.preferredX, isNull);
      expect(notifications, 2);
    });
  });

  group('HomericEditorController canonical edits', () {
    test('reverse replacement inherits attributes and notifies once', () {
      final doc = Document([
        Block(id: 'a', type: 'paragraph', runs: [
          InlineRun('ab', attributes: const {'bold': true}),
          InlineRun('cd'),
        ]),
      ]);
      final controller = HomericEditorController(
        document: doc,
        selection: HomericSelection(
          anchor: doc.positionAt(0, 3),
          head: doc.positionAt(0, 1),
        ),
      );
      var notifications = 0;
      controller.addListener(() => notifications++);

      expect(controller.replaceSelection('X'), isTrue);

      expect(controller.document.blocks.single.text, 'aXd');
      expect(controller.document.blocks.single.runs.first.attributes['bold'],
          isTrue);
      expect(controller.selection, const HomericSelection.collapsed(3));
      expect(notifications, 1);
      expect(controller.canUndo, isTrue);
    });

    test('expanded Backspace and Delete are one transition', () {
      for (final backward in [true, false]) {
        final doc = _document(['abcdef']);
        final controller = HomericEditorController(
          document: doc,
          selection: HomericSelection(
            anchor: doc.positionAt(0, 5),
            head: doc.positionAt(0, 2),
          ),
        );
        var notifications = 0;
        controller.addListener(() => notifications++);

        final changed =
            backward ? controller.deleteBackward() : controller.deleteForward();

        expect(changed, isTrue);
        expect(controller.document.blocks.single.text, 'abf');
        expect(controller.selection, const HomericSelection.collapsed(3));
        expect(notifications, 1);
      }
    });

    test('collapsed deletion removes one canonical grapheme', () {
      for (final fixture in <({String text, int caret, String expected})>[
        (text: 'áb', caret: 2, expected: 'b'),
        (text: '👨‍👩‍👧‍👦x', caret: 11, expected: 'x'),
      ]) {
        final doc = _document([fixture.text]);
        final controller = HomericEditorController(
          document: doc,
          selection:
              HomericSelection.collapsed(doc.positionAt(0, fixture.caret)),
        );

        expect(controller.deleteBackward(), isTrue);
        expect(controller.document.blocks.single.text, fixture.expected);
        expect(controller.selection, const HomericSelection.collapsed(1));
      }

      final doc = _document(['áb']);
      final controller = HomericEditorController(
        document: doc,
        selection: HomericSelection.collapsed(doc.positionAt(0, 0)),
      );
      expect(controller.deleteForward(), isTrue);
      expect(controller.document.blocks.single.text, 'b');
    });

    test('block edges do not cross structural tokens', () {
      final doc = _document(['a', 'b']);
      final atStart = HomericEditorController(
        document: doc,
        selection: HomericSelection.collapsed(doc.positionAt(1, 0)),
      );
      final atEnd = HomericEditorController(
        document: doc,
        selection: HomericSelection.collapsed(doc.positionAt(0, 1)),
      );

      expect(atStart.deleteBackward(), isFalse);
      expect(atEnd.deleteForward(), isFalse);
      expect(atStart.document, same(doc));
      expect(atEnd.document, same(doc));
    });

    test('hidden deletion target is revealed before canonical mutation', () {
      final doc = _document(['**x**']);
      final hidden = Decoration.replace('a', 0, 2, replacementLength: 0);
      late CanonicalEditTarget target;
      late String textObservedByHook;
      late HomericEditorController controller;
      controller = HomericEditorController(
        document: doc,
        decorations: DecorationSet.of([hidden]),
        selection: HomericSelection.collapsed(doc.positionAt(0, 2)),
        onBeforeCanonicalMutation: (value) {
          target = value;
          textObservedByHook = controller.document.blocks.single.text;
        },
      );

      expect(controller.deleteBackward(), isTrue);

      expect(target, const CanonicalEditTarget('a', 0, 2));
      expect(textObservedByHook, '**x**');
      expect(controller.document.blocks.single.text, '*x**');
    });

    test('external transaction maps selection and decorations once', () {
      final doc = _document(['abcd']);
      final decoration = Decoration.inline('a', 1, 3);
      final controller = HomericEditorController(
        document: doc,
        decorations: DecorationSet.of([decoration]),
        selection: HomericSelection(
          anchor: doc.positionAt(0, 4),
          head: doc.positionAt(0, 2),
          affinity: HomericCaretAffinity.upstream,
        ),
      );
      final tx = Transaction(doc)..insertText(doc.positionAt(0, 1), 'XY');
      var notifications = 0;
      controller.addListener(() => notifications++);

      expect(controller.applyTransaction(tx), isTrue);

      expect(controller.selection!.anchor, doc.positionAt(0, 4) + 2);
      expect(controller.selection!.head, doc.positionAt(0, 2) + 2);
      expect(controller.selection!.isForward, isFalse);
      expect(controller.selection!.affinity, HomericCaretAffinity.upstream);
      expect(controller.decorations.forBlock('a').single.start, 3);
      expect(notifications, 1);
    });

    test('decoration replacement is observable and exactly undoable', () {
      final doc = _document(['abcd']);
      final before = DecorationSet.of([Decoration.inline('a', 0, 1)]);
      final after = before.add([Decoration.inline('a', 2, 4)]);
      final selection = HomericSelection.collapsed(doc.positionAt(0, 2));
      final controller = HomericEditorController(
        document: doc,
        decorations: before,
        selection: selection,
      );
      var notifications = 0;
      controller.addListener(() => notifications++);

      expect(controller.replaceDecorations(after), isTrue);
      expect(controller.document, same(doc));
      expect(controller.decorations, same(after));
      expect(controller.selection, selection);
      expect(notifications, 1);

      expect(controller.undo(), isTrue);
      expect(controller.document, same(doc));
      expect(controller.decorations, same(before));
      expect(controller.selection, selection);
      expect(notifications, 2);
      expect(controller.replaceDecorations(before), isFalse);
      expect(notifications, 2);
    });
  });

  group('atomic batches, composition, and undo', () {
    test('undo and redo restore exact snapshots and notify once', () {
      final doc = _document(['abcd']);
      final beforeDecorations =
          DecorationSet.of([Decoration.inline('a', 0, 1)]);
      final afterDecorations =
          beforeDecorations.add([Decoration.inline('a', 2, 4)]);
      final beforeSelection = HomericSelection(
        anchor: doc.positionAt(0, 4),
        head: doc.positionAt(0, 1),
        affinity: HomericCaretAffinity.upstream,
      );
      final controller = HomericEditorController(
        document: doc,
        decorations: beforeDecorations,
        selection: beforeSelection,
        preferredX: 27,
      );
      var notifications = 0;
      controller.addListener(() => notifications++);

      expect(controller.replaceDecorations(afterDecorations), isTrue);
      expect(controller.canUndo, isTrue);
      expect(controller.canRedo, isFalse);

      expect(controller.undo(), isTrue);
      expect(controller.document, same(doc));
      expect(controller.decorations, same(beforeDecorations));
      expect(controller.selection, beforeSelection);
      expect(controller.composing, isNull);
      expect(controller.preferredX, 27);
      expect(controller.canUndo, isFalse);
      expect(controller.canRedo, isTrue);

      expect(controller.redo(), isTrue);
      expect(controller.document, same(doc));
      expect(controller.decorations, same(afterDecorations));
      expect(controller.selection, beforeSelection);
      expect(controller.composing, isNull);
      expect(controller.preferredX, 27);
      expect(controller.canUndo, isTrue);
      expect(controller.canRedo, isFalse);
      expect(notifications, 3);
    });

    test('state and content revisions are monotonic witnesses', () {
      final doc = _document(['ab']);
      final controller = HomericEditorController(
        document: doc,
        selection: HomericSelection.collapsed(doc.positionAt(0, 1)),
      );

      expect(controller.stateRevision, 0);
      expect(controller.contentRevision, 0);

      expect(
        controller.setSelection(
          HomericSelection.collapsed(doc.positionAt(0, 0)),
        ),
        isTrue,
      );
      expect(controller.stateRevision, 1);
      expect(controller.contentRevision, 0);

      final beforeMutation = controller.stateRevision;
      expect(controller.replaceSelection('x'), isTrue);
      expect(controller.stateRevision, 2);
      expect(controller.contentRevision, 1);
      expect(controller.undo(), isTrue);
      expect(controller.document, same(doc));
      expect(controller.stateRevision, 3);
      expect(controller.stateRevision, greaterThan(beforeMutation));
      expect(controller.contentRevision, 2);

      expect(controller.redo(), isTrue);
      expect(controller.stateRevision, 4);
      expect(controller.contentRevision, 3);
    });

    test('attribute-only edits do not advance the content revision', () {
      final doc = _document(['ab']);
      final controller = HomericEditorController(
        document: doc,
        selection: HomericSelection.collapsed(doc.positionAt(0, 1)),
      );

      expect(
        controller.applyBlockEditBatch(
          blockId: 'a',
          edits: const [
            CanonicalTextEdit(
              0,
              1,
              'a',
              attributes: {'strong': true},
            ),
          ],
          selection: const BlockTextSelection.collapsed(1),
        ),
        isTrue,
      );
      expect(controller.stateRevision, 1);
      expect(controller.contentRevision, 0);
      expect(controller.document.blocks.single.text, 'ab');
    });

    test('selection and preferred-x changes preserve redo', () {
      final doc = _document(['ab']);
      final controller = HomericEditorController(
        document: doc,
        selection: HomericSelection.collapsed(doc.positionAt(0, 1)),
      );
      controller.replaceSelection('x');
      controller.undo();
      final contentRevision = controller.contentRevision;

      expect(
        controller.setSelection(
          HomericSelection.collapsed(doc.positionAt(0, 0)),
          preferredX: 12,
        ),
        isTrue,
      );
      expect(controller.canRedo, isTrue);
      expect(controller.contentRevision, contentRevision);
      expect(controller.resetPreferredX(), isTrue);
      expect(controller.canRedo, isTrue);
      expect(controller.contentRevision, contentRevision);
      expect(controller.redo(), isTrue);
      expect(controller.document.blocks.single.text, 'axb');
    });

    test('new committed mutations clear redo', () {
      HomericEditorController editedController() {
        final doc = _document(['ab']);
        final controller = HomericEditorController(
          document: doc,
          selection: HomericSelection.collapsed(doc.positionAt(0, 1)),
        );
        controller.replaceSelection('x');
        controller.undo();
        expect(controller.canRedo, isTrue);
        return controller;
      }

      final textController = editedController();
      expect(textController.replaceSelection('y'), isTrue);
      expect(textController.canRedo, isFalse);

      final decorationController = editedController();
      expect(
        decorationController.replaceDecorations(
          DecorationSet.of([Decoration.inline('a', 0, 1)]),
        ),
        isTrue,
      );
      expect(decorationController.canRedo, isFalse);
      expect(decorationController.contentRevision, 2);

      final transactionController = editedController();
      final tx = Transaction(transactionController.document)
        ..insertText(transactionController.document.positionAt(0, 0), '!');
      expect(transactionController.applyTransaction(tx), isTrue);
      expect(transactionController.canRedo, isFalse);
    });

    test('composition remains one symmetric bounded history unit', () {
      final doc = _document(['ab']);
      final controller = HomericEditorController(
        document: doc,
        selection: HomericSelection.collapsed(doc.positionAt(0, 1)),
        maxUndoDepth: 2,
      );
      var notifications = 0;
      controller.addListener(() => notifications++);

      controller.applyBlockEditBatch(
        blockId: 'a',
        edits: const [CanonicalTextEdit(1, 1, 'x')],
        selection: const BlockTextSelection.collapsed(2),
        composing: const BlockTextRange(1, 2),
      );
      controller.applyBlockEditBatch(
        blockId: 'a',
        edits: const [CanonicalTextEdit(1, 2, 'xy')],
        selection: const BlockTextSelection.collapsed(3),
        composing: const BlockTextRange(1, 3),
      );

      final beforeUndoNotifications = notifications;
      expect(controller.undo(), isTrue);
      expect(controller.document, same(doc));
      expect(controller.composing, isNull);
      expect(notifications, beforeUndoNotifications + 1);
      expect(controller.canRedo, isTrue);

      expect(controller.redo(), isTrue);
      expect(controller.document.blocks.single.text, 'axyb');
      expect(controller.composing, isNull);
      expect(notifications, beforeUndoNotifications + 2);

      expect(controller.replaceSelection('1'), isTrue);
      expect(controller.replaceSelection('2'), isTrue);
      expect(controller.replaceSelection('3'), isTrue);
      expect(controller.undo(), isTrue);
      expect(controller.undo(), isTrue);
      expect(controller.undo(), isFalse);
      expect(controller.redo(), isTrue);
      expect(controller.redo(), isTrue);
      expect(controller.redo(), isFalse);
    });

    test('ordered batch commits once and undoes exact state', () {
      final doc = _document(['abcd']);
      final selection = HomericSelection.collapsed(doc.positionAt(0, 1));
      final controller = HomericEditorController(
        document: doc,
        selection: selection,
      );
      var notifications = 0;
      controller.addListener(() => notifications++);

      expect(
        controller.applyBlockEditBatch(
          blockId: 'a',
          edits: const [
            CanonicalTextEdit(1, 2, 'XY'),
            CanonicalTextEdit(3, 4, 'Z'),
          ],
          selection: const BlockTextSelection.collapsed(4),
        ),
        isTrue,
      );

      expect(controller.document.blocks.single.text, 'aXYZd');
      expect(controller.selection, const HomericSelection.collapsed(5));
      expect(notifications, 1);
      expect(controller.undo(), isTrue);
      expect(controller.document, same(doc));
      expect(controller.selection, selection);
      expect(notifications, 2);
    });

    test('later batch edits reveal decorations in shadow coordinates', () {
      final hidden = Decoration.replace(
        'a',
        2,
        4,
        replacementLength: 0,
      );
      final targets = <CanonicalEditTarget>[];
      late HomericEditorController controller;
      controller = HomericEditorController(
        document: Document([
          Block(id: 'a', type: 'paragraph', runs: [InlineRun('abcdef')]),
        ]),
        decorations: DecorationSet.of([hidden]),
        selection: const HomericSelection.collapsed(1),
        onBeforeCanonicalMutation: (target) {
          expect(controller.document.blocks.single.text, 'abcdef');
          targets.add(target);
        },
      );

      expect(
        controller.applyBlockEditBatch(
          blockId: 'a',
          edits: const [
            CanonicalTextEdit(0, 0, 'XYZ'),
            CanonicalTextEdit(5, 6, ''),
          ],
          selection: const BlockTextSelection.collapsed(5),
        ),
        isTrue,
      );

      expect(targets, const [CanonicalEditTarget('a', 2, 4)]);
      expect(controller.document.blocks.single.text, 'XYZabdef');
    });

    test('undo history retains only the configured number of snapshots', () {
      final controller = HomericEditorController(
        document: Document([
          Block(id: 'a', type: 'paragraph', runs: [InlineRun('')]),
        ]),
        selection: const HomericSelection.collapsed(1),
        maxUndoDepth: 2,
      );

      expect(controller.replaceSelection('a'), isTrue);
      expect(controller.replaceSelection('b'), isTrue);
      expect(controller.replaceSelection('c'), isTrue);
      expect(controller.document.blocks.single.text, 'abc');

      expect(controller.undo(), isTrue);
      expect(controller.document.blocks.single.text, 'ab');
      expect(controller.undo(), isTrue);
      expect(controller.document.blocks.single.text, 'a');
      expect(controller.undo(), isFalse);
    });

    test('selection-only batch preserves reverse direction and affinity', () {
      final doc = _document(['abcd']);
      final controller = HomericEditorController(
        document: doc,
        selection: HomericSelection.collapsed(doc.positionAt(0, 1)),
      );

      expect(
        controller.applyBlockEditBatch(
          blockId: 'a',
          selection: const BlockTextSelection(
            anchor: 4,
            head: 1,
            affinity: HomericCaretAffinity.upstream,
          ),
        ),
        isTrue,
      );

      expect(controller.selection!.anchor, doc.positionAt(0, 4));
      expect(controller.selection!.head, doc.positionAt(0, 1));
      expect(controller.selection!.isForward, isFalse);
      expect(controller.selection!.affinity, HomericCaretAffinity.upstream);
      expect(controller.document, same(doc));
      expect(controller.canUndo, isFalse);
    });

    test('provisional composition updates form one undo unit', () {
      final doc = _document(['ab']);
      final initial = HomericSelection.collapsed(doc.positionAt(0, 1));
      final decoration = Decoration.inline('a', 1, 2);
      final decorations = DecorationSet.of([decoration]);
      final controller = HomericEditorController(
        document: doc,
        decorations: decorations,
        selection: initial,
      );

      expect(
        controller.applyBlockEditBatch(
          blockId: 'a',
          edits: const [CanonicalTextEdit(1, 1, 'x')],
          selection: const BlockTextSelection.collapsed(2),
          composing: const BlockTextRange(1, 2),
        ),
        isTrue,
      );
      expect(
        controller.applyBlockEditBatch(
          blockId: 'a',
          edits: const [CanonicalTextEdit(1, 2, 'xy')],
          selection: const BlockTextSelection.collapsed(3),
          composing: const BlockTextRange(1, 3),
        ),
        isTrue,
      );
      expect(controller.canUndo, isFalse,
          reason: 'the open composition has not committed yet');
      expect(controller.decorations, isNot(same(decorations)));

      expect(
        controller.applyBlockEditBatch(
          blockId: 'a',
          selection: const BlockTextSelection.collapsed(3),
        ),
        isTrue,
      );
      expect(controller.composing, isNull);
      expect(controller.canUndo, isTrue);
      expect(controller.undo(), isTrue);
      expect(controller.document, same(doc));
      expect(controller.decorations, same(decorations));
      expect(controller.decorations.forBlock('a'), [decoration]);
      expect(controller.selection, initial);
    });

    test('selection-only composition update keeps group open', () {
      final doc = _document(['ab']);
      final controller = HomericEditorController(
        document: doc,
        selection: HomericSelection.collapsed(doc.positionAt(0, 1)),
      );
      controller.applyBlockEditBatch(
        blockId: 'a',
        edits: const [CanonicalTextEdit(1, 1, 'x')],
        selection: const BlockTextSelection.collapsed(2),
        composing: const BlockTextRange(1, 2),
      );

      expect(
        controller.applyBlockEditBatch(
          blockId: 'a',
          selection: const BlockTextSelection.collapsed(1),
          composing: const BlockTextRange(1, 2),
        ),
        isTrue,
      );
      expect(controller.canUndo, isFalse);
      expect(controller.composing, HomericTextRange(2, 3));
    });

    test('controller actions defer to the platform during composition', () {
      final doc = _document(['ab']);
      final controller = HomericEditorController(
        document: doc,
        selection: HomericSelection.collapsed(doc.positionAt(0, 1)),
      );
      controller.applyBlockEditBatch(
        blockId: 'a',
        edits: const [CanonicalTextEdit(1, 1, 'x')],
        selection: const BlockTextSelection.collapsed(2),
        composing: const BlockTextRange(1, 2),
      );
      final selectionDuringComposition = controller.selection;

      expect(controller.deleteBackward(), isFalse);
      expect(controller.deleteForward(), isFalse);
      expect(controller.replaceSelection('z'), isFalse);
      expect(
        controller.setSelection(
          HomericSelection.collapsed(controller.document.positionAt(0, 0)),
        ),
        isFalse,
      );
      expect(controller.document.blocks.single.text, 'axb');
      expect(controller.selection, selectionDuringComposition);
      expect(controller.composing, isNotNull);
    });

    test('all controller-owned interruptions commit visible composition', () {
      for (final interruption in CompositionInterruption.values) {
        final doc = _document(['ab']);
        final controller = HomericEditorController(
          document: doc,
          selection: HomericSelection.collapsed(doc.positionAt(0, 1)),
        );
        controller.applyBlockEditBatch(
          blockId: 'a',
          edits: const [CanonicalTextEdit(1, 1, 'x')],
          selection: const BlockTextSelection.collapsed(2),
          composing: const BlockTextRange(1, 2),
        );

        final changed = controller.interruptComposition(interruption);

        if (interruption == CompositionInterruption.staleEpoch) {
          expect(changed, isFalse);
          expect(controller.composing, isNotNull);
          expect(controller.canUndo, isFalse);
        } else {
          expect(changed, isTrue, reason: interruption.name);
          expect(controller.document.blocks.single.text, 'axb');
          expect(controller.composing, isNull);
          expect(controller.canUndo, isTrue);
        }
      }
    });

    test('pointer relocation commits composition before moving selection', () {
      final doc = _document(['ab']);
      final controller = HomericEditorController(
        document: doc,
        selection: HomericSelection.collapsed(doc.positionAt(0, 1)),
      );
      controller.applyBlockEditBatch(
        blockId: 'a',
        edits: const [CanonicalTextEdit(1, 1, 'x')],
        selection: const BlockTextSelection.collapsed(2),
        composing: const BlockTextRange(1, 2),
      );

      expect(
        controller.relocateSelection(
          HomericSelection.collapsed(controller.document.positionAt(0, 0)),
        ),
        isTrue,
      );
      expect(controller.composing, isNull);
      expect(controller.selection, const HomericSelection.collapsed(1));
      expect(controller.canUndo, isTrue);
    });

    test('active block switch closes composition before the new undo unit', () {
      final doc = _document(['ab', 'cd']);
      final controller = HomericEditorController(
        document: doc,
        selection: HomericSelection.collapsed(doc.positionAt(0, 1)),
      );
      controller.applyBlockEditBatch(
        blockId: 'a',
        edits: const [CanonicalTextEdit(1, 1, 'x')],
        selection: const BlockTextSelection.collapsed(2),
        composing: const BlockTextRange(1, 2),
      );

      expect(
        controller.applyBlockEditBatch(
          blockId: 'b',
          edits: const [CanonicalTextEdit(2, 2, '!')],
          selection: const BlockTextSelection.collapsed(3),
        ),
        isTrue,
      );
      expect(controller.document.blocks[0].text, 'axb');
      expect(controller.document.blocks[1].text, 'cd!');
      expect(controller.composing, isNull);

      expect(controller.undo(), isTrue);
      expect(controller.document.blocks[0].text, 'axb');
      expect(controller.document.blocks[1].text, 'cd');
      expect(controller.undo(), isTrue);
      expect(controller.document, same(doc));
    });

    test('disposal commits visible composition without discarding undo state',
        () {
      final doc = _document(['ab']);
      final controller = HomericEditorController(
        document: doc,
        selection: HomericSelection.collapsed(doc.positionAt(0, 1)),
      );
      controller.applyBlockEditBatch(
        blockId: 'a',
        edits: const [CanonicalTextEdit(1, 1, 'x')],
        selection: const BlockTextSelection.collapsed(2),
        composing: const BlockTextRange(1, 2),
      );

      controller.dispose();

      expect(controller.document.blocks.single.text, 'axb');
      expect(controller.composing, isNull);
      expect(controller.canUndo, isTrue);
    });

    test('external transaction closes composition before its own undo unit',
        () {
      final doc = _document(['ab']);
      final controller = HomericEditorController(
        document: doc,
        selection: HomericSelection.collapsed(doc.positionAt(0, 1)),
      );
      controller.applyBlockEditBatch(
        blockId: 'a',
        edits: const [CanonicalTextEdit(1, 1, 'x')],
        selection: const BlockTextSelection.collapsed(2),
        composing: const BlockTextRange(1, 2),
      );
      final tx = Transaction(controller.document)
        ..insertText(controller.document.positionAt(0, 3), '!');

      expect(controller.applyTransaction(tx), isTrue);
      expect(controller.document.blocks.single.text, 'axb!');
      expect(controller.undo(), isTrue);
      expect(controller.document.blocks.single.text, 'axb');
      expect(controller.undo(), isTrue);
      expect(controller.document, same(doc));
    });

    test('invalid edit batch is atomic and does not notify', () {
      final doc = _document(['ab', 'cd']);
      final controller = HomericEditorController(
        document: doc,
        selection: HomericSelection.collapsed(doc.positionAt(0, 1)),
      );
      var notifications = 0;
      controller.addListener(() => notifications++);

      expect(
        controller.applyBlockEditBatch(
          blockId: 'a',
          edits: const [CanonicalTextEdit(0, 1, 'x\ny')],
          selection: const BlockTextSelection.collapsed(3),
        ),
        isFalse,
      );
      expect(controller.document, same(doc));
      expect(notifications, 0);
    });
  });
}

Document _document(List<String> texts) => Document([
      for (var i = 0; i < texts.length; i++)
        Block(
          id: String.fromCharCode('a'.codeUnitAt(0) + i),
          type: 'paragraph',
          runs: [InlineRun(texts[i])],
        ),
    ]);
