import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

/// Canonical sprintnotes v:1 wire shape (compact, key order matches encode).
/// Includes bold/italic/code run attributes and a block attribute.
const String sprintnotesCanonicalFixture =
    '{"v":1,"blocks":[{"id":"blk_1","type":"paragraph","attributes":{"align":"left"},"runs":[{"text":"plain ","attributes":{}},{"text":"bold","attributes":{"bold":true}},{"text":" ","attributes":{}},{"text":"italic","attributes":{"italic":true}},{"text":" ","attributes":{}},{"text":"code","attributes":{"code":true}}]},{"id":"blk_2","type":"paragraph","attributes":{},"runs":[{"text":"","attributes":{}}]}]}';

void main() {
  group('HomericDocumentCodec', () {
    test('HomericDocumentCodecException is a FormatException', () {
      final error = HomericDocumentCodecException('boom');
      expect(error, isA<FormatException>());
      expect(error.message, 'boom');
      // Hosts catch FormatException for plain-text migration fallback.
      Object? caught;
      try {
        throw error;
      } on FormatException catch (e) {
        caught = e;
      }
      expect(caught, same(error));
    });

    test(
        'sprintnotes canonical fixture decodes and re-encodes byte-identically',
        () {
      final document =
          HomericDocumentCodec.decodeJson(sprintnotesCanonicalFixture);
      expect(document.blockCount, 2);
      expect(document.blocks[0].attributes['align'], 'left');
      expect(document.blocks[0].runs[1].attributes['bold'], isTrue);
      expect(document.blocks[0].runs[3].attributes['italic'], isTrue);
      expect(document.blocks[0].runs[5].attributes['code'], isTrue);
      expect(document.blocks[1].runs.single.text, '');

      final reencoded = HomericDocumentCodec.encodeJson(document);
      expect(reencoded, sprintnotesCanonicalFixture);
      // Round-trip through map form is also stable.
      expect(
        jsonEncode(HomericDocumentCodec.encode(document)),
        sprintnotesCanonicalFixture,
      );
    });

    test('empty blocks list becomes one empty paragraph with InlineRun("")',
        () {
      final document = HomericDocumentCodec.decode(<String, Object?>{
        'v': 1,
        'blocks': <Object?>[],
      });
      expect(document.blockCount, 1);
      expect(document.blocks.single.type, 'paragraph');
      expect(document.blocks.single.runs, hasLength(1));
      expect(document.blocks.single.runs.single.text, '');
    });

    test('missing or empty runs become [InlineRun("")]', () {
      final missing = HomericDocumentCodec.decode(<String, Object?>{
        'v': 1,
        'blocks': <Object?>[
          <String, Object?>{
            'id': 'a',
            'type': 'paragraph',
            'attributes': <String, Object?>{},
          },
        ],
      });
      expect(missing.blocks.single.runs.single.text, '');

      final empty = HomericDocumentCodec.decode(<String, Object?>{
        'v': 1,
        'blocks': <Object?>[
          <String, Object?>{
            'id': 'b',
            'type': 'paragraph',
            'attributes': <String, Object?>{},
            'runs': <Object?>[],
          },
        ],
      });
      expect(empty.blocks.single.runs.single.text, '');
      expect(
        HomericDocumentCodec.encodeJson(empty),
        '{"v":1,"blocks":[{"id":"b","type":"paragraph","attributes":{},'
        '"runs":[{"text":"","attributes":{}}]}]}',
      );
    });

    test('encode always writes attributes maps on blocks and runs', () {
      final encoded = HomericDocumentCodec.encode(
        Document([
          Block(
            id: 'e',
            type: 'paragraph',
            runs: [InlineRun('x')],
          ),
        ]),
      );
      final json = jsonEncode(encoded);
      expect(json, contains('"attributes":{}'));
      expect(json, contains('"runs":[{"text":"x","attributes":{}}]'));
    });

    test(
        'rejects unsupported versions and malformed payloads as FormatException',
        () {
      expect(
        () => HomericDocumentCodec.decode(
            <String, Object?>{'v': 2, 'blocks': []}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => HomericDocumentCodec.decodeJson('{'),
        throwsA(isA<FormatException>()),
      );
    });

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
      ]);

      final restored =
          HomericDocumentCodec.decode(HomericDocumentCodec.encode(original));
      expect(restored.blockCount, original.blockCount);
      for (var i = 0; i < original.blockCount; i++) {
        expect(restored.blocks[i].id, original.blocks[i].id);
        expect(restored.blocks[i].text, original.blocks[i].text);
      }
    });
  });
}
