import 'package:flutter/services.dart';
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
      containsPair('inputAction', 'TextInputAction.none'),
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
    session.blur();
    session.attach(blockId: 'a');
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
    session.attach(blockId: 'a');
    calls.clear();

    expect(
      session.publishGeometry(
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

    expect(controller.replaceSelection('X'), isTrue);
    calls.clear();
    expect(
      session.publishGeometry(
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
