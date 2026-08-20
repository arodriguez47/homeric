import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

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

    expect(scrollController.offset, closeTo(before + 50, 0.01));
  });
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
