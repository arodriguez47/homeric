import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/src/model/block.dart';
import 'package:homeric/src/model/document.dart';
import 'package:homeric/src/model/inline_run.dart';

Block _paragraph(String id, String text) =>
    Block(id: id, type: 'paragraph', runs: [InlineRun(text)]);

void main() {
  group('Document construction and read-back', () {
    test('empty document has no blocks and size 0', () {
      final doc = Document();
      expect(doc.isEmpty, isTrue);
      expect(doc.blockCount, 0);
      expect(doc.size, 0);
    });

    test('reads back blocks, text, runs, and attributes', () {
      final doc = Document([
        Block(
          id: 'a',
          type: 'heading',
          attributes: {'level': 1},
          runs: [InlineRun('Title')],
        ),
        Block(
          id: 'b',
          type: 'paragraph',
          runs: [
            InlineRun('plain '),
            InlineRun('bold', attributes: {'bold': true}),
          ],
        ),
      ]);
      expect(doc.blockCount, 2);
      expect(doc.blocks[0].text, 'Title');
      expect(doc.blocks[0].attributes, {'level': 1});
      expect(doc.blocks[1].runs[1].attributes, {'bold': true});
      expect(doc.blocks[1].text, 'plain bold');
    });

    test('blocks list is unmodifiable', () {
      final doc = Document([_paragraph('a', 'x')]);
      expect(
          () => doc.blocks.add(_paragraph('b', 'y')), throwsUnsupportedError);
    });

    test('size sums block sizes, including empty blocks', () {
      final doc = Document([
        _paragraph('a', 'Hi'), // 4
        Block(id: 'b', type: 'paragraph'), // 2
        _paragraph('c', 'yo'), // 4
      ]);
      expect(doc.size, 10);
    });
  });

  group('Block boundary positions', () {
    test('positionBeforeBlock / positionAfterBlock match token counting', () {
      final doc = Document([
        _paragraph('a', 'Hi'), // spans [0, 4)
        Block(id: 'b', type: 'paragraph'), // spans [4, 6)
        _paragraph('c', 'yo'), // spans [6, 10)
      ]);
      expect(doc.positionBeforeBlock(0), 0);
      expect(doc.positionAfterBlock(0), 4);
      expect(doc.positionBeforeBlock(1), 4);
      expect(doc.positionAfterBlock(1), 6);
      expect(doc.positionBeforeBlock(2), 6);
      expect(doc.positionAfterBlock(2), 10);
      expect(() => doc.positionBeforeBlock(3), throwsRangeError);
      expect(() => doc.positionAfterBlock(-1), throwsRangeError);
    });

    test('positionAt maps (block, offset) to a document position', () {
      final doc = Document([_paragraph('a', 'Hi'), _paragraph('b', 'yo')]);
      expect(doc.positionAt(0, 0), 1);
      expect(doc.positionAt(0, 2), 3); // end of "Hi" content
      expect(doc.positionAt(1, 0), 5);
      expect(doc.positionAt(1, 2), 7);
      expect(() => doc.positionAt(1, 3), throwsRangeError);
      expect(() => doc.positionAt(2, 0), throwsRangeError);
    });
  });

  group('Lookup by stable id', () {
    test('blockById and indexOfBlockId find blocks; unknown ids are null', () {
      final doc = Document([_paragraph('a', 'x'), _paragraph('b', 'y')]);
      expect(doc.blockById('b')!.text, 'y');
      expect(doc.indexOfBlockId('a'), 0);
      expect(doc.blockById('zzz'), isNull);
      expect(doc.indexOfBlockId('zzz'), isNull);
    });

    test('duplicate ids are rejected', () {
      final doc = Document([_paragraph('dup', 'x'), _paragraph('dup', 'y')]);
      expect(() => doc.blockById('dup'), throwsStateError);
    });
  });

  group('Edits and structural sharing', () {
    test('updateBlock shares every untouched block by reference', () {
      final doc = Document([
        _paragraph('a', 'first'),
        _paragraph('b', 'second'),
        _paragraph('c', 'third'),
      ]);
      final edited = doc.updateBlock(
          1, doc.blocks[1].copyWith(runs: [InlineRun('SECOND')]));

      expect(identical(edited.blocks[0], doc.blocks[0]), isTrue);
      expect(identical(edited.blocks[2], doc.blocks[2]), isTrue);
      expect(identical(edited.blocks[1], doc.blocks[1]), isFalse);
      // Shared blocks share their run lists and attribute bags too.
      expect(identical(edited.blocks[0].runs, doc.blocks[0].runs), isTrue);
      expect(identical(edited.blocks[0].attributes, doc.blocks[0].attributes),
          isTrue);
      // The touched block keeps its stable id.
      expect(edited.blocks[1].id, 'b');
      // The source document is untouched.
      expect(doc.blocks[1].text, 'second');
      expect(edited.blocks[1].text, 'SECOND');
    });

    test('insertBlock and removeBlock share untouched blocks', () {
      final doc = Document([_paragraph('a', 'x'), _paragraph('b', 'y')]);
      final inserted = doc.insertBlock(1, _paragraph('mid', 'm'));
      expect(inserted.blockCount, 3);
      expect(identical(inserted.blocks[0], doc.blocks[0]), isTrue);
      expect(identical(inserted.blocks[2], doc.blocks[1]), isTrue);

      final removed = doc.removeBlock(0);
      expect(removed.blockCount, 1);
      expect(identical(removed.blocks[0], doc.blocks[1]), isTrue);
    });

    test('replaceBlockRange validates its range', () {
      final doc = Document([_paragraph('a', 'x')]);
      expect(() => doc.replaceBlockRange(0, 2, const []), throwsRangeError);
      expect(() => doc.replaceBlockRange(-1, 0, const []), throwsRangeError);
    });

    test('sizes stay correct after edits when the source cache was warm', () {
      final doc = Document([
        _paragraph('a', 'Hi'),
        _paragraph('b', 'yo'),
        _paragraph('c', 'end'),
      ]);
      expect(doc.size, 13); // warm the cumulative cache
      final edited = doc.updateBlock(
          1, doc.blocks[1].copyWith(runs: [InlineRun('yodel')]));
      expect(edited.size, 16);
      expect(edited.positionBeforeBlock(2), 11);
      expect(edited.positionBeforeBlock(0), 0);
    });

    test('sizes stay correct after edits when the source cache was cold', () {
      final doc = Document([_paragraph('a', 'Hi'), _paragraph('b', 'yo')]);
      // No size/resolve call on `doc` first: its cache is still cold.
      final edited = doc.removeBlock(0);
      expect(edited.size, 4);
      expect(edited.positionBeforeBlock(0), 0);
    });

    test('chained edits keep sharing and correct sizes', () {
      final doc = Document([
        _paragraph('a', 'one'),
        _paragraph('b', 'two'),
        _paragraph('c', 'three'),
      ]);
      final step1 = doc.insertBlock(3, _paragraph('d', 'four'));
      final step2 = step1.updateBlock(
          0, step1.blocks[0].copyWith(runs: [InlineRun('ONE!')]));
      expect(identical(step2.blocks[1], doc.blocks[1]), isTrue);
      expect(identical(step2.blocks[2], doc.blocks[2]), isTrue);
      expect(step2.size, 6 + 5 + 7 + 6);
    });
  });
}
