// Behavior spec follows prosemirror-transform src/step.ts,
// src/replace_step.ts, src/mark_step.ts, and src/attr_step.ts
// @ 662b7a937bafde19b7e2a83241dbc8888e257c89 (MIT (c) Marijn Haverbeke).
// Semantics reference only; the test code is original Dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

import 'transform_test_utils.dart';

void main() {
  group('ReplaceStep.apply', () {
    test('inline insert inside a block', () {
      final doc = threeBlocks();
      final step = ReplaceStep(3, 3, inlineSlice('XY'));
      final result = step.apply(doc);
      expect(result.failed, isFalse);
      final after = result.doc!;
      expect(after.blocks[0].text, 'alXYpha');
      expect(after.blocks[0].id, 'a');
      expect(after.size, doc.size + 2);
      // Untouched blocks are shared by reference.
      expect(identical(after.blocks[1], doc.blocks[1]), isTrue);
      expect(identical(after.blocks[2], doc.blocks[2]), isTrue);
    });

    test('inline delete inside a block', () {
      final doc = threeBlocks();
      final result = ReplaceStep(2, 4, Slice.empty).apply(doc);
      expect(result.failed, isFalse);
      expect(result.doc!.blocks[0].text, 'aha');
    });

    test('replace spanning a block boundary keeps the leading identity', () {
      final doc = threeBlocks();
      // pos 4 = offset 3 in "alpha", pos 10 = offset 2 in "bravo".
      final result = ReplaceStep(4, 10, Slice.empty).apply(doc);
      expect(result.failed, isFalse);
      final after = result.doc!;
      expect(after.blockCount, 2);
      final merged = after.blocks[0];
      expect(merged.id, 'a');
      expect(merged.type, 'paragraph');
      expect(identical(merged.attributes, doc.blocks[0].attributes), isTrue);
      expect(merged.text, 'alpavo');
      expect(after.blockById('b'), isNull);
      final joins = result.structural.whereType<BlockJoin>().toList();
      expect(joins, hasLength(1));
      expect(joins.single.leadingId, 'a');
      expect(joins.single.removedId, 'b');
      expect(joins.single.removedOffset, 2);
      expect(joins.single.leadingOffset, 3);
    });

    test(
        'cross-block replace with inline content merges into the leading '
        'block', () {
      final doc = threeBlocks();
      final result = ReplaceStep(4, 10, inlineSlice('--')).apply(doc);
      expect(result.failed, isFalse);
      final merged = result.doc!.blocks[0];
      expect(merged.id, 'a');
      expect(merged.text, 'alp--avo');
    });

    test('whole-block delete between boundaries', () {
      final doc = threeBlocks();
      final result = ReplaceStep(7, 14, Slice.empty).apply(doc);
      expect(result.failed, isFalse);
      expect(result.doc!.blocks.map((b) => b.id), ['a', 'c']);
    });

    test('block insert at document start and end', () {
      final doc = threeBlocks();
      final atStart =
          ReplaceStep(0, 0, Slice([para('x', 'xx')])).apply(doc).doc!;
      expect(atStart.blocks.map((b) => b.id), ['x', 'a', 'b', 'c']);
      final atEnd =
          ReplaceStep(23, 23, Slice([para('y', 'yy')])).apply(doc).doc!;
      expect(atEnd.blocks.map((b) => b.id), ['a', 'b', 'c', 'y']);
    });

    test('replace at document start and end of a block\'s content', () {
      final doc = threeBlocks();
      final head = ReplaceStep(1, 2, inlineSlice('A')).apply(doc).doc!;
      expect(head.blocks[0].text, 'Alpha');
      final tail = ReplaceStep(22, 22, inlineSlice('!')).apply(doc).doc!;
      expect(tail.blocks[2].text, 'charlie!');
    });

    test(
        'split-shaped step: leading keeps identity, trailing takes the '
        'slice block identity', () {
      final doc = threeBlocks();
      final slice = Slice(
        [
          Block(id: 'a', type: 'paragraph'),
          Block(
            id: 'fresh',
            type: 'paragraph',
            attributes: doc.blocks[0].attributes,
          ),
        ],
        openStart: true,
        openEnd: true,
      );
      final result = ReplaceStep(3, 3, slice, structure: true).apply(doc);
      expect(result.failed, isFalse);
      final after = result.doc!;
      expect(after.blocks.map((b) => b.id), ['a', 'fresh', 'b', 'c']);
      expect(after.blocks[0].text, 'al');
      expect(after.blocks[1].text, 'pha');
      final splits = result.structural.whereType<BlockSplit>().toList();
      expect(splits, hasLength(1));
      expect(splits.single.sourceId, 'a');
      expect(splits.single.trailingId, 'fresh');
      expect(splits.single.sourceOffset, 2);
      expect(splits.single.trailingOffset, 0);
    });

    test('empty replace is a successful no-op with an identity map', () {
      final doc = threeBlocks();
      final step = ReplaceStep(5, 5, Slice.empty);
      final result = step.apply(doc);
      expect(result.failed, isFalse);
      expectSameDoc(result.doc!, doc);
      final map = step.getMap();
      for (final pos in [0, 4, 5, 6, 23]) {
        expect(map.map(pos), pos);
        expect(map.map(pos, assoc: -1), pos);
      }
    });

    test('misfit applications fail as values, never throw', () {
      final doc = threeBlocks();
      // Unbalanced empty-slice deletion: inline start, boundary end.
      expect(ReplaceStep(4, 7, Slice.empty).apply(doc).failed, isTrue);
      // Open slice at a block boundary.
      expect(ReplaceStep(0, 0, inlineSlice('x')).apply(doc).failed, isTrue);
      // Closed slice at an inline position.
      expect(ReplaceStep(3, 3, Slice([para('z', 'zz')])).apply(doc).failed,
          isTrue);
      // Out-of-range positions.
      expect(ReplaceStep(0, 99, Slice.empty).apply(doc).failed, isTrue);
      expect(ReplaceStep(90, 99, Slice.empty).apply(doc).failed, isTrue);
      // Duplicate block id insertion.
      expect(ReplaceStep(0, 0, Slice([para('b', 'dup')])).apply(doc).failed,
          isTrue);
    });
  });

  group('ReplaceStep structure guard', () {
    test('a structural join over pure boundary tokens applies', () {
      final doc = threeBlocks();
      final result = ReplaceStep(6, 8, Slice.empty, structure: true).apply(doc);
      expect(result.failed, isFalse);
      expect(result.doc!.blocks[0].text, 'alphabravo');
    });

    test(
        'a rebased structural join refuses to destroy concurrently '
        'inserted content', () {
      final doc = threeBlocks();
      final join = ReplaceStep(6, 8, Slice.empty, structure: true);
      // Concurrent edit: a new block inserted exactly at the boundary.
      final concurrent = ReplaceStep(7, 7, Slice([para('x', 'xx')]));
      final docWithBlock = concurrent.apply(doc).doc!;
      final mapping = Mapping()..appendMap(concurrent.getMap());
      final rebased = join.map(mapping);
      expect(rebased, isNotNull);
      final result = rebased!.apply(docWithBlock);
      expect(result.failed, isTrue);
      // Without the guard the same range replace would destroy 'xx'.
      final unguarded =
          ReplaceStep((rebased as ReplaceStep).from, rebased.to, Slice.empty);
      expect(unguarded.apply(docWithBlock).failed, isFalse);
    });
  });

  group('Step.invert round-trips (every step kind)', () {
    test('inline insert', () {
      final doc = threeBlocks();
      expectInvertRoundTrip(doc, ReplaceStep(3, 3, inlineSlice('XY')));
    });

    test('inline delete', () {
      final doc = threeBlocks();
      expectInvertRoundTrip(doc, ReplaceStep(2, 4, Slice.empty));
    });

    test('inline replace with attributed text', () {
      final doc = threeBlocks();
      expectInvertRoundTrip(doc,
          ReplaceStep(2, 5, inlineSlice('BOLD', attributes: {'bold': true})));
    });

    test(
        'cross-block delete (join): trailing id, type, and attrs are '
        'restored by the inverse', () {
      final doc = threeBlocks();
      final after = expectInvertRoundTrip(doc, ReplaceStep(4, 10, Slice.empty));
      expect(after.blockById('b'), isNull);
    });

    test('cross-block replace with a multi-block slice', () {
      final doc = threeBlocks();
      final slice = Slice(
        [
          Block(id: '', type: '', runs: [InlineRun('one')]),
          para('m', 'middle'),
          Block(id: 't', type: 'quote', runs: [InlineRun('two')]),
        ],
        openStart: true,
        openEnd: true,
      );
      final after = expectInvertRoundTrip(doc, ReplaceStep(4, 17, slice));
      expect(after.blocks.map((b) => b.id), ['a', 'm', 't']);
      expect(after.blocks[0].text, 'alpone');
      // pos 17 is offset 2 in "charlie", so the tail "arlie" survives.
      expect(after.blocks[2].text, 'twoarlie');
      expect(after.blocks[2].type, 'quote');
    });

    test('whole-block delete and insert', () {
      final doc = threeBlocks();
      expectInvertRoundTrip(doc, ReplaceStep(7, 14, Slice.empty));
      expectInvertRoundTrip(doc, ReplaceStep(7, 7, Slice([para('n', 'new')])));
    });

    test('split-shaped structural step', () {
      final doc = threeBlocks();
      final slice = Slice(
        [
          Block(id: 'a', type: 'paragraph'),
          Block(id: 'fresh', type: 'paragraph'),
        ],
        openStart: true,
        openEnd: true,
      );
      expectInvertRoundTrip(doc, ReplaceStep(9, 9, slice, structure: true));
    });

    test('join-shaped structural step', () {
      final doc = threeBlocks();
      expectInvertRoundTrip(
          doc, ReplaceStep(6, 8, Slice.empty, structure: true));
    });

    test('AddMarkStep and RemoveMarkStep', () {
      final doc = threeBlocks();
      expectInvertRoundTrip(doc, AddMarkStep(2, 5, 'bold', true));
      final marked = AddMarkStep(2, 5, 'bold', true).apply(doc).doc!;
      expectInvertRoundTrip(marked, RemoveMarkStep(2, 5, 'bold', true));
    });

    test('AddMarkStep spanning a block boundary', () {
      final doc = threeBlocks();
      expectInvertRoundTrip(doc, AddMarkStep(4, 10, 'em', 'loud'));
    });

    test('BlockAttrStep for type and attributes', () {
      final doc = threeBlocks();
      expectInvertRoundTrip(doc, BlockAttrStep('b', type: 'paragraph'));
      expectInvertRoundTrip(
          doc, BlockAttrStep('b', attributes: {'level': 3, 'x': 'y'}));
      expectInvertRoundTrip(
          doc, BlockAttrStep('b', type: 'code', attributes: {'lang': 'dart'}));
    });
  });

  group('Step.getMap', () {
    test('ReplaceStep map reflects the size delta', () {
      final step = ReplaceStep(4, 10, inlineSlice('--'));
      final map = step.getMap();
      expect(map.map(0), 0);
      expect(map.map(4, assoc: -1), 4);
      expect(map.map(10), 6);
      expect(map.map(23), 19);
    });

    test('mark and attr steps produce empty maps', () {
      expect(AddMarkStep(2, 5, 'bold', true).getMap().ranges, isEmpty);
      expect(RemoveMarkStep(2, 5, 'bold', true).getMap().ranges, isEmpty);
      expect(BlockAttrStep('a', type: 't').getMap().ranges, isEmpty);
    });
  });

  group('Step.map (rebase)', () {
    test('a replace shifts over an earlier insertion', () {
      final step = ReplaceStep(8, 10, Slice.empty);
      final mapping = Mapping()..appendMap(StepMap(const [0, 0, 5]));
      final mapped = step.map(mapping)! as ReplaceStep;
      expect(mapped.from, 13);
      expect(mapped.to, 15);
      expect(mapped.structure, isFalse);
    });

    test('a replace whose range was deleted across maps to null', () {
      final step = ReplaceStep(4, 6, Slice.empty);
      final mapping = Mapping()..appendMap(StepMap(const [2, 10, 0]));
      expect(step.map(mapping), isNull);
    });

    test('a mark step collapsed by deletion maps to null', () {
      final step = AddMarkStep(4, 6, 'bold', true);
      final mapping = Mapping()..appendMap(StepMap(const [2, 10, 0]));
      expect(step.map(mapping), isNull);
    });

    test('a block attr step is unaffected by position mapping', () {
      final step = BlockAttrStep('a', type: 'code');
      final mapping = Mapping()..appendMap(StepMap(const [0, 5, 0]));
      expect(identical(step.map(mapping), step), isTrue);
    });
  });

  group('Step.merge', () {
    test('adjacent text inserts coalesce (typing forward)', () {
      final doc = threeBlocks();
      final first = ReplaceStep(3, 3, inlineSlice('X'));
      final second = ReplaceStep(4, 4, inlineSlice('Y'));
      final merged = first.merge(second);
      expect(merged, isNotNull);
      final sequential = second.apply(first.apply(doc).doc!).doc!;
      expectSameDoc(merged!.apply(doc).doc!, sequential);
    });

    test('adjacent backward deletes coalesce (backspacing)', () {
      final doc = threeBlocks();
      final first = ReplaceStep(3, 4, Slice.empty);
      final second = ReplaceStep(2, 3, Slice.empty);
      final merged = first.merge(second);
      expect(merged, isNotNull);
      final sequential = second.apply(first.apply(doc).doc!).doc!;
      expectSameDoc(merged!.apply(doc).doc!, sequential);
    });

    test('adjacent forward deletes coalesce', () {
      final doc = threeBlocks();
      final first = ReplaceStep(3, 4, Slice.empty);
      final second = ReplaceStep(3, 4, Slice.empty);
      final merged = first.merge(second);
      expect(merged, isNotNull);
      final sequential = second.apply(first.apply(doc).doc!).doc!;
      expectSameDoc(merged!.apply(doc).doc!, sequential);
    });

    test('non-adjacent inserts refuse to merge', () {
      final first = ReplaceStep(3, 3, inlineSlice('X'));
      final second = ReplaceStep(9, 9, inlineSlice('Y'));
      expect(first.merge(second), isNull);
      expect(second.merge(first), isNull);
    });

    test('structural steps refuse to merge', () {
      final join = ReplaceStep(6, 8, Slice.empty, structure: true);
      final insert = ReplaceStep(6, 6, inlineSlice('X'));
      expect(join.merge(insert), isNull);
      expect(insert.merge(join), isNull);
    });

    test('overlapping identical mark steps merge', () {
      final a = AddMarkStep(2, 5, 'bold', true);
      final b = AddMarkStep(4, 9, 'bold', true);
      final merged = a.merge(b)! as AddMarkStep;
      expect(merged.from, 2);
      expect(merged.to, 9);
      expect(a.merge(AddMarkStep(4, 9, 'em', true)), isNull);
      expect(a.merge(AddMarkStep(7, 9, 'bold', true)), isNull);
    });

    test(
        'block attr steps on the same block merge with later-wins '
        'semantics', () {
      final doc = threeBlocks();
      final a = BlockAttrStep('b', type: 'code');
      final b = BlockAttrStep('b', attributes: {'lang': 'dart'});
      final merged = a.merge(b);
      expect(merged, isNotNull);
      final sequential = b.apply(a.apply(doc).doc!).doc!;
      expectSameDoc(merged!.apply(doc).doc!, sequential);
      expect(a.merge(BlockAttrStep('c', type: 'x')), isNull);
    });
  });

  group('Mark step strictness (lossless invert guarantee)', () {
    test('AddMarkStep fails where the key is already present', () {
      final doc = threeBlocks();
      final marked = AddMarkStep(2, 5, 'bold', true).apply(doc).doc!;
      final result = AddMarkStep(3, 6, 'bold', true).apply(marked);
      expect(result.failed, isTrue);
    });

    test('RemoveMarkStep fails where the value does not match', () {
      final doc = threeBlocks();
      final marked = AddMarkStep(2, 5, 'em', 'a').apply(doc).doc!;
      expect(RemoveMarkStep(2, 5, 'em', 'b').apply(marked).failed, isTrue);
      expect(RemoveMarkStep(2, 5, 'em', 'a').apply(marked).failed, isFalse);
    });

    test('mark steps over content-free ranges are no-ops', () {
      final doc = threeBlocks();
      final result = AddMarkStep(6, 8, 'bold', true).apply(doc);
      expect(result.failed, isFalse);
      expectSameDoc(result.doc!, doc);
    });
  });

  group('BlockAttrStep', () {
    test('applies type and attribute changes by stable id', () {
      final doc = threeBlocks();
      final result =
          BlockAttrStep('b', type: 'code', attributes: {'lang': 'dart'})
              .apply(doc);
      expect(result.failed, isFalse);
      final block = result.doc!.blockById('b')!;
      expect(block.type, 'code');
      expect(block.attributes, {'lang': 'dart'});
      expect(block.text, 'bravo');
    });

    test('fails as a value when the block id is gone', () {
      final doc = threeBlocks();
      final result = BlockAttrStep('zz', type: 'code').apply(doc);
      expect(result.failed, isTrue);
    });
  });
}
