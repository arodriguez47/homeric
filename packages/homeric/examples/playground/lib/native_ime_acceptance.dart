import 'dart:convert';

import 'package:flutter/material.dart' hide Decoration;
import 'package:homeric/homeric.dart';

void main() => runApp(const _NativeImeAcceptanceApp());

class _NativeImeAcceptanceApp extends StatefulWidget {
  const _NativeImeAcceptanceApp();

  @override
  State<_NativeImeAcceptanceApp> createState() =>
      _NativeImeAcceptanceAppState();
}

class _NativeImeAcceptanceAppState extends State<_NativeImeAcceptanceApp> {
  static const _stages = <({
    String instruction,
    String expected,
    bool canUndo,
    bool canRedo,
  })>[
    (
      instruction: 'Type Z',
      expected: 'alphaZ',
      canUndo: true,
      canRedo: false,
    ),
    (
      instruction: 'Press Command-Z',
      expected: 'alpha',
      canUndo: false,
      canRedo: true,
    ),
    (
      instruction: 'Press Command-Shift-Z',
      expected: 'alphaZ',
      canUndo: true,
      canRedo: false,
    ),
    (
      instruction: 'Press Option-E, then E',
      expected: 'alphaZé',
      canUndo: true,
      canRedo: false,
    ),
    (
      instruction: 'Press Command-Z',
      expected: 'alphaZ',
      canUndo: true,
      canRedo: true,
    ),
  ];

  final _documentKey = GlobalKey<HomericEditableDocumentState>();
  late final HomericEditorController _controller;
  late final HomericTextInputSession _inputSession;
  var _stage = 0;
  var _failed = false;

  @override
  void initState() {
    super.initState();
    final document = Document(<Block>[
      Block(
        id: 'native-ime',
        type: 'paragraph',
        runs: <InlineRun>[InlineRun('alpha')],
      ),
    ]);
    _controller = HomericEditorController(document: document)
      ..setSelection(
        HomericSelection.collapsed(document.positionAt(0, 5)),
      )
      ..addListener(_reportState);
    _inputSession = HomericTextInputSession(controller: _controller);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final result = await _documentKey.currentState?.settleFocusOnBlock(
        'native-ime',
      );
      if (result != HomericFocusSettlementResult.focused ||
          !_inputSession.isAttached ||
          _inputSession.activeBlockId != 'native-ime') {
        _failed = true;
        debugPrint(
          'HOMERIC_NATIVE_IME_COMPLETE result=fail '
          'reason=focus_not_ready focus=${result?.name}',
        );
        if (mounted) setState(() {});
        return;
      }
      debugPrint(
        'HOMERIC_NATIVE_IME_READY '
        'focus=${result?.name} stage=$_stage '
        'expected=${_stages[_stage].expected}',
      );
      _reportState();
    });
  }

  @override
  void dispose() {
    _inputSession.dispose();
    _controller
      ..removeListener(_reportState)
      ..dispose();
    super.dispose();
  }

  void _reportState() {
    final text = _controller.document.blockById('native-ime')!.text;
    final expected = _stage < _stages.length ? _stages[_stage] : null;
    if (!_failed &&
        expected != null &&
        text == expected.expected &&
        _controller.canUndo == expected.canUndo &&
        _controller.canRedo == expected.canRedo) {
      debugPrint(
        'HOMERIC_NATIVE_IME_PASS stage=$_stage '
        'text=${jsonEncode(text)} '
        'canUndo=${_controller.canUndo} canRedo=${_controller.canRedo}',
      );
      _stage += 1;
      if (_stage == _stages.length) {
        debugPrint('HOMERIC_NATIVE_IME_COMPLETE result=pass');
      } else {
        debugPrint(
          'HOMERIC_NATIVE_IME_READY stage=$_stage '
          'expected=${_stages[_stage].expected}',
        );
      }
    }
    final selection = _controller.selection;
    final composing = _controller.composing;
    final payload = <String, Object?>{
      'text': text,
      'selection': selection == null
          ? null
          : <String, Object>{
              'anchor': selection.anchor,
              'head': selection.head,
            },
      'composing': composing == null
          ? null
          : <String, Object>{
              'start': composing.start,
              'end': composing.end,
            },
      'canUndo': _controller.canUndo,
      'canRedo': _controller.canRedo,
      'activeBlockId': _controller.activeBlockId,
      'inputBlockId': _inputSession.activeBlockId,
      'inputAttached': _inputSession.isAttached,
      'stateRevision': _controller.stateRevision,
      'stage': _stage,
    };
    debugPrint('HOMERIC_NATIVE_IME_STATE ${jsonEncode(payload)}');
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final text = _controller.document.blockById('native-ime')!.text;
    final complete = _stage == _stages.length;
    final instruction = _failed
        ? 'Acceptance could not acquire the focused native input owner.'
        : complete
            ? 'Acceptance sequence complete.'
            : '${_stage + 1}/${_stages.length}: '
                '${_stages[_stage].instruction}.';
    return MaterialApp(
      title: 'Homeric native IME acceptance',
      home: Scaffold(
        appBar: AppBar(title: const Text('Native IME acceptance')),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '$instruction\n'
                'Canonical text: $text',
                key: const ValueKey('native-ime-status'),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: HomericEditableDocument.builder(
                key: _documentKey,
                controller: _controller,
                inputSession: _inputSession,
                padding: const EdgeInsets.all(24),
                blockBuilder: (context, block, focusNode) =>
                    HomericEditableParagraph(
                  controller: _controller,
                  inputSession: _inputSession,
                  blockId: block.id,
                  focusNode: focusNode,
                  baseStyle: const TextStyle(fontSize: 24, height: 1.5),
                  resolveStyle: (_) =>
                      const TextStyle(fontSize: 24, height: 1.5),
                  caretColor: Colors.blue,
                  selectionColor: const Color(0x554F64C8),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
