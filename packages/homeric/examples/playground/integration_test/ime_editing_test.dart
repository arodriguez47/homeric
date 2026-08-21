import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric_playground/main.dart';
import 'package:homeric_playground/view_models/document_view_model.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('platform delta composition survives connection loss once',
      (tester) async {
    final document = Document(<Block>[
      Block(
        id: 'ime',
        type: 'paragraph',
        runs: <InlineRun>[InlineRun('alpha')],
      ),
      Block(
        id: 'other',
        type: 'paragraph',
        runs: <InlineRun>[InlineRun('second paragraph')],
      ),
    ]);
    final viewModel = DocumentViewModel(document: document);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      viewModel.dispose();
    });

    await tester.pumpWidget(PlaygroundApp(viewModel: viewModel));
    await tester.pumpAndSettle();

    final controller = viewModel.editorController;
    final session = viewModel.inputSession;
    final documentHost = tester.state<HomericEditableDocumentState>(
      find.byType(HomericEditableDocument),
    );
    expect(
      controller.setSelection(
        HomericSelection.collapsed(document.positionAt(0, 5)),
      ),
      true,
    );
    expect(
      await documentHost.settleFocusOnBlock('ime'),
      HomericFocusSettlementResult.focused,
    );
    await tester.pump();
    expect(session.activeBlockId, 'ime');

    await _sendPlatformDeltas(tester, <Map<String, Object>>[
      _delta(
        oldText: 'alpha',
        start: 5,
        end: 5,
        text: 'e',
        selection: 6,
        composingStart: 5,
        composingEnd: 6,
      ),
    ]);
    await tester.pump();
    expect(controller.document.blockById('ime')!.text, 'alphae');
    expect(
      controller.composing,
      HomericTextRange(
        controller.document.positionAt(0, 5),
        controller.document.positionAt(0, 6),
      ),
    );
    expect(controller.canUndo, false,
        reason: 'an open composition is not a committed history unit');

    await _sendPlatformDeltas(tester, <Map<String, Object>>[
      _delta(
        oldText: 'alphae',
        start: 5,
        end: 6,
        text: 'é',
        selection: 6,
      ),
    ]);
    await tester.pump();
    expect(controller.document.blockById('ime')!.text, 'alphaé');
    expect(controller.composing, isNull);
    expect(controller.canUndo, true);
    expect(controller.undo(), true);
    expect(controller.document.blockById('ime')!.text, 'alpha');
    expect(controller.undo(), false,
        reason: 'the composing sequence commits as one history unit');
    expect(controller.redo(), true);
    expect(controller.document.blockById('ime')!.text, 'alphaé');

    await _sendPlatformDeltas(tester, <Map<String, Object>>[
      _delta(
        oldText: 'alphaé',
        start: 6,
        end: 6,
        text: 'n',
        selection: 7,
        composingStart: 6,
        composingEnd: 7,
      ),
    ]);
    await tester.pump();
    final staleDelta = session.debugDeltaCallback;
    expect(staleDelta, isNotNull);
    expect(controller.document.blockById('ime')!.text, 'alphaén');
    expect(
      controller.composing,
      HomericTextRange(
        controller.document.positionAt(0, 6),
        controller.document.positionAt(0, 7),
      ),
    );

    await _sendPlatformMethod(
      tester,
      const MethodCall(
        'TextInputClient.onConnectionClosed',
        <Object>[-1],
      ),
    );
    await tester.pump();
    expect(session.isAttached, true,
        reason: 'the still-focused host opens one fresh input epoch');
    expect(session.debugDeltaCallback, isNot(same(staleDelta)));
    expect(controller.composing, isNull);
    expect(controller.document.blockById('ime')!.text, 'alphaén');

    final currentDelta = session.debugDeltaCallback;
    final beforeStaleDocument = controller.document;
    final beforeStaleSelection = controller.selection;
    final beforeStaleComposing = controller.composing;
    final beforeStaleStateRevision = controller.stateRevision;
    final beforeStaleActiveBlockId = controller.activeBlockId;
    final beforeStaleCanUndo = controller.canUndo;
    final beforeStaleCanRedo = controller.canRedo;

    staleDelta!(<TextEditingDelta>[
      const TextEditingDeltaInsertion(
        oldText: 'alphaén',
        textInserted: 'x',
        insertionOffset: 7,
        selection: TextSelection.collapsed(offset: 8),
        composing: TextRange.empty,
      ),
    ]);
    await tester.pump();
    expect(controller.document, same(beforeStaleDocument));
    expect(controller.selection, beforeStaleSelection);
    expect(controller.composing, beforeStaleComposing);
    expect(controller.stateRevision, beforeStaleStateRevision);
    expect(controller.activeBlockId, beforeStaleActiveBlockId);
    expect(controller.canUndo, beforeStaleCanUndo);
    expect(controller.canRedo, beforeStaleCanRedo);
    expect(session.isAttached, true);
    expect(session.debugDeltaCallback, same(currentDelta),
        reason: 'the retired callback cannot disturb the current epoch');

    expect(controller.undo(), true);
    expect(controller.document.blockById('ime')!.text, 'alphaé',
        reason: 'connection loss commits visible composition exactly once');
    expect(controller.undo(), true);
    expect(controller.document.blockById('ime')!.text, 'alpha');
    expect(controller.undo(), false);
    expect(controller.redo(), true);
    expect(controller.document.blockById('ime')!.text, 'alphaé');
    expect(controller.redo(), true);
    expect(controller.document.blockById('ime')!.text, 'alphaén');
    expect(controller.redo(), false);
    expect(controller.undo(), true);
    expect(controller.document.blockById('ime')!.text, 'alphaé');

    final breakSelection =
        HomericSelection.collapsed(controller.document.positionAt(0, 6));
    controller.setSelection(breakSelection);
    expect(controller.selection, breakSelection);
    await tester.pump();
    final beforeBreak = controller.document;
    final beforeBreakSelection = controller.selection;
    expect(controller.canRedo, true,
        reason: 'the connection-loss composition remains redoable');
    await _sendPlatformMethod(
      tester,
      const MethodCall(
        'TextInputClient.performAction',
        <Object>[-1, 'TextInputAction.newline'],
      ),
    );
    expect(controller.canRedo, false,
        reason: 'the new structural mutation clears the old redo branch');
    expect(
      controller.document.blocks.map((block) => block.text),
      <String>['alphaé', '', 'second paragraph'],
    );
    final afterBreak = controller.document;
    final afterBreakSelection = controller.selection;
    final trailingBlockId = controller.document.blocks[1].id;
    expect(controller.activeBlockId, trailingBlockId);
    await tester.pump();
    await tester.pump();
    expect(session.activeBlockId, trailingBlockId,
        reason: 'the mounted document retargets input to the split block');
    expect(documentHost.focusedBlockId, trailingBlockId);
    session.debugDeltaCallback!(<TextEditingDelta>[
      const TextEditingDeltaInsertion(
        oldText: '',
        textInserted: 'X',
        insertionOffset: 0,
        selection: TextSelection.collapsed(offset: 1),
        composing: TextRange.empty,
      ),
    ]);
    expect(controller.document.blockById(trailingBlockId)!.text, 'X');
    expect(controller.document.blockById('ime')!.text, 'alphaé');
    final afterRetargetedDelta = controller.document;

    expect(controller.undo(), true);
    expect(controller.document, same(afterBreak));
    expect(controller.selection, afterBreakSelection);
    expect(controller.undo(), true);
    expect(controller.document, same(beforeBreak));
    expect(controller.selection, beforeBreakSelection);
    expect(controller.undo(), true);
    expect(controller.document.blockById('ime')!.text, 'alpha');
    expect(controller.undo(), false);
    expect(controller.redo(), true);
    expect(controller.document.blockById('ime')!.text, 'alphaé');
    expect(controller.redo(), true);
    expect(controller.document, same(afterBreak));
    expect(controller.redo(), true);
    expect(controller.document, same(afterRetargetedDelta));
    expect(controller.redo(), false);

    binding.reportData ??= <String, dynamic>{};
    binding.reportData!['homeric_ime'] = <String, Object>{
      'actual_platform': defaultTargetPlatform.name,
      'synthetic_framework_adapter': true,
      'composition_history': 'one_unit',
      'connection_loss': 'committed_once_and_fresh_epoch_attached',
      'newline_action': 'split_retargeted_one_history_unit',
    };
  });
}

Map<String, Object> _delta({
  required String oldText,
  required int start,
  required int end,
  required String text,
  required int selection,
  int composingStart = -1,
  int composingEnd = -1,
}) =>
    <String, Object>{
      'oldText': oldText,
      'deltaStart': start,
      'deltaEnd': end,
      'deltaText': text,
      'selectionBase': selection,
      'selectionExtent': selection,
      'selectionAffinity': 'TextAffinity.downstream',
      'selectionIsDirectional': false,
      'composingBase': composingStart,
      'composingExtent': composingEnd,
    };

Future<void> _sendPlatformDeltas(
  WidgetTester tester,
  List<Map<String, Object>> deltas,
) =>
    _sendPlatformMethod(
      tester,
      MethodCall(
        'TextInputClient.updateEditingStateWithDeltas',
        <Object>[
          -1,
          <String, Object>{'deltas': deltas},
        ],
      ),
    );

Future<void> _sendPlatformMethod(
  WidgetTester tester,
  MethodCall method,
) async {
  final response = Completer<void>();
  tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.textInput.name,
    SystemChannels.textInput.codec.encodeMethodCall(method),
    (_) => response.complete(),
  );
  await response.future;
}
