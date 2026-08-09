// Behavior spec follows prosemirror-transform src/transform.ts
// @ 662b7a937bafde19b7e2a83241dbc8888e257c89 (MIT (c) Marijn Haverbeke).
// Semantics reference only; the test code is original Dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

import 'transform_test_utils.dart';

void main() {
  group('Transaction accumulation', () {
    test('collects steps, pre-step docs, and maps in order', () {
      final doc = threeBlocks();
      final tr = Transaction(doc);
      final s1 = ReplaceStep(3, 3, inlineSlice('XY'));
      tr.step(s1);
      final afterFirst = tr.doc;
      final s2 = ReplaceStep(10, 12, Slice.empty);
      tr.step(s2);
      final s3 = BlockAttrStep('c', type: 'quote');
      tr.step(s3);

      expect(tr.before, same(doc));
      expect(tr.steps, [s1, s2, s3]);
      expect(tr.docs, hasLength(3));
      expect(tr.docs[0], same(doc));
      expect(tr.docs[1], same(afterFirst));
      expect(tr.mapping.maps, hasLength(3));
      expect(tr.docChanged, isTrue);
    });

    test('docs[] retention shares untouched blocks (no deep copies)', () {
      final doc = threeBlocks();
      final tr = Transaction(doc)
        ..step(ReplaceStep(9, 9, inlineSlice('!')))
        ..step(ReplaceStep(10, 10, inlineSlice('?')));
      for (final version in [...tr.docs, tr.doc]) {
        expect(identical(version.blocks[0], doc.blocks[0]), isTrue);
        expect(identical(version.blocks[2], doc.blocks[2]), isTrue);
      }
    });

    test('transaction mapping equals composing the per-step maps', () {
      final doc = threeBlocks();
      final tr = Transaction(doc)
        ..step(ReplaceStep(3, 3, inlineSlice('XY')))
        ..step(ReplaceStep(12, 14, Slice.empty))
        ..step(ReplaceStep(1, 2, inlineSlice('abc')));
      for (var pos = 0; pos <= doc.size; pos++) {
        for (final assoc in [-1, 1]) {
          var sequential = pos;
          for (final step in tr.steps) {
            sequential = step.getMap().map(sequential, assoc: assoc);
          }
          expect(tr.mapping.map(pos, assoc: assoc), sequential,
              reason: 'pos $pos assoc $assoc');
        }
      }
    });
  });

  group('Transaction error behavior', () {
    test('maybeStep returns a failed result and leaves state untouched', () {
      final doc = threeBlocks();
      final tr = Transaction(doc);
      final result = tr.maybeStep(ReplaceStep(4, 7, Slice.empty));
      expect(result.failed, isTrue);
      expect(tr.steps, isEmpty);
      expect(tr.docs, isEmpty);
      expect(tr.doc, same(doc));
    });

    test(
        'step() throws StepFailedError on a misfit (the only throwing '
        'entry point)', () {
      final tr = Transaction(threeBlocks());
      expect(() => tr.step(ReplaceStep(4, 7, Slice.empty)),
          throwsA(isA<StepFailedError>()));
    });

    test(
        'stepPairMirrored is atomic: a failing second step records '
        'nothing', () {
      final doc = threeBlocks();
      final tr = Transaction(doc)..step(ReplaceStep(3, 3, inlineSlice('XY')));
      // After the insert: `a` spans [0, 9), `b` [9, 16), `c` [16, 25).
      final stepsBefore = List.of(tr.steps);
      final docsBefore = List.of(tr.docs);
      final mapsBefore = List.of(tr.mapping.maps);
      final docBefore = tr.doc;
      final changesBefore = tr.changes;

      expect(
        () => tr.stepPairMirrored(
          // Applies cleanly on its own: insert inside `c`'s text.
          ReplaceStep(24, 24, inlineSlice('!')),
          // Misfit: deletes `a`'s closing token without `b`'s opening one.
          (d) => ReplaceStep(6, 9, Slice.empty),
          record: const BlockMove(blockId: 'a', fromIndex: 0, toIndex: 1),
        ),
        throwsA(isA<StepFailedError>()),
      );

      expect(tr.steps, stepsBefore);
      expect(tr.docs, docsBefore);
      expect(tr.docs.single, same(docsBefore.single));
      expect(tr.doc, same(docBefore));
      expect(tr.mapping.maps, hasLength(mapsBefore.length));
      for (var i = 0; i < mapsBefore.length; i++) {
        expect(tr.mapping.maps[i], same(mapsBefore[i]));
      }
      expect(tr.mapping.getMirror(0), isNull);
      final changesAfter = tr.changes;
      expect(changesAfter, same(changesBefore));
      expect(changesAfter.structural, isEmpty);
      expectSameDoc(tr.doc, docBefore);
    });
  });

  group('Transaction result', () {
    test('finish() yields (new Document, ChangeList, Mapping)', () {
      final doc = threeBlocks();
      final tr = Transaction(doc)..step(ReplaceStep(3, 3, inlineSlice('X')));
      final result = tr.finish();
      expect(result.doc, same(tr.doc));
      expect(result.mapping, same(tr.mapping));
      expect(result.changes.changeFor('a'), isNotNull);
    });
  });

  group('ChangeList', () {
    test('reports only touched blocks with old/new global ranges', () {
      final doc = threeBlocks();
      final tr = Transaction(doc)..step(ReplaceStep(9, 9, inlineSlice('zz')));
      final changes = tr.changes;
      expect(changes.touchedBlockIds, ['b']);
      final change = changes.changeFor('b')!;
      expect(change.before, const BlockSpan(7, 14));
      expect(change.after, const BlockSpan(7, 16));
      expect(changes.changeFor('a'), isNull);
      expect(changes.changeFor('c'), isNull);
    });

    test('reports created and removed blocks', () {
      final doc = threeBlocks();
      final tr = Transaction(doc)
        ..step(ReplaceStep(7, 14, Slice.empty))
        ..step(ReplaceStep(16, 16, Slice([para('n', 'new')])));
      final changes = tr.changes;
      final removed = changes.changeFor('b')!;
      expect(removed.isRemoved, isTrue);
      expect(removed.before, const BlockSpan(7, 14));
      final created = changes.changeFor('n')!;
      expect(created.isCreated, isTrue);
      expect(created.after, const BlockSpan(16, 21));
    });

    test('carries split and join outcomes from the steps', () {
      final doc = threeBlocks();
      final tr = Transaction(doc)
        ..step(ReplaceStep(4, 10, Slice.empty)); // join b into a
      final joins = tr.changes.structural.whereType<BlockJoin>().toList();
      expect(joins, hasLength(1));
      expect(joins.single.leadingId, 'a');
      expect(joins.single.removedId, 'b');
    });
  });

  group('Selection mapping through a transaction', () {
    test('a selection survives a 3-step transaction per PM semantics', () {
      final doc = threeBlocks();
      // Selection inside "bravo": anchor pos 9 (offset 1), head pos 12
      // (offset 4).
      final tr = Transaction(doc)
        ..step(ReplaceStep(2, 2, inlineSlice('++'))) // before: shifts +2
        ..step(ReplaceStep(17, 19, Slice.empty)) // after: no effect
        ..step(ReplaceStep(10, 10, inlineSlice('*'))); // between the ends
      final anchor = tr.mapping.mapResult(9);
      final head = tr.mapping.mapResult(12, assoc: -1);
      expect(anchor.deleted, isFalse);
      expect(head.deleted, isFalse);
      // +2 from the first insert, +1 from the insert at 10.
      expect(anchor.pos, 12);
      expect(head.pos, 15);
    });

    test(
        'deletedAcross reports an anchor whose surroundings were both '
        'removed', () {
      final doc = threeBlocks();
      final tr = Transaction(doc)
        ..step(ReplaceStep(2, 2, inlineSlice('X')))
        ..step(ReplaceStep(9, 14, Slice.empty)) // deletes around pos 10..13
        ..step(ReplaceStep(1, 1, inlineSlice('Y')));
      final result = tr.mapping.mapResult(11);
      expect(result.deletedAcross, isTrue);
      expect(result.deletedBefore, isTrue);
      expect(result.deletedAfter, isTrue);
      // A position at the deletion edge is not deleted across.
      final edge = tr.mapping.mapResult(8, assoc: -1);
      expect(edge.deletedAcross, isFalse);
      expect(edge.deletedAfter, isTrue);
    });
  });
}
