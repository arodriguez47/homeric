import 'package:flutter/widgets.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

const _style = TextStyle(fontSize: 14);

void main() {
  for (final keyCase in <({String name, LogicalKeyboardKey key})>[
    (name: 'keyboard Enter', key: LogicalKeyboardKey.enter),
    (name: 'numpad Enter', key: LogicalKeyboardKey.numpadEnter),
  ]) {
    testWidgets('${keyCase.name} mounts and retargets the trailing block',
        (tester) async {
      await _expectBreakRetargetsAndAcceptsDelta(
        tester,
        trigger: () => tester.sendKeyEvent(keyCase.key),
      );
    });
  }

  testWidgets('TextInputAction.newline mounts and retargets the trailing block',
      (tester) async {
    TextInputConnection.debugResetId();
    final document = _document(<String>['alpha']);
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(0, 2)),
    );
    final session = HomericTextInputSession(controller: controller);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    final key = GlobalKey<HomericEditableDocumentState>();
    await tester.pumpWidget(_editableDocument(controller, session, key: key));
    await tester.pump();
    final paragraph = find.byKey(const ValueKey('homeric-editable-block-0'));
    await tester.tapAt(tester.getTopLeft(paragraph) + const Offset(15, 7));
    await tester.pump();
    controller.setSelection(
      HomericSelection.collapsed(controller.document.positionAt(0, 2)),
    );
    await _sendTextInputAction(
      tester.binding,
      1,
      'TextInputAction.newline',
    );
    await tester.pump();
    await tester.pump();

    expect(controller.document.blocks.map((block) => block.text),
        <String>['al', 'pha']);
    final trailingBlockId = controller.document.blocks.last.id;
    expect(controller.activeBlockId, trailingBlockId);
    expect(session.activeBlockId, trailingBlockId);
    expect(key.currentState!.focusedBlockId, trailingBlockId);
    _insertAtStartThroughPlatform(session, oldText: 'pha', text: 'X');
    await tester.pump();
    expect(controller.document.blocks.last.text, 'Xpha');
  });

  testWidgets('document drag suspends input and retargets only on release',
      (tester) async {
    final document = _document(List<String>.generate(50, (index) => '$index'));
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(0, 1)),
    );
    final session = HomericTextInputSession(controller: controller);
    final key = GlobalKey<HomericEditableDocumentState>();
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: HomericEditableDocument(
        key: key,
        controller: controller,
        inputSession: session,
        child: const SizedBox(),
      ),
    ));
    final firstDelegate = _CommandDelegate();
    final lastDelegate = _CommandDelegate();
    key.currentState!.registerCommandHost('block-0', firstDelegate);
    key.currentState!.registerCommandHost('block-49', lastDelegate);
    expect(session.attach(blockId: 'block-0', commandDelegate: firstDelegate),
        isTrue);

    key.currentState!.beginSelectionDrag();
    for (var index = 1; index < document.blockCount; index++) {
      controller.setSelection(HomericSelection(
        anchor: document.positionAt(0, 1),
        head: document.positionAt(index, 1),
      ));
      expect(session.activeBlockId, 'block-0');
    }

    expect(key.currentState!.endSelectionDrag(), isTrue);
    expect(session.activeBlockId, 'block-49');
    session.debugSelectorCallback!('moveRight:');
    expect(firstDelegate.invocations, 0);
    expect(lastDelegate.invocations, 1);
  });

  testWidgets('removing the composing block closes it before host retarget',
      (tester) async {
    final document = _document(<String>['a', 'b']);
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(1, 1)),
    );
    final session = HomericTextInputSession(controller: controller);
    final key = GlobalKey<HomericEditableDocumentState>();
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: HomericEditableDocument(
        key: key,
        controller: controller,
        inputSession: session,
        child: const SizedBox(),
      ),
    ));
    final leadingDelegate = _CommandDelegate();
    final removedDelegate = _CommandDelegate();
    key.currentState!
      ..registerCommandHost('block-0', leadingDelegate)
      ..registerCommandHost('block-1', removedDelegate);
    expect(
      session.attach(blockId: 'block-1', commandDelegate: removedDelegate),
      isTrue,
    );
    expect(
      controller.applyBlockEditBatch(
        blockId: 'block-1',
        edits: const <CanonicalTextEdit>[
          CanonicalTextEdit(1, 1, 'X'),
        ],
        selection: const BlockTextSelection.collapsed(2),
        composing: const BlockTextRange(1, 2),
      ),
      isTrue,
    );
    expect(controller.composing, isNotNull);

    final transaction = Transaction(controller.document)
      ..joinBlocks(controller.document.positionAfterBlock(0));
    expect(controller.applyTransaction(transaction), isTrue);

    expect(controller.composing, isNull);
    expect(controller.document.blocks.single.text, 'abX');
    expect(session.activeBlockId, 'block-0');
    session.debugSelectorCallback!('moveRight:');
    expect(removedDelegate.invocations, 0);
    expect(leadingDelegate.invocations, 1);
  });

  testWidgets('builder mounts a bounded natural-height window', (tester) async {
    final document = _document(
      List<String>.generate(3500, (index) => 'row $index'),
    );
    final controller = HomericEditorController(document: document);
    final session = HomericTextInputSession(controller: controller);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_withOverlay(
      SizedBox(
        width: 500,
        height: 300,
        child: HomericEditableDocument.builder(
          controller: controller,
          inputSession: session,
          cacheExtent: 100,
          estimatedBlockHeight: 30,
          blockBuilder: (context, block, focusNode) => SizedBox(
            key: ValueKey('content-${block.id}'),
            height: block.id == 'block-0' ? 70 : 30,
          ),
        ),
      ),
    ));

    expect(tester.getSize(find.byKey(const ValueKey('content-block-0'))).height,
        70);
    expect(find.byKey(const ValueKey('content-block-3499')), findsNothing);
    expect(find.byType(SizedBox).evaluate().length, lessThan(40));
  });

  testWidgets(
      'recycled unchanged paragraphs reuse layout while changed content misses',
      (tester) async {
    final document = _document(List<String>.generate(
      40,
      (index) => 'row $index with enough text to exercise paragraph layout',
    ));
    final controller = HomericEditorController(document: document);
    final session = HomericTextInputSession(controller: controller);
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_withOverlay(SizedBox(
      width: 500,
      height: 180,
      child: HomericEditableDocument.builder(
        controller: controller,
        inputSession: session,
        scrollController: scrollController,
        cacheExtent: 0,
        estimatedBlockHeight: 44,
        layoutRevision: const ('test-style', 14.0),
        blockBuilder: (context, block, focusNode) => HomericEditableParagraph(
          controller: controller,
          inputSession: session,
          blockId: block.id,
          focusNode: focusNode,
          resolveStyle: (_) => _style,
        ),
      ),
    )));
    await tester.pump();

    scrollController.jumpTo(scrollController.position.maxScrollExtent);
    await tester.pump();
    final unchangedProbe = HomericParagraphLayoutProbe.start();
    scrollController.jumpTo(0);
    await tester.pump();
    final unchanged = unchangedProbe.stop();
    expect(unchanged.countFor(HomericParagraphLayoutCategory.live), 0,
        reason: 'unchanged recycled rows should reclaim shaped paragraphs');

    scrollController.jumpTo(scrollController.position.maxScrollExtent);
    await tester.pump();
    expect(
      controller.applyBlockEditBatch(
        blockId: 'block-0',
        edits: const <CanonicalTextEdit>[CanonicalTextEdit(0, 0, 'changed ')],
        selection: const BlockTextSelection.collapsed(8),
        composing: null,
      ),
      isTrue,
    );
    final changedProbe = HomericParagraphLayoutProbe.start();
    scrollController.jumpTo(0);
    await tester.pump();
    final changed = changedProbe.stop();
    expect(changed.countFor(HomericParagraphLayoutCategory.live), 1,
        reason: 'the changed block must not reuse its stale paragraph');
  });

  testWidgets('deleting a mounted block cannot reinsert its detached shape',
      (tester) async {
    final document = _document(<String>['first', 'removed', 'last']);
    final controller = HomericEditorController(document: document);
    final session = HomericTextInputSession(controller: controller);
    final key = GlobalKey<HomericEditableDocumentState>();
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_editableDocument(controller, session, key: key));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('homeric-editable-block-1')),
      findsOneWidget,
    );
    expect(key.currentState!.debugParagraphLayoutCacheEntries, 0);

    final transaction = Transaction(controller.document)
      ..joinBlocks(controller.document.positionAfterBlock(0));
    expect(controller.applyTransaction(transaction), isTrue);
    await tester.pump();

    expect(
      find.byKey(const ValueKey('homeric-editable-block-1')),
      findsNothing,
    );
    expect(key.currentState!.debugParagraphLayoutCacheEntries, 0,
        reason: 'a deleted mounted row is no longer an allowed cache key');
  });

  testWidgets('far scroll reaches a stable block without eager mounting',
      (tester) async {
    final document = _document(
      List<String>.generate(1000, (index) => 'row $index'),
    );
    final controller = HomericEditorController(document: document);
    final session = HomericTextInputSession(controller: controller);
    final key = GlobalKey<HomericEditableDocumentState>();
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_withOverlay(
      SizedBox(
        width: 500,
        height: 300,
        child: HomericEditableDocument.builder(
          key: key,
          controller: controller,
          inputSession: session,
          cacheExtent: 100,
          estimatedBlockHeight: 30,
          blockBuilder: (context, block, focusNode) => SizedBox(
            key: ValueKey('content-${block.id}'),
            height: 30,
          ),
        ),
      ),
    ));

    final result = key.currentState!.scrollToBlock('block-900');
    for (var frame = 0; frame < 10; frame++) {
      await tester.pump();
    }
    expect(await result, HomericScrollToBlockResult.reached);
    expect(find.byKey(const ValueKey('content-block-900')), findsOneWidget);
    expect(find.byKey(const ValueKey('content-block-0')), findsNothing);
  });

  testWidgets('newer off-screen selection wins overlapping focus requests',
      (tester) async {
    final document = _document(
      List<String>.generate(100, (index) => 'row $index'),
    );
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(50, 0)),
    );
    final session = HomericTextInputSession(controller: controller);
    final key = GlobalKey<HomericEditableDocumentState>();
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_withOverlay(SizedBox(
      width: 500,
      height: 180,
      child: HomericEditableDocument.builder(
        key: key,
        controller: controller,
        inputSession: session,
        cacheExtent: 0,
        estimatedBlockHeight: 44,
        blockBuilder: (context, block, focusNode) => Focus(
          focusNode: focusNode,
          child: SizedBox(
            key: ValueKey('content-${block.id}'),
            height: 44,
          ),
        ),
      ),
    )));
    final middle = key.currentState!.scrollToBlock('block-50');
    for (var frame = 0; frame < 10; frame++) {
      await tester.pump();
    }
    expect(await middle, HomericScrollToBlockResult.reached);

    expect(
      key.currentState!.moveToDocumentBoundary(
        forward: true,
        extend: false,
      ),
      isTrue,
    );
    expect(
      key.currentState!.moveToDocumentBoundary(
        forward: false,
        extend: false,
      ),
      isTrue,
    );
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump();
    }

    expect(controller.activeBlockId, 'block-0');
    expect(key.currentState!.focusedBlockId, 'block-0');
  });

  testWidgets('deep typing skips order rebuilds while structure updates them',
      (tester) async {
    final document = _document(
      List<String>.generate(1000, (index) => 'row $index'),
    );
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(900, 3)),
    );
    final session = HomericTextInputSession(controller: controller);
    final key = GlobalKey<HomericEditableDocumentState>();
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_withOverlay(SizedBox(
      width: 500,
      height: 180,
      child: HomericEditableDocument.builder(
        key: key,
        controller: controller,
        inputSession: session,
        cacheExtent: 0,
        estimatedBlockHeight: 44,
        blockBuilder: (context, block, focusNode) => const SizedBox(height: 44),
      ),
    )));
    final initialRebuilds = key.currentState!.debugHeightOrderRebuildCount;

    expect(
      controller.applyBlockEditBatch(
        blockId: 'block-900',
        edits: const <CanonicalTextEdit>[CanonicalTextEdit(3, 3, 'X')],
        selection: const BlockTextSelection.collapsed(4),
        composing: null,
      ),
      isTrue,
    );
    expect(key.currentState!.debugHeightOrderRebuildCount, initialRebuilds);

    expect(
      controller.insertParagraphBreak(trailingBlockId: 'split-block'),
      isTrue,
    );
    expect(
      key.currentState!.debugHeightOrderRebuildCount,
      initialRebuilds + 1,
    );

    expect(controller.deleteBackward(), isTrue);
    expect(
      key.currentState!.debugHeightOrderRebuildCount,
      initialRebuilds + 2,
    );

    expect(key.currentState!.moveBlockBy('block-900', -1), isTrue);
    expect(
      key.currentState!.debugHeightOrderRebuildCount,
      initialRebuilds + 3,
    );
  });

  testWidgets('external replacement outside the active block rebuilds order',
      (tester) async {
    final document = _document(<String>['alpha', 'beta', 'gamma']);
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(2, 2)),
    );
    final session = HomericTextInputSession(controller: controller);
    final key = GlobalKey<HomericEditableDocumentState>();
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_withOverlay(SizedBox(
      width: 500,
      height: 180,
      child: HomericEditableDocument.builder(
        key: key,
        controller: controller,
        inputSession: session,
        cacheExtent: 0,
        estimatedBlockHeight: 44,
        blockBuilder: (context, block, focusNode) => SizedBox(
          height: 44,
          child: Text(block.text, key: ValueKey('text-${block.id}')),
        ),
      ),
    )));
    final initialRebuilds = key.currentState!.debugHeightOrderRebuildCount;
    final originalIds = controller.document.blocks.map((block) => block.id);
    final transaction = Transaction(controller.document)
      ..insertText(controller.document.positionAt(0, 5), '!');

    expect(controller.applyTransaction(transaction), isTrue);
    await tester.pump();

    expect(controller.document.blocks.map((block) => block.id), originalIds);
    expect(controller.activeBlockId, 'block-2');
    expect(
      key.currentState!.debugHeightOrderRebuildCount,
      initialRebuilds + 1,
    );
    expect(find.text('alpha!'), findsOneWidget);
  });

  testWidgets('only the active off-screen row remains kept alive',
      (tester) async {
    final document = _document(
      List<String>.generate(100, (index) => 'row $index'),
    );
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(0, 0)),
    );
    final session = HomericTextInputSession(controller: controller);
    final key = GlobalKey<HomericEditableDocumentState>();
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_withOverlay(SizedBox(
      width: 500,
      height: 300,
      child: HomericEditableDocument.builder(
        key: key,
        controller: controller,
        inputSession: session,
        cacheExtent: 0,
        estimatedBlockHeight: 30,
        blockBuilder: (context, block, focusNode) => SizedBox(
          key: ValueKey('content-${block.id}'),
          height: 30,
        ),
      ),
    )));

    final result = key.currentState!.scrollToBlock('block-80');
    for (var frame = 0; frame < 10; frame++) {
      await tester.pump();
    }
    expect(await result, HomericScrollToBlockResult.reached);
    expect(
      find.byKey(
        const ValueKey('content-block-0'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey('content-block-1'),
        skipOffstage: false,
      ),
      findsNothing,
    );

    controller.setSelection(
      HomericSelection.collapsed(document.positionAt(80, 0)),
    );
    await tester.pump();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1));
    await tester.pump();
    expect(
      find.byKey(
        const ValueKey('content-block-0'),
        skipOffstage: false,
      ),
      findsNothing,
    );
  });

  testWidgets('one measured change above the viewport corrects its anchor once',
      (tester) async {
    final document = _document(
      List<String>.generate(60, (index) => 'row $index'),
    );
    final controller = HomericEditorController(document: document);
    final session = HomericTextInputSession(controller: controller);
    final scrollController = ScrollController();
    final changedHeight = ValueNotifier<double>(30);
    final key = GlobalKey<HomericEditableDocumentState>();
    addTearDown(changedHeight.dispose);
    addTearDown(scrollController.dispose);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_withOverlay(SizedBox(
      width: 500,
      height: 300,
      child: HomericEditableDocument.builder(
        key: key,
        controller: controller,
        inputSession: session,
        scrollController: scrollController,
        cacheExtent: 600,
        estimatedBlockHeight: 30,
        blockBuilder: (context, block, focusNode) => block.id == 'block-9'
            ? ValueListenableBuilder<double>(
                valueListenable: changedHeight,
                builder: (_, height, __) => SizedBox(
                  key: const ValueKey('content-block-9'),
                  height: height,
                ),
              )
            : const SizedBox(height: 30),
      ),
    )));
    final result = key.currentState!.scrollToBlock('block-20');
    for (var frame = 0; frame < 10; frame++) {
      await tester.pump();
    }
    expect(await result, HomericScrollToBlockResult.reached);
    expect(
      find.byKey(
        const ValueKey('content-block-9'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    final before = scrollController.offset;

    changedHeight.value = 80;
    await tester.pump();
    await tester.pump();

    // The always-visible 44px reorder target is now the row's minimum height.
    expect(scrollController.offset, closeTo(before + 36, 0.01));
  });

  testWidgets('reorder preserves an unaffected visible viewport anchor',
      (tester) async {
    final document = _document(
      List<String>.generate(60, (index) => 'row $index'),
    );
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(20, 0)),
    );
    final session = HomericTextInputSession(controller: controller);
    final key = GlobalKey<HomericEditableDocumentState>();
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_withOverlay(SizedBox(
      width: 500,
      height: 300,
      child: HomericEditableDocument.builder(
        key: key,
        controller: controller,
        inputSession: session,
        cacheExtent: 100,
        estimatedBlockHeight: 44,
        blockBuilder: (context, block, focusNode) => SizedBox(
          key: ValueKey('content-${block.id}'),
          height: 30,
        ),
      ),
    )));
    final result = key.currentState!.scrollToBlock('block-20');
    for (var frame = 0; frame < 10; frame++) {
      await tester.pump();
    }
    expect(await result, HomericScrollToBlockResult.reached);
    final anchor = find.byKey(const ValueKey('content-block-20'));
    final beforeTop = tester.getTopLeft(anchor).dy;

    expect(key.currentState!.moveBlockBy('block-0', 59), isTrue);
    await tester.pump();
    await tester.pump();

    expect(tester.getTopLeft(anchor).dy, closeTo(beforeTop, 0.5));
    expect(controller.document.blocks.last.id, 'block-0');
  });

  testWidgets('global selection exposes directional fragments and empty wash',
      (tester) async {
    final document = _document(<String>['ab', '', 'cd']);
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection(
        anchor: document.positionAt(0, 1),
        head: document.positionAt(2, 1),
      ),
    );
    final session = HomericTextInputSession(controller: controller);
    final key = GlobalKey<HomericEditableDocumentState>();
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_editableDocument(controller, session, key: key));
    await tester.pump();

    expect(
      key.currentState!.selectionFragmentForBlock('block-0'),
      const BlockTextSelection(anchor: 1, head: 2),
    );
    expect(
      key.currentState!.selectionFragmentForBlock('block-1'),
      const BlockTextSelection(anchor: 0, head: 0),
    );
    expect(
      key.currentState!.selectionFragmentForBlock('block-2'),
      const BlockTextSelection(anchor: 0, head: 1),
    );
    expect(key.currentState!.isBlockFullySelected('block-1'), isTrue);
    expect(
      find.byKey(const ValueKey('homeric-empty-selection-block-1')),
      findsOneWidget,
    );

    controller.setSelection(HomericSelection(
      anchor: document.positionAt(2, 1),
      head: document.positionAt(0, 1),
      affinity: HomericCaretAffinity.upstream,
    ));
    await tester.pump();
    expect(
      key.currentState!.selectionFragmentForBlock('block-0'),
      const BlockTextSelection(
        anchor: 2,
        head: 1,
        affinity: HomericCaretAffinity.upstream,
      ),
    );
    expect(
      key.currentState!.selectionFragmentForBlock('block-2'),
      const BlockTextSelection(
        anchor: 1,
        head: 0,
        affinity: HomericCaretAffinity.upstream,
      ),
    );
  });

  testWidgets('arrows and Shift arrows cross blocks without losing the anchor',
      (tester) async {
    final document = _document(<String>['ab', 'cd']);
    final controller = HomericEditorController(document: document);
    final session = HomericTextInputSession(controller: controller);
    final key = GlobalKey<HomericEditableDocumentState>();
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_editableDocument(controller, session, key: key));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('homeric-editable-block-0')));
    controller.setSelection(
      HomericSelection.collapsed(controller.document.positionAt(0, 2)),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    _expectSelectionHead(controller, blockId: 'block-1', offset: 0);
    expect(session.activeBlockId, 'block-1');
    expect(key.currentState!.focusedBlockId, 'block-1');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    _expectSelectionHead(controller, blockId: 'block-0', offset: 2);

    await _sendShiftArrow(tester, LogicalKeyboardKey.arrowRight);
    await tester.pump();
    final anchor = controller.document.positionAt(0, 2);
    expect(controller.selection?.anchor, anchor);
    _expectSelectionHead(controller, blockId: 'block-1', offset: 0);

    await _sendShiftArrow(tester, LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(controller.selection?.anchor, anchor);
    _expectSelectionHead(controller, blockId: 'block-1', offset: 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(controller.selection?.isCollapsed, isTrue);
    _expectSelectionHead(controller, blockId: 'block-1', offset: 1);
  });

  testWidgets('vertical arrows cross single-line blocks and retain preferred x',
      (tester) async {
    final document = _document(<String>['ab', 'cd']);
    final controller = HomericEditorController(document: document);
    final session = HomericTextInputSession(controller: controller);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_editableDocument(controller, session));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('homeric-editable-block-0')));
    controller.setSelection(
      HomericSelection.collapsed(controller.document.positionAt(0, 1)),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    _expectSelectionHead(controller, blockId: 'block-1', offset: 0);
    final preferredX = controller.preferredX;
    expect(preferredX, isNotNull);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    _expectSelectionHead(controller, blockId: 'block-0', offset: 2);
    expect(controller.preferredX, preferredX);
  });

  testWidgets('document Select All and boundary commands own global positions',
      (tester) async {
    final document = _document(<String>['ab', 'cd']);
    final controller = HomericEditorController(document: document);
    final session = HomericTextInputSession(controller: controller);
    final key = GlobalKey<HomericEditableDocumentState>();
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_editableDocument(controller, session, key: key));
    await tester.pump();
    final paragraph = find.byKey(const ValueKey('homeric-editable-block-0'));
    await tester.tap(paragraph);
    controller.setSelection(
      HomericSelection.collapsed(controller.document.positionAt(0, 1)),
    );
    await tester.pump();

    expect(key.currentState!.selectAll(), isTrue);
    await tester.pump();
    expect(
      controller.selection,
      HomericSelection(
        anchor: controller.document.positionAt(0, 0),
        head: controller.document.positionAt(1, 2),
      ),
    );

    controller.setSelection(
      HomericSelection.collapsed(controller.document.positionAt(0, 1)),
    );
    await tester.pump();
    expect(
      key.currentState!.moveToDocumentBoundary(
        forward: true,
        extend: true,
      ),
      isTrue,
    );
    await tester.pump();
    expect(controller.selection?.anchor, controller.document.positionAt(0, 1));
    expect(controller.selection?.head, controller.document.positionAt(1, 2));
  });

  testWidgets(
      'stationary edge drag autoscrolls through recycled rows and retargets once',
      (tester) async {
    final document = _document(
      List<String>.generate(80, (index) => 'row $index content'),
    );
    final controller = HomericEditorController(document: document);
    final session = HomericTextInputSession(controller: controller);
    final scrollController = ScrollController();
    final key = GlobalKey<HomericEditableDocumentState>();
    addTearDown(scrollController.dispose);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_withOverlay(SizedBox(
      width: 500,
      height: 180,
      child: HomericEditableDocument.builder(
        key: key,
        controller: controller,
        inputSession: session,
        scrollController: scrollController,
        cacheExtent: 0,
        estimatedBlockHeight: 44,
        blockBuilder: (context, block, focusNode) => HomericEditableParagraph(
          controller: controller,
          inputSession: session,
          blockId: block.id,
          focusNode: focusNode,
          resolveStyle: (_) => _style,
        ),
      ),
    )));
    await tester.pump();

    final paragraph = find.byKey(
      const ValueKey<String>('homeric-editable-block-0'),
    );
    final viewport = tester.getRect(find.byType(CustomScrollView));
    final start = tester.getCenter(paragraph);
    await tester.tap(paragraph);
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 1));
    key.currentState!.beginPointerSelectionDrag(document.positionAt(0, 2));
    key.currentState!.updatePointerSelectionDrag(
      Offset(start.dx, viewport.bottom + 20),
    );
    for (var tick = 0; tick < 24; tick++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(key.currentState!.pointerSelectionDragActive, isTrue);
    expect(scrollController.offset, greaterThan(0));
    expect(session.activeBlockId, 'block-0');
    final selection = controller.selection!;
    final anchor =
        controller.document.resolve(selection.anchor) as InlinePosition;
    final head = controller.document.resolve(selection.head) as InlinePosition;
    expect(anchor.block.id, 'block-0');
    expect(controller.document.indexOfBlockId(head.block.id), greaterThan(0));

    expect(key.currentState!.endPointerSelectionDrag(), isTrue);
    await tester.pump();
    expect(key.currentState!.pointerSelectionDragActive, isFalse);
    expect(session.activeBlockId, head.block.id);
    final stoppedOffset = scrollController.offset;
    await tester.pump(const Duration(milliseconds: 80));
    expect(scrollController.offset, stoppedOffset);
  });

  testWidgets('selection autoscroll reverses from bottom edge to top edge',
      (tester) async {
    final document = _document(
      List<String>.generate(80, (index) => 'row $index content'),
    );
    final controller = HomericEditorController(document: document);
    final session = HomericTextInputSession(controller: controller);
    final scrollController = ScrollController();
    final key = GlobalKey<HomericEditableDocumentState>();
    addTearDown(scrollController.dispose);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_withOverlay(SizedBox(
      width: 500,
      height: 180,
      child: HomericEditableDocument.builder(
        key: key,
        controller: controller,
        inputSession: session,
        scrollController: scrollController,
        cacheExtent: 0,
        estimatedBlockHeight: 44,
        blockBuilder: (context, block, focusNode) => HomericEditableParagraph(
          controller: controller,
          inputSession: session,
          blockId: block.id,
          focusNode: focusNode,
          resolveStyle: (_) => _style,
        ),
      ),
    )));
    final middle = key.currentState!.scrollToBlock('block-30');
    for (var frame = 0; frame < 10; frame++) {
      await tester.pump();
    }
    expect(await middle, HomericScrollToBlockResult.reached);
    final viewport = tester.getRect(find.byType(CustomScrollView));
    final startOffset = scrollController.offset;

    key.currentState!.beginPointerSelectionDrag(document.positionAt(30, 2));
    key.currentState!.updatePointerSelectionDrag(
      Offset(viewport.center.dx, viewport.bottom + 20),
    );
    for (var tick = 0; tick < 4; tick++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final afterDownwardTicks = scrollController.offset;
    expect(afterDownwardTicks, greaterThan(startOffset));

    key.currentState!.updatePointerSelectionDrag(
      Offset(viewport.center.dx, viewport.top - 20),
    );
    for (var tick = 0; tick < 4; tick++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(scrollController.offset, lessThan(afterDownwardTicks));
    key.currentState!.cancelPointerSelectionDrag();
  });

  testWidgets('document mutation cancels selection autoscroll immediately',
      (tester) async {
    final document = _document(
      List<String>.generate(40, (index) => 'row $index content'),
    );
    final controller = HomericEditorController(document: document);
    final session = HomericTextInputSession(controller: controller);
    final scrollController = ScrollController();
    final key = GlobalKey<HomericEditableDocumentState>();
    addTearDown(scrollController.dispose);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_withOverlay(SizedBox(
      width: 500,
      height: 180,
      child: HomericEditableDocument.builder(
        key: key,
        controller: controller,
        inputSession: session,
        scrollController: scrollController,
        cacheExtent: 0,
        estimatedBlockHeight: 44,
        blockBuilder: (context, block, focusNode) => HomericEditableParagraph(
          controller: controller,
          inputSession: session,
          blockId: block.id,
          focusNode: focusNode,
          resolveStyle: (_) => _style,
        ),
      ),
    )));
    await tester.pump();

    final paragraph = find.byKey(
      const ValueKey<String>('homeric-editable-block-0'),
    );
    final viewport = tester.getRect(find.byType(CustomScrollView));
    final start = tester.getCenter(paragraph);
    await tester.tap(paragraph);
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 1));
    key.currentState!.beginPointerSelectionDrag(document.positionAt(0, 2));
    key.currentState!.updatePointerSelectionDrag(
      Offset(start.dx, viewport.bottom + 20),
    );
    await tester.pump(const Duration(milliseconds: 32));
    expect(key.currentState!.pointerSelectionDragActive, isTrue);

    expect(
      controller.applyBlockEditBatch(
        blockId: 'block-0',
        edits: const <CanonicalTextEdit>[CanonicalTextEdit(0, 0, 'X')],
        selection: const BlockTextSelection.collapsed(1),
        composing: null,
      ),
      isTrue,
    );
    await tester.pump();
    expect(key.currentState!.pointerSelectionDragActive, isFalse);
    final stoppedOffset = scrollController.offset;
    await tester.pump(const Duration(milliseconds: 80));
    expect(scrollController.offset, stoppedOffset);
  });

  testWidgets('focus leaving every editor row cancels a live pointer drag',
      (tester) async {
    final document = _document(
      List<String>.generate(40, (index) => 'row $index content'),
    );
    final controller = HomericEditorController(document: document);
    final session = HomericTextInputSession(controller: controller);
    final key = GlobalKey<HomericEditableDocumentState>();
    final outsideFocus = FocusNode();
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    addTearDown(outsideFocus.dispose);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_withOverlay(Column(children: <Widget>[
      SizedBox(
        width: 500,
        height: 180,
        child: HomericEditableDocument.builder(
          key: key,
          controller: controller,
          inputSession: session,
          scrollController: scrollController,
          cacheExtent: 0,
          estimatedBlockHeight: 44,
          blockBuilder: (context, block, focusNode) => HomericEditableParagraph(
            controller: controller,
            inputSession: session,
            blockId: block.id,
            focusNode: focusNode,
            resolveStyle: (_) => _style,
          ),
        ),
      ),
      Focus(
          focusNode: outsideFocus, child: const SizedBox(width: 1, height: 1)),
    ])));
    await tester.pump();
    final paragraph = find.byKey(const ValueKey('homeric-editable-block-0'));
    await tester.tapAt(tester.getTopLeft(paragraph) + const Offset(15, 7));
    await tester.pump();
    expect(session.isAttached, isTrue);
    key.currentState!.beginPointerSelectionDrag(document.positionAt(0, 2));
    final viewport = tester.getRect(find.byType(CustomScrollView));
    key.currentState!.updatePointerSelectionDrag(
      Offset(viewport.center.dx, viewport.bottom + 20),
    );
    await tester.pump(const Duration(milliseconds: 32));
    expect(key.currentState!.pointerSelectionDragActive, isTrue);
    expect(scrollController.offset, greaterThan(0));

    outsideFocus.requestFocus();
    await tester.pump();
    await tester.pump();

    expect(key.currentState!.pointerSelectionDragActive, isFalse);
    expect(FocusManager.instance.primaryFocus, same(outsideFocus));
    expect(session.isAttached, isFalse);
    final stoppedOffset = scrollController.offset;
    await tester.pump(const Duration(milliseconds: 80));
    expect(scrollController.offset, stoppedOffset);
    expect(FocusManager.instance.primaryFocus, same(outsideFocus));
  });

  testWidgets('edge grabber is visible, opaque, and reorders only by its drag',
      (tester) async {
    final document = _document(<String>['alpha', 'beta', 'gamma']);
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(1, 1)),
    );
    final session = HomericTextInputSession(controller: controller);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_editableDocument(controller, session));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('homeric-editable-block-1')));
    controller.setSelection(
      HomericSelection.collapsed(controller.document.positionAt(1, 2)),
    );
    await tester.pump();

    final handles = find.text('⋮');
    expect(handles, findsNWidgets(3));
    final firstHandle = handles.at(0);
    expect(tester.getSize(firstHandle).width, lessThanOrEqualTo(44));
    final handleTarget = find.ancestor(
      of: firstHandle,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is SizedBox && widget.width == 44 && widget.height == 44,
      ),
    );
    expect(handleTarget, findsOneWidget);
    final handleText = tester.widget<Text>(firstHandle);
    // `Color.a` postdates Homeric's Flutter 3.24 minimum.
    // ignore: deprecated_member_use
    expect(handleText.style?.color?.alpha, 255);
    final mouseRegion = find.ancestor(
      of: firstHandle,
      matching: find.byType(MouseRegion),
    );
    expect(tester.widget<MouseRegion>(mouseRegion).cursor,
        SystemMouseCursors.grab);

    final focusedNode = FocusManager.instance.primaryFocus;
    expect(focusedNode, isNotNull);
    final inputEpoch = session.debugDeltaCallback;
    expect(inputEpoch, isNotNull);
    final gesture = await tester.startGesture(tester.getCenter(firstHandle));
    await tester.pump();
    expect(
      tester
          .widgetList<MouseRegion>(find.byType(MouseRegion))
          .any((region) => region.cursor == SystemMouseCursors.grabbing),
      isTrue,
    );
    await gesture.moveBy(const Offset(0, 70));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      controller.document.blocks.map((block) => block.id),
      <String>['block-1', 'block-2', 'block-0'],
    );
    expect(FocusManager.instance.primaryFocus, same(focusedNode));
    expect(controller.activeBlockId, 'block-1');
    final resolvedHead =
        controller.document.resolve(controller.selection!.head);
    expect(resolvedHead, isA<InlinePosition>());
    expect((resolvedHead as InlinePosition).block.id, 'block-1');
    expect(resolvedHead.offset, 2);
    inputEpoch!(<TextEditingDelta>[
      const TextEditingDeltaInsertion(
        oldText: 'beta',
        textInserted: 'X',
        insertionOffset: 2,
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange.empty,
      ),
    ]);
    await tester.pump();
    expect(
      controller.document.blocks
          .singleWhere((block) => block.id == 'block-1')
          .text,
      'beXta',
    );
  });

  testWidgets('Cmd Shift arrows move a focused block once and edge is a no-op',
      (tester) async {
    final document = _document(<String>['alpha', 'beta', 'gamma']);
    final controller = HomericEditorController(document: document);
    final session = HomericTextInputSession(controller: controller);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_editableDocument(controller, session));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('homeric-editable-block-1')));
    controller.setSelection(
      HomericSelection.collapsed(controller.document.positionAt(1, 2)),
    );
    await tester.pump();
    final focusedNode = FocusManager.instance.primaryFocus;
    expect(focusedNode, isNotNull);

    var notifications = 0;
    controller.addListener(() => notifications++);
    await _sendBlockMoveShortcut(tester, LogicalKeyboardKey.arrowUp);
    await tester.pump();

    expect(notifications, 1);
    expect(
      controller.document.blocks.map((block) => block.id),
      <String>['block-1', 'block-0', 'block-2'],
    );
    expect(controller.activeBlockId, 'block-1');
    expect(FocusManager.instance.primaryFocus, same(focusedNode));
    expect(controller.canUndo, isTrue);

    notifications = 0;
    await _sendBlockMoveShortcut(tester, LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(notifications, 0);
    expect(
      controller.document.blocks.map((block) => block.id),
      <String>['block-1', 'block-0', 'block-2'],
    );

    expect(controller.undo(), isTrue);
    expect(
      controller.document.blocks.map((block) => block.id),
      <String>['block-0', 'block-1', 'block-2'],
    );
  });

  testWidgets('Cmd Shift Down moves a focused block once', (tester) async {
    final document = _document(<String>['alpha', 'beta', 'gamma']);
    final controller = HomericEditorController(document: document);
    final session = HomericTextInputSession(controller: controller);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_editableDocument(controller, session));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('homeric-editable-block-1')));
    controller.setSelection(
      HomericSelection.collapsed(controller.document.positionAt(1, 2)),
    );
    await tester.pump();

    var notifications = 0;
    controller.addListener(() => notifications++);
    await _sendBlockMoveShortcut(tester, LogicalKeyboardKey.arrowDown);
    await tester.pump();

    expect(notifications, 1);
    expect(
      controller.document.blocks.map((block) => block.id),
      <String>['block-0', 'block-2', 'block-1'],
    );
    expect(controller.activeBlockId, 'block-1');
  });

  testWidgets(
      'unrelated selector does not consume the matching block-move duplicate',
      (tester) async {
    final document = _document(<String>['alpha', 'beta', 'gamma', 'delta']);
    final controller = HomericEditorController(document: document);
    final session = HomericTextInputSession(controller: controller);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_editableDocument(controller, session));
    await tester.pump();
    final paragraph = find.byKey(const ValueKey('homeric-editable-block-2'));
    await tester.tapAt(tester.getTopLeft(paragraph) + const Offset(15, 7));
    controller.setSelection(
      HomericSelection.collapsed(controller.document.positionAt(2, 2)),
    );
    await tester.pump();
    await _sendBlockMoveShortcut(tester, LogicalKeyboardKey.arrowUp);
    await tester.pump();
    session.debugSelectorCallback!('moveRight:');
    await tester.pump();
    final selectionAfterUnrelatedSelector = controller.selection;
    session.debugSelectorCallback!('moveUpAndModifySelection:');
    await tester.pump();

    expect(controller.document.blocks.map((block) => block.id),
        <String>['block-0', 'block-2', 'block-1', 'block-3']);
    expect(
      selectionAfterUnrelatedSelector,
      HomericSelection.collapsed(controller.document.positionAt(1, 3)),
      reason: 'the unrelated selector must execute normally',
    );
    expect(controller.selection, selectionAfterUnrelatedSelector);
  });

  testWidgets('document semantics expose one active editable field',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final document = _document(<String>['alpha', 'beta', 'gamma']);
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(1, 2)),
    );
    final session = HomericTextInputSession(controller: controller);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_editableDocument(controller, session));
    await tester.pump();

    expect(find.bySemanticsLabel('Document editor, 3 blocks'), findsOneWidget);
    final documentData = tester
        .getSemantics(find.bySemanticsLabel('Document editor, 3 blocks'))
        .getSemanticsData();
    final selectAllActionId = CustomSemanticsAction.getIdentifier(
      const CustomSemanticsAction(label: 'Select all document text'),
    );
    expect(documentData.customSemanticsActionIds, contains(selectAllActionId));
    final paragraphs = find.byType(HomericEditableParagraph);
    var editableCount = 0;
    for (var index = 0; index < paragraphs.evaluate().length; index++) {
      final data = tester.getSemantics(paragraphs.at(index)).getSemanticsData();
      // ignore: deprecated_member_use
      if (data.hasFlag(SemanticsFlag.isTextField)) editableCount++;
    }
    expect(editableCount, 1);
    final activeData = tester
        .getSemantics(
          find.byKey(const ValueKey('homeric-editable-block-1')),
        )
        .getSemanticsData();
    // ignore: deprecated_member_use
    expect(activeData.hasFlag(SemanticsFlag.isTextField), isTrue);
    semantics.dispose();
  });

  testWidgets('document semantics rebuild for selection and composition only',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final document = _document(<String>['alpha']);
    final controller = HomericEditorController(document: document);
    final session = HomericTextInputSession(controller: controller);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    final selectAllActionId = CustomSemanticsAction.getIdentifier(
      const CustomSemanticsAction(label: 'Select all document text'),
    );

    await tester.pumpWidget(_editableDocument(controller, session));
    await tester.pump();
    SemanticsData documentSemantics() => tester
        .getSemantics(find.bySemanticsLabel('Document editor, 1 blocks'))
        .getSemanticsData();
    expect(
      documentSemantics().customSemanticsActionIds,
      isNot(contains(selectAllActionId)),
    );

    final paragraph = find.byKey(const ValueKey('homeric-editable-block-0'));
    await tester.tapAt(tester.getTopLeft(paragraph) + const Offset(15, 7));
    await tester.pump();
    expect(controller.selection, isNotNull);
    expect(
      documentSemantics().customSemanticsActionIds,
      contains(selectAllActionId),
    );

    expect(
      controller.applyBlockEditBatch(
        blockId: 'block-0',
        edits: const <CanonicalTextEdit>[CanonicalTextEdit(0, 0, 'X')],
        selection: const BlockTextSelection.collapsed(1),
        composing: const BlockTextRange(0, 1),
      ),
      isTrue,
    );
    await tester.pump();
    expect(
      documentSemantics().customSemanticsActionIds,
      isNot(contains(selectAllActionId)),
    );

    expect(
      controller
          .interruptComposition(CompositionInterruption.pointerRelocation),
      isTrue,
    );
    await tester.pump();
    expect(
      documentSemantics().customSemanticsActionIds,
      contains(selectAllActionId),
    );
    semantics.dispose();
  });

  testWidgets('handle accessibility action uses the same one-move command',
      (tester) async {
    final document = _document(<String>['alpha', 'beta', 'gamma']);
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(1, 2)),
    );
    final session = HomericTextInputSession(controller: controller);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(_editableDocument(controller, session));
    await tester.pump();
    final node = tester.getSemantics(
      find.bySemanticsLabel('Move block, block 2 of 3'),
    );
    final actionId = CustomSemanticsAction.getIdentifier(
      const CustomSemanticsAction(label: 'Move block down'),
    );
    expect(
        node.getSemanticsData().customSemanticsActionIds, contains(actionId));

    var notifications = 0;
    controller.addListener(() => notifications++);
    // `rootPipelineOwner` postdates Homeric's Flutter 3.24 minimum.
    // ignore: deprecated_member_use
    tester.binding.pipelineOwner.semanticsOwner!.performAction(
      node.id,
      SemanticsAction.customAction,
      actionId,
    );
    await tester.pumpAndSettle();

    expect(notifications, 1);
    expect(
      controller.document.blocks.map((block) => block.id),
      <String>['block-0', 'block-2', 'block-1'],
    );
    expect(controller.activeBlockId, 'block-1');
    semantics.dispose();
  });

  testWidgets('all reorder surfaces disable for cross-block selection',
      (tester) async {
    final document = _document(<String>['alpha', 'beta', 'gamma']);
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection(
        anchor: document.positionAt(0, 1),
        head: document.positionAt(1, 2),
      ),
    );
    final session = HomericTextInputSession(controller: controller);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_editableDocument(controller, session));
    await tester.pump();

    final before = controller.document;
    final handle = find.text('⋮').at(1);
    await tester.drag(handle, const Offset(0, -70));
    await _sendBlockMoveShortcut(tester, LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();

    expect(identical(controller.document, before), isTrue);
    final semantics = tester.getSemantics(
      find.ancestor(
        of: handle,
        matching: find.bySemanticsLabel('Move block, block 2 of 3'),
      ),
    );
    // `flagsCollection` postdates Homeric's Flutter 3.24 minimum.
    // ignore: deprecated_member_use
    expect(semantics.hasFlag(SemanticsFlag.isEnabled), isFalse);

    controller.setSelection(
      HomericSelection.collapsed(controller.document.positionAt(1, 2)),
    );
    await tester.pump();
    final enabledSemantics = tester.getSemantics(
      find.bySemanticsLabel('Move block, block 2 of 3'),
    );
    // `flagsCollection` postdates Homeric's Flutter 3.24 minimum.
    // ignore: deprecated_member_use
    expect(enabledSemantics.hasFlag(SemanticsFlag.isEnabled), isTrue);
  });

  testWidgets('composition disables handle and both move shortcuts',
      (tester) async {
    final document = _document(<String>['alpha', 'beta', 'gamma']);
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(1, 1)),
    );
    final session = HomericTextInputSession(controller: controller);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_editableDocument(controller, session));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('homeric-editable-block-1')));
    expect(
      controller.applyBlockEditBatch(
        blockId: 'block-1',
        edits: const <CanonicalTextEdit>[
          CanonicalTextEdit(1, 1, 'X'),
        ],
        selection: const BlockTextSelection.collapsed(2),
        composing: const BlockTextRange(1, 2),
      ),
      isTrue,
    );
    await tester.pump();
    final before = controller.document;

    final handle = find.text('⋮').at(1);
    await tester.drag(handle, const Offset(0, -70));
    await _sendBlockMoveShortcut(tester, LogicalKeyboardKey.arrowUp);
    await _sendBlockMoveShortcut(tester, LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();

    expect(identical(controller.document, before), isTrue);
    final semantics = tester.getSemantics(
      find.bySemanticsLabel('Move block, block 2 of 3'),
    );
    // `flagsCollection` postdates Homeric's Flutter 3.24 minimum.
    // ignore: deprecated_member_use
    expect(semantics.hasFlag(SemanticsFlag.isEnabled), isFalse);
  });

  testWidgets('drag witness goes stale when the document changes mid-drag',
      (tester) async {
    final document = _document(<String>['alpha', 'beta', 'gamma']);
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(1, 1)),
    );
    final session = HomericTextInputSession(controller: controller);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_editableDocument(controller, session));
    await tester.pump();
    final handle = find.text('⋮').first;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump();
    expect(controller.replaceSelection('X'), isTrue);
    await tester.pump();

    await gesture.moveBy(const Offset(0, 70));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      controller.document.blocks.map((block) => block.id),
      <String>['block-0', 'block-1', 'block-2'],
    );
    expect(controller.document.blocks[1].text, 'bXeta');
  });

  testWidgets(
      'consumer geometry, active caret, and live scroll padding stay current',
      (tester) async {
    final document = _document(<String>['alpha', 'beta']);
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(0, 1)),
    );
    final session = HomericTextInputSession(controller: controller);
    final key = GlobalKey<HomericEditableDocumentState>();
    final padding = ValueNotifier<EdgeInsetsGeometry>(EdgeInsets.zero);
    HomericEditableBlockGeometry? firstGeometry;
    HomericEditableBlockGeometry? latestGeometry;
    addTearDown(padding.dispose);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    Widget build(double width) => _withOverlay(SizedBox(
          width: width,
          height: 240,
          child: HomericEditableDocument.builder(
            key: key,
            controller: controller,
            inputSession: session,
            scrollPadding: padding,
            cacheExtent: 0,
            blockBuilder: (context, block, focusNode) =>
                HomericEditableParagraph(
              controller: controller,
              inputSession: session,
              blockId: block.id,
              focusNode: focusNode,
              resolveStyle: (_) => _style,
              overlayBuilder: (context, geometry) {
                if (block.id != 'block-0') return const <Widget>[];
                firstGeometry ??= geometry;
                latestGeometry = geometry;
                final caret = geometry.caretRect(1);
                return <Widget>[
                  if (caret != null)
                    Positioned.fromRect(
                      rect: caret,
                      child: const SizedBox(
                        key: ValueKey('consumer-caret-overlay'),
                      ),
                    ),
                ];
              },
            ),
          ),
        ));

    await tester.pumpWidget(build(320));
    await tester.pump();
    final initial = key.currentState!.activeCaretGeometry;
    expect(initial, isNotNull);
    expect(firstGeometry!.isCurrent, isTrue);
    expect(firstGeometry!.documentRevision, controller.documentRevision);
    expect(
        find.byKey(const ValueKey('consumer-caret-overlay')), findsOneWidget);

    padding.value = const EdgeInsets.only(top: 48);
    await tester.pump();
    final padded = key.currentState!.activeCaretGeometry;
    expect(padded, isNotNull);
    expect(padded!.globalRect.top, closeTo(initial!.globalRect.top + 48, 0.01));
    expect(identical(session.controller, controller), isTrue);

    expect(controller.replaceSelection('X'), isTrue);
    expect(firstGeometry!.isCurrent, isFalse,
        reason: 'document revision invalidates geometry before the next frame');
    expect(key.currentState!.activeCaretGeometry, isNull);
    await tester.pumpWidget(build(180));
    await tester.pump();
    expect(firstGeometry!.isCurrent, isFalse);
    expect(latestGeometry!.layoutGeneration,
        greaterThan(firstGeometry!.layoutGeneration));
    expect(key.currentState!.activeCaretGeometry, isNotNull);
  });

  testWidgets('public focus settlement reaches an off-screen stable block',
      (tester) async {
    final document = _document(List<String>.generate(40, (index) => '$index'));
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(0, 0)),
    );
    final session = HomericTextInputSession(controller: controller);
    final key = GlobalKey<HomericEditableDocumentState>();
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_editableDocument(controller, session, key: key));
    await tester.pump();

    final pending = key.currentState!.settleFocusOnBlock('block-30');
    await tester.pumpAndSettle();
    expect(await pending, HomericFocusSettlementResult.focused);
    expect(key.currentState!.focusedBlockId, 'block-30');
    expect(controller.activeBlockId, 'block-30');
    expect(
      await key.currentState!.settleFocusOnBlock('missing'),
      HomericFocusSettlementResult.missing,
    );
  });
}

Widget _editableDocument(
  HomericEditorController controller,
  HomericTextInputSession session, {
  Key? key,
}) =>
    _withOverlay(SizedBox(
      width: 500,
      height: 300,
      child: HomericEditableDocument.builder(
        key: key,
        controller: controller,
        inputSession: session,
        cacheExtent: 0,
        estimatedBlockHeight: 44,
        blockBuilder: (context, block, focusNode) => HomericEditableParagraph(
          controller: controller,
          inputSession: session,
          blockId: block.id,
          focusNode: focusNode,
          resolveStyle: (_) => _style,
        ),
      ),
    ));

void _expectSelectionHead(
  HomericEditorController controller, {
  required String blockId,
  required int offset,
}) {
  final selection = controller.selection;
  expect(selection, isNotNull);
  final resolved = controller.document.resolve(selection!.head);
  expect(resolved, isA<InlinePosition>());
  expect((resolved as InlinePosition).block.id, blockId);
  expect(resolved.offset, offset);
}

Future<void> _expectBreakRetargetsAndAcceptsDelta(
  WidgetTester tester, {
  required Future<void> Function() trigger,
}) async {
  TextInputConnection.debugResetId();
  final document = _document(<String>['alpha']);
  final controller = HomericEditorController(
    document: document,
    selection: HomericSelection.collapsed(document.positionAt(0, 2)),
  );
  final session = HomericTextInputSession(controller: controller);
  final key = GlobalKey<HomericEditableDocumentState>();
  addTearDown(session.dispose);
  addTearDown(controller.dispose);

  await tester.pumpWidget(_editableDocument(controller, session, key: key));
  await tester.pump();
  final paragraph = find.byKey(const ValueKey('homeric-editable-block-0'));
  await tester.tapAt(tester.getTopLeft(paragraph) + const Offset(15, 7));
  await tester.pump();
  controller.setSelection(
    HomericSelection.collapsed(controller.document.positionAt(0, 2)),
  );

  await trigger();
  await tester.pump();
  await tester.pump();

  expect(controller.document.blocks.map((block) => block.text),
      <String>['al', 'pha']);
  final trailingBlockId = controller.document.blocks.last.id;
  expect(controller.activeBlockId, trailingBlockId);
  expect(session.activeBlockId, trailingBlockId);
  expect(key.currentState!.focusedBlockId, trailingBlockId);
  _insertAtStartThroughPlatform(session, oldText: 'pha', text: 'X');
  await tester.pump();
  expect(controller.document.blocks.last.text, 'Xpha');
}

void _insertAtStartThroughPlatform(
  HomericTextInputSession session, {
  required String oldText,
  required String text,
}) {
  session.debugDeltaCallback!(<TextEditingDelta>[
    TextEditingDeltaInsertion(
      oldText: oldText,
      textInserted: text,
      insertionOffset: 0,
      selection: TextSelection.collapsed(offset: text.length),
      composing: TextRange.empty,
    ),
  ]);
}

Future<void> _sendShiftArrow(
  WidgetTester tester,
  LogicalKeyboardKey arrow,
) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  try {
    await tester.sendKeyEvent(arrow);
  } finally {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  }
}

Future<void> _sendBlockMoveShortcut(
  WidgetTester tester,
  LogicalKeyboardKey arrow,
) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  try {
    await tester.sendKeyEvent(arrow);
  } finally {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  }
}

Future<void> _sendTextInputAction(
  TestWidgetsFlutterBinding binding,
  int clientId,
  String action,
) async {
  final message = const JSONMessageCodec().encodeMessage(<String, Object?>{
    'method': 'TextInputClient.performAction',
    'args': <Object?>[clientId, action],
  });
  await binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/textinput',
    message,
    (_) {},
  );
}

Widget _withOverlay(Widget child) => Directionality(
      textDirection: TextDirection.ltr,
      child: Localizations(
        locale: const Locale('en'),
        delegates: const <LocalizationsDelegate<dynamic>>[
          DefaultWidgetsLocalizations.delegate,
        ],
        child: Overlay(
          initialEntries: <OverlayEntry>[
            OverlayEntry(builder: (_) => child),
          ],
        ),
      ),
    );

Document _document(List<String> texts) => Document(<Block>[
      for (var index = 0; index < texts.length; index++)
        Block(
          id: 'block-$index',
          type: 'paragraph',
          runs: <InlineRun>[InlineRun(texts[index])],
        ),
    ]);

final class _CommandDelegate implements HomericTextInputCommandDelegate {
  int invocations = 0;

  @override
  Object? invoke(Intent intent) {
    invocations++;
    return null;
  }

  @override
  void showToolbar() {}
}
