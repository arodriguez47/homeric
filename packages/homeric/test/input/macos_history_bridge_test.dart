import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('homericIntentForMacOSSelector maps undo:/redo: to standard intents',
      () {
    expect(
      homericIntentForMacOSSelector('undo:'),
      isA<UndoTextIntent>(),
    );
    expect(
      homericIntentForMacOSSelector('redo:'),
      isA<RedoTextIntent>(),
    );
    expect(
      homericIntentForMacOSSelector('deleteBackward:'),
      isA<DeleteCharacterIntent>(),
    );
    expect(homericIntentForMacOSSelector('not-a-selector:'), isNull);
  });

  test('HomericMacOSHistoryBridge publishes enablement and routes menu undo',
      () async {
    final controller = HomericEditorController(
      document: Document([
        Block(id: 'b', type: 'paragraph', runs: [InlineRun('ab')]),
      ]),
    );
    final end = controller.globalPositionForBlockOffset('b', 2);
    controller.setSelection(HomericSelection.collapsed(end));
    final session = HomericTextInputSession(controller: controller);
    final calls = <MethodCall>[];
    const channel = MethodChannel(kHomericMacOSHistoryChannel);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    final bridge = HomericMacOSHistoryBridge(
      controller: controller,
      session: session,
      channel: channel,
    );
    bridge.attach();
    addTearDown(bridge.detach);
    await pumpEventQueue();
    expect(bridge.debugPublishedCanUndo, isFalse);
    expect(
      calls.where((call) => call.method == 'setUndoState'),
      isNotEmpty,
    );

    final liveDelegate = _RecordingDelegate(controller);
    expect(
      session.attach(blockId: 'b', commandDelegate: liveDelegate),
      isTrue,
    );
    expect(controller.replaceSelection('x'), isTrue);
    await pumpEventQueue();
    expect(controller.document.blocks.single.text, 'abx');
    expect(bridge.debugPublishedCanUndo, isTrue);
    expect(bridge.debugPublishedCanRedo, isFalse);

    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      kHomericMacOSHistoryChannel,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('undo'),
      ),
      (_) {},
    );
    await pumpEventQueue();
    expect(controller.document.blocks.single.text, 'ab');
    expect(liveDelegate.intents, hasLength(1));
    expect(liveDelegate.intents.single, isA<UndoTextIntent>());
    expect(bridge.debugPublishedCanRedo, isTrue);
  });

  test('HomericMacOSHistoryBridge menu undo is inert without a live host',
      () async {
    final controller = HomericEditorController(
      document: Document([
        Block(id: 'b', type: 'paragraph', runs: [InlineRun('ab')]),
      ]),
    );
    final end = controller.globalPositionForBlockOffset('b', 2);
    controller.setSelection(HomericSelection.collapsed(end));
    final session = HomericTextInputSession(controller: controller);
    const channel = MethodChannel(kHomericMacOSHistoryChannel);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    addTearDown(session.dispose);
    addTearDown(controller.dispose);

    expect(controller.replaceSelection('x'), isTrue);
    expect(controller.document.blocks.single.text, 'abx');
    final bridge = HomericMacOSHistoryBridge(
      controller: controller,
      session: session,
      channel: channel,
    );
    bridge.attach();
    addTearDown(bridge.detach);

    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      kHomericMacOSHistoryChannel,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('undo'),
      ),
      (_) {},
    );
    await pumpEventQueue();
    expect(controller.document.blocks.single.text, 'abx',
        reason: 'menu undo without an attached host must not mutate');
  });
}

final class _RecordingDelegate implements HomericTextInputCommandDelegate {
  _RecordingDelegate(this.controller);

  final HomericEditorController controller;
  final List<Intent> intents = <Intent>[];

  @override
  Object? invoke(Intent intent) {
    intents.add(intent);
    if (intent is UndoTextIntent) return controller.undo();
    if (intent is RedoTextIntent) return controller.redo();
    return null;
  }

  @override
  void showToolbar() {}

  @override
  void showAutocorrectionPromptRect(TextRange range) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void cancelTransientInput() {}
}
