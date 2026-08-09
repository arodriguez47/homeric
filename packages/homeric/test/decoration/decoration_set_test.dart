// DecorationSet: non-destructive overlays surviving arbitrary edits.
//
// Fixture layout (threeBlocks, PM tokens): block `a` "alpha" spans [0, 7)
// with content at [1, 6); block `b` "bravo" spans [7, 14) with content at
// [8, 13); block `c` "charlie" spans [14, 23) with content at [15, 22).
// A local offset o in block `b` sits at global position 8 + o.

import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

import '../transform/transform_test_utils.dart';

/// Runs [build] as a transaction over [doc] and returns its result.
TransactionResult edit(Document doc, void Function(Transaction txn) build) {
  final txn = Transaction(doc);
  build(txn);
  return txn.finish();
}

/// The document text a decoration currently covers.
String coveredText(Document doc, Decoration decoration) {
  final block = doc.blockById(decoration.blockId);
  expect(block, isNotNull,
      reason: 'decoration block ${decoration.blockId} must exist');
  return block!.text.substring(decoration.start, decoration.end);
}

/// The decoration in [set] carrying exactly [spec] (by identity).
Decoration bySpec(DecorationSet set, Object spec) =>
    set.decorations.firstWhere((d) => identical(d.spec, spec));

/// Canonical dump of a set, for structural comparisons.
String dumpSet(DecorationSet set) {
  final lines = <String>[];
  for (final d in set.decorations) {
    lines.add('${d.blockId} ${d.kind.name} [${d.start},${d.end}) '
        '${d.inclusiveStart}/${d.inclusiveEnd} '
        'r=${d.replacementLength} spec=${d.spec}');
  }
  return lines.join('\n');
}

void main() {
  group('Decoration construction', () {
    test('rejects a negative start', () {
      expect(() => Decoration.inline('b', -1, 2), throwsArgumentError);
    });

    test('rejects an end before the start', () {
      expect(() => Decoration.inline('b', 3, 2), throwsArgumentError);
    });

    test('rejects a negative replacementLength', () {
      expect(() => Decoration.replace('b', 0, 2, replacementLength: -1),
          throwsArgumentError);
    });

    test(
        'widget is a zero-length point; other kinds have no '
        'replacementLength', () {
      final widget = Decoration.widget('b', 3);
      expect(widget.start, 3);
      expect(widget.end, 3);
      expect(widget.isCollapsed, isTrue);
      expect(widget.replacementLength, isNull);
      expect(Decoration.inline('b', 0, 2).replacementLength, isNull);
      expect(
          Decoration.replace('b', 0, 2, replacementLength: 0).replacementLength,
          0);
    });

    test('copyWith re-anchors and carries everything else', () {
      final spec = Object();
      final original = Decoration.replace('b', 1, 4,
          replacementLength: 2, inclusiveStart: true, spec: spec);
      final moved = original.copyWith(blockId: 'x', start: 0, end: 3);
      expect(moved.kind, DecorationKind.replace);
      expect(moved.blockId, 'x');
      expect((moved.start, moved.end), (0, 3));
      expect(moved.inclusiveStart, isTrue);
      expect(moved.inclusiveEnd, isFalse);
      expect(moved.replacementLength, 2);
      expect(identical(moved.spec, spec), isTrue);
    });

    test('copyWith enforces the widget point invariant', () {
      expect(() => Decoration.widget('b', 2).copyWith(end: 3),
          throwsArgumentError);
    });

    test('equality is anchor fields plus the identical spec instance', () {
      final spec = Object();
      expect(Decoration.inline('b', 1, 4, spec: spec),
          Decoration.inline('b', 1, 4, spec: spec));
      expect(Decoration.inline('b', 1, 4, spec: Object()),
          isNot(Decoration.inline('b', 1, 4, spec: Object())));
      expect(Decoration.inline('b', 1, 4), isNot(Decoration.inline('b', 1, 5)));
    });
  });

  group('DecorationSet add/remove', () {
    test('of() shards by block id and sorts by start then end', () {
      final set = DecorationSet.of([
        Decoration.inline('b', 3, 5),
        Decoration.inline('a', 1, 2),
        Decoration.inline('b', 1, 4),
        Decoration.inline('b', 1, 2),
      ]);
      expect(set.length, 4);
      expect(set.blockIds.toSet(), {'a', 'b'});
      expect(
        set.forBlock('b').map((d) => (d.start, d.end)).toList(),
        [(1, 2), (1, 4), (3, 5)],
      );
      expect(set.forBlock('missing'), isEmpty);
    });

    test('add rebuilds only the touched shard', () {
      final set = DecorationSet.of([
        Decoration.inline('a', 1, 2),
        Decoration.inline('b', 1, 4),
      ]);
      final grown = set.add([Decoration.inline('b', 0, 1)]);
      expect(grown.forBlock('b').length, 2);
      expect(identical(grown.forBlock('a'), set.forBlock('a')), isTrue);
      expect(identical(set.add(const []), set), isTrue);
    });

    test('remove matches by value + spec identity, one match per target', () {
      final specA = Object();
      final specB = Object();
      final first = Decoration.inline('b', 1, 4, spec: specA);
      final second = Decoration.inline('b', 1, 4, spec: specB);
      final untouched = Decoration.inline('a', 1, 2);
      final set = DecorationSet.of([first, second, untouched]);
      final removed = set.remove([Decoration.inline('b', 1, 4, spec: specA)]);
      expect(removed.length, 2);
      expect(identical(removed.forBlock('b').single.spec, specB), isTrue);
      expect(identical(removed.forBlock('a'), set.forBlock('a')), isTrue);
      // An emptied shard disappears.
      final emptied = removed.remove([second]).remove([untouched]);
      expect(emptied.isEmpty, isTrue);
      // Removing something absent returns the same instance.
      expect(
          identical(set.remove([Decoration.inline('c', 0, 1)]), set), isTrue);
    });
  });

  group('inclusivity matrix', () {
    // Range decoration [1, 4) ("rav") in block b, all four combinations,
    // for both range kinds: inserts before/at-start/inside/at-end/after,
    // deletes before/inside/after.
    for (final kind in [DecorationKind.inline, DecorationKind.replace]) {
      for (final inclusiveStart in [false, true]) {
        for (final inclusiveEnd in [false, true]) {
          test(
              '${kind.name} [1,4) survives inserts and deletes '
              '(inclusiveStart: $inclusiveStart, '
              'inclusiveEnd: $inclusiveEnd)', () {
            final decoration = kind == DecorationKind.inline
                ? Decoration.inline('b', 1, 4,
                    inclusiveStart: inclusiveStart,
                    inclusiveEnd: inclusiveEnd,
                    spec: 'd')
                : Decoration.replace('b', 1, 4,
                    replacementLength: 2,
                    inclusiveStart: inclusiveStart,
                    inclusiveEnd: inclusiveEnd,
                    spec: 'd');
            final set = DecorationSet.of([decoration]);

            (int, int) after(void Function(Transaction txn) build) {
              final result = edit(threeBlocks(), build);
              final mapped = set.map(result.mapping, result.changes);
              final d = mapped.forBlock('b').single;
              expect(d.kind, kind);
              expect(d.replacementLength, decoration.replacementLength);
              return (d.start, d.end);
            }

            // Insert "XX" before the range.
            expect(after((t) => t.insertText(8, 'XX')), (3, 6));
            // Insert exactly at the start: joins iff inclusiveStart.
            expect(after((t) => t.insertText(9, 'XX')),
                (inclusiveStart ? 1 : 3, 6));
            // Insert strictly inside: the range grows.
            expect(after((t) => t.insertText(10, 'XX')), (1, 6));
            // Insert exactly at the end: joins iff inclusiveEnd.
            expect(after((t) => t.insertText(12, 'XX')),
                (1, inclusiveEnd ? 6 : 4));
            // Insert after the range.
            expect(after((t) => t.insertText(13, 'XX')), (1, 4));
            // Delete before, inside, after.
            expect(after((t) => t.deleteRange(8, 9)), (0, 3));
            expect(after((t) => t.deleteRange(10, 11)), (1, 3));
            expect(after((t) => t.deleteRange(12, 13)), (1, 4));
          });
        }
      }
    }

    for (final inclusiveEnd in [false, true]) {
      test(
          'widget @2 maps by inclusiveEnd alone (inclusiveEnd: '
          '$inclusiveEnd)', () {
        final set = DecorationSet.of([
          Decoration.widget('b', 2, inclusiveEnd: inclusiveEnd, spec: 'w'),
        ]);

        int offsetAfter(void Function(Transaction txn) build) {
          final result = edit(threeBlocks(), build);
          final d =
              set.map(result.mapping, result.changes).forBlock('b').single;
          expect(d.kind, DecorationKind.widget);
          expect(d.isCollapsed, isTrue);
          return d.start;
        }

        // Insert before the slot.
        expect(offsetAfter((t) => t.insertText(9, 'XX')), 4);
        // Insert exactly at the slot: pushed after iff inclusiveEnd.
        expect(
            offsetAfter((t) => t.insertText(10, 'XX')), inclusiveEnd ? 4 : 2);
        // Insert after the slot.
        expect(offsetAfter((t) => t.insertText(11, 'XX')), 2);
        // Delete before / starting at the slot.
        expect(offsetAfter((t) => t.deleteRange(8, 9)), 1);
        expect(offsetAfter((t) => t.deleteRange(10, 11)), 2);
      });
    }

    test('widget slot strictly inside a deletion is dropped', () {
      final set = DecorationSet.of([Decoration.widget('b', 2, spec: 'w')]);
      final result = edit(threeBlocks(), (t) => t.deleteRange(9, 11));
      final removed = <Decoration>[];
      final mapped =
          set.map(result.mapping, result.changes, onRemoved: removed.add);
      expect(mapped.isEmpty, isTrue);
      expect(removed.single.spec, 'w');
    });

    test(
        'zero-length range decoration: all four combinations at an '
        'insertion point', () {
      (int, int) mapCollapsed({
        required bool inclusiveStart,
        required bool inclusiveEnd,
      }) {
        final set = DecorationSet.of([
          Decoration.inline('b', 2, 2,
              inclusiveStart: inclusiveStart, inclusiveEnd: inclusiveEnd),
        ]);
        final result = edit(threeBlocks(), (t) => t.insertText(10, 'XX'));
        final d = set.map(result.mapping, result.changes).forBlock('b').single;
        return (d.start, d.end);
      }

      // Exclusive both: stays put (collapse to the earlier position).
      expect(mapCollapsed(inclusiveStart: false, inclusiveEnd: false), (2, 2));
      // Start-inclusive only: stays before the insertion.
      expect(mapCollapsed(inclusiveStart: true, inclusiveEnd: false), (2, 2));
      // End-inclusive only: moves after the insertion.
      expect(mapCollapsed(inclusiveStart: false, inclusiveEnd: true), (4, 4));
      // Inclusive both: grows around the insertion.
      expect(mapCollapsed(inclusiveStart: true, inclusiveEnd: true), (2, 4));
    });
  });

  group('survival across step kinds and builders', () {
    test('insertText in another block: whole set returns identical', () {
      final set = DecorationSet.of([
        Decoration.inline('b', 1, 4, spec: 'd'),
        Decoration.widget('c', 2, spec: 'w'),
      ]);
      final result = edit(threeBlocks(), (t) => t.insertText(2, 'XX'));
      final mapped = set.map(result.mapping, result.changes);
      expect(identical(mapped, set), isTrue);
    });

    test('raw inline ReplaceStep before the range shifts offsets', () {
      final set = DecorationSet.of([Decoration.inline('b', 1, 4, spec: 'd')]);
      final result = edit(
          threeBlocks(), (t) => t.step(ReplaceStep(8, 8, inlineSlice('XX'))));
      final d = set.map(result.mapping, result.changes).forBlock('b').single;
      expect((d.start, d.end), (3, 6));
      expect(coveredText(result.doc, d), 'rav');
    });

    test('deleteRange inside the range shrinks it around the deletion', () {
      final set = DecorationSet.of([Decoration.inline('b', 1, 4, spec: 'd')]);
      final result = edit(threeBlocks(), (t) => t.deleteRange(10, 12));
      final d = set.map(result.mapping, result.changes).forBlock('b').single;
      expect((d.start, d.end), (1, 2));
      expect(coveredText(result.doc, d), 'r');
    });

    test('setBlockType (BlockAttrStep) leaves the set identical', () {
      final set = DecorationSet.of([Decoration.inline('b', 1, 4, spec: 'd')]);
      final result =
          edit(threeBlocks(), (t) => t.setBlockType('b', 'paragraph'));
      expect(result.changes.changeFor('b'), isNotNull);
      expect(identical(set.map(result.mapping, result.changes), set), isTrue);
    });

    test('setBlockAttributes leaves the set identical', () {
      final set = DecorationSet.of(
          [Decoration.replace('b', 0, 5, replacementLength: 1, spec: 'd')]);
      final result =
          edit(threeBlocks(), (t) => t.setBlockAttributes('b', {'level': 3}));
      expect(identical(set.map(result.mapping, result.changes), set), isTrue);
    });

    test('toggleMark (Add/RemoveMarkStep) leaves the set identical', () {
      final set = DecorationSet.of([Decoration.inline('b', 1, 4, spec: 'd')]);
      final doc = threeBlocks();
      final added = edit(doc, (t) => t.toggleMark(8, 13, 'bold', true));
      expect(added.changes.changeFor('b'), isNotNull);
      expect(identical(set.map(added.mapping, added.changes), set), isTrue);
      final removed = edit(added.doc, (t) => t.toggleMark(8, 13, 'bold', true));
      expect(identical(set.map(removed.mapping, removed.changes), set), isTrue);
    });
  });

  group('splitBlock', () {
    // splitBlock(10) splits b ("bravo") at local offset 2: leading b keeps
    // "br" (span [7, 11)), trailing b2 gets "avo" (span [11, 16)).
    test(
        'decorations re-key across the split per position and '
        'inclusivity', () {
      final set = DecorationSet.of([
        Decoration.inline('b', 0, 2, spec: 'lead'),
        Decoration.inline('b', 3, 5, spec: 'tail'),
        Decoration.inline('b', 2, 4, spec: 'atSplitExclusive'),
        Decoration.inline('b', 2, 4,
            inclusiveStart: true, spec: 'atSplitInclusive'),
        Decoration.inline('b', 1, 4, spec: 'spanning'),
      ]);
      final result =
          edit(threeBlocks(), (t) => t.splitBlock(10, trailingBlockId: 'b2'));
      final removed = <Decoration>[];
      final mapped =
          set.map(result.mapping, result.changes, onRemoved: removed.add);
      expect(removed, isEmpty);

      // Before the split point: stays in the leading block.
      final lead = bySpec(mapped, 'lead');
      expect((lead.blockId, lead.start, lead.end), ('b', 0, 2));
      expect(coveredText(result.doc, lead), 'br');

      // Past the split point: follows its text into the fresh-id block
      // with shifted local offsets.
      final tail = bySpec(mapped, 'tail');
      expect((tail.blockId, tail.start, tail.end), ('b2', 1, 3));
      expect(coveredText(result.doc, tail), 'vo');

      // Starting exactly at the split point: exclusive start follows the
      // text into the trailing block...
      final exclusive = bySpec(mapped, 'atSplitExclusive');
      expect((exclusive.blockId, exclusive.start, exclusive.end), ('b2', 0, 2));
      expect(coveredText(result.doc, exclusive), 'av');

      // ...while an inclusive start stays at the leading block's end
      // (clamped, pinned choice).
      final inclusive = bySpec(mapped, 'atSplitInclusive');
      expect((inclusive.blockId, inclusive.start, inclusive.end), ('b', 2, 2));

      // Spanning the split point: stays in the leading block, end clamped
      // to the leading content length (pinned choice).
      final spanning = bySpec(mapped, 'spanning');
      expect((spanning.blockId, spanning.start, spanning.end), ('b', 1, 2));
      expect(coveredText(result.doc, spanning), 'r');
    });
  });

  group('joinBlocks and cross-block replace', () {
    test(
        'trailing block decorations re-key to the leading id with '
        'shifted offsets', () {
      final set = DecorationSet.of([
        Decoration.inline('a', 1, 3, spec: 'leading'),
        Decoration.inline('b', 1, 3, spec: 'trailing'),
      ]);
      final result = edit(threeBlocks(), (t) => t.joinBlocks(7));
      final mapped = set.map(result.mapping, result.changes);
      expect(mapped.forBlock('b'), isEmpty);

      final leading = bySpec(mapped, 'leading');
      expect((leading.blockId, leading.start, leading.end), ('a', 1, 3));
      expect(coveredText(result.doc, leading), 'lp');

      // Merged text is "alphabravo": b's local [1, 3) ("ra") is now at
      // a's local [6, 8).
      final trailing = bySpec(mapped, 'trailing');
      expect((trailing.blockId, trailing.start, trailing.end), ('a', 6, 8));
      expect(coveredText(result.doc, trailing), 'ra');
    });

    test(
        'cross-block deleteRange re-keys the far block and reports the '
        'engulfed ones', () {
      final set = DecorationSet.of([
        Decoration.inline('a', 1, 2, spec: 'stays'),
        Decoration.inline('a', 4, 5, spec: 'engulfedA'),
        Decoration.inline('b', 1, 3, spec: 'engulfedB'),
        Decoration.inline('c', 3, 6, spec: 'rekeys'),
      ]);
      // Deletes global [3, 17): the tail of a, all of b, the head of c.
      // Merged block a is "al" + "arlie" = "alarlie".
      final result = edit(threeBlocks(), (t) => t.deleteRange(3, 17));
      final removed = <Decoration>[];
      final mapped =
          set.map(result.mapping, result.changes, onRemoved: removed.add);
      expect(removed.map((d) => d.spec).toSet(), {'engulfedA', 'engulfedB'});
      expect(mapped.forBlock('b'), isEmpty);
      expect(mapped.forBlock('c'), isEmpty);

      final stays = bySpec(mapped, 'stays');
      expect((stays.blockId, stays.start, stays.end), ('a', 1, 2));
      expect(coveredText(result.doc, stays), 'l');

      final rekeys = bySpec(mapped, 'rekeys');
      expect((rekeys.blockId, rekeys.start, rekeys.end), ('a', 3, 6));
      expect(coveredText(result.doc, rekeys), 'rli');
    });
  });

  group('moveBlock', () {
    test(
        'a decoration and a selection inside a moved block land at the '
        'destination', () {
      final set = DecorationSet.of([Decoration.inline('a', 1, 3, spec: 'm')]);
      final result = edit(threeBlocks(), (t) => t.moveBlock('a', 2));
      final removed = <Decoration>[];
      final mapped =
          set.map(result.mapping, result.changes, onRemoved: removed.add);
      expect(removed, isEmpty,
          reason: 'mirror recovery must run before the drop rule');

      // The shard follows the preserved block id, offsets intact — the
      // whole set is untouched in block-local terms.
      expect(identical(mapped, set), isTrue);
      final d = mapped.forBlock('a').single;
      expect(coveredText(result.doc, d), 'lp');

      // A selection position inside the moved block recovers into the
      // destination instead of reporting deletedAcross. Global position 3
      // (a's local offset 2) lands at 19: the new document is b [0, 7),
      // c [7, 16), a [16, 23), so a's content starts at 17.
      final selection = result.mapping.mapResult(3);
      expect(selection.deletedAcross, isFalse);
      expect(selection.deleted, isFalse);
      expect(selection.pos, 19);
      final resolved = result.doc.resolve(selection.pos);
      expect(resolved, isA<InlinePosition>());
      resolved as InlinePosition;
      expect(resolved.block.id, 'a');
      expect(resolved.offset, 2);
    });

    test('widget slot identity is stable through a move', () {
      final spec = Object();
      final widget = Decoration.widget('a', 2, spec: spec);
      final set = DecorationSet.of([widget]);
      final result = edit(threeBlocks(), (t) => t.moveBlock('a', 2));
      final d = set.map(result.mapping, result.changes).forBlock('a').single;
      expect(identical(d, widget), isTrue);
      expect(identical(d.spec, spec), isTrue);
      expect(d.start, 2);
    });

    test(
        'decorations in shifted-but-unchanged blocks keep their '
        'offsets', () {
      final set = DecorationSet.of([
        Decoration.inline('b', 1, 4, spec: 'between'),
        Decoration.inline('c', 0, 7, spec: 'whole'),
      ]);
      final result = edit(threeBlocks(), (t) => t.moveBlock('a', 2));
      final mapped = set.map(result.mapping, result.changes);
      expect(identical(mapped, set), isTrue);
      expect(coveredText(result.doc, bySpec(mapped, 'between')), 'rav');
      expect(coveredText(result.doc, bySpec(mapped, 'whole')), 'charlie');
    });
  });

  group('drop and clamp', () {
    test(
        'deleting exactly the decorated range collapses it, not drops '
        'it', () {
      final set = DecorationSet.of([Decoration.inline('b', 0, 5, spec: 'd')]);
      final result = edit(threeBlocks(), (t) => t.deleteRange(8, 13));
      final removed = <Decoration>[];
      final mapped =
          set.map(result.mapping, result.changes, onRemoved: removed.add);
      expect(removed, isEmpty);
      final d = mapped.forBlock('b').single;
      expect((d.start, d.end), (0, 0));
    });

    test('a one-side overlap with a replacement clamps per inclusivity', () {
      // Replace b's local [3, 5) with "XYZ": b becomes "braXYZ". The
      // decoration [1, 4) has its end strictly inside the replaced range.
      (int, int) mapWithEnd({required bool inclusiveEnd}) {
        final set = DecorationSet.of([
          Decoration.inline('b', 1, 4, inclusiveEnd: inclusiveEnd),
        ]);
        final result = edit(threeBlocks(),
            (t) => t.step(ReplaceStep(11, 13, inlineSlice('XYZ'))));
        final removed = <Decoration>[];
        final d = set
            .map(result.mapping, result.changes, onRemoved: removed.add)
            .forBlock('b')
            .single;
        expect(removed, isEmpty,
            reason: 'a one-sided overlap is clamped, never dropped');
        return (d.start, d.end);
      }

      // Inclusive end absorbs the replacement; exclusive end stops before
      // it.
      expect(mapWithEnd(inclusiveEnd: true), (1, 6));
      expect(mapWithEnd(inclusiveEnd: false), (1, 3));
    });

    test('removing a whole block drops and reports its decorations', () {
      final set = DecorationSet.of([
        Decoration.inline('b', 1, 4, spec: 'doomed'),
        Decoration.widget('b', 0, spec: 'doomedWidget'),
        Decoration.inline('a', 1, 3, spec: 'safe'),
      ]);
      final result =
          edit(threeBlocks(), (t) => t.step(ReplaceStep(7, 14, Slice.empty)));
      final removed = <Decoration>[];
      final mapped =
          set.map(result.mapping, result.changes, onRemoved: removed.add);
      expect(removed.map((d) => d.spec).toSet(), {'doomed', 'doomedWidget'});
      expect(mapped.forBlock('b'), isEmpty);
      expect(identical(mapped.forBlock('a'), set.forBlock('a')), isTrue);
    });
  });

  group('edge cases', () {
    test('overlapping decorations map independently', () {
      final set = DecorationSet.of([
        Decoration.inline('b', 1, 4, spec: 'first'),
        Decoration.inline('b', 2, 5, spec: 'second'),
      ]);
      final result = edit(threeBlocks(), (t) => t.insertText(8, 'XX'));
      final mapped = set.map(result.mapping, result.changes);
      final first = bySpec(mapped, 'first');
      final second = bySpec(mapped, 'second');
      expect((first.start, first.end), (3, 6));
      expect((second.start, second.end), (4, 7));
    });

    test(
        'adjacent decorations at a shared boundary split an insertion '
        'per inclusivity', () {
      final set = DecorationSet.of([
        Decoration.inline('b', 1, 3, spec: 'leftExclusive'),
        Decoration.inline('b', 1, 3, inclusiveEnd: true, spec: 'leftGrows'),
        Decoration.inline('b', 3, 5, spec: 'rightExclusive'),
        Decoration.inline('b', 3, 5, inclusiveStart: true, spec: 'rightGrows'),
      ]);
      // Insert "XX" exactly at the shared boundary (local 3).
      final result = edit(threeBlocks(), (t) => t.insertText(11, 'XX'));
      final mapped = set.map(result.mapping, result.changes);
      final leftExclusive = bySpec(mapped, 'leftExclusive');
      final leftGrows = bySpec(mapped, 'leftGrows');
      final rightExclusive = bySpec(mapped, 'rightExclusive');
      final rightGrows = bySpec(mapped, 'rightGrows');
      expect((leftExclusive.start, leftExclusive.end), (1, 3));
      expect((leftGrows.start, leftGrows.end), (1, 5));
      expect((rightExclusive.start, rightExclusive.end), (5, 7));
      expect((rightGrows.start, rightGrows.end), (3, 7));
    });

    test('a decoration spanning the entire block keeps spanning it', () {
      final set = DecorationSet.of([Decoration.inline('b', 0, 5, spec: 'd')]);
      final result = edit(threeBlocks(), (t) => t.insertText(10, 'XX'));
      final d = set.map(result.mapping, result.changes).forBlock('b').single;
      expect((d.start, d.end), (0, 7));
      expect(coveredText(result.doc, d), 'brXXavo');
    });

    test(
        'an empty replace decoration (hide entirely) survives edits '
        'elsewhere untouched', () {
      final hidden =
          Decoration.replace('b', 0, 5, replacementLength: 0, spec: 'hidden');
      final set = DecorationSet.of([hidden]);
      final result = edit(threeBlocks(), (t) => t.insertText(2, 'XX'));
      final mapped = set.map(result.mapping, result.changes);
      expect(identical(mapped, set), isTrue);
      final d = mapped.forBlock('b').single;
      expect(d.replacementLength, 0);
      expect((d.start, d.end), (0, 5));
    });

    test('decorations for unknown block ids are carried inert', () {
      final set = DecorationSet.of([Decoration.inline('zzz', 0, 3)]);
      final result = edit(threeBlocks(), (t) => t.insertText(2, 'XX'));
      expect(identical(set.map(result.mapping, result.changes), set), isTrue);
    });
  });

  group('composition and sharing', () {
    test(
        'mapping through a composed multi-transaction Mapping equals '
        'mapping through each transaction sequentially', () {
      final doc0 = threeBlocks();
      final set = DecorationSet.of([
        Decoration.inline('a', 1, 3, spec: 'inA'),
        Decoration.replace('b', 1, 4, replacementLength: 0, spec: 'inB'),
        Decoration.widget('c', 2, spec: 'inC'),
      ]);
      final first = edit(doc0, (t) => t.insertText(9, 'XX'));
      final second = edit(first.doc, (t) => t.joinBlocks(7));

      final sequential = set
          .map(first.mapping, first.changes)
          .map(second.mapping, second.changes);

      final composedMapping = Mapping()
        ..appendMapping(first.mapping)
        ..appendMapping(second.mapping);
      final composedChanges = ChangeList.compute(doc0, second.doc, [
        ...first.changes.structural,
        ...second.changes.structural,
      ]);
      final composed = set.map(composedMapping, composedChanges);

      expect(dumpSet(composed), dumpSet(sequential));
      // Both paths carried the untouched c shard by reference.
      expect(identical(sequential.forBlock('c'), set.forBlock('c')), isTrue);
      expect(identical(composed.forBlock('c'), set.forBlock('c')), isTrue);
    });

    test('untouched shards are reference-identical after map', () {
      final set = DecorationSet.of([
        Decoration.inline('a', 1, 3, spec: 'inA'),
        Decoration.inline('b', 1, 4, spec: 'inB'),
        Decoration.widget('c', 2, spec: 'inC'),
      ]);
      final result = edit(threeBlocks(), (t) => t.insertText(8, 'XX'));
      final mapped = set.map(result.mapping, result.changes);
      expect(identical(mapped, set), isFalse);
      final d = mapped.forBlock('b').single;
      expect((d.start, d.end), (3, 6));
      expect(identical(mapped.forBlock('a'), set.forBlock('a')), isTrue);
      expect(identical(mapped.forBlock('c'), set.forBlock('c')), isTrue);
    });
  });
}
