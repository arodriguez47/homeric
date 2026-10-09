import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

void main() {
  group('HomericMarkdownShortcutPolicy', () {
    test('converts **bold** into a bold run attribute', () {
      final controller = HomericEditorController(
        document: Document([
          Block(id: 'b', type: 'paragraph', runs: [InlineRun('**bold*')]),
        ]),
        // Caret after the first closing star.
        selection: HomericSelection.collapsed(
          Document([
            Block(id: 'b', type: 'paragraph', runs: [InlineRun('**bold*')]),
          ]).positionAt(0, 7),
        ),
      );
      addTearDown(controller.dispose);
      const HomericMarkdownShortcutPolicy().installOn(controller);

      expect(controller.replaceSelection('*'), isTrue);
      final block = controller.document.blocks.single;
      expect(block.text, 'bold');
      expect(block.runs.single.attributes['bold'], isTrue);
    });

    test('converts *italic* into an italic run attribute', () {
      final document = Document([
        Block(id: 'b', type: 'paragraph', runs: [InlineRun('*itali')]),
      ]);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(document.positionAt(0, 6)),
      );
      addTearDown(controller.dispose);
      const HomericMarkdownShortcutPolicy().installOn(controller);

      expect(controller.replaceSelection('*'), isTrue);
      expect(controller.document.blocks.single.text, 'itali');
      expect(
        controller.document.blocks.single.runs.single.attributes['italic'],
        isTrue,
      );
    });

    test('converts `code` into a code run attribute', () {
      final document = Document([
        Block(id: 'b', type: 'paragraph', runs: [InlineRun('`code')]),
      ]);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(document.positionAt(0, 5)),
      );
      addTearDown(controller.dispose);
      const HomericMarkdownShortcutPolicy().installOn(controller);

      expect(controller.replaceSelection('`'), isTrue);
      expect(controller.document.blocks.single.text, 'code');
      expect(
        controller.document.blocks.single.runs.single.attributes['code'],
        isTrue,
      );
    });

    test('preserves italic when converting bold inside an italic run', () {
      final document = Document([
        Block(id: 'b', type: 'paragraph', runs: [
          InlineRun('before **bold* after', attributes: {'italic': true}),
        ]),
      ]);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(document.positionAt(0, 14)),
      );
      addTearDown(controller.dispose);
      const HomericMarkdownShortcutPolicy().installOn(controller);

      expect(controller.replaceSelection('*'), isTrue);
      final block = controller.document.blocks.single;
      expect(block.text, 'before bold after');
      expect(block.runs.map((run) => run.text), ['before ', 'bold', ' after']);
      expect(block.runs.map((run) => run.attributes), [
        {'italic': true},
        {'italic': true, 'bold': true},
        {'italic': true},
      ]);
      expect(controller.selection?.head, controller.document.positionAt(0, 11));
      expect(document.blocks.single.text, 'before **bold* after');
      expect(document.blocks.single.runs.single.attributes, {'italic': true});
    });

    for (final shortcut in [
      (marker: '**', key: 'host.bold'),
      (marker: '*', key: 'host.italic'),
      (marker: '`', key: 'host.code'),
    ]) {
      test('preserves host attributes when applying ${shortcut.key}', () {
        final marker = shortcut.marker;
        final attributes = <String, Object?>{
          'host.annotation': {
            'id': 'note-1',
            'tags': ['source', 'review'],
          },
          'host.color': 'blue',
          'host.optional': null,
          shortcut.key: false,
        };
        final text = '${marker}text${marker.substring(0, marker.length - 1)}';
        final document = Document([
          Block(id: 'b', type: 'paragraph', runs: [
            InlineRun(text, attributes: attributes),
          ]),
        ]);
        final controller = HomericEditorController(
          document: document,
          selection: HomericSelection.collapsed(
            document.positionAt(0, text.length),
          ),
        );
        addTearDown(controller.dispose);
        const HomericMarkdownShortcutPolicy(
          boldKey: 'host.bold',
          italicKey: 'host.italic',
          codeKey: 'host.code',
        ).installOn(controller);

        expect(controller.replaceSelection(marker[marker.length - 1]), isTrue);
        final block = controller.document.blocks.single;
        expect(block.text, 'text');
        expect(block.runs.single.attributes, {
          ...attributes,
          shortcut.key: true,
        });
        expect(document.blocks.single.runs.single.attributes, attributes);
      });
    }

    for (final shortcut in [
      (marker: '**', key: 'bold'),
      (marker: '*', key: 'italic'),
      (marker: '`', key: 'code'),
    ]) {
      test('preserves mixed-format spans when applying ${shortcut.key}', () {
        final marker = shortcut.marker;
        final firstAttributes = <String, Object?>{
          'italic': true,
          shortcut.key: false,
        };
        final middleAttributes = <String, Object?>{
          'code': true,
          'host.annotation': {'id': 'middle'},
        };
        final document = Document([
          Block(id: 'b', type: 'paragraph', runs: [
            InlineRun('before $marker', attributes: {'host.part': 'prefix'}),
            InlineRun('one', attributes: firstAttributes),
            InlineRun('', attributes: {'host.empty': true}),
            InlineRun('two', attributes: middleAttributes),
            InlineRun(
              'three${marker.substring(0, marker.length - 1)} after',
              attributes: {'underline': true},
            ),
          ]),
        ]);
        final offset = document.blocks.single.text.indexOf(' after');
        final controller = HomericEditorController(
          document: document,
          selection: HomericSelection.collapsed(document.positionAt(0, offset)),
        );
        addTearDown(controller.dispose);
        const HomericMarkdownShortcutPolicy().installOn(controller);

        expect(controller.replaceSelection(marker[marker.length - 1]), isTrue);
        final block = controller.document.blocks.single;
        expect(block.text, 'before onetwothree after');
        expect(block.runs.map((run) => run.text), [
          'before ',
          'one',
          'two',
          'three',
          ' after',
        ]);
        expect(block.runs.map((run) => run.attributes), [
          {'host.part': 'prefix'},
          {...firstAttributes, shortcut.key: true},
          {...middleAttributes, shortcut.key: true},
          {'underline': true, shortcut.key: true},
          {'underline': true},
        ]);
        expect(
          controller.selection?.head,
          controller.document.positionAt(0, 'before onetwothree'.length),
        );
      });
    }

    test('does nothing when the policy is not installed (journal-safe default)',
        () {
      final document = Document([
        Block(id: 'b', type: 'paragraph', runs: [InlineRun('**bold*')]),
      ]);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(document.positionAt(0, 7)),
      );
      addTearDown(controller.dispose);

      expect(controller.replaceSelection('*'), isTrue);
      expect(controller.document.blocks.single.text, '**bold**');
      expect(controller.document.blocks.single.runs.single.attributes, isEmpty);
    });
  });
}
