import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

const _style = TextStyle(fontSize: 14);

void main() {
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
}

Widget _editableDocument(
  HomericEditorController controller,
  HomericTextInputSession session,
) =>
    _withOverlay(SizedBox(
      width: 500,
      height: 300,
      child: HomericEditableDocument.builder(
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
