import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

void main() {
  group('HomericSelectionSnapshot', () {
    test('expanded selection exposes plainText and per-block spans', () {
      final document = Document([
        Block(id: 'a', type: 'paragraph', runs: [InlineRun('Hello')]),
        Block(id: 'b', type: 'paragraph', runs: [InlineRun('World')]),
      ]);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection(
          anchor: document.positionAt(0, 0),
          head: document.positionAt(1, 5),
        ),
      );
      addTearDown(controller.dispose);

      final snapshot = controller.selectionSnapshot!;
      expect(snapshot.plainText, 'Hello\nWorld');
      expect(snapshot.spans, [
        const HomericBlockSpan(blockId: 'a', start: 0, end: 5),
        const HomericBlockSpan(blockId: 'b', start: 0, end: 5),
      ]);
    });

    test('collapsed selection yields empty plainText snapshot', () {
      final controller = HomericEditorController(
        document: Document([
          Block(id: 'a', type: 'paragraph', runs: [InlineRun('Hi')]),
        ]),
        selection: const HomericSelection.collapsed(1),
      );
      addTearDown(controller.dispose);

      final snapshot = controller.selectionSnapshot!;
      expect(snapshot.plainText, isEmpty);
      expect(snapshot.spans, isEmpty);
    });

    test('selectionChanges emits on selection updates', () async {
      final controller = HomericEditorController(
        document: Document([
          Block(id: 'a', type: 'paragraph', runs: [InlineRun('abcd')]),
        ]),
        selection: const HomericSelection.collapsed(1),
      );
      addTearDown(controller.dispose);

      final events = <HomericSelectionSnapshot?>[];
      final sub = controller.selectionChanges.listen(events.add);
      addTearDown(sub.cancel);

      controller.setSelection(const HomericSelection(anchor: 1, head: 3));
      expect(events, isNotEmpty);
      expect(events.last!.plainText, 'ab');
      expect(events.last!.spans.single,
          const HomericBlockSpan(blockId: 'a', start: 0, end: 2));
    });

    test('selectionSnapshot remains readable after dispose', () {
      final controller = HomericEditorController(
        document: Document([
          Block(id: 'a', type: 'paragraph', runs: [InlineRun('keep')]),
        ]),
        selection: const HomericSelection(anchor: 1, head: 5),
      );
      final before = controller.selectionSnapshot!;
      controller.dispose();
      expect(controller.selectionSnapshot, before);
    });
  });
}
