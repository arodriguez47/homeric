import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

/// Fixture shaped like sprintnotes' JSON v:1 `documentJson` codec output
/// (block id/type/attributes + inline runs with run attributes).
const String sprintnotesV1Fixture = '''
{
  "v": 1,
  "blocks": [
    {
      "id": "blk_intro",
      "type": "paragraph",
      "attributes": {
        "nexus": {
          "schemaVersion": 2,
          "blockId": "blk_intro"
        }
      },
      "runs": [
        {
          "text": "Hello ",
          "attributes": {}
        },
        {
          "text": "world",
          "attributes": {
            "bold": true
          }
        }
      ]
    },
    {
      "id": "blk_empty",
      "type": "paragraph",
      "attributes": {},
      "runs": []
    },
    {
      "id": "blk_code",
      "type": "paragraph",
      "attributes": {},
      "runs": [
        {
          "text": "print",
          "attributes": {
            "code": true,
            "italic": true
          }
        }
      ]
    }
  ]
}
''';

void main() {
  group('HomericDocumentCodec', () {
    test('round-trips a multi-block document with run attributes', () {
      final original = Document([
        Block(
          id: 'a',
          type: 'paragraph',
          attributes: const <String, Object?>{'align': 'left'},
          runs: [
            InlineRun('plain '),
            InlineRun('bold',
                attributes: const <String, Object?>{'bold': true}),
            InlineRun(' italic',
                attributes: const <String, Object?>{'italic': true}),
          ],
        ),
        Block(
          id: 'b',
          type: 'heading',
          runs: [InlineRun('Title')],
        ),
        Block(id: 'c', type: 'paragraph'),
      ]);

      final encoded = HomericDocumentCodec.encode(original);
      expect(encoded['v'], HomericDocumentCodec.formatVersion);
      final restored = HomericDocumentCodec.decode(encoded);

      expect(restored.blockCount, original.blockCount);
      for (var i = 0; i < original.blockCount; i++) {
        final a = original.blocks[i];
        final b = restored.blocks[i];
        expect(b.id, a.id);
        expect(b.type, a.type);
        expect(attributesEqual(b.attributes, a.attributes), isTrue);
        expect(b.runs.length, a.runs.length);
        for (var r = 0; r < a.runs.length; r++) {
          expect(b.runs[r].text, a.runs[r].text);
          expect(
            attributesEqual(b.runs[r].attributes, a.runs[r].attributes),
            isTrue,
          );
        }
      }
    });

    test('encodeJson / decodeJson round-trip', () {
      final document = Document([
        Block(
          id: 'x',
          type: 'paragraph',
          runs: [
            InlineRun('hi', attributes: const <String, Object?>{'code': true})
          ],
        ),
      ]);
      final json = HomericDocumentCodec.encodeJson(document);
      final restored = HomericDocumentCodec.decodeJson(json);
      expect(restored.blocks.single.text, 'hi');
      expect(restored.blocks.single.runs.single.attributes['code'], isTrue);
    });

    test('decodes a sprintnotes-shaped v:1 fixture', () {
      final document = HomericDocumentCodec.decodeJson(sprintnotesV1Fixture);
      expect(document.blockCount, 3);

      final intro = document.blocks[0];
      expect(intro.id, 'blk_intro');
      expect(intro.type, 'paragraph');
      expect(intro.runs.length, 2);
      expect(intro.runs[0].text, 'Hello ');
      expect(intro.runs[0].attributes, isEmpty);
      expect(intro.runs[1].text, 'world');
      expect(intro.runs[1].attributes['bold'], isTrue);
      final nexus = intro.attributes['nexus']! as Map<String, Object?>;
      expect(nexus['blockId'], 'blk_intro');

      expect(document.blocks[1].id, 'blk_empty');
      expect(document.blocks[1].runs, isEmpty);
      expect(document.blocks[1].contentLength, 0);

      final code = document.blocks[2];
      expect(code.runs.single.text, 'print');
      expect(code.runs.single.attributes['code'], isTrue);
      expect(code.runs.single.attributes['italic'], isTrue);
    });

    test('re-encoding the v:1 fixture preserves semantic equality', () {
      final document = HomericDocumentCodec.decodeJson(sprintnotesV1Fixture);
      final again =
          HomericDocumentCodec.decode(HomericDocumentCodec.encode(document));
      expect(again.blockCount, document.blockCount);
      for (var i = 0; i < document.blockCount; i++) {
        expect(again.blocks[i].id, document.blocks[i].id);
        expect(again.blocks[i].text, document.blocks[i].text);
        expect(
          attributesEqual(
            again.blocks[i].attributes,
            document.blocks[i].attributes,
          ),
          isTrue,
        );
      }
    });

    test('rejects unsupported versions and malformed payloads', () {
      expect(
        () => HomericDocumentCodec.decode(
            <String, Object?>{'v': 2, 'blocks': []}),
        throwsA(isA<HomericDocumentCodecException>()),
      );
      expect(
        () => HomericDocumentCodec.decode(<String, Object?>{
          'v': 1,
          'blocks': <Object?>[
            <String, Object?>{'id': '', 'type': 'paragraph'},
          ],
        }),
        throwsA(isA<HomericDocumentCodecException>()),
      );
      expect(
        () => HomericDocumentCodec.decodeJson('{'),
        throwsA(isA<HomericDocumentCodecException>()),
      );
    });

    test('always writes empty attributes and runs keys', () {
      final encoded = HomericDocumentCodec.encode(
        Document([Block(id: 'e', type: 'paragraph')]),
      );
      final blocks = encoded['blocks']! as List<Object?>;
      final block = blocks.single! as Map<String, Object?>;
      expect(block.containsKey('attributes'), isTrue);
      expect(block['attributes'], isEmpty);
      expect(block.containsKey('runs'), isTrue);
      expect(block['runs'], isEmpty);
      // Stable JSON keys for host Drift storage.
      expect(jsonEncode(encoded), contains('"attributes":{}'));
      expect(jsonEncode(encoded), contains('"runs":[]'));
    });
  });
}
