import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/src/model/block.dart';
import 'package:homeric/src/model/document.dart';
import 'package:homeric/src/model/position.dart';

import '../transform/transform_test_utils.dart';

void main() {
  group('ProseMirror token-scheme pin (hand-computed values)', () {
    // Two blocks "Hi" / "yo": each block is <open>H i<close> = 4 tokens,
    // so the document size is 8 and the second block's first character
    // sits at position 5. These values match ProseMirror exactly.
    final doc = Document([para('a', 'Hi'), para('b', 'yo')]);

    test('doc size is 8', () {
      expect(doc.size, 8);
    });

    test("second block's first character is at position 5", () {
      final resolved = doc.resolve(5);
      expect(resolved, isA<InlinePosition>());
      final inline = resolved as InlinePosition;
      expect(inline.blockIndex, 1);
      expect(inline.block.id, 'b');
      expect(inline.offset, 0);
      expect(inline.blockStart, 4);
    });

    test('an empty block has size 2', () {
      expect(Block(id: 'e', type: 'paragraph').size, 2);
      expect(Document([Block(id: 'e', type: 'paragraph')]).size, 2);
    });

    test('the gap between adjacent blocks is one position, two tokens', () {
      // Exactly one position (4) separates "Hi" content end (3) from
      // "yo" content start (5), even though two tokens (close + open)
      // sit between them.
      expect(doc.resolve(3), isA<InlinePosition>());
      expect(doc.resolve(4), isA<BlockBoundaryPosition>());
      expect(doc.resolve(5), isA<InlinePosition>());
      final gap = doc.resolve(4) as BlockBoundaryPosition;
      expect(gap.blockBefore!.id, 'a');
      expect(gap.blockAfter!.id, 'b');
    });
  });

  group('resolve over every position', () {
    test('classifies all 9 positions of the "Hi"/"yo" document', () {
      final doc = Document([para('a', 'Hi'), para('b', 'yo')]);
      final expected = <(Type, int, int)>[
        (BlockBoundaryPosition, 0, 0), // 0: doc start
        (InlinePosition, 0, 0), // 1: before 'H'
        (InlinePosition, 0, 1), // 2: between 'H' and 'i'
        (InlinePosition, 0, 2), // 3: after 'i'
        (BlockBoundaryPosition, 1, 0), // 4: between blocks
        (InlinePosition, 1, 0), // 5: before 'y'
        (InlinePosition, 1, 1), // 6: between 'y' and 'o'
        (InlinePosition, 1, 2), // 7: after 'o'
        (BlockBoundaryPosition, 2, 0), // 8: doc end
      ];
      for (var pos = 0; pos <= doc.size; pos++) {
        final resolved = doc.resolve(pos);
        final (type, indexValue, offset) = expected[pos];
        expect(resolved.runtimeType, type, reason: 'position $pos');
        expect(resolved.position, pos);
        switch (resolved) {
          case final BlockBoundaryPosition boundary:
            expect(boundary.insertionIndex, indexValue,
                reason: 'position $pos');
          case final InlinePosition inline:
            expect(inline.blockIndex, indexValue, reason: 'position $pos');
            expect(inline.offset, offset, reason: 'position $pos');
        }
      }
    });

    test('document start boundary has no blockBefore', () {
      final doc = Document([para('a', 'x')]);
      final start = doc.resolve(0) as BlockBoundaryPosition;
      expect(start.insertionIndex, 0);
      expect(start.blockBefore, isNull);
      expect(identical(start.blockAfter, doc.blocks[0]), isTrue);
    });

    test('document end boundary has no blockAfter', () {
      final doc = Document([para('a', 'x')]);
      final end = doc.resolve(doc.size) as BlockBoundaryPosition;
      expect(end.insertionIndex, 1);
      expect(identical(end.blockBefore, doc.blocks[0]), isTrue);
      expect(end.blockAfter, isNull);
    });

    test('empty document resolves only position 0', () {
      final doc = Document();
      final only = doc.resolve(0) as BlockBoundaryPosition;
      expect(only.insertionIndex, 0);
      expect(only.blockBefore, isNull);
      expect(only.blockAfter, isNull);
    });

    test('resolves inside an empty block between non-empty blocks', () {
      final doc = Document([
        para('a', 'a'), // [0, 3)
        Block(id: 'empty', type: 'paragraph'), // [3, 5)
        para('c', 'c'), // [5, 8)
      ]);
      final inside = doc.resolve(4) as InlinePosition;
      expect(inside.block.id, 'empty');
      expect(inside.offset, 0);
      expect(inside.blockStart, 3);
      expect(doc.resolve(3), isA<BlockBoundaryPosition>());
      expect(doc.resolve(5), isA<BlockBoundaryPosition>());
    });

    test('offset at content end (before closing token) is contentLength', () {
      final doc = Document([para('a', 'Hi')]);
      final atEnd = doc.resolve(3) as InlinePosition;
      expect(atEnd.offset, 2);
      expect(atEnd.offset, atEnd.block.contentLength);
    });

    test('resolve agrees with positionAt for every text offset', () {
      final doc = Document([
        para('a', 'one'),
        Block(id: 'b', type: 'paragraph'),
        para('c', 'three'),
      ]);
      for (var blockIndex = 0; blockIndex < doc.blockCount; blockIndex++) {
        final block = doc.blocks[blockIndex];
        for (var offset = 0; offset <= block.contentLength; offset++) {
          final resolved =
              doc.resolve(doc.positionAt(blockIndex, offset)) as InlinePosition;
          expect(resolved.blockIndex, blockIndex);
          expect(resolved.offset, offset);
        }
      }
    });
  });

  group('typed errors on bad resolve', () {
    test('negative positions throw PositionOutOfRangeError', () {
      final doc = Document([para('a', 'Hi')]);
      expect(() => doc.resolve(-1), throwsA(isA<PositionOutOfRangeError>()));
    });

    test('past-end positions throw PositionOutOfRangeError', () {
      final doc = Document([para('a', 'Hi')]);
      expect(() => doc.resolve(doc.size + 1),
          throwsA(isA<PositionOutOfRangeError>()));
      expect(
          () => Document().resolve(1), throwsA(isA<PositionOutOfRangeError>()));
    });

    test('the error reports position and document size', () {
      final doc = Document([para('a', 'Hi')]);
      try {
        doc.resolve(99);
        fail('expected PositionOutOfRangeError');
      } on PositionOutOfRangeError catch (error) {
        expect(error.position, 99);
        expect(error.size, 4);
        expect('$error', contains('99'));
        expect('$error', contains('[0, 4]'));
      }
    });
  });
}
