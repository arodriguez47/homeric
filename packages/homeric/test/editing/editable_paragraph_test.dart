import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart'
    show kDoubleTapTimeout, kSecondaryMouseButton;
import 'package:flutter/material.dart'
    show AdaptiveTextSelectionToolbar, MaterialApp, Scaffold;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

const _style = TextStyle(fontSize: 14);

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  setUp(TextInputConnection.debugResetId);

  tearDown(() => debugDefaultTargetPlatformOverride = null);

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

  testWidgets('shortcut and selector each dispatch one standard action',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final controller = HomericEditorController(document: _document('abc'));
    final session = HomericTextInputSession(controller: controller);
    final focusNode = FocusNode();
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
    focusNode.requestFocus();
    await tester.pump();
    controller.setSelection(const HomericSelection.collapsed(4));
    await tester.pump();
    var notifications = 0;
    controller.addListener(() => notifications++);

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(controller.document.blocks.single.text, 'ab');
    expect(notifications, 1);

    await _sendSelectors(binding, 1, const <String>['deleteBackward:']);
    await tester.pump();
    expect(controller.document.blocks.single.text, 'a');
    expect(notifications, 2);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('keyboard clipboard commands mutate once through host actions',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final controller = HomericEditorController(
      document: _document('abcd'),
      selection: const HomericSelection(anchor: 2, head: 4),
    );
    final session = HomericTextInputSession(controller: controller);
    final focusNode = FocusNode();
    final clipboard = _FakeClipboard(readValue: 'XY');
    addTearDown(focusNode.dispose);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_harness(HomericEditableParagraph(
      controller: controller,
      inputSession: session,
      focusNode: focusNode,
      blockId: 'b',
      clipboard: clipboard,
      resolveStyle: (_) => _style,
    )));
    focusNode.requestFocus();
    await tester.pump();
    var notifications = 0;
    controller.addListener(() => notifications++);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(clipboard.writes, <String>['bc']);
    expect(controller.document.blocks.single.text, 'ad');
    expect(notifications, 1);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(controller.document.blocks.single.text, 'aXYd');
    expect(notifications, 2);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('clipboard semantics dispatch the same standard host actions',
      (tester) async {
    final handle = tester.ensureSemantics();
    final controller = HomericEditorController(
      document: _document('abcd'),
      selection: const HomericSelection(anchor: 2, head: 4),
    );
    final session = HomericTextInputSession(controller: controller);
    final focusNode = FocusNode();
    final clipboard = _FakeClipboard(readValue: 'Q');
    addTearDown(focusNode.dispose);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_harness(HomericEditableParagraph(
      controller: controller,
      inputSession: session,
      focusNode: focusNode,
      blockId: 'b',
      clipboard: clipboard,
      resolveStyle: (_) => _style,
    )));
    focusNode.requestFocus();
    await tester.pump();
    final node = tester.getSemantics(find.byType(HomericEditableParagraph));
    final data = node.getSemanticsData();
    expect(data.hasAction(ui.SemanticsAction.copy), isTrue);
    expect(data.hasAction(ui.SemanticsAction.cut), isTrue);
    expect(data.hasAction(ui.SemanticsAction.paste), isTrue);
    expect(data.customSemanticsActionIds, isNotEmpty);

    // `rootPipelineOwner` postdates Homeric's Flutter 3.24 minimum.
    // ignore: deprecated_member_use
    tester.binding.pipelineOwner.semanticsOwner!
        .performAction(node.id, ui.SemanticsAction.copy);
    await tester.pump();
    expect(clipboard.writes, <String>['bc']);

    // ignore: deprecated_member_use
    tester.binding.pipelineOwner.semanticsOwner!
        .performAction(node.id, ui.SemanticsAction.cut);
    await tester.pump();
    expect(controller.document.blocks.single.text, 'ad');
    handle.dispose();
  });

  testWidgets('read-only detaches input and keeps selection and copy semantics',
      (tester) async {
    final handle = tester.ensureSemantics();
    final document = _document('abcd');
    final controller = HomericEditorController(
      document: document,
      selection: const HomericSelection(anchor: 2, head: 4),
    );
    final session = HomericTextInputSession(controller: controller);
    final focusNode = FocusNode();
    final clipboard = _FakeClipboard(readValue: 'Q');
    addTearDown(focusNode.dispose);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_harness(HomericEditableParagraph(
      controller: controller,
      inputSession: session,
      focusNode: focusNode,
      blockId: 'b',
      clipboard: clipboard,
      resolveStyle: (_) => _style,
    )));
    focusNode.requestFocus();
    await tester.pump();
    expect(session.isAttached, isTrue);
    final staleDelta = session.debugDeltaCallback!;

    expect(controller.setReadOnly(true), isTrue);
    await tester.pump();

    expect(session.isAttached, isFalse);
    final node = tester.getSemantics(find.byType(HomericEditableParagraph));
    final data = node.getSemanticsData();
    // ignore: deprecated_member_use
    expect(data.hasFlag(ui.SemanticsFlag.isTextField), isTrue);
    // ignore: deprecated_member_use
    expect(data.hasFlag(ui.SemanticsFlag.isReadOnly), isTrue);
    expect(data.hasAction(ui.SemanticsAction.copy), isTrue);
    expect(data.hasAction(ui.SemanticsAction.cut), isFalse);
    expect(data.hasAction(ui.SemanticsAction.paste), isFalse);
    expect(data.hasAction(ui.SemanticsAction.setText), isFalse);
    expect(data.hasAction(ui.SemanticsAction.setSelection), isTrue);

    // `rootPipelineOwner` postdates Homeric's Flutter 3.24 minimum.
    // ignore: deprecated_member_use
    tester.binding.pipelineOwner.semanticsOwner!
        .performAction(node.id, ui.SemanticsAction.copy);
    await tester.pump();
    expect(clipboard.writes, <String>['bc']);

    staleDelta(const <TextEditingDelta>[
      TextEditingDeltaInsertion(
        oldText: 'abcd',
        textInserted: 'X',
        insertionOffset: 2,
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange.empty,
      ),
    ]);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(controller.document, same(document));

    tester.semantics.setSelection(
      find.semantics.byValue('abcd'),
      base: 0,
      extent: 4,
    );
    await tester.pump();
    expect(controller.selection, const HomericSelection(anchor: 1, head: 5));

    expect(controller.setReadOnly(false), isTrue);
    await tester.pump();
    expect(session.isAttached, isTrue,
        reason: 'the still-focused host binds one fresh input epoch');
    handle.dispose();
  });

  testWidgets('paste started before blur stays stale after refocus',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final controller = HomericEditorController(
      document: _document('ab'),
      selection: const HomericSelection.collapsed(2),
    );
    final session = HomericTextInputSession(controller: controller);
    final focusNode = FocusNode();
    final pendingRead = Completer<String?>();
    final clipboard = _FakeClipboard(pendingRead: pendingRead);
    addTearDown(focusNode.dispose);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_harness(HomericEditableParagraph(
      controller: controller,
      inputSession: session,
      focusNode: focusNode,
      blockId: 'b',
      clipboard: clipboard,
      resolveStyle: (_) => _style,
    )));
    focusNode.requestFocus();
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    focusNode.unfocus();
    await tester.pump();
    focusNode.requestFocus();
    await tester.pump();

    pendingRead.complete('stale');
    await tester.pump();
    expect(controller.document.blocks.single.text, 'ab');
    expect(controller.canUndo, isFalse);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('macOS word selectors preserve direction and reversal semantics',
      (tester) async {
    final controller = HomericEditorController(document: _document('one two'));
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
    controller.setSelection(HomericSelection.collapsed(
        controller.globalPositionForBlockOffset('b', 7)));
    await tester.pump();

    await _sendSelectors(binding, 1, const ['moveWordLeft:']);
    await tester.pump();
    expect(controller.selection, const HomericSelection.collapsed(5));

    await _sendSelectors(binding, 1, const ['moveWordLeftAndModifySelection:']);
    await tester.pump();
    expect(controller.selection, const HomericSelection(anchor: 5, head: 1));

    await _sendSelectors(
        binding, 1, const ['moveWordRightAndModifySelection:']);
    await tester.pump();
    expect(controller.selection, const HomericSelection(anchor: 5, head: 4));

    await _sendSelectors(
        binding, 1, const ['moveWordRightAndModifySelection:']);
    await tester.pump();
    expect(controller.selection, const HomericSelection.collapsed(5),
        reason: 'macOS collapses at the anchor before reversing direction');
  });

  testWidgets('word deletion uses the canonical directional range',
      (tester) async {
    final controller = HomericEditorController(document: _document('one two'));
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
    controller.setSelection(HomericSelection.collapsed(
        controller.globalPositionForBlockOffset('b', 7)));
    await tester.pump();

    await _sendSelectors(binding, 1, const ['deleteWordBackward:']);
    await tester.pump();
    expect(controller.document.blocks.single.text, 'one ');
    expect(controller.selection, const HomericSelection.collapsed(5));
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

  testWidgets('consumer decorations project from the current canonical block',
      (tester) async {
    final document = Document([
      Block(
        id: 'b',
        type: 'paragraph',
        runs: [
          InlineRun('a', attributes: const {'tone': 'warm'}),
          InlineRun('b'),
        ],
      ),
    ]);
    final controller = HomericEditorController(
      document: document,
      decorations: DecorationSet.of([
        Decoration.inline('b', 0, 2, spec: 'controller'),
      ]),
    );
    final session = HomericTextInputSession(controller: controller);
    final canonicalDecorations = controller.decorations;
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    Iterable<Decoration> project(Block block) sync* {
      var offset = 0;
      for (final run in block.runs) {
        final tone = run.attributes['tone'];
        if (tone != null) {
          yield Decoration.inline(
            block.id,
            offset,
            offset + run.length,
            spec: tone,
          );
        }
        offset += run.length;
      }
    }

    await tester.pumpWidget(_harness(HomericEditableParagraph(
      controller: controller,
      inputSession: session,
      blockId: 'b',
      deriveDecorations: project,
      derivePaintLayers: (block, decorations) => <PaintLayer>[
        for (final decoration in decorations)
          if (decoration.spec == 'warm' || decoration.spec == 'cool')
            PaintLayer(
              range: DocRange(
                DocOffset(decoration.start),
                DocOffset(decoration.end),
              ),
              band: PaintBand.underlay,
              painter: solidWashPainter,
              spec: SolidWashSpec(
                decoration.spec == 'warm'
                    ? const Color(0x11FF0000)
                    : const Color(0x110000FF),
              ),
            ),
      ],
      resolveStyle: (run) => TextStyle(
        color: switch (run.decorations.map((item) => item.spec).toSet()) {
          final specs when specs.contains('warm') => const Color(0xFFFF0000),
          final specs when specs.contains('cool') => const Color(0xFF0000FF),
          _ => const Color(0xFF000000),
        },
        decoration: run.decorations.any((item) => item.spec == 'controller')
            ? TextDecoration.underline
            : null,
      ),
    )));
    await tester.pump();

    RenderHomericParagraph render() =>
        tester.renderObject(find.byType(HomericParagraph));
    TextStyle styleAt(int offset) => render()
        .source
        .segments
        .whereType<TextSegment<TextStyle>>()
        .singleWhere((segment) =>
            segment.viewStart <= offset && segment.viewEnd > offset)
        .style;
    expect(styleAt(0).color, const Color(0xFFFF0000));
    expect(styleAt(0).decoration, TextDecoration.underline,
        reason: 'consumer projection merges with controller decorations');
    expect(
      (render().paintLayers.single.spec as SolidWashSpec).color,
      const Color(0x11FF0000),
    );
    expect(styleAt(1).color, const Color(0xFF000000));

    final mark = Transaction(controller.document)
      ..step(AddMarkStep(2, 3, 'tone', 'cool'));
    expect(controller.applyTransaction(mark), isTrue);
    await tester.pump();

    expect(styleAt(1).color, const Color(0xFF0000FF),
        reason: 'projection must read the new immutable Block, not a stale '
            'parent-built decoration list');
    expect(styleAt(1).decoration, TextDecoration.underline);
    expect(
      (render().paintLayers.last.spec as SolidWashSpec).color,
      const Color(0x110000FF),
      reason: 'derived paint observes the same current merged decorations',
    );
    expect(controller.decorations, same(canonicalDecorations),
        reason: 'transient projection never enters canonical history');

    expect(controller.undo(), isTrue);
    await tester.pump();
    expect(styleAt(1).color, const Color(0xFF000000));
    expect(controller.redo(), isTrue);
    await tester.pump();
    expect(styleAt(1).color, const Color(0xFF0000FF),
        reason: 'undo and redo each derive from their current immutable block');
    expect(controller.decorations, same(canonicalDecorations));
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
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(ColoredBox), findsOneWidget,
        reason: 'composition pauses blinking with the caret visible');

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

  testWidgets('focused caret blinks, resets visible, and cancels on disposal',
      (tester) async {
    const caretColor = Color(0xFF123456);
    final controller = HomericEditorController(document: _document('abc'));
    final session = HomericTextInputSession(controller: controller);
    final focusNode = FocusNode();
    var resolveCalls = 0;
    addTearDown(focusNode.dispose);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    final caret = find.byWidgetPredicate(
      (widget) => widget is ColoredBox && widget.color == caretColor,
    );
    await tester.pumpWidget(_harness(HomericEditableParagraph(
      controller: controller,
      inputSession: session,
      focusNode: focusNode,
      blockId: 'b',
      caretColor: caretColor,
      resolveStyle: (_) {
        resolveCalls++;
        return _style;
      },
    )));
    focusNode.requestFocus();
    await tester.pump();

    expect(caret, findsOneWidget);
    final callsBeforeBlink = resolveCalls;
    await tester.pump(const Duration(milliseconds: 499));
    expect(caret, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    expect(caret, findsNothing);
    expect(resolveCalls, callsBeforeBlink,
        reason: 'a blink rebuilds only the caret overlay');
    controller.setSelection(HomericSelection.collapsed(
      controller.globalPositionForBlockOffset('b', 1),
    ));
    await tester.pump();
    expect(caret, findsOneWidget,
        reason: 'selection movement restarts visible');
    await tester.pump(const Duration(milliseconds: 500));
    expect(caret, findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('unrelated rebuilds and decoration updates preserve blink phase',
      (tester) async {
    const caretColor = Color(0xFF2468AC);
    final controller = HomericEditorController(document: _document('abc'));
    final session = HomericTextInputSession(controller: controller);
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    late StateSetter rebuild;
    final caret = find.byWidgetPredicate(
      (widget) => widget is ColoredBox && widget.color == caretColor,
    );
    await tester.pumpWidget(_harness(StatefulBuilder(
      builder: (context, setState) {
        rebuild = setState;
        return HomericEditableParagraph(
          controller: controller,
          inputSession: session,
          focusNode: focusNode,
          blockId: 'b',
          caretColor: caretColor,
          resolveStyle: (_) => _style,
        );
      },
    )));
    focusNode.requestFocus();
    await tester.pump();

    await tester.pump(const Duration(milliseconds: 200));
    rebuild(() {});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    controller.replaceDecorations(
      DecorationSet.of([Decoration.inline('b', 0, 1)]),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(caret, findsNothing,
        reason: 'neither update restarts the original 500ms blink phase');
  });

  testWidgets('reduced motion keeps a focused caret steadily visible',
      (tester) async {
    const caretColor = Color(0xFF654321);
    final controller = HomericEditorController(document: _document('abc'));
    final session = HomericTextInputSession(controller: controller);
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    final caret = find.byWidgetPredicate(
      (widget) => widget is ColoredBox && widget.color == caretColor,
    );
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(disableAnimations: true),
      child: _harness(HomericEditableParagraph(
        controller: controller,
        inputSession: session,
        focusNode: focusNode,
        blockId: 'b',
        caretColor: caretColor,
        resolveStyle: (_) => _style,
      )),
    ));
    focusNode.requestFocus();
    await tester.pump();

    expect(caret, findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(caret, findsOneWidget);
  });

  testWidgets('disabled TickerMode pauses a focused caret while visible',
      (tester) async {
    const caretColor = Color(0xFFABCDEF);
    final controller = HomericEditorController(document: _document('abc'));
    final session = HomericTextInputSession(controller: controller);
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    final caret = find.byWidgetPredicate(
      (widget) => widget is ColoredBox && widget.color == caretColor,
    );
    await tester.pumpWidget(TickerMode(
      enabled: false,
      child: _harness(HomericEditableParagraph(
        controller: controller,
        inputSession: session,
        focusNode: focusNode,
        blockId: 'b',
        caretColor: caretColor,
        resolveStyle: (_) => _style,
      )),
    ));
    focusNode.requestFocus();
    await tester.pump();

    expect(caret, findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(caret, findsOneWidget);
  });

  testWidgets('blur retains an expanded selection with its inactive tint',
      (tester) async {
    const active = Color(0xFF112233);
    const inactive = Color(0xFF445566);
    final controller = HomericEditorController(
      document: _document('abc'),
      selection: const HomericSelection(anchor: 1, head: 3),
    );
    final session = HomericTextInputSession(controller: controller);
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_harness(HomericEditableParagraph(
      controller: controller,
      inputSession: session,
      focusNode: focusNode,
      blockId: 'b',
      selectionColor: active,
      inactiveSelectionColor: inactive,
      resolveStyle: (_) => _style,
    )));
    focusNode.requestFocus();
    await tester.pump();

    var render = tester
        .renderObject<RenderHomericParagraph>(find.byType(HomericParagraph));
    expect((render.paintLayers.single.spec as SolidWashSpec).color, active);
    focusNode.unfocus();
    await tester.pump();
    await tester.pump();
    render = tester
        .renderObject<RenderHomericParagraph>(find.byType(HomericParagraph));
    expect((render.paintLayers.single.spec as SolidWashSpec).color, inactive);
    expect(controller.selection, const HomericSelection(anchor: 1, head: 3));
    expect(find.byType(ColoredBox), findsNothing);
  });

  testWidgets('desktop selection is arbitrated by the text selection detector',
      (tester) async {
    final controller = HomericEditorController(document: _document('one two'));
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

    expect(find.byType(TextSelectionGestureDetector), findsOneWidget);
  });

  testWidgets('macOS rapid clicks clamp at whole paragraph selection',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final controller = HomericEditorController(document: _document('one two'));
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
    final point = tester.getTopLeft(find.byType(HomericEditableParagraph)) +
        const Offset(12, 7);

    await tester.tapAt(point);
    expect(controller.selection!.isCollapsed, isTrue);
    await tester.tapAt(point);
    var local = _localSelection(controller);
    expect('one two'.substring(local.start, local.end), 'one');
    await tester.tapAt(point);
    local = _localSelection(controller);
    expect((local.start, local.end), (0, 7));
    await tester.tapAt(point);
    local = _localSelection(controller);
    expect((local.start, local.end), (0, 7));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('single-tap observer excludes drag and multi-click sequences',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final controller = HomericEditorController(document: _document('one two'));
    final session = HomericTextInputSession(controller: controller);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    var calls = 0;
    var hoverCalls = 0;
    var hoverExits = 0;
    var ancestorHoverCalls = 0;
    await tester.pumpWidget(_harness(MouseRegion(
      opaque: false,
      onHover: (_) => ancestorHoverCalls++,
      child: HomericEditableParagraph(
        controller: controller,
        inputSession: session,
        blockId: 'b',
        resolveStyle: (_) => _style,
        onSingleTap: (geometry, localPosition, globalPosition) {
          expect(geometry.isCurrent, isTrue);
          expect(localPosition.dx, greaterThanOrEqualTo(0));
          expect(globalPosition.dx, greaterThan(0));
          calls++;
        },
        onHover: (geometry, localPosition, globalPosition) {
          expect(geometry.isCurrent, isTrue);
          hoverCalls++;
        },
        onHoverExit: (geometry) {
          hoverExits++;
        },
      ),
    )));
    await tester.pump();
    final point = tester.getTopLeft(find.byType(HomericEditableParagraph)) +
        const Offset(12, 7);

    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(point);
    await tester.pump();
    expect(hoverCalls, greaterThan(0));
    expect(ancestorHoverCalls, greaterThan(0),
        reason: 'the additive hover plane must remain non-opaque');
    expect(calls, 0,
        reason: 'hover shares the pointer plane without becoming a tap');
    await mouse.moveTo(const Offset(-10, -10));
    await tester.pump();
    expect(hoverExits, 1);
    await mouse.removePointer();

    await tester.tapAt(point);
    expect(calls, 1);
    await tester.tapAt(point);
    await tester.tapAt(point);
    expect(calls, 1, reason: 'double and triple click stay owned by selection');

    await tester.pump(const Duration(milliseconds: 500));
    final gesture = await tester.startGesture(point);
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    await gesture.up();
    expect(calls, 1, reason: 'drag selection cannot become an additive tap');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('word drag expands by words and pointer cancel clears its anchor',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final controller =
        HomericEditorController(document: _document('one two three'));
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
    final origin = tester.getTopLeft(find.byType(HomericEditableParagraph));
    final firstWord = origin + const Offset(10, 7);
    final geometry = ParagraphGeometry(tester
        .renderObject<RenderHomericParagraph>(find.byType(HomericParagraph)));
    final thirdWord = geometry
        .rectsForRange(
          DocRange(const DocOffset(8), const DocOffset(13)),
        )
        .value
        .first
        .toRect()
        .center;
    await tester.tapAt(firstWord);
    final gesture = await tester.startGesture(firstWord);
    await gesture.moveTo(origin + thirdWord);
    await tester.pump();
    var local = _localSelection(controller);
    expect((local.start, local.end), (0, 13));
    await gesture.cancel();

    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 1));
    final fresh = await tester.startGesture(origin + const Offset(35, 7));
    await fresh.moveTo(origin + const Offset(52, 7));
    await tester.pump();
    await fresh.up();
    local = _localSelection(controller);
    expect(local.start, greaterThan(0),
        reason: 'the cancelled word anchor cannot leak into the next drag');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('triple-click drag remains clamped to the active paragraph',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final controller = HomericEditorController(document: _document('one two'));
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
    final point = tester.getTopLeft(find.byType(HomericEditableParagraph)) +
        const Offset(10, 7);
    await tester.tapAt(point);
    await tester.tapAt(point);
    final gesture = await tester.startGesture(point);
    await gesture.moveBy(const Offset(-300, 300));
    await tester.pump();
    await gesture.up();
    final local = _localSelection(controller);
    expect((local.start, local.end), (0, 7));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
      'secondary click preserves inside selection and menu is stale safe',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final clipboard = _FakeClipboard();
    final controller = HomericEditorController(
      document: _document('one two'),
      selection: const HomericSelection(anchor: 1, head: 4),
    );
    final session = HomericTextInputSession(controller: controller);
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 200,
          child: HomericEditableParagraph(
            controller: controller,
            inputSession: session,
            focusNode: focusNode,
            blockId: 'b',
            clipboard: clipboard,
            resolveStyle: (_) => _style,
          ),
        ),
      ),
    ));
    focusNode.requestFocus();
    await tester.pump();
    final origin = tester.getTopLeft(find.byType(HomericEditableParagraph));
    await tester.tapAt(
      origin + const Offset(10, 7),
      buttons: kSecondaryMouseButton,
    );
    await tester.pump();
    expect(_localSelection(controller),
        const BlockTextSelection(anchor: 0, head: 3));
    final toolbar = tester.widget<AdaptiveTextSelectionToolbar>(
      find.byType(AdaptiveTextSelectionToolbar),
    );
    expect(toolbar.buttonItems!.map((item) => item.type), [
      ContextMenuButtonType.cut,
      ContextMenuButtonType.copy,
      ContextMenuButtonType.paste,
      ContextMenuButtonType.selectAll,
      ContextMenuButtonType.custom,
      ContextMenuButtonType.custom,
    ]);
    expect(toolbar.buttonItems!.map((item) => item.onPressed != null), [
      true,
      true,
      true,
      true,
      false,
      false,
    ]);
    final staleCut = toolbar.buttonItems!.first.onPressed!;
    controller.setSelection(const HomericSelection.collapsed(8));
    await tester.pump();
    staleCut();
    await tester.pump();
    expect(clipboard.writes, isEmpty);
    expect(controller.document.blocks.single.text, 'one two');
    expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);

    final geometry = ParagraphGeometry(tester
        .renderObject<RenderHomericParagraph>(find.byType(HomericParagraph)));
    final secondWord = geometry
        .rectsForRange(
          DocRange(const DocOffset(4), const DocOffset(7)),
        )
        .value
        .first
        .toRect()
        .center;
    await tester.tapAt(
      origin + secondWord,
      buttons: kSecondaryMouseButton,
    );
    await tester.pump();
    final outside = _localSelection(controller);
    expect('one two'.substring(outside.start, outside.end), 'two');
    ContextMenuController.removeAny();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('adaptive menu supports keyboard traversal and activation',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final clipboard = _FakeClipboard();
    final controller = HomericEditorController(
      document: _document('one two'),
      selection: const HomericSelection(anchor: 1, head: 4),
    );
    final session = HomericTextInputSession(controller: controller);
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 200,
          child: HomericEditableParagraph(
            controller: controller,
            inputSession: session,
            focusNode: focusNode,
            blockId: 'b',
            clipboard: clipboard,
            resolveStyle: (_) => _style,
          ),
        ),
      ),
    ));
    focusNode.requestFocus();
    await tester.pump();
    final origin = tester.getTopLeft(find.byType(HomericEditableParagraph));
    await tester.tapAt(
      origin + const Offset(10, 7),
      buttons: kSecondaryMouseButton,
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(primaryFocus, isNot(same(focusNode)));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump();

    expect(clipboard.writes, <String>['one']);
    expect(controller.document.blocks.single.text, 'one two');
    expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('current projected spell results paint outside controller state',
      (tester) async {
    final provider = _FakeSpellProvider();
    final controller = HomericEditorController(document: _document('mispell'));
    final session = HomericTextInputSession(controller: controller);
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    final decorations = controller.decorations;
    await tester.pumpWidget(_harness(HomericEditableParagraph(
      controller: controller,
      inputSession: session,
      focusNode: focusNode,
      blockId: 'b',
      resolveStyle: (_) => _style,
      spellCheckProvider: provider,
    )));
    await tester.pump();
    focusNode.requestFocus();
    await tester.pump();
    await tester.pump();
    expect(provider.requests, hasLength(1));
    final revision = controller.stateRevision;
    provider.complete(const <SuggestionSpan>[
      SuggestionSpan(TextRange(start: 0, end: 7), <String>['misspell']),
    ]);
    await tester.pump();
    await tester.pump();

    final render = tester
        .renderObject<RenderHomericParagraph>(find.byType(HomericParagraph));
    expect(render.paintLayers.last.band, PaintBand.overlay);
    expect(controller.decorations, same(decorations));
    expect(controller.stateRevision, revision);
  });

  testWidgets('inactive paragraphs never schedule spelling work',
      (tester) async {
    final firstProvider = _FakeSpellProvider();
    final secondProvider = _FakeSpellProvider();
    final firstController =
        HomericEditorController(document: _document('first'));
    final secondController = HomericEditorController(
      document: Document([
        Block(id: 'c', type: 'paragraph', runs: [InlineRun('second')]),
      ]),
    );
    final firstSession = HomericTextInputSession(controller: firstController);
    final secondSession = HomericTextInputSession(controller: secondController);
    final firstFocus = FocusNode();
    final secondFocus = FocusNode();
    addTearDown(firstFocus.dispose);
    addTearDown(secondFocus.dispose);
    addTearDown(firstSession.dispose);
    addTearDown(secondSession.dispose);
    addTearDown(firstController.dispose);
    addTearDown(secondController.dispose);
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Column(children: [
        SizedBox(
          width: 200,
          child: HomericEditableParagraph(
            controller: firstController,
            inputSession: firstSession,
            focusNode: firstFocus,
            blockId: 'b',
            resolveStyle: (_) => _style,
            spellCheckProvider: firstProvider,
          ),
        ),
        SizedBox(
          width: 200,
          child: HomericEditableParagraph(
            controller: secondController,
            inputSession: secondSession,
            focusNode: secondFocus,
            blockId: 'c',
            resolveStyle: (_) => _style,
            spellCheckProvider: secondProvider,
          ),
        ),
      ]),
    ));
    await tester.pump();
    expect(firstProvider.requests, isEmpty);
    expect(secondProvider.requests, isEmpty);

    firstFocus.requestFocus();
    await tester.pump();
    await tester.pump();
    expect(firstProvider.requests, hasLength(1));
    expect(secondProvider.requests, isEmpty);
  });

  testWidgets('spell provider swap refreshes without reconnecting input',
      (tester) async {
    final firstProvider = _FakeSpellProvider();
    final secondProvider = _FakeSpellProvider();
    final controller = HomericEditorController(document: _document('mispell'));
    final session = HomericTextInputSession(controller: controller);
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    late StateSetter rebuild;
    HomericSpellCheckProvider provider = firstProvider;
    var toolbarRequests = 0;

    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: StatefulBuilder(builder: (context, setState) {
        rebuild = setState;
        return SizedBox(
          width: 200,
          child: HomericEditableParagraph(
            controller: controller,
            inputSession: session,
            focusNode: focusNode,
            blockId: 'b',
            resolveStyle: (_) => _style,
            spellCheckProvider: provider,
            onShowToolbar: () => toolbarRequests++,
          ),
        );
      }),
    ));
    focusNode.requestFocus();
    await tester.pump();
    await tester.pump();
    expect(firstProvider.requests, hasLength(1));

    rebuild(() => provider = secondProvider);
    await tester.pump();
    await tester.pump();

    expect(secondProvider.requests, hasLength(1));
    await _sendShowToolbar(binding, 1);
    expect(toolbarRequests, 1,
        reason: 'a spelling-only swap keeps the current input client');
  });

  testWidgets('stale spell result is discarded and current result is painted',
      (tester) async {
    final provider = _FakeSpellProvider();
    final controller = HomericEditorController(document: _document('bad'));
    final session = HomericTextInputSession(controller: controller);
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_harness(HomericEditableParagraph(
      controller: controller,
      inputSession: session,
      focusNode: focusNode,
      blockId: 'b',
      resolveStyle: (_) => _style,
      spellCheckProvider: provider,
    )));
    focusNode.requestFocus();
    await tester.pump();
    await tester.pump();
    expect(provider.requests, hasLength(1));

    controller.applyBlockEditBatch(
      blockId: 'b',
      edits: const <CanonicalTextEdit>[CanonicalTextEdit(0, 1, 's')],
      selection: const BlockTextSelection.collapsed(1),
    );
    await tester.pump();
    expect(provider.requests, hasLength(2));
    provider.completeAt(0, const <SuggestionSpan>[
      SuggestionSpan(TextRange(start: 0, end: 3), <String>['good']),
    ]);
    await tester.pump();
    await tester.pump();
    var render = tester
        .renderObject<RenderHomericParagraph>(find.byType(HomericParagraph));
    expect(render.paintLayers, isEmpty);

    provider.completeAt(1, const <SuggestionSpan>[
      SuggestionSpan(TextRange(start: 0, end: 3), <String>['sad']),
    ]);
    await tester.pump();
    await tester.pump();
    render = tester
        .renderObject<RenderHomericParagraph>(find.byType(HomericParagraph));
    expect(render.paintLayers, hasLength(1));
    expect(render.paintLayers.single.band, PaintBand.overlay);
  });

  testWidgets(
      'projected spelling maps hidden syntax and replacement is one undo unit',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final provider = _FakeSpellProvider();
    final controller = HomericEditorController(
      document: _document('**bold**'),
      decorations: DecorationSet.of([
        Decoration.replace('b', 0, 2, replacementLength: 0),
        Decoration.replace('b', 6, 8, replacementLength: 0),
      ]),
    );
    final session = HomericTextInputSession(controller: controller);
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 200,
          child: HomericEditableParagraph(
            controller: controller,
            inputSession: session,
            focusNode: focusNode,
            blockId: 'b',
            resolveStyle: (_) => _style,
            spellCheckProvider: provider,
          ),
        ),
      ),
    ));
    focusNode.requestFocus();
    await tester.pump();
    await tester.pump();
    expect(provider.requests.single.text, 'bold');
    provider.complete(const <SuggestionSpan>[
      SuggestionSpan(TextRange(start: 0, end: 4), <String>['strong']),
    ]);
    await tester.pump();
    await tester.pump();
    expect(controller.canUndo, isFalse,
        reason: 'transient spelling state never enters controller history');

    final origin = tester.getTopLeft(find.byType(HomericEditableParagraph));
    final geometry = ParagraphGeometry(tester
        .renderObject<RenderHomericParagraph>(find.byType(HomericParagraph)));
    final visibleWord = geometry
        .rectsForRange(
          DocRange(const DocOffset(0), const DocOffset(8)),
        )
        .value
        .first
        .toRect()
        .center;
    await tester.tapAt(
      origin + visibleWord,
      buttons: kSecondaryMouseButton,
    );
    await tester.pump();
    final toolbar = tester.widget<AdaptiveTextSelectionToolbar>(
      find.byType(AdaptiveTextSelectionToolbar),
    );
    expect(toolbar.buttonItems!.first.label, 'strong');
    toolbar.buttonItems!.first.onPressed!();
    await tester.pump();
    expect(controller.document.blocks.single.text, 'strong');
    expect(controller.canUndo, isTrue);
    expect(controller.undo(), isTrue);
    expect(controller.document.blocks.single.text, '**bold**');
    expect(controller.canUndo, isFalse);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('no spell provider leaves ordinary editing enabled',
      (tester) async {
    final controller = HomericEditorController(document: _document('plain'));
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
          const Offset(12, 7),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(controller.document.blocks.single.text, isNot('plain'));
  });

  testWidgets('current platform toolbar callback opens one adaptive menu',
      (tester) async {
    final controller = HomericEditorController(
      document: _document('one two'),
      selection: const HomericSelection(anchor: 1, head: 4),
    );
    final session = HomericTextInputSession(controller: controller);
    final focusNode = FocusNode();
    final replacementFocusNode = FocusNode();
    var toolbarRequests = 0;
    addTearDown(focusNode.dispose);
    addTearDown(replacementFocusNode.dispose);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 200,
          child: HomericEditableParagraph(
            key: const ValueKey('first-host'),
            controller: controller,
            inputSession: session,
            focusNode: replacementFocusNode,
            blockId: 'b',
            resolveStyle: (_) => _style,
            onShowToolbar: () => toolbarRequests++,
          ),
        ),
      ),
    ));
    replacementFocusNode.requestFocus();
    await tester.pump();
    await _sendShowToolbar(binding, 1);
    await tester.pump();
    expect(toolbarRequests, 1);
    expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 200,
          child: HomericEditableParagraph(
            key: const ValueKey('replacement-host'),
            controller: controller,
            inputSession: session,
            focusNode: focusNode,
            blockId: 'b',
            resolveStyle: (_) => _style,
            onShowToolbar: () => toolbarRequests++,
          ),
        ),
      ),
    ));
    focusNode.requestFocus();
    await tester.pump();
    await _sendShowToolbar(binding, 1);
    await tester.pump();
    expect(toolbarRequests, 1,
        reason: 'the superseded text-input client is inert');
    expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
    await _sendShowToolbar(binding, 2);
    await tester.pump();
    expect(toolbarRequests, 2);
    expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
    ContextMenuController.removeAny();
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

BlockTextSelection _localSelection(HomericEditorController controller) {
  final selection = controller.selection!;
  return BlockTextSelection(
    anchor: controller.blockOffsetForGlobalPosition('b', selection.anchor),
    head: controller.blockOffsetForGlobalPosition('b', selection.head),
    affinity: selection.affinity,
  );
}

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

Future<void> _sendShowToolbar(
  TestWidgetsFlutterBinding binding,
  int clientId,
) async {
  final message = const JSONMessageCodec().encodeMessage(<String, Object?>{
    'method': 'TextInputClient.showToolbar',
    'args': <Object?>[clientId, 0, 1],
  });
  await binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/textinput',
    message,
    (_) {},
  );
}

final class _FakeClipboard implements HomericClipboardAdapter {
  _FakeClipboard({this.readValue, this.pendingRead});

  String? readValue;
  Completer<String?>? pendingRead;
  final List<String> writes = <String>[];

  @override
  Future<String?> readText() async => pendingRead?.future ?? readValue;

  @override
  Future<void> writeText(String text) async => writes.add(text);
}

final class _FakeSpellProvider implements HomericSpellCheckProvider {
  final List<HomericSpellCheckRequest> requests = [];
  final List<Completer<List<SuggestionSpan>>> _pending = [];

  @override
  Future<List<SuggestionSpan>> check(HomericSpellCheckRequest request) {
    requests.add(request);
    final completer = Completer<List<SuggestionSpan>>();
    _pending.add(completer);
    return completer.future;
  }

  void complete(List<SuggestionSpan> suggestions) {
    completeAt(0, suggestions);
  }

  void completeAt(int index, List<SuggestionSpan> suggestions) {
    _pending[index].complete(suggestions);
  }
}
