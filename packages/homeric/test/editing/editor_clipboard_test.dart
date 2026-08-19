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

  test('paste rejects multiline atomically and reports a typed event',
      () async {
    for (final value in <String>['a\nb', 'a\rb', 'a\r\nb']) {
      final events = <HomericHostEvent>[];
      final controller = HomericEditorController(
        document: _document('abcd'),
        selection: const HomericSelection(anchor: 2, head: 4),
      );
      var notifications = 0;
      controller.addListener(() => notifications++);
      final clipboard = HomericEditorClipboard(
        controller: controller,
        blockId: 'b',
        adapter: _FakeClipboard(readValue: value),
        isHostCurrent: () => true,
        onEvent: events.add,
      );

      await clipboard.paste();

      expect(controller.document.blocks.single.text, 'abcd');
      expect(controller.selection, const HomericSelection(anchor: 2, head: 4));
      expect(controller.canUndo, isFalse);
      expect(notifications, 0);
      expect(events.single, isA<HomericPasteRejected>());
      clipboard.dispose();
      controller.dispose();
    }
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
