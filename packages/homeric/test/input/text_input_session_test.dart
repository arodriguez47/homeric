import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TextInputConnection.debugResetId();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.textInput,
      (call) async {
        calls.add(call);
        return null;
      },
    );
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.textInput,
      null,
    );
  });

  test('ordered selectors and toolbar stay bound to their attachment epoch',
      () {
    final controller = HomericEditorController(
      document: _document('ab'),
      selection: const HomericSelection.collapsed(1),
    );
    final session = HomericTextInputSession(controller: controller);
    final oldDelegate = _FakeCommandDelegate();
    final currentDelegate = _FakeCommandDelegate();

    session.attach(blockId: 'a', commandDelegate: oldDelegate);
    final oldSelector = session.debugSelectorCallback!;
    final oldToolbar = session.debugToolbarCallback!;
    session.attach(blockId: 'a', commandDelegate: currentDelegate);

    oldSelector('copy:');
    oldToolbar();
    expect(oldDelegate.intents, isEmpty);
    expect(oldDelegate.toolbarCount, 0);

    final currentSelector = session.debugSelectorCallback!;
    currentSelector('moveRight:');
    currentSelector('moveRight:');
    currentSelector('deleteBackward:');
    session.debugToolbarCallback!();
    expect(currentDelegate.intents, hasLength(3));
    expect(currentDelegate.intents[0].runtimeType,
        currentDelegate.intents[1].runtimeType,
        reason: 'identical ordered selectors are never time-deduplicated');
    expect(currentDelegate.toolbarCount, 1);

    session.dispose();
    controller.dispose();
  });

  test('floating cursor callbacks stay ordered and bound to their epoch', () {
    final controller = HomericEditorController(
      document: _document('ab'),
      selection: const HomericSelection.collapsed(1),
    );
    final session = HomericTextInputSession(controller: controller);
    final oldDelegate = _FakeCommandDelegate();
    final currentDelegate = _FakeCommandDelegate();

    session.attach(blockId: 'a', commandDelegate: oldDelegate);
    final stale = session.debugFloatingCursorCallback!;
    session.attach(blockId: 'a', commandDelegate: currentDelegate);
    expect(oldDelegate.transientCancelCount, 1);
    stale(RawFloatingCursorPoint(state: FloatingCursorDragState.Start));
    expect(oldDelegate.floatingCursorPoints, isEmpty);

    final current = session.debugFloatingCursorCallback!;
    current(RawFloatingCursorPoint(state: FloatingCursorDragState.Start));
    current(RawFloatingCursorPoint(
      state: FloatingCursorDragState.Update,
      offset: const Offset(12, 4),
    ));
    current(RawFloatingCursorPoint(state: FloatingCursorDragState.End));
    expect(
      currentDelegate.floatingCursorPoints.map((point) => point.state),
      <FloatingCursorDragState>[
        FloatingCursorDragState.Start,
        FloatingCursorDragState.Update,
        FloatingCursorDragState.End,
      ],
    );

    session.blur();
    expect(currentDelegate.transientCancelCount, 1);
    current(RawFloatingCursorPoint(state: FloatingCursorDragState.Start));
    expect(currentDelegate.floatingCursorPoints, hasLength(3));
    session.dispose();
    controller.dispose();
  });

  test('autocorrection prompt ranges validate the current attachment epoch',
      () {
    final controller = HomericEditorController(
      document: _document('alpha'),
      selection: const HomericSelection.collapsed(2),
    );
    final session = HomericTextInputSession(controller: controller);
    final firstDelegate = _FakeCommandDelegate();
    final currentDelegate = _FakeCommandDelegate();

    session.attach(blockId: 'a', commandDelegate: firstDelegate);
    final stale = session.debugAutocorrectionPromptCallback!;
    stale(1, 4);

    expect(firstDelegate.autocorrectionPromptRanges, const <TextRange>[
      TextRange(start: 1, end: 4),
    ]);

    session.blur();
    session.attach(blockId: 'a', commandDelegate: currentDelegate);
    final current = session.debugAutocorrectionPromptCallback!;

    stale(0, 2);
    expect(firstDelegate.autocorrectionPromptRanges, hasLength(1));
    expect(currentDelegate.autocorrectionPromptRanges, isEmpty);

    current(-1, 2);
    current(2, 2);
    current(0, 6);
    expect(currentDelegate.autocorrectionPromptRanges, isEmpty);

    current(0, 5);
    expect(currentDelegate.autocorrectionPromptRanges, const <TextRange>[
      TextRange(start: 0, end: 5),
    ]);

    session.dispose();
    controller.dispose();
  });

  test('attaches a delta client over canonical block text before geometry', () {
    final document = _document('raw **text**');
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(0, 4)),
    );
    final session = HomericTextInputSession(controller: controller);

    expect(session.attach(blockId: 'a'), isTrue);

    expect(session.isAttached, isTrue);
    expect(session.activeBlockId, 'a');
    expect(calls.map((call) => call.method), <String>[
      'TextInput.setClient',
      'TextInput.setEditingState',
      'TextInput.show',
    ]);
    expect(
      (calls.first.arguments as List<Object?>)[1],
      containsPair('enableDeltaModel', true),
    );
    expect(
      (calls.first.arguments as List<Object?>)[1],
      containsPair('inputAction', 'TextInputAction.newline'),
    );
    expect(
      calls[1].arguments,
      containsPair('text', 'raw **text**'),
    );

    session.dispose();
    controller.dispose();
  });

  test('accepted insertion mutates once without an editing-state echo',
      () async {
    final document = _document('ab');
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(0, 1)),
    );
    final session = HomericTextInputSession(controller: controller);
    var notifications = 0;
    controller.addListener(() => notifications++);
    session.attach(blockId: 'a');
    calls.clear();

    await _sendDeltas(binding, 1, <Map<String, Object?>>[
      _delta(
        oldText: 'ab',
        deltaText: 'X',
        start: 1,
        end: 1,
        selectionBase: 2,
        selectionExtent: 2,
      ),
    ]);

    expect(controller.document.blocks.single.text, 'aXb');
    expect(controller.selection, const HomericSelection.collapsed(3));
    expect(notifications, 1);
    expect(
      calls.where((call) => call.method == 'TextInput.setEditingState'),
      isEmpty,
    );

    session.dispose();
    controller.dispose();
  });

  test('ordered mixed deltas commit and undo as one controller boundary',
      () async {
    final document = _document('abcd');
    final initialSelection =
        HomericSelection.collapsed(document.positionAt(0, 1));
    final controller = HomericEditorController(
      document: document,
      selection: initialSelection,
    );
    final session = HomericTextInputSession(controller: controller);
    var notifications = 0;
    controller.addListener(() => notifications++);
    session.attach(blockId: 'a');
    calls.clear();

    await _sendDeltas(binding, 1, <Map<String, Object?>>[
      _delta(
        oldText: 'abcd',
        deltaText: 'XY',
        start: 1,
        end: 2,
        selectionBase: 3,
        selectionExtent: 3,
        composingBase: 1,
        composingExtent: 3,
      ),
      _delta(
        oldText: 'aXYcd',
        deltaText: '',
        start: -1,
        end: -1,
        selectionBase: 3,
        selectionExtent: 1,
        composingBase: 1,
        composingExtent: 3,
      ),
      _delta(
        oldText: 'aXYcd',
        deltaText: 'Z',
        start: 3,
        end: 4,
        selectionBase: 4,
        selectionExtent: 4,
      ),
    ]);

    expect(controller.document.blocks.single.text, 'aXYZd');
    expect(controller.selection, const HomericSelection.collapsed(5));
    expect(controller.composing, isNull);
    expect(notifications, 1);
    expect(controller.canUndo, isTrue);
    expect(
      calls.where((call) => call.method == 'TextInput.setEditingState'),
      isEmpty,
    );

    expect(controller.undo(), isTrue);
    expect(controller.document, same(document));
    expect(controller.selection, initialSelection);

    session.dispose();
    controller.dispose();
  });

  test('selection and composing-only delta preserves block-local direction',
      () async {
    final document = _document('abcd');
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(0, 2)),
    );
    final session = HomericTextInputSession(controller: controller);
    session.attach(blockId: 'a');
    calls.clear();

    await _sendDeltas(binding, 1, <Map<String, Object?>>[
      _delta(
        oldText: 'abcd',
        deltaText: '',
        start: -1,
        end: -1,
        selectionBase: 4,
        selectionExtent: 1,
        selectionIsDirectional: true,
        composingBase: 1,
        composingExtent: 3,
      ),
    ]);

    expect(controller.selection!.anchor, document.positionAt(0, 4));
    expect(controller.selection!.head, document.positionAt(0, 1));
    expect(controller.selection!.isForward, isFalse);
    expect(
      controller.composing,
      HomericTextRange(
        document.positionAt(0, 1),
        document.positionAt(0, 3),
      ),
    );
    expect(calls, isEmpty);

    session.dispose();
    controller.dispose();
  });

  test('canonical platform offsets stay local to a later document block',
      () async {
    final document = _documents(<String>['first', 'second']);
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection(
        anchor: document.positionAt(1, 4),
        head: document.positionAt(1, 2),
        affinity: HomericCaretAffinity.upstream,
      ),
    );
    final session = HomericTextInputSession(controller: controller);

    expect(session.attach(blockId: 'b'), isTrue);
    expect(calls[1].arguments, containsPair('text', 'second'));
    expect(calls[1].arguments, containsPair('selectionBase', 4));
    expect(calls[1].arguments, containsPair('selectionExtent', 2));
    calls.clear();

    await _sendDeltas(binding, 1, <Map<String, Object?>>[
      _delta(
        oldText: 'second',
        deltaText: 'X',
        start: 2,
        end: 4,
        selectionBase: 3,
        selectionExtent: 3,
      ),
    ]);

    expect(controller.document.blocks[0].text, 'first');
    expect(controller.document.blocks[1].text, 'seXnd');
    expect(
      controller.selection,
      HomericSelection.collapsed(controller.document.positionAt(1, 3)),
    );
    expect(_editingStateCalls(calls), isEmpty);

    session.dispose();
    controller.dispose();
  });

  test('cross-block selection exposes one collapsed head-block shadow', () {
    final document = _documents(<String>['first', 'second']);
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection(
        anchor: document.positionAt(0, 2),
        head: document.positionAt(1, 3),
      ),
    );
    final session = HomericTextInputSession(controller: controller);

    expect(session.attach(blockId: 'b'), isTrue);
    expect(calls[1].arguments, containsPair('text', 'second'));
    expect(calls[1].arguments, containsPair('selectionBase', 3));
    expect(calls[1].arguments, containsPair('selectionExtent', 3));

    session.dispose();
    controller.dispose();
  });

  test('first composing delta replaces a cross-block selection once', () async {
    final document = _documents(<String>['abc', 'def']);
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection(
        anchor: document.positionAt(0, 1),
        head: document.positionAt(1, 2),
      ),
    );
    final session = HomericTextInputSession(controller: controller);
    final host = _FakeCommandDelegate();
    var notifications = 0;
    controller.addListener(() => notifications++);
    session.attach(blockId: 'b', commandDelegate: host);
    expect(
      session.geometryLeaseFor(blockId: 'b', owner: host),
      isNotNull,
    );
    calls.clear();

    await _sendDeltas(binding, 1, <Map<String, Object?>>[
      _delta(
        oldText: 'def',
        deltaText: 'X',
        start: 2,
        end: 2,
        selectionBase: 3,
        selectionExtent: 3,
        composingBase: 2,
        composingExtent: 3,
      ),
    ]);

    expect(
        controller.document.blocks.map((block) => block.text), <String>['aXf']);
    expect(controller.selection,
        HomericSelection.collapsed(controller.document.positionAt(0, 2)));
    expect(
      controller.composing,
      HomericTextRange(
        controller.document.positionAt(0, 1),
        controller.document.positionAt(0, 2),
      ),
    );
    expect(notifications, 1);
    expect(session.geometryLeaseFor(blockId: 'a', owner: host), isNull,
        reason: 'the surviving block has no mounted host capability yet');
    expect(_editingStateCalls(calls), hasLength(1));
    expect(_editingStateCalls(calls).single.arguments,
        containsPair('text', 'aXf'));
    expect(controller.canUndo, isFalse);

    calls.clear();
    await _sendDeltas(binding, 1, <Map<String, Object?>>[
      _delta(
        oldText: 'aXf',
        deltaText: '',
        start: -1,
        end: -1,
        selectionBase: 2,
        selectionExtent: 2,
      ),
    ]);
    expect(controller.composing, isNull);
    expect(controller.canUndo, isTrue);
    expect(controller.undo(), isTrue);
    expect(controller.document, same(document));
    expect(
      controller.selection,
      HomericSelection(
        anchor: document.positionAt(0, 1),
        head: document.positionAt(1, 2),
      ),
    );

    session.dispose();
    controller.dispose();
  });

  test('suspended deltas are inert and retarget reuses the connection',
      () async {
    final document = _documents(<String>['a', 'b', 'c']);
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(0, 1)),
    );
    final session = HomericTextInputSession(controller: controller);
    session.attach(blockId: 'a');
    final setClientCount =
        calls.where((call) => call.method == 'TextInput.setClient').length;
    calls.clear();

    session.suspendDeltas();
    controller.setSelection(HomericSelection(
      anchor: document.positionAt(0, 1),
      head: document.positionAt(2, 1),
    ));
    await _sendDeltas(binding, 1, <Map<String, Object?>>[
      _delta(
        oldText: 'a',
        deltaText: 'X',
        start: 1,
        end: 1,
        selectionBase: 2,
        selectionExtent: 2,
      ),
    ]);
    expect(controller.document, same(document));

    expect(session.retarget(blockId: 'c'), isTrue);
    session.resumeDeltas();
    expect(session.activeBlockId, 'c');
    expect(
        calls.where((call) => call.method == 'TextInput.setClient'), isEmpty);
    expect(setClientCount, 1);
    expect(
      _editingStateCalls(calls).last.arguments,
      containsPair('text', 'c'),
    );
    expect(
      calls.where((call) => call.method == 'TextInput.show'),
      hasLength(1),
      reason: 'retargeting must reassert the native first responder',
    );

    session.dispose();
    controller.dispose();
  });

  test('uncoordinated active-block switch closes on the next microtask',
      () async {
    final document = _documents(<String>['a', 'b']);
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(0, 1)),
    );
    final session = HomericTextInputSession(controller: controller);
    session.attach(blockId: 'a');
    calls.clear();

    controller.setSelection(
      HomericSelection.collapsed(document.positionAt(1, 1)),
    );
    expect(session.isAttached, isTrue,
        reason: 'a document coordinator may retarget synchronously');
    await Future<void>.delayed(Duration.zero);

    expect(session.isAttached, isFalse);
    expect(
      calls.where((call) => call.method == 'TextInput.clearClient'),
      hasLength(1),
    );
    session.dispose();
    controller.dispose();
  });

  test('stale old value and newline are corrected exactly once', () async {
    final document = _document('ab');
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(0, 1)),
    );
    final session = HomericTextInputSession(controller: controller);
    session.attach(blockId: 'a');

    calls.clear();
    await _sendDeltas(binding, 1, <Map<String, Object?>>[
      _delta(
        oldText: 'zz',
        deltaText: 'X',
        start: 1,
        end: 1,
        selectionBase: 2,
        selectionExtent: 2,
      ),
    ]);
    expect(controller.document.blocks.single.text, 'ab');
    expect(_editingStateCalls(calls), hasLength(1));

    calls.clear();
    await _sendDeltas(binding, 1, <Map<String, Object?>>[
      _delta(
        oldText: 'ab',
        deltaText: '\n',
        start: 1,
        end: 1,
        selectionBase: 2,
        selectionExtent: 2,
      ),
    ]);
    expect(controller.document.blocks.single.text, 'ab');
    expect(_editingStateCalls(calls), hasLength(1));
    expect(
        _editingStateCalls(calls).single.arguments, containsPair('text', 'ab'));

    session.dispose();
    controller.dispose();
  });

  test('controller-originated edit synchronizes once', () {
    final document = _document('ab');
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(0, 1)),
    );
    final session = HomericTextInputSession(controller: controller);
    session.attach(blockId: 'a');
    calls.clear();

    expect(controller.replaceSelection('X'), isTrue);

    expect(controller.document.blocks.single.text, 'aXb');
    expect(_editingStateCalls(calls), hasLength(1));
    expect(_editingStateCalls(calls).single.arguments,
        containsPair('text', 'aXb'));

    session.dispose();
    controller.dispose();
  });

  test('repeat attach reuses connection; blur and dispose close once', () {
    final document = _document('ab');
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(0, 1)),
    );
    final session = HomericTextInputSession(controller: controller);

    expect(session.attach(blockId: 'a'), isTrue);
    calls.clear();
    expect(session.attach(blockId: 'a'), isTrue);
    expect(calls, isEmpty);

    session.blur();
    session.blur();
    expect(
      calls.where((call) => call.method == 'TextInput.clearClient'),
      hasLength(1),
    );
    expect(session.isAttached, isFalse);

    calls.clear();
    expect(session.attach(blockId: 'a'), isTrue);
    calls.clear();
    session.dispose();
    session.dispose();
    expect(
      calls.where((call) => call.method == 'TextInput.clearClient'),
      hasLength(1),
    );
    controller.dispose();
  });

  test('superseded epoch and post-blur callbacks cannot mutate', () async {
    final document = _document('ab');
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(0, 1)),
    );
    final session = HomericTextInputSession(controller: controller);
    session.attach(blockId: 'a');
    final oldCallback = session.debugDeltaCallback!;
    expect(session.debugDeltaCallback, same(oldCallback));
    session.blur();
    session.attach(blockId: 'a');
    final currentCallback = session.debugDeltaCallback!;
    expect(currentCallback, isNot(same(oldCallback)));
    expect(session.debugDeltaCallback, same(currentCallback));
    calls.clear();

    oldCallback(<TextEditingDelta>[
      const TextEditingDeltaInsertion(
        oldText: 'ab',
        textInserted: 'X',
        insertionOffset: 1,
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange.empty,
      ),
    ]);
    expect(controller.document.blocks.single.text, 'ab');
    expect(_editingStateCalls(calls), hasLength(1));

    session.blur();
    calls.clear();
    await _sendDeltas(binding, 2, <Map<String, Object?>>[
      _delta(
        oldText: 'ab',
        deltaText: 'Y',
        start: 1,
        end: 1,
        selectionBase: 2,
        selectionExtent: 2,
      ),
    ]);
    expect(controller.document.blocks.single.text, 'ab');
    expect(_editingStateCalls(calls), isEmpty);

    session.dispose();
    calls.clear();
    oldCallback(<TextEditingDelta>[
      const TextEditingDeltaInsertion(
        oldText: 'ab',
        textInserted: 'Z',
        insertionOffset: 1,
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange.empty,
      ),
    ]);
    expect(controller.document.blocks.single.text, 'ab');
    expect(_editingStateCalls(calls), isEmpty);

    controller.dispose();
  });

  test('platform close finalizes composition and later callbacks are inert',
      () async {
    final document = _document('ab');
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(0, 1)),
    );
    final session = HomericTextInputSession(controller: controller);
    session.attach(blockId: 'a');

    await _sendDeltas(binding, 1, <Map<String, Object?>>[
      _delta(
        oldText: 'ab',
        deltaText: 'X',
        start: 1,
        end: 1,
        selectionBase: 2,
        selectionExtent: 2,
        composingBase: 1,
        composingExtent: 2,
      ),
    ]);
    expect(controller.composing, isNotNull);
    calls.clear();

    await _sendConnectionClosed(binding, 1);

    expect(session.isAttached, isFalse);
    expect(controller.document.blocks.single.text, 'aXb');
    expect(controller.composing, isNull);
    expect(
      calls.where((call) => call.method == 'TextInput.clearClient'),
      isEmpty,
    );

    calls.clear();
    await _sendDeltas(binding, 1, <Map<String, Object?>>[
      _delta(
        oldText: 'aXb',
        deltaText: 'Y',
        start: 2,
        end: 2,
        selectionBase: 3,
        selectionExtent: 3,
      ),
    ]);
    expect(controller.document.blocks.single.text, 'aXb');
    expect(_editingStateCalls(calls), isEmpty);

    session.dispose();
    controller.dispose();
  });

  test('post-dispose callback cannot mutate', () async {
    final document = _document('ab');
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(0, 1)),
    );
    final session = HomericTextInputSession(controller: controller);
    session.attach(blockId: 'a');
    session.dispose();
    calls.clear();

    await _sendDeltas(binding, 1, <Map<String, Object?>>[
      _delta(
        oldText: 'ab',
        deltaText: 'X',
        start: 1,
        end: 1,
        selectionBase: 2,
        selectionExtent: 2,
      ),
    ]);

    expect(controller.document, same(document));
    expect(_editingStateCalls(calls), isEmpty);
    controller.dispose();
  });

  test('perform action restores canonical state without structural intent',
      () async {
    final document = _document('ab');
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(0, 1)),
    );
    final session = HomericTextInputSession(controller: controller);
    session.attach(blockId: 'a');
    calls.clear();

    await _sendAction(binding, 1, 'TextInputAction.newline');

    expect(controller.document, same(document));
    expect(_editingStateCalls(calls), hasLength(1));
    expect(
        _editingStateCalls(calls).single.arguments, containsPair('text', 'ab'));

    session.dispose();
    controller.dispose();
  });

  test('geometry accepts only the current document and monotonic generation',
      () {
    final document = _document('ab');
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(0, 1)),
    );
    final session = HomericTextInputSession(controller: controller);
    final host = _FakeCommandDelegate();
    session.attach(blockId: 'a', commandDelegate: host);
    final geometryLease = session.geometryLeaseFor(
      blockId: 'a',
      owner: host,
    )!;
    calls.clear();

    expect(
      session.publishGeometry(
        lease: geometryLease,
        documentRevision: document,
        layoutGeneration: 5,
        editableSize: const Size(100, 20),
        transform: Matrix4.identity(),
        caretRect: const Rect.fromLTWH(10, 0, 1, 20),
        composingRect: const Rect.fromLTWH(5, 0, 20, 20),
      ),
      isTrue,
    );
    expect(
      calls.map((call) => call.method),
      containsAll(<String>[
        'TextInput.setEditableSizeAndTransform',
        'TextInput.setCaretRect',
        'TextInput.setMarkedTextRect',
      ]),
    );

    calls.clear();
    expect(
      session.publishGeometry(
        lease: geometryLease,
        documentRevision: document,
        layoutGeneration: 6,
        editableSize: const Size(100, 20),
        transform: Matrix4.identity(),
        caretRect: const Rect.fromLTWH(10, 0, 1, 20),
      ),
      isTrue,
    );
    final clearedComposingRect = calls.singleWhere(
      (call) => call.method == 'TextInput.setMarkedTextRect',
    );
    expect(
      clearedComposingRect.arguments,
      <String, double>{'width': 0, 'height': 0, 'x': 0, 'y': 0},
    );

    expect(controller.replaceSelection('X'), isTrue);
    calls.clear();
    expect(
      session.publishGeometry(
        lease: geometryLease,
        documentRevision: document,
        layoutGeneration: 6,
        editableSize: const Size(100, 20),
        transform: Matrix4.identity(),
        caretRect: const Rect.fromLTWH(20, 0, 1, 20),
      ),
      isFalse,
    );
    expect(calls, isEmpty);

    expect(
      session.publishGeometry(
        lease: geometryLease,
        documentRevision: controller.document,
        layoutGeneration: 4,
        editableSize: const Size(100, 20),
        transform: Matrix4.identity(),
        caretRect: const Rect.fromLTWH(20, 0, 1, 20),
      ),
      isFalse,
    );
    expect(calls, isEmpty);

    session.dispose();
    controller.dispose();
  });

  test('delta replacement never splits a surrogate pair', () async {
    final document = _document('a😀');
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(0, 3)),
    );
    final session = HomericTextInputSession(controller: controller);
    session.attach(blockId: 'a');
    calls.clear();

    await _sendDeltas(binding, 1, <Map<String, Object?>>[
      _delta(
        oldText: 'a😀',
        deltaText: '😁',
        start: 1,
        end: 3,
        selectionBase: 3,
        selectionExtent: 3,
      ),
    ]);

    expect(controller.document.blocks.single.text, 'a😁');
    expect(controller.document.blocks.single.text.runes, <int>[0x61, 0x1F601]);
    session.dispose();
    controller.dispose();
  });

  test('ownerless attachment cannot publish ambiguous platform geometry', () {
    final document = _document('ab');
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(0, 1)),
    );
    final session = HomericTextInputSession(controller: controller);
    expect(session.attach(blockId: 'a'), isTrue);
    expect(
      session.geometryLeaseFor(blockId: 'a', owner: Object()),
      isNull,
    );

    final geometryOwner = Object();
    expect(
      session.attach(blockId: 'a', geometryOwner: geometryOwner),
      isTrue,
    );
    final lease = session.geometryLeaseFor(
      blockId: 'a',
      owner: geometryOwner,
    );
    expect(lease, isNotNull);
    calls.clear();
    expect(
      session.publishGeometry(
        lease: lease!,
        documentRevision: document,
        layoutGeneration: 1,
        editableSize: const Size(100, 20),
        transform: Matrix4.identity(),
        caretRect: const Rect.fromLTWH(10, 0, 1, 20),
      ),
      isTrue,
    );

    session.dispose();
    controller.dispose();
  });

  test('geometry is bound to the exact active block and host capability', () {
    final document = _documents(<String>['alpha', 'beta']);
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(0, 1)),
    );
    final session = HomericTextInputSession(controller: controller);
    final firstHost = _FakeCommandDelegate();
    final replacementHost = _FakeCommandDelegate();
    final secondHost = _FakeCommandDelegate();
    expect(
      session.attach(blockId: 'a', commandDelegate: firstHost),
      isTrue,
    );
    final firstLease = session.geometryLeaseFor(
      blockId: 'a',
      owner: firstHost,
    )!;
    calls.clear();

    controller.setSelection(
      HomericSelection.collapsed(controller.document.positionAt(1, 1)),
    );
    calls.clear();
    expect(
      session.publishGeometry(
        lease: firstLease,
        documentRevision: controller.document,
        layoutGeneration: 19,
        editableSize: const Size(100, 20),
        transform: Matrix4.identity(),
        caretRect: const Rect.fromLTWH(5, 0, 1, 20),
      ),
      isFalse,
      reason: 'controller focus moved before the session retarget completed',
    );
    expect(calls, isEmpty);
    expect(
      session.retarget(blockId: 'b', commandDelegate: secondHost),
      isTrue,
    );
    final secondLease = session.geometryLeaseFor(
      blockId: 'b',
      owner: secondHost,
    )!;
    expect(
      session.geometryLeaseFor(blockId: 'a', owner: firstHost),
      isNull,
    );
    expect(secondLease, isNot(same(firstLease)));
    calls.clear();

    expect(
      session.publishGeometry(
        lease: firstLease,
        documentRevision: controller.document,
        layoutGeneration: 20,
        editableSize: const Size(100, 20),
        transform: Matrix4.identity(),
        caretRect: const Rect.fromLTWH(10, 0, 1, 20),
      ),
      isFalse,
      reason: 'a recycled prior row cannot position the current IME',
    );
    expect(calls, isEmpty);

    expect(
      session.retarget(blockId: 'b', commandDelegate: replacementHost),
      isTrue,
    );
    final replacementLease = session.geometryLeaseFor(
      blockId: 'b',
      owner: replacementHost,
    )!;
    expect(
      session.geometryLeaseFor(blockId: 'b', owner: secondHost),
      isNull,
    );
    expect(replacementLease, isNot(same(secondLease)));
    calls.clear();
    expect(
      session.publishGeometry(
        lease: firstLease,
        documentRevision: controller.document,
        layoutGeneration: 21,
        editableSize: const Size(100, 20),
        transform: Matrix4.identity(),
        caretRect: const Rect.fromLTWH(20, 0, 1, 20),
      ),
      isFalse,
      reason: 'a replaced same-block host cannot publish stale geometry',
    );
    expect(calls, isEmpty);

    expect(
      session.publishGeometry(
        lease: replacementLease,
        documentRevision: controller.document,
        layoutGeneration: 1,
        editableSize: const Size(100, 20),
        transform: Matrix4.identity(),
        caretRect: const Rect.fromLTWH(30, 0, 1, 20),
      ),
      isTrue,
    );
    expect(
      calls.map((call) => call.method),
      containsAll(<String>[
        'TextInput.setEditableSizeAndTransform',
        'TextInput.setCaretRect',
      ]),
    );

    session.dispose();
    controller.dispose();
  });
}

Document _document(String text) => Document(<Block>[
      Block(
        id: 'a',
        type: 'paragraph',
        runs: <InlineRun>[InlineRun(text)],
      ),
    ]);

Document _documents(List<String> texts) => Document(<Block>[
      for (var index = 0; index < texts.length; index++)
        Block(
          id: String.fromCharCode('a'.codeUnitAt(0) + index),
          type: 'paragraph',
          runs: <InlineRun>[InlineRun(texts[index])],
        ),
    ]);

Map<String, Object?> _delta({
  required String oldText,
  required String deltaText,
  required int start,
  required int end,
  required int selectionBase,
  required int selectionExtent,
  int composingBase = -1,
  int composingExtent = -1,
  bool selectionIsDirectional = false,
}) =>
    <String, Object?>{
      'oldText': oldText,
      'deltaText': deltaText,
      'deltaStart': start,
      'deltaEnd': end,
      'selectionBase': selectionBase,
      'selectionExtent': selectionExtent,
      'selectionAffinity': 'TextAffinity.downstream',
      'selectionIsDirectional': selectionIsDirectional,
      'composingBase': composingBase,
      'composingExtent': composingExtent,
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

Future<void> _sendAction(
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

Future<void> _sendConnectionClosed(
  TestWidgetsFlutterBinding binding,
  int clientId,
) async {
  final message = const JSONMessageCodec().encodeMessage(<String, Object?>{
    'method': 'TextInputClient.onConnectionClosed',
    'args': <Object?>[clientId],
  });
  await binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/textinput',
    message,
    (_) {},
  );
}

List<MethodCall> _editingStateCalls(List<MethodCall> calls) =>
    calls.where((call) => call.method == 'TextInput.setEditingState').toList();

final class _FakeCommandDelegate implements HomericTextInputCommandDelegate {
  final List<Intent> intents = <Intent>[];
  final List<RawFloatingCursorPoint> floatingCursorPoints =
      <RawFloatingCursorPoint>[];
  final List<TextRange> autocorrectionPromptRanges = <TextRange>[];
  int toolbarCount = 0;
  int transientCancelCount = 0;

  @override
  Object? invoke(Intent intent) {
    intents.add(intent);
    return null;
  }

  @override
  void showToolbar() => toolbarCount++;

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {
    floatingCursorPoints.add(point);
  }

  @override
  void showAutocorrectionPromptRect(TextRange range) {
    autocorrectionPromptRanges.add(range);
  }

  @override
  void cancelTransientInput() => transientCancelCount++;
}
