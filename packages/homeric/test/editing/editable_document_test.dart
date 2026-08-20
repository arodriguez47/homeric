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
}

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
