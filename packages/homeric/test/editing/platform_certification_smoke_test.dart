import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric/src/editing/editor_clipboard.dart'
    show HomericEditorClipboard;

/// CI-runnable smoke coverage paired with
/// `docs/testing/platform-certification.md`.
///
/// These tests document host-visible defaults and semantics contracts that
/// certification builds on. They do **not** claim real-device IME, touch, or
/// screen-reader runs.
void main() {
  test('paste policy default remains expandBlocks (Nexus-compatible)', () {
    final controller = HomericEditorController(
      document: Document([
        Block(id: 'b', type: 'paragraph', runs: [InlineRun('hi')]),
      ]),
      selection: const HomericSelection.collapsed(1),
    );
    final clipboard = HomericEditorClipboard(
      controller: controller,
      blockId: 'b',
      adapter: _EmptyClipboard(),
      isHostCurrent: () => true,
    );
    addTearDown(clipboard.dispose);
    addTearDown(controller.dispose);
    expect(clipboard.pastePolicy, HomericPastePolicy.expandBlocks);
  });

  testWidgets(
    'editable paragraph mounts for accessibility host wiring',
    (tester) async {
      final controller = HomericEditorController(
        document: Document([
          Block(id: 'b', type: 'paragraph', runs: [InlineRun('Accessible')]),
        ]),
        selection: const HomericSelection.collapsed(1),
      );
      final session = HomericTextInputSession(controller: controller);
      addTearDown(session.dispose);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomericEditableParagraph(
              controller: controller,
              inputSession: session,
              blockId: 'b',
              resolveStyle: (_) => const TextStyle(fontSize: 16),
              baseStyle: const TextStyle(fontSize: 16),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(HomericEditableParagraph), findsOneWidget);
      // Paragraph paints through a custom render object; presence of the
      // public host is the CI-runnable accessibility wiring smoke signal.
      expect(tester.takeException(), isNull);
    },
  );

  test('codec v1 remains available for host persistence certification', () {
    final document = HomericDocumentCodec.decodeJson(
      '{"v":1,"blocks":[{"id":"b","type":"paragraph","attributes":{},'
      '"runs":[{"text":"ok","attributes":{}}]}]}',
    );
    expect(document.blocks.single.text, 'ok');
    expect(HomericDocumentCodec.encode(document)['v'], 1);
  });
}

final class _EmptyClipboard implements HomericClipboardAdapter {
  @override
  Future<String?> readText() async => null;

  @override
  Future<void> writeText(String text) async {}
}
