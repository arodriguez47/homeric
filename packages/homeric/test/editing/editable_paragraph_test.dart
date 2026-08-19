import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

const _style = TextStyle(fontSize: 14);

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  setUp(TextInputConnection.debugResetId);

  testWidgets(
      'mounted smoke: focus, canonical input, click, replacement, Backspace',
      (tester) async {
    final document = _document('abc');
    final controller = HomericEditorController(document: document);
    final session = HomericTextInputSession(controller: controller);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_harness(HomericEditableParagraph(
      controller: controller,
      inputSession: session,
      blockId: 'b',
      resolveStyle: (_) => _style,
    )));
    await tester.pump();

    await tester.tapAt(
      tester.getTopLeft(find.byType(HomericEditableParagraph)) +
          const Offset(15, 7),
    );
    await tester.pump();

    expect(session.isAttached, isTrue);
    expect(controller.selection, const HomericSelection.collapsed(2));

    await _sendDeltas(binding, 1, [
      _delta(
        oldText: 'abc',
        deltaText: 'X',
        start: 1,
        end: 1,
        selection: 2,
      ),
    ]);
    await tester.pump();
    expect(controller.document.blocks.single.text, 'aXbc');

    controller.setSelection(const HomericSelection(anchor: 2, head: 4));
    await tester.pump();
    await _sendDeltas(binding, 1, [
      _delta(
        oldText: 'aXbc',
        deltaText: 'Y',
        start: 1,
        end: 3,
        selection: 2,
      ),
    ]);
    await tester.pump();
    expect(controller.document.blocks.single.text, 'aYc');

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(controller.document.blocks.single.text, 'ac');
  });

  testWidgets('arrows use current descendant geometry and preserve direction',
      (tester) async {
    final document = _document('abc');
    final controller = HomericEditorController(document: document);
    final session = HomericTextInputSession(controller: controller);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_harness(HomericEditableParagraph(
      controller: controller,
      inputSession: session,
      blockId: 'b',
      resolveStyle: (_) => _style,
    )));
    await tester.pump();
    await tester.tapAt(
      tester.getTopLeft(find.byType(HomericEditableParagraph)) +
          const Offset(15, 7),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(controller.selection, const HomericSelection.collapsed(3));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(controller.selection, const HomericSelection(anchor: 3, head: 2));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(controller.selection, const HomericSelection.collapsed(3));
    expect(controller.preferredX, isNull);
  });

  testWidgets('vertical arrows retain preferred x and Shift fixes the anchor',
      (tester) async {
    final controller = HomericEditorController(document: _document('abcdef'));
    final session = HomericTextInputSession(controller: controller);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_harness(
      HomericEditableParagraph(
        controller: controller,
        inputSession: session,
        blockId: 'b',
        resolveStyle: (_) => _style,
      ),
      width: 30,
    ));
    await tester.pump();
    await tester.tapAt(
      tester.getTopLeft(find.byType(HomericEditableParagraph)) +
          const Offset(15, 7),
    );
    await tester.pump();
    final initialHead = controller.selection!.head;

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    final afterDown = controller.selection!;
    expect(afterDown.isCollapsed, isTrue);
    expect(afterDown.head, isNot(initialHead));
    final preferredX = controller.preferredX;
    expect(preferredX, isNotNull);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    final extended = controller.selection!;
    expect(extended.anchor, afterDown.head);
    expect(extended.head, isNot(afterDown.head));
    expect(controller.preferredX, preferredX);
  });

  testWidgets('macOS selector reaches the same canonical action',
      (tester) async {
    final document = _document('abc');
    final controller = HomericEditorController(document: document);
    final session = HomericTextInputSession(controller: controller);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_harness(HomericEditableParagraph(
      controller: controller,
      inputSession: session,
      blockId: 'b',
      resolveStyle: (_) => _style,
    )));
    await tester.pump();
    await tester.tapAt(
      tester.getTopLeft(find.byType(HomericEditableParagraph)) +
          const Offset(15, 7),
    );
    await tester.pump();

    await _sendSelectors(binding, 1, const ['moveRight:']);
    await tester.pump();
    expect(controller.selection, const HomericSelection.collapsed(3));
    await _sendSelectors(binding, 1, const ['deleteBackward:']);
    await tester.pump();
    expect(controller.document.blocks.single.text, 'ac');

    await _sendSelectors(binding, 1, const ['moveWordRight:']);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(controller.document.blocks.single.text, 'ac');
  });

  testWidgets('focused state reuse transfers input to the replacement block',
      (tester) async {
    final document = Document([
      Block(id: 'a', type: 'paragraph', runs: [InlineRun('abc')]),
      Block(id: 'b', type: 'paragraph', runs: [InlineRun('xyz')]),
    ]);
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(0, 1)),
    );
    final session = HomericTextInputSession(controller: controller);
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    late StateSetter rebuild;
    var blockId = 'a';

    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: StatefulBuilder(builder: (context, setState) {
        rebuild = setState;
        return SizedBox(
          width: 200,
          child: HomericEditableParagraph(
            key: const ValueKey('reused-editor'),
            controller: controller,
            inputSession: session,
            focusNode: focusNode,
            blockId: blockId,
            resolveStyle: (_) => _style,
          ),
        );
      }),
    ));
    focusNode.requestFocus();
    await tester.pump();
    expect(session.activeBlockId, 'a');

    rebuild(() => blockId = 'b');
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);
    expect(session.activeBlockId, 'b');
    expect(controller.activeBlockId, 'b');

    await _sendDeltas(binding, 2, [
      _delta(
        oldText: 'xyz',
        deltaText: 'Q',
        start: 0,
        end: 0,
        selection: 1,
      ),
    ]);
    await tester.pump();
    expect(controller.document.blockById('a')!.text, 'abc');
    expect(controller.document.blockById('b')!.text, 'Qxyz');
  });

  testWidgets('focused dependency swaps transfer connection ownership',
      (tester) async {
    final firstController = HomericEditorController(
      document: _document('first'),
      selection: const HomericSelection.collapsed(1),
    );
    final secondController = HomericEditorController(
      document: _document('second'),
      selection: const HomericSelection.collapsed(1),
    );
    final firstSession = HomericTextInputSession(controller: firstController);
    final secondSession = HomericTextInputSession(
      controller: secondController,
    );
    final firstFocus = FocusNode();
    final secondFocus = FocusNode();
    addTearDown(firstFocus.dispose);
    addTearDown(secondFocus.dispose);
    addTearDown(firstSession.dispose);
    addTearDown(secondSession.dispose);
    addTearDown(firstController.dispose);
    addTearDown(secondController.dispose);
    late StateSetter rebuild;
    var controller = firstController;
    var session = firstSession;
    var focusNode = firstFocus;

    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: StatefulBuilder(builder: (context, setState) {
        rebuild = setState;
        return SizedBox(
          width: 200,
          child: HomericEditableParagraph(
            key: const ValueKey('dependency-swap-editor'),
            controller: controller,
            inputSession: session,
            focusNode: focusNode,
            blockId: 'b',
            resolveStyle: (_) => _style,
          ),
        );
      }),
    ));
    firstFocus.requestFocus();
    await tester.pump();
    expect(firstSession.activeBlockId, 'b');

    rebuild(() => focusNode = secondFocus);
    await tester.pump();
    expect(firstSession.activeBlockId, 'b');
    expect(secondFocus.hasFocus, isTrue);

    rebuild(() {
      controller = secondController;
      session = secondSession;
    });
    await tester.pump();
    expect(firstSession.isAttached, isFalse);
    expect(secondSession.activeBlockId, 'b');
    expect(secondController.activeBlockId, 'b');
  });

  testWidgets('active composition leaves destructive keys to the platform',
      (tester) async {
    final document = _document('abc');
    final controller = HomericEditorController(document: document);
    final session = HomericTextInputSession(controller: controller);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_harness(HomericEditableParagraph(
      controller: controller,
      inputSession: session,
      blockId: 'b',
      resolveStyle: (_) => _style,
    )));
    await tester.pump();
    await tester.tapAt(
      tester.getTopLeft(find.byType(HomericEditableParagraph)) +
          const Offset(15, 7),
    );
    controller.applyBlockEditBatch(
      blockId: 'b',
      selection: const BlockTextSelection.collapsed(1),
      composing: const BlockTextRange(0, 1),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    expect(controller.document.blocks.single.text, 'abc');
    expect(controller.composing, isNotNull);
  });

  testWidgets(
      'editable semantics expose canonical value and directional selection',
      (tester) async {
    final handle = tester.ensureSemantics();
    final document = _document('**bold**');
    final controller = HomericEditorController(
      document: document,
      selection: const HomericSelection(anchor: 3, head: 7),
      decorations: DecorationSet.of([
        Decoration.replace('b', 0, 2, replacementLength: 0),
        Decoration.replace('b', 6, 8, replacementLength: 0),
      ]),
    );
    final session = HomericTextInputSession(controller: controller);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_harness(HomericEditableParagraph(
      controller: controller,
      inputSession: session,
      blockId: 'b',
      resolveStyle: (_) => _style,
    )));
    await tester.pump();

    final data = tester
        .getSemantics(find.byType(HomericEditableParagraph))
        .getSemanticsData();
    expect(data.value, '**bold**');
    // `flagsCollection` was added after Homeric's Flutter 3.24 minimum.
    // ignore: deprecated_member_use
    expect(data.hasFlag(ui.SemanticsFlag.isTextField), isTrue);
    // ignore: deprecated_member_use
    expect(data.hasFlag(ui.SemanticsFlag.isReadOnly), isFalse);
    expect(data.textSelection,
        const TextSelection(baseOffset: 2, extentOffset: 6));
    expect(data.hasAction(ui.SemanticsAction.setText), isTrue);
    expect(data.hasAction(ui.SemanticsAction.setSelection), isTrue);

    tester.semantics.setSelection(
      find.semantics.byValue('**bold**'),
      base: 6,
      extent: 8,
    );
    await tester.pump();
    expect(controller.selection, const HomericSelection(anchor: 7, head: 9));
    expect(
      tester
          .renderObject<RenderHomericParagraph>(find.byType(HomericParagraph))
          .source
          .viewText,
      'bold**',
      reason: 'accessibility selection into hidden syntax reveals it',
    );
    tester.semantics.setText(
      find.semantics.byValue('**bold**'),
      'plain',
    );
    await tester.pump();
    expect(controller.document.blocks.single.text, 'plain');
    handle.dispose();
  });

  testWidgets('hidden deletion callback runs before canonical mutation',
      (tester) async {
    final document = _document('**bold**');
    String? textObservedByReveal;
    CanonicalEditTarget? revealed;
    late HomericEditorController controller;
    controller = HomericEditorController(
      document: document,
      decorations: DecorationSet.of([
        Decoration.replace('b', 0, 2, replacementLength: 0),
        Decoration.replace('b', 6, 8, replacementLength: 0),
      ]),
      selection: const HomericSelection.collapsed(7),
      onBeforeCanonicalMutation: (target) {
        textObservedByReveal = controller.document.blocks.single.text;
        revealed = target;
      },
    );
    final focusNode = FocusNode();
    final session = HomericTextInputSession(controller: controller);
    addTearDown(focusNode.dispose);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_harness(HomericEditableParagraph(
      controller: controller,
      inputSession: session,
      focusNode: focusNode,
      blockId: 'b',
      resolveStyle: (_) => _style,
    )));
    await tester.pump();
    focusNode.requestFocus();
    await tester.pump();
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    expect(textObservedByReveal, '**bold**');
    expect(revealed, const CanonicalEditTarget('b', 6, 8));
    expect(controller.document.blocks.single.text, '**bold*');
  });

  testWidgets('reverse drag crosses wraps and clamps outside the paragraph',
      (tester) async {
    final controller = HomericEditorController(document: _document('abcdef'));
    final session = HomericTextInputSession(controller: controller);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_harness(
      HomericEditableParagraph(
        controller: controller,
        inputSession: session,
        blockId: 'b',
        resolveStyle: (_) => _style,
      ),
      width: 30,
    ));
    await tester.pump();
    final origin = tester.getTopLeft(find.byType(HomericEditableParagraph));
    final gesture = await tester.startGesture(origin + const Offset(20, 35));
    await gesture.moveTo(origin + const Offset(-40, -20));
    await tester.pump();
    await gesture.up();

    final selection = controller.selection!;
    expect(selection.isForward, isFalse);
    expect(controller.blockOffsetForGlobalPosition('b', selection.anchor),
        greaterThanOrEqualTo(4));
    expect(controller.blockOffsetForGlobalPosition('b', selection.head), 0);
  });

  testWidgets('relayout during drag never queries the stale generation',
      (tester) async {
    final controller = HomericEditorController(document: _document('abcdef'));
    final session = HomericTextInputSession(controller: controller);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    late StateSetter rebuild;
    var width = 200.0;
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: StatefulBuilder(builder: (context, setState) {
        rebuild = setState;
        return Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: HomericEditableParagraph(
              controller: controller,
              inputSession: session,
              blockId: 'b',
              resolveStyle: (_) => _style,
            ),
          ),
        );
      }),
    ));
    await tester.pump();
    final origin = tester.getTopLeft(find.byType(HomericEditableParagraph));
    final gesture = await tester.startGesture(origin + const Offset(60, 7));
    await gesture.moveBy(const Offset(-25, 0));
    await tester.pump();
    expect(controller.selection, isNotNull,
        reason: 'the drag must own the gesture before relayout');
    rebuild(() => width = 30);
    await tester.pump();
    await gesture.moveBy(const Offset(-30, 20));
    await tester.pump();
    await gesture.up();

    expect(tester.takeException(), isNull);
    final selection = controller.selection!;
    expect(controller.blockOffsetForGlobalPosition('b', selection.anchor),
        inInclusiveRange(0, 6));
    expect(controller.blockOffsetForGlobalPosition('b', selection.head),
        inInclusiveRange(0, 6));
  });

  testWidgets('editing paint layers have fixed order and blur hides them',
      (tester) async {
    final document = _document('abcd');
    final controller = HomericEditorController(
      document: document,
      selection: const HomericSelection(anchor: 2, head: 4),
    );
    final session = HomericTextInputSession(controller: controller);
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    final consumerUnderlay = PaintLayer(
      range: DocRange(const DocOffset(0), const DocOffset(1)),
      band: PaintBand.underlay,
      painter: solidWashPainter,
      spec: const SolidWashSpec(Color(0xFF00FF00)),
    );
    final consumerOverlay = PaintLayer(
      range: DocRange(const DocOffset(0), const DocOffset(1)),
      band: PaintBand.overlay,
      painter: underlinePainter,
      spec: const UnderlineSpec(Color(0xFFFF0000)),
    );
    await tester.pumpWidget(_harness(HomericEditableParagraph(
      controller: controller,
      inputSession: session,
      focusNode: focusNode,
      blockId: 'b',
      resolveStyle: (_) => _style,
      paintLayers: [consumerUnderlay, consumerOverlay],
    )));
    await tester.pump();
    focusNode.requestFocus();
    await tester.pump();
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);
    expect(controller.selection, const HomericSelection(anchor: 2, head: 4));
    var render = tester
        .renderObject<RenderHomericParagraph>(find.byType(HomericParagraph));
    expect(render.paintLayers.map((layer) => layer.band), [
      PaintBand.underlay,
      PaintBand.overlay,
      PaintBand.underlay,
    ]);
    expect(render.paintLayers.last.painter, same(solidWashPainter));
    expect(find.byType(ColoredBox), findsNothing,
        reason: 'an expanded selection paints a wash, not a caret');
    controller.applyBlockEditBatch(
      blockId: 'b',
      selection: const BlockTextSelection.collapsed(2),
      composing: const BlockTextRange(1, 2),
    );
    await tester.pump();

    render = tester
        .renderObject<RenderHomericParagraph>(find.byType(HomericParagraph));
    expect(render.paintLayers.map((layer) => layer.band), [
      PaintBand.underlay,
      PaintBand.overlay,
      PaintBand.overlay,
    ]);
    expect(render.paintLayers.first, same(consumerUnderlay));
    expect(render.paintLayers[1], same(consumerOverlay));
    expect(render.paintLayers.last.painter, same(underlinePainter));
    expect(find.byType(ColoredBox), findsOneWidget,
        reason: 'collapsed focused selection paints one static caret');

    focusNode.unfocus();
    await tester.pump();
    await tester.pump();
    expect(render.paintLayers, [consumerUnderlay, consumerOverlay]);
    expect(find.byType(ColoredBox), findsNothing);
    expect(controller.selection, isNotNull,
        reason: 'blur keeps the logical selection');
    expect(controller.composing, isNull,
        reason: 'blur commits and clears visible composition');
  });

  testWidgets('empty paragraph is hit-testable and accepts its first input',
      (tester) async {
    final controller = HomericEditorController(document: _document(''));
    final session = HomericTextInputSession(controller: controller);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_harness(HomericEditableParagraph(
      controller: controller,
      inputSession: session,
      blockId: 'b',
      resolveStyle: (_) => _style,
    )));
    await tester.pump();
    expect(tester.getSize(find.byType(HomericEditableParagraph)).height, 14);
    await tester.tapAt(
      tester.getTopLeft(find.byType(HomericEditableParagraph)) +
          const Offset(80, 7),
    );
    await tester.pump();
    expect(controller.selection, const HomericSelection.collapsed(1));
    expect(find.byType(ColoredBox), findsOneWidget);

    await _sendDeltas(binding, 1, [
      _delta(
        oldText: '',
        deltaText: 'A',
        start: 0,
        end: 0,
        selection: 1,
      ),
    ]);
    await tester.pump();
    expect(controller.document.blocks.single.text, 'A');
  });

  testWidgets('Tab and Shift-Tab traverse without inserting text',
      (tester) async {
    final controller = HomericEditorController(document: _document('abc'));
    final session = HomericTextInputSession(controller: controller);
    final before = FocusNode();
    final editor = FocusNode();
    final after = FocusNode();
    addTearDown(before.dispose);
    addTearDown(editor.dispose);
    addTearDown(after.dispose);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Column(children: [
        Focus(focusNode: before, child: const SizedBox(width: 1, height: 1)),
        SizedBox(
          width: 200,
          child: HomericEditableParagraph(
            controller: controller,
            inputSession: session,
            focusNode: editor,
            blockId: 'b',
            resolveStyle: (_) => _style,
          ),
        ),
        Focus(focusNode: after, child: const SizedBox(width: 1, height: 1)),
      ]),
    ));
    await tester.pump();
    await tester.tapAt(
      tester.getTopLeft(find.byType(HomericEditableParagraph)) +
          const Offset(15, 7),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(after.hasFocus, isTrue);
    final retainedSelection = controller.selection;
    editor.requestFocus();
    await tester.pump();
    await tester.pump();
    expect(controller.selection, retainedSelection,
        reason: 'returning focus restores the logical selection');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(before.hasFocus, isTrue);
    expect(controller.document.blocks.single.text, 'abc');
  });
}

Document _document(String text) => Document([
      Block(
        id: 'b',
        type: 'paragraph',
        runs: [if (text.isNotEmpty) InlineRun(text)],
      ),
    ]);

Widget _harness(Widget child, {double width = 200}) => Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: width, child: child),
      ),
    );

Map<String, Object?> _delta({
  required String oldText,
  required String deltaText,
  required int start,
  required int end,
  required int selection,
}) =>
    <String, Object?>{
      'oldText': oldText,
      'deltaText': deltaText,
      'deltaStart': start,
      'deltaEnd': end,
      'selectionBase': selection,
      'selectionExtent': selection,
      'selectionAffinity': 'TextAffinity.downstream',
      'selectionIsDirectional': false,
      'composingBase': -1,
      'composingExtent': -1,
    };

Future<void> _sendDeltas(
  TestWidgetsFlutterBinding binding,
  int clientId,
  List<Map<String, Object?>> deltas,
) async {
  final message = const JSONMessageCodec().encodeMessage(<String, Object?>{
    'method': 'TextInputClient.updateEditingStateWithDeltas',
    'args': <Object?>[
      clientId,
      <String, Object?>{'deltas': deltas},
    ],
  });
  await binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/textinput',
    message,
    (_) {},
  );
}

Future<void> _sendSelectors(
  TestWidgetsFlutterBinding binding,
  int clientId,
  List<String> selectors,
) async {
  final message = const JSONMessageCodec().encodeMessage(<String, Object?>{
    'method': 'TextInputClient.performSelectors',
    'args': <Object?>[clientId, selectors],
  });
  await binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/textinput',
    message,
    (_) {},
  );
}
