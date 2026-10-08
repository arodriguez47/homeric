import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

void main() {
  group('synchronous plainText / encode snapshots', () {
    test('plainTextSnapshot reflects the last keystroke immediately', () {
      final controller = HomericEditorController(
        document: Document([
          Block(id: 'b', type: 'paragraph', runs: [InlineRun('Hi')]),
        ]),
        selection: const HomericSelection.collapsed(3),
      );
      addTearDown(controller.dispose);

      expect(controller.plainTextSnapshot, 'Hi');
      expect(controller.replaceSelection('!'), isTrue);
      expect(controller.plainTextSnapshot, 'Hi!');
    });

    test('encodeSnapshot round-trips through HomericDocumentCodec', () {
      final controller = HomericEditorController(
        document: Document([
          Block(
            id: 'b',
            type: 'paragraph',
            runs: [
              InlineRun('x', attributes: const <String, Object?>{'bold': true}),
            ],
          ),
        ]),
      );
      addTearDown(controller.dispose);

      final encoded = controller.encodeSnapshot();
      expect(encoded['v'], 1);
      final restored = HomericDocumentCodec.decode(encoded);
      expect(restored.blocks.single.text, 'x');
      expect(restored.blocks.single.runs.single.attributes['bold'], isTrue);
      expect(controller.encodeJsonSnapshot(), contains('"bold":true'));
    });

    test('types then disposes immediately then reads snapshot', () {
      final controller = HomericEditorController(
        document: Document([
          Block(id: 'b', type: 'paragraph', runs: [InlineRun('')]),
        ]),
        selection: const HomericSelection.collapsed(1),
      );

      expect(controller.replaceSelection('last'), isTrue);
      expect(controller.replaceSelection(' key'), isTrue);
      final plain = controller.plainTextSnapshot;
      final encoded = controller.encodeSnapshot();
      controller.dispose();

      // Dispose must not clear the last keystroke for route-pop flushes.
      expect(controller.plainTextSnapshot, plain);
      expect(controller.plainTextSnapshot, 'last key');
      expect(controller.encodeSnapshot(), encoded);
      expect(
          HomericDocumentCodec.decode(encoded).blocks.single.text, 'last key');
    });
  });
}
