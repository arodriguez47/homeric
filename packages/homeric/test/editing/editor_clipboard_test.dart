import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric/src/editing/editor_clipboard.dart'
    show HomericEditorClipboard;

void main() {
  test('cut writes visible projection then deletes the canonical selection',
      () async {
    final document = _document('**bold**');
    final controller = HomericEditorController(
      document: document,
      selection: const HomericSelection(anchor: 1, head: 9),
      decorations: DecorationSet.of(<Decoration>[
        Decoration.replace('b', 0, 2, replacementLength: 0),
        Decoration.replace('b', 6, 8, replacementLength: 0),
      ]),
    );
    final adapter = _FakeClipboard();
    final clipboard = HomericEditorClipboard(
      controller: controller,
      blockId: 'b',
      adapter: adapter,
      isHostCurrent: () => true,
    );
    addTearDown(clipboard.dispose);
    addTearDown(controller.dispose);

    await clipboard.cut();

    expect(adapter.writes, <String>['bold']);
    expect(controller.document.blocks.single.text, '');
    expect(controller.selection, const HomericSelection.collapsed(1));
    expect(controller.canUndo, isTrue);
  });

  test('copy preserves reverse selection and exports only projected text',
      () async {
    final controller = HomericEditorController(
      document: _document('**bold**'),
      selection: const HomericSelection(anchor: 9, head: 1),
      decorations: DecorationSet.of(<Decoration>[
        Decoration.replace('b', 0, 2, replacementLength: 0),
        Decoration.replace('b', 6, 8, replacementLength: 0),
      ]),
    );
    final adapter = _FakeClipboard();
    final clipboard = HomericEditorClipboard(
      controller: controller,
      blockId: 'b',
      adapter: adapter,
      isHostCurrent: () => true,
    );
    addTearDown(clipboard.dispose);
    addTearDown(controller.dispose);

    await clipboard.copy();

    expect(adapter.writes, <String>['bold']);
    expect(controller.document.blocks.single.text, '**bold**');
    expect(controller.selection, const HomericSelection(anchor: 9, head: 1));
    expect(controller.canUndo, isFalse);
  });

  test('failed and stale cuts never delete', () async {
    final events = <HomericHostEvent>[];
    final controller = HomericEditorController(
      document: _document('abcd'),
      selection: const HomericSelection(anchor: 2, head: 4),
    );
    final adapter = _FakeClipboard();
    final clipboard = HomericEditorClipboard(
      controller: controller,
      blockId: 'b',
      adapter: adapter,
      isHostCurrent: () => true,
      onEvent: events.add,
    );
    addTearDown(clipboard.dispose);
    addTearDown(controller.dispose);

    adapter.writeError = StateError('denied');
    await clipboard.cut();
    expect(controller.document.blocks.single.text, 'abcd');
    expect(events.single, isA<HomericClipboardFailure>());

    adapter.writeError = null;
    adapter.pendingWrite = Completer<void>();
    final pending = clipboard.cut();
    controller.setSelection(const HomericSelection(anchor: 1, head: 3));
    adapter.pendingWrite!.complete();
    await pending;
    expect(controller.document.blocks.single.text, 'abcd');
    expect(controller.canUndo, isFalse);
  });

  test('multiline paste reaches one structural controller transaction',
      () async {
    final controller = HomericEditorController(
      document: _document('abcd'),
      selection: const HomericSelection(anchor: 2, head: 4),
    );
    var notifications = 0;
    controller.addListener(() => notifications++);
    final clipboard = HomericEditorClipboard(
      controller: controller,
      blockId: 'b',
      adapter: _FakeClipboard(readValue: 'X\r\n\rY'),
      isHostCurrent: () => true,
    );

    await clipboard.paste();

    expect(controller.document.blocks.map((block) => block.text),
        <String>['aX', '', 'Yd']);
    expect(notifications, 1);
    expect(controller.canUndo, isTrue);
    expect(controller.undo(), isTrue);
    expect(controller.document.blocks.single.text, 'abcd');
    clipboard.dispose();
    controller.dispose();
  });

  test('cross-block copy projects visible slices and empty separators',
      () async {
    final document = _documents(<String>['**one**', '', '__three__']);
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection(
        anchor: document.positionAt(2, 9),
        head: document.positionAt(0, 0),
      ),
      decorations: DecorationSet.of(<Decoration>[
        Decoration.replace('a', 0, 2, replacementLength: 0),
        Decoration.replace('a', 5, 7, replacementLength: 0),
        Decoration.replace('c', 0, 2, replacementLength: 0),
        Decoration.replace('c', 7, 9, replacementLength: 0),
      ]),
    );
    final adapter = _FakeClipboard();
    final clipboard = HomericEditorClipboard(
      controller: controller,
      blockId: 'a',
      adapter: adapter,
      isHostCurrent: () => true,
    );

    await clipboard.copy();

    expect(adapter.writes, <String>['one\n\nthree']);
    expect(controller.document, same(document));
    clipboard.dispose();
    controller.dispose();
  });

  test('null and empty paste are no-ops while adapter failure is typed',
      () async {
    final events = <HomericHostEvent>[];
    final controller = HomericEditorController(
      document: _document('abcd'),
      selection: const HomericSelection.collapsed(3),
    );
    final adapter = _FakeClipboard();
    final clipboard = HomericEditorClipboard(
      controller: controller,
      blockId: 'b',
      adapter: adapter,
      isHostCurrent: () => true,
      onEvent: events.add,
    );
    addTearDown(clipboard.dispose);
    addTearDown(controller.dispose);

    await clipboard.paste();
    adapter.readValue = '';
    await clipboard.paste();
    adapter.readError = StateError('unavailable');
    await clipboard.paste();

    expect(controller.document.blocks.single.text, 'abcd');
    expect(controller.canUndo, isFalse);
    expect(events.single, isA<HomericClipboardFailure>());
  });

  test('overlapping paste and mutation-undo ABA completions are inert',
      () async {
    final controller = HomericEditorController(
      document: _document('ab'),
      selection: const HomericSelection.collapsed(2),
    );
    final adapter = _FakeClipboard();
    final clipboard = HomericEditorClipboard(
      controller: controller,
      blockId: 'b',
      adapter: adapter,
      isHostCurrent: () => true,
    );
    addTearDown(clipboard.dispose);
    addTearDown(controller.dispose);

    final older = Completer<String?>();
    final newer = Completer<String?>();
    adapter.pendingReads.addAll(<Completer<String?>>[older, newer]);
    final first = clipboard.paste();
    final second = clipboard.paste();
    newer.complete('2');
    await second;
    older.complete('1');
    await first;
    expect(controller.document.blocks.single.text, 'a2b');

    final aba = Completer<String?>();
    adapter.pendingReads.add(aba);
    final pending = clipboard.paste();
    controller.replaceSelection('x');
    controller.undo();
    aba.complete('stale');
    await pending;
    expect(controller.document.blocks.single.text, 'a2b');
  });

  test('blur, host replacement, and disposal invalidate pending work',
      () async {
    final controller = HomericEditorController(
      document: _document('ab'),
      selection: const HomericSelection.collapsed(2),
    );
    final adapter = _FakeClipboard();
    var focused = true;
    final blurredHost = HomericEditorClipboard(
      controller: controller,
      blockId: 'b',
      adapter: adapter,
      isHostCurrent: () => focused,
    );
    addTearDown(controller.dispose);

    final blurRead = Completer<String?>();
    adapter.pendingReads.add(blurRead);
    final blurredPaste = blurredHost.paste();
    focused = false;
    blurRead.complete('blurred');
    await blurredPaste;
    expect(controller.document.blocks.single.text, 'ab');
    blurredHost.dispose();

    var hostEpoch = 1;
    final replacedHost = HomericEditorClipboard(
      controller: controller,
      blockId: 'b',
      adapter: adapter,
      isHostCurrent: () => hostEpoch == 1,
    );
    final replacementRead = Completer<String?>();
    adapter.pendingReads.add(replacementRead);
    final replacedPaste = replacedHost.paste();
    hostEpoch = 2;
    replacementRead.complete('replaced');
    await replacedPaste;
    expect(controller.document.blocks.single.text, 'ab');
    replacedHost.dispose();

    final disposedHost = HomericEditorClipboard(
      controller: controller,
      blockId: 'b',
      adapter: adapter,
      isHostCurrent: () => true,
    );
    final disposalRead = Completer<String?>();
    adapter.pendingReads.add(disposalRead);
    final disposedPaste = disposedHost.paste();
    disposedHost.dispose();
    disposalRead.complete('disposed');
    await disposedPaste;
    expect(controller.document.blocks.single.text, 'ab');
  });
}

Document _document(String text) => Document(<Block>[
      Block(
        id: 'b',
        type: 'paragraph',
        runs: <InlineRun>[if (text.isNotEmpty) InlineRun(text)],
      ),
    ]);

Document _documents(List<String> texts) => Document(<Block>[
      for (var index = 0; index < texts.length; index++)
        Block(
          id: String.fromCharCode('a'.codeUnitAt(0) + index),
          type: 'paragraph',
          runs: <InlineRun>[
            if (texts[index].isNotEmpty) InlineRun(texts[index]),
          ],
        ),
    ]);

final class _FakeClipboard implements HomericClipboardAdapter {
  _FakeClipboard({this.readValue});

  String? readValue;
  Object? readError;
  Object? writeError;
  Completer<void>? pendingWrite;
  final List<Completer<String?>> pendingReads = <Completer<String?>>[];
  final List<String> writes = <String>[];

  @override
  Future<String?> readText() async {
    if (readError case final error?) throw error;
    if (pendingReads.isNotEmpty) return pendingReads.removeAt(0).future;
    return readValue;
  }

  @override
  Future<void> writeText(String text) async {
    writes.add(text);
    if (writeError case final error?) throw error;
    await pendingWrite?.future;
  }
}
