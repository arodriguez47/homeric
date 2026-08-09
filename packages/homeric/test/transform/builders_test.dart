// Builder semantics follow prosemirror-transform src/transform.ts
// (replace/split/join/mark helpers)
// @ 662b7a937bafde19b7e2a83241dbc8888e257c89 (MIT (c) Marijn Haverbeke).
// Semantics reference only; the test code is original Dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

import 'transform_test_utils.dart';

void main() {
  group('insertText', () {
    test('inserts plain and attributed text at an inline position', () {
      final tr = Transaction(threeBlocks())
        ..insertText(3, 'XY')
        ..insertText(1, 'go', attributes: {'bold': true});
      expect(tr.doc.blocks[0].text, 'goalXYpha');
      expect(tr.doc.blocks[0].runs.first.attributes, {'bold': true});
    });

    test('empty text is a no-op and boundary positions are rejected', () {
      final tr = Transaction(threeBlocks())..insertText(3, '');
      expect(tr.steps, isEmpty);
      expect(() => tr.insertText(0, 'x'), throwsArgumentError);
      expect(() => tr.insertText(7, 'x'), throwsArgumentError);
    });
  });

  group('deleteRange', () {
    test('deletes within a block', () {
      final tr = Transaction(threeBlocks())..deleteRange(2, 4);
      expect(tr.doc.blocks[0].text, 'aha');
    });

    test(
        'cross-block delete keeps the leading block\'s id, type, and '
        'attribute bag', () {
      final doc = threeBlocks();
      final tr = Transaction(doc)..deleteRange(4, 10);
      final merged = tr.doc.blocks[0];
      expect(merged.id, 'a');
      expect(merged.type, 'paragraph');
      expect(identical(merged.attributes, doc.blocks[0].attributes), isTrue);
      expect(merged.text, 'alpavo');
      expect(tr.doc.blockById('b'), isNull);
    });

    test('normalizes mixed inline/boundary endpoints to a balanced range', () {
      // [inline in a, boundary after b) deletes a's tail and all of b.
      final tr = Transaction(threeBlocks())..deleteRange(4, 14);
      expect(tr.doc.blocks.map((b) => b.id), ['a', 'c']);
      expect(tr.doc.blocks[0].text, 'alp');
      // [boundary before b, inline in b) deletes b's head only.
      final tr2 = Transaction(threeBlocks())..deleteRange(7, 10);
      expect(tr2.doc.blocks.map((b) => b.id), ['a', 'b', 'c']);
      expect(tr2.doc.blocks[1].text, 'avo');
    });

    test('whole-block boundary range removes the blocks', () {
      final tr = Transaction(threeBlocks())..deleteRange(7, 14);
      expect(tr.doc.blocks.map((b) => b.id), ['a', 'c']);
    });
  });

  group('splitBlock', () {
    test(
        'leading half keeps id and bag reference; trailing half gets a '
        'fresh id, the same type, and shares the bag reference', () {
      final doc = threeBlocks();
      final original = doc.blocks[1]; // heading 'b' with {'level': 2}
      final tr = Transaction(doc);
      final newId = tr.splitBlock(10); // offset 2 in "bravo"
      final leading = tr.doc.blocks[1];
      final trailing = tr.doc.blocks[2];
      // Pinned: leading keeps the original id and attribute-bag reference.
      expect(leading.id, 'b');
      expect(identical(leading.attributes, original.attributes), isTrue);
      expect(leading.text, 'br');
      // Pinned: trailing gets a fresh id, same type, shared bag reference.
      expect(trailing.id, newId);
      expect(trailing.id, isNot('b'));
      expect(tr.before.blockById(newId), isNull);
      expect(trailing.type, original.type);
      expect(identical(trailing.attributes, original.attributes), isTrue);
      expect(trailing.text, 'avo');
      expect(tr.doc.blockCount, 4);
      final splits = tr.changes.structural.whereType<BlockSplit>().toList();
      expect(splits.single.sourceId, 'b');
      expect(splits.single.trailingId, newId);
    });

    test('honors an explicit trailing id and rejects boundaries', () {
      final tr = Transaction(threeBlocks());
      expect(tr.splitBlock(10, trailingBlockId: 'tail'), 'tail');
      expect(tr.doc.blocks[2].id, 'tail');
      expect(() => tr.splitBlock(0), throwsArgumentError);
    });
  });

  group('joinBlocks', () {
    test('keeps the leading id, type, and bag; the trailing id disappears', () {
      final doc = threeBlocks();
      final tr = Transaction(doc)..joinBlocks(7);
      final merged = tr.doc.blocks[0];
      expect(merged.id, 'a');
      expect(merged.type, 'paragraph');
      expect(identical(merged.attributes, doc.blocks[0].attributes), isTrue);
      expect(merged.text, 'alphabravo');
      expect(tr.doc.blockById('b'), isNull);
      final joins = tr.changes.structural.whereType<BlockJoin>().toList();
      expect(joins.single.leadingId, 'a');
      expect(joins.single.removedId, 'b');
    });

    test('rejects non-boundary positions and document edges', () {
      final tr = Transaction(threeBlocks());
      expect(() => tr.joinBlocks(9), throwsArgumentError);
      expect(() => tr.joinBlocks(0), throwsArgumentError);
      expect(() => tr.joinBlocks(23), throwsArgumentError);
    });
  });

  group('moveBlock', () {
    test('preserves the block instance, id, and attribute bag', () {
      final doc = threeBlocks();
      final moved = doc.blocks[0];
      final tr = Transaction(doc)..moveBlock('a', 2);
      expect(tr.doc.blocks.map((b) => b.id), ['b', 'c', 'a']);
      expect(identical(tr.doc.blocks[2], moved), isTrue);
      expect(identical(tr.doc.blocks[2].attributes, moved.attributes), isTrue);
      final moves = tr.changes.structural.whereType<BlockMove>().toList();
      expect(moves.single.blockId, 'a');
      expect(moves.single.fromIndex, 0);
      expect(moves.single.toIndex, 2);
    });

    test(
        'a selection inside a moved block maps into the destination via '
        'the mirror pair, not deletedAcross', () {
      final doc = threeBlocks();
      // Selection over "lph": positions 2..5 inside block 'a' [0, 7).
      final tr = Transaction(doc)..moveBlock('a', 2);
      // New layout: b [0, 7), c [7, 16), a [16, 23).
      final anchor = tr.mapping.mapResult(2);
      final head = tr.mapping.mapResult(5, assoc: -1);
      expect(anchor.deletedAcross, isFalse);
      expect(head.deletedAcross, isFalse);
      expect(anchor.pos, 18);
      expect(head.pos, 21);
      // The mapped selection still covers "lph" in the destination.
      final resolved = tr.doc.resolve(anchor.pos);
      expect(resolved, isA<InlinePosition>());
      expect((resolved as InlinePosition).block.id, 'a');
      expect(resolved.offset, 1);
    });

    test('moving to the same index is a no-op', () {
      final tr = Transaction(threeBlocks())..moveBlock('b', 1);
      expect(tr.steps, isEmpty);
    });

    test('rejects unknown ids and out-of-range targets', () {
      final tr = Transaction(threeBlocks());
      expect(() => tr.moveBlock('zz', 0), throwsArgumentError);
      expect(() => tr.moveBlock('a', 3), throwsRangeError);
    });
  });

  group('setBlockType / setBlockAttributes', () {
    test('setBlockType changes only the type', () {
      final doc = threeBlocks();
      final tr = Transaction(doc)..setBlockType('b', 'quote');
      final block = tr.doc.blockById('b')!;
      expect(block.type, 'quote');
      expect(
          identical(block.attributes, doc.blockById('b')!.attributes), isTrue);
      expect(block.text, 'bravo');
    });

    test('setBlockAttributes replaces the bag and keeps the type', () {
      final tr = Transaction(threeBlocks())
        ..setBlockAttributes('b', {'level': 5});
      final block = tr.doc.blockById('b')!;
      expect(block.type, 'heading');
      expect(block.attributes, {'level': 5});
    });
  });

  group('toggleMark', () {
    test('adds the mark where the range is unmarked', () {
      final tr = Transaction(threeBlocks())..toggleMark(2, 5, 'bold', true);
      final runs = tr.doc.blocks[0].runs;
      expect(runs.map((r) => r.text), ['a', 'lph', 'a']);
      expect(runs[1].attributes, {'bold': true});
    });

    test('removes the mark when the whole range already carries it', () {
      final doc = threeBlocks();
      final tr = Transaction(doc)..toggleMark(2, 5, 'bold', true);
      final tr2 = Transaction(tr.doc)..toggleMark(2, 5, 'bold', true);
      expectSameDoc(tr2.doc, doc);
    });

    test(
        'a partially marked range becomes fully marked, replacing '
        'conflicting values losslessly', () {
      final doc = Document([
        para('a', '', runs: [
          InlineRun('one'),
          InlineRun('two', attributes: {'em': 'a'}),
          InlineRun('three', attributes: {'em': 'b'}),
        ]),
      ]);
      final tr = Transaction(doc)..toggleMark(1, 12, 'em', 'b');
      final runs = tr.doc.blocks[0].runs;
      expect(runs, hasLength(1));
      expect(runs.single.text, 'onetwothree');
      expect(runs.single.attributes, {'em': 'b'});
      // Every emitted step individually inverts losslessly.
      var current = doc;
      final inverses = <Step>[];
      for (final step in tr.steps) {
        inverses.add(step.invert(current));
        current = step.apply(current).doc!;
      }
      for (final inverse in inverses.reversed) {
        current = inverse.apply(current).doc!;
      }
      expectSameDoc(current, doc);
    });

    test('spans block boundaries', () {
      final tr = Transaction(threeBlocks())..toggleMark(4, 10, 'bold', true);
      expect(tr.doc.blocks[0].runs.last.attributes, {'bold': true});
      expect(tr.doc.blocks[1].runs.first.attributes, {'bold': true});
      expect(tr.doc.blocks[0].runs.last.text, 'ha');
      expect(tr.doc.blocks[1].runs.first.text, 'br');
    });

    test('a content-free range is a no-op', () {
      final tr = Transaction(threeBlocks())..toggleMark(6, 8, 'bold', true);
      expect(tr.steps, isEmpty);
    });
  });

  group('Builder-produced transactions', () {
    test(
        'mapping equals per-step composition for mirror-free '
        'transactions', () {
      final doc = threeBlocks();
      final tr = Transaction(doc)
        ..insertText(3, 'xx')
        ..splitBlock(12, trailingBlockId: 'tail')
        ..deleteRange(1, 3);
      for (var pos = 0; pos <= doc.size; pos++) {
        var sequential = pos;
        for (final step in tr.steps) {
          sequential = step.getMap().map(sequential);
        }
        expect(tr.mapping.map(pos), sequential, reason: 'pos $pos');
      }
    });

    test(
        'every builder step inverts losslessly through a mixed '
        'transaction', () {
      final doc = threeBlocks();
      final tr = Transaction(doc)
        ..insertText(3, 'xx')
        ..splitBlock(6, trailingBlockId: 'tail')
        ..setBlockType('tail', 'quote')
        ..toggleMark(1, 3, 'bold', true);
      tr.joinBlocks(tr.doc.positionAfterBlock(0));
      var current = tr.doc;
      for (var i = tr.steps.length - 1; i >= 0; i--) {
        final inverse = tr.steps[i].invert(tr.docs[i]);
        final result = inverse.apply(current);
        expect(result.failed, isFalse, reason: 'inverse of step $i');
        current = result.doc!;
      }
      expectSameDoc(current, doc);
    });
  });
}
