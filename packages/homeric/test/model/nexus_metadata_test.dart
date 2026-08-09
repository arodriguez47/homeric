import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/src/model/attributes.dart';
import 'package:homeric/src/model/block.dart';
import 'package:homeric/src/model/document.dart';
import 'package:homeric/src/model/inline_run.dart';

/// A real `nexus` metadata map, shaped exactly like Nexus persists it under
/// the `nexus` key of a block's `data` bag (schema version 2 with a mirror;
/// reference: nexus `lib/models/document_block_metadata.dart`).
Map<String, Object?> _nexusFixture() => <String, Object?>{
      'nexus': <String, Object?>{
        'schemaVersion': 2,
        'blockId': 'blk_9f2c4e7a',
        'mirror': <String, Object?>{
          'mirrorId': 'mir_5d81b3aa',
          'source': <String, Object?>{
            'type': 'node',
            'id': 'node_c07e21f4',
          },
          'capturedAt': 1712345678,
          'sourceContentHash': 'sha256:9b74c9897bac770ffc029102a200c5de',
          'sourceSnapshotText': 'The captured source text, verbatim.',
          'groupId': 'grp_e66d012b',
        },
      },
    };

void main() {
  group('Nexus metadata hosting (R2)', () {
    test('the attribute bag stores the nexus map untranslated', () {
      final block = Block(
        id: 'blk_9f2c4e7a',
        type: 'paragraph',
        attributes: _nexusFixture(),
        runs: [InlineRun('mirrored content')],
      );
      final stored = block.attributes['nexus'];
      expect(stored, isA<Map<String, Object?>>());
      expect(attributesEqual(stored, _nexusFixture()['nexus']), isTrue);
    });

    test('round-trip is byte-identical under JSON encoding', () {
      final block = Block(
        id: 'blk_9f2c4e7a',
        type: 'paragraph',
        attributes: _nexusFixture(),
      );
      // Insertion order is preserved through freezing, so the JSON encoding
      // of the stored bag is byte-identical to the fixture's.
      expect(jsonEncode(block.attributes), jsonEncode(_nexusFixture()));
    });

    test('deep-equality round-trip of every nested field', () {
      final block = Block(
        id: 'b',
        type: 'paragraph',
        attributes: _nexusFixture(),
      );
      final nexus = block.attributes['nexus']! as Map<String, Object?>;
      expect(nexus['schemaVersion'], 2);
      expect(nexus['blockId'], 'blk_9f2c4e7a');
      final mirror = nexus['mirror']! as Map<String, Object?>;
      expect(mirror['mirrorId'], 'mir_5d81b3aa');
      expect(mirror['capturedAt'], 1712345678);
      expect(mirror['sourceContentHash'],
          'sha256:9b74c9897bac770ffc029102a200c5de');
      expect(
          mirror['sourceSnapshotText'], 'The captured source text, verbatim.');
      expect(mirror['groupId'], 'grp_e66d012b');
      final source = mirror['source']! as Map<String, Object?>;
      expect(source['type'], 'node');
      expect(source['id'], 'node_c07e21f4');
    });

    test('metadata survives edits by reference (no translation, no copy)', () {
      final block = Block(
        id: 'b',
        type: 'paragraph',
        attributes: _nexusFixture(),
        runs: [InlineRun('before')],
      );
      final doc = Document([block]);
      final edited =
          doc.updateBlock(0, block.copyWith(runs: [InlineRun('after')]));
      expect(
        identical(edited.blocks[0].attributes, block.attributes),
        isTrue,
        reason: 'run edits must share the frozen attribute bag',
      );
      expect(edited.blocks[0].id, block.id);
    });

    test('hosted metadata is frozen against mutation', () {
      final block = Block(
        id: 'b',
        type: 'paragraph',
        attributes: _nexusFixture(),
      );
      final nexus = block.attributes['nexus']! as Map<String, Object?>;
      final mirror = nexus['mirror']! as Map<String, Object?>;
      expect(() => nexus['schemaVersion'] = 3, throwsUnsupportedError);
      expect(() => mirror['groupId'] = 'other', throwsUnsupportedError);
    });
  });
}
