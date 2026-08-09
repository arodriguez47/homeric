// View text derivation: document text + decorations -> per-block view
// text with a bidirectional ViewMap.
//
// Offsets in these tests are block-LOCAL content offsets, matching
// Decoration's anchoring. The object replacement character U+FFFC is
// written as `ors` below for readability.

import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

import '../transform/transform_test_utils.dart';

const String ors = objectReplacementCharacter;

/// Expects two derivations to be indistinguishable.
void expectSameDerivation(DerivedViewText actual, DerivedViewText expected,
    {String? reason}) {
  expect(actual.viewText, expected.viewText, reason: reason);
  expect(actual.viewMap, expected.viewMap, reason: reason);
  expect(actual.styledRanges, expected.styledRanges, reason: reason);
  expect(actual.slots, expected.slots, reason: reason);
}

/// Derives every block of [doc] against [set], keyed by block id.
Map<String, DerivedViewText> deriveAll(Document doc, DecorationSet set) => {
      for (final block in doc.blocks)
        block.id: deriveViewText(block, set.forBlock(block.id)),
    };

Matcher throwsArgumentErrorMentioning(String fragment) => throwsA(
    isA<ArgumentError>().having((e) => '$e', 'message', contains(fragment)));

void main() {
  group('derivation basics', () {
    test('no decorations: view text is document text, identity map', () {
      final block = para('a', 'plain text');
      final derived = deriveViewText(block, const []);
      expect(derived.viewText, 'plain text');
      expect(derived.viewMap.isIdentity, isTrue);
      expect(derived.styledRanges, isEmpty);
      expect(derived.slots, isEmpty);
      for (var pos = 0; pos <= block.contentLength; pos++) {
        expect(derived.viewMap.docToView(pos), pos);
        expect(derived.viewMap.viewToDoc(pos), pos);
      }
    });

    test('empty block derives to empty view text', () {
      final derived = deriveViewText(para('a', ''), const []);
      expect(derived.viewText, '');
      expect(derived.viewMap.isIdentity, isTrue);
    });

    test('replace with content substitutes exactly replacementLength', () {
      final block = para('a', 'a[LONG]b');
      final derived = deriveViewText(block, [
        Decoration.replace('a', 1, 7,
            replacementLength: 3, spec: const ReplacementText('###')),
      ]);
      expect(derived.viewText, 'a###b');
      expect(derived.viewMap.triples, [1, 6, 3]);
      checkViewMapRoundTrip(derived.viewMap, block.contentLength);
    });

    test('inline decorations pass text through and may overlap', () {
      final block = para('a', 'overlap');
      final one = Decoration.inline('a', 0, 5, spec: 'one');
      final two = Decoration.inline('a', 3, 7, spec: 'two');
      final derived = deriveViewText(block, [two, one]);
      expect(derived.viewText, 'overlap');
      expect(derived.styledRanges, [
        StyledRange(0, 5, one),
        StyledRange(3, 7, two),
      ]);
    });
  });

  group('hidden delimiters (**bold**)', () {
    final block = para('a', '**bold**');
    final decorations = [
      Decoration.replace('a', 0, 2, replacementLength: 0),
      Decoration.replace('a', 6, 8, replacementLength: 0),
    ];

    test('view text is "bold" and the map is pinned', () {
      final derived = deriveViewText(block, decorations);
      expect(derived.viewText, 'bold');
      expect(derived.viewMap.triples, [0, 2, 0, 6, 2, 0]);
    });

    test('round-trip holds for every position outside the hidden spans', () {
      final derived = deriveViewText(block, decorations);
      checkViewMapRoundTrip(derived.viewMap, block.contentLength);
      // The visible positions, spelled out. View boundaries touching a
      // hidden span resolve to the assoc-chosen doc edge of that span.
      final map = derived.viewMap;
      expect([for (var p = 2; p <= 6; p++) map.docToView(p)], [0, 1, 2, 3, 4]);
      expect([for (var v = 0; v <= 4; v++) map.viewToDoc(v, assoc: 1)],
          [2, 3, 4, 5, 8]);
      expect([for (var v = 0; v <= 4; v++) map.viewToDoc(v, assoc: -1)],
          [0, 3, 4, 5, 6]);
    });

    test('positions inside hidden spans map to the visible edge', () {
      final map = deriveViewText(block, decorations).viewMap;
      for (final assoc in const [-1, 1]) {
        expect(map.docToView(1, assoc: assoc), 0,
            reason: 'inside leading delimiter');
        expect(map.docToView(7, assoc: assoc), 4,
            reason: 'inside trailing delimiter');
        expect(map.isInsideReplacedSpan(1), isTrue);
        expect(map.isInsideReplacedSpan(7), isTrue);
        expect(map.isInsideReplacedSpan(2), isFalse);
      }
    });

    test('assoc chooses the edge when the replacement has content', () {
      // 'x{{id}}y' with the anchor folded to a single slot character.
      final anchored = para('a', 'x{{id}}y');
      final map = deriveViewText(anchored, [
        Decoration.replace('a', 1, 7,
            replacementLength: 1, spec: const ReplacementText(ors)),
      ]).viewMap;
      expect(map.docToView(3, assoc: -1), 1,
          reason: 'caller chose the edge before the replacement');
      expect(map.docToView(3, assoc: 1), 2,
          reason: 'caller chose the edge after the replacement');
      expect(map.viewToDoc(1, assoc: -1), 1);
      expect(map.viewToDoc(1, assoc: 1), 1);
      expect(map.viewToDoc(2, assoc: -1), 7);
    });
  });

  group('widget slots', () {
    test('a widget injects exactly one U+FFFC slot', () {
      final block = para('a', 'hello');
      final widget = Decoration.widget('a', 2, spec: 'w');
      final derived = deriveViewText(block, [widget]);
      expect(derived.viewText, 'he${ors}llo');
      expect(derived.viewText.length, block.contentLength + 1);
      expect(derived.slots, [ViewSlot(2, widget)]);
      expect(derived.viewMap.triples, [2, 0, 1]);
      checkViewMapRoundTrip(derived.viewMap, block.contentLength);
    });

    test('a widget at the block end lands after all text', () {
      final block = para('a', 'fin');
      final widget = Decoration.widget('a', 3, spec: 'w');
      final derived = deriveViewText(block, [widget]);
      expect(derived.viewText, 'fin$ors');
      expect(derived.slots, [ViewSlot(3, widget)]);
    });

    test('a widget in an empty block is the whole view text', () {
      final widget = Decoration.widget('a', 0, spec: 'w');
      final derived = deriveViewText(para('a', ''), [widget]);
      expect(derived.viewText, ors);
      expect(derived.slots, [ViewSlot(0, widget)]);
    });

    test('widgets at the same position keep insertion order', () {
      final block = para('a', 'ab');
      final first = Decoration.widget('a', 1, spec: 'first');
      final second = Decoration.widget('a', 1, spec: 'second');
      final derived = deriveViewText(block, [first, second]);
      expect(derived.viewText, 'a$ors${ors}b');
      expect(derived.slots, [ViewSlot(1, first), ViewSlot(2, second)]);
      final swapped = deriveViewText(block, [second, first]);
      expect(swapped.slots, [ViewSlot(1, second), ViewSlot(2, first)]);
    });

    test('a widget strictly inside a replaced span is hidden with it', () {
      final block = para('a', 'abcdef');
      final derived = deriveViewText(block, [
        Decoration.replace('a', 1, 4, replacementLength: 0),
        Decoration.widget('a', 2, spec: 'hidden'),
      ]);
      expect(derived.viewText, 'aef');
      expect(derived.slots, isEmpty);
      expect(derived.viewMap.triples, [1, 3, 0]);
    });

    test('widgets at replaced-span boundaries flank the replacement', () {
      final block = para('a', 'abcdef');
      final before = Decoration.widget('a', 2, spec: 'before');
      final after = Decoration.widget('a', 4, spec: 'after');
      final derived = deriveViewText(block, [
        after,
        before,
        Decoration.replace('a', 2, 4,
            replacementLength: 1, spec: const ReplacementText('X')),
      ]);
      expect(derived.viewText, 'ab${ors}X${ors}ef');
      expect(derived.slots, [ViewSlot(2, before), ViewSlot(4, after)]);
      checkViewMapRoundTrip(derived.viewMap, block.contentLength);
    });
  });

  group('nexus workaround proofs', () {
    test('(a) hidden markdown delimiters render without the delimiters', () {
      final block = para('a', '**bold** and __marked__');
      final derived = deriveViewText(block, [
        Decoration.replace('a', 0, 2, replacementLength: 0),
        Decoration.replace('a', 6, 8, replacementLength: 0),
        Decoration.replace('a', 13, 15, replacementLength: 0),
        Decoration.replace('a', 21, 23, replacementLength: 0),
      ]);
      expect(derived.viewText, 'bold and marked');
      checkViewMapRoundTrip(derived.viewMap, block.contentLength);
    });

    test('(b) inline aside: ++content++ replaced with its content', () {
      final block = para('a', '++hidden thought++');
      final aside = Decoration.replace('a', 0, 18,
          replacementLength: 14, spec: const ReplacementText('hidden thought'));
      final style = Decoration.inline('a', 0, 18, spec: 'aside-style');
      final derived = deriveViewText(block, [aside, style]);
      expect(derived.viewText, 'hidden thought');
      // The covering inline range styles the replacement content.
      expect(derived.styledRanges, [StyledRange(0, 14, style)]);
      checkViewMapRoundTrip(derived.viewMap, block.contentLength);
    });

    test('(c) multi-char anchor folds to a single slot character', () {
      final block = para('a', 'see {{anchor-42}} here');
      final derived = deriveViewText(block, [
        Decoration.replace('a', 4, 17,
            replacementLength: 1, spec: const ReplacementText(ors)),
      ]);
      expect(derived.viewText, 'see $ors here');
      expect(derived.viewText.length, 10);
      checkViewMapRoundTrip(derived.viewMap, block.contentLength);
    });

    test(
        '(d) footnote marker occupies one widget slot with stable '
        'identity', () {
      final marker = Object();
      final block = para('a', 'A cited fact.');
      final widget = Decoration.widget('a', 13, spec: marker);
      final derived = deriveViewText(block, [widget]);
      expect(derived.viewText, 'A cited fact.$ors');
      expect(derived.slots, hasLength(1));
      expect(identical(derived.slots.single.decoration.spec, marker), isTrue,
          reason: 'the slot carries the marker spec as its identity');
      final map = derived.viewMap;
      expect(map.docToView(13, assoc: -1), 13,
          reason: 'caret can sit before the marker');
      expect(map.docToView(13, assoc: 1), 14,
          reason: 'caret can sit after the marker');
    });
  });

  group('edge cases', () {
    test('replace-to-empty at block start and end', () {
      final block = para('a', 'hello');
      final atStart = deriveViewText(block, [
        Decoration.replace('a', 0, 2, replacementLength: 0),
      ]);
      expect(atStart.viewText, 'llo');
      checkViewMapRoundTrip(atStart.viewMap, block.contentLength);
      final atEnd = deriveViewText(block, [
        Decoration.replace('a', 3, 5, replacementLength: 0),
      ]);
      expect(atEnd.viewText, 'hel');
      checkViewMapRoundTrip(atEnd.viewMap, block.contentLength);
    });

    test('two adjacent replace decorations', () {
      final block = para('a', 'abcdef');
      final derived = deriveViewText(block, [
        Decoration.replace('a', 1, 3, replacementLength: 0),
        Decoration.replace('a', 3, 5, replacementLength: 0),
      ]);
      expect(derived.viewText, 'af');
      expect(derived.viewMap.triples, [1, 4, 0],
          reason: 'doc-adjacent hidden spans canonicalize into one');
      checkViewMapRoundTrip(derived.viewMap, block.contentLength);
      expect(derived.viewMap.isInsideReplacedSpan(3), isTrue,
          reason: 'the shared boundary has no view identity of its own');
      expect(derived.viewMap.docToView(3, assoc: -1), 1);
      expect(derived.viewMap.docToView(3, assoc: 1), 1);
    });

    test('a widget followed by an adjacent hidden span keeps the law', () {
      final block = para('a', 'abcdef');
      final widget = Decoration.widget('a', 3, spec: 'w');
      final derived = deriveViewText(block, [
        widget,
        Decoration.replace('a', 3, 5, replacementLength: 0),
      ]);
      expect(derived.viewText, 'abc${ors}f');
      expect(derived.viewMap.triples, [3, 2, 1],
          reason: 'the view-collapsed span is absorbed into the slot span');
      expect(derived.slots, [ViewSlot(3, widget)]);
      checkViewMapRoundTrip(derived.viewMap, block.contentLength);
    });

    test('replace covering the whole block yields empty view text', () {
      final block = para('a', 'gone');
      final derived = deriveViewText(block, [
        Decoration.replace('a', 0, 4, replacementLength: 0),
      ]);
      expect(derived.viewText, '');
      checkViewMapRoundTrip(derived.viewMap, block.contentLength);
    });

    test('zero-length replace inserts pure view content', () {
      final block = para('a', 'ab');
      final derived = deriveViewText(block, [
        Decoration.replace('a', 1, 1,
            replacementLength: 2, spec: const ReplacementText('--')),
      ]);
      expect(derived.viewText, 'a--b');
      checkViewMapRoundTrip(derived.viewMap, block.contentLength);
    });

    test(
        'inline range overlapping a replace boundary clips to visible '
        'text', () {
      final block = para('a', '**bold** tail');
      final style = Decoration.inline('a', 1, 6, spec: 's');
      final derived = deriveViewText(block, [
        Decoration.replace('a', 0, 2, replacementLength: 0),
        Decoration.replace('a', 6, 8, replacementLength: 0),
        style,
      ]);
      expect(derived.viewText, 'bold tail');
      // Doc [1, 6) covers half the leading delimiter plus 'bold'; the
      // visible part is view [0, 4).
      expect(derived.styledRanges, [StyledRange(0, 4, style)]);
    });

    test('inline range entirely inside a hidden span is omitted', () {
      final block = para('a', 'a**b');
      final derived = deriveViewText(block, [
        Decoration.replace('a', 1, 3, replacementLength: 0),
        Decoration.inline('a', 1, 3, spec: 'invisible'),
        Decoration.inline('a', 2, 2, spec: 'collapsed'),
      ]);
      expect(derived.viewText, 'ab');
      expect(derived.styledRanges, isEmpty);
    });

    test('overlapping replace decorations are a consumer bug', () {
      final block = para('a', 'abcdef');
      expect(
        () => deriveViewText(block, [
          Decoration.replace('a', 0, 4, replacementLength: 0),
          Decoration.replace('a', 2, 6, replacementLength: 0),
        ]),
        throwsArgumentErrorMentioning('block "a"'),
      );
      expect(
        () => deriveViewText(block, [
          Decoration.replace('a', 2, 6, replacementLength: 0),
          Decoration.replace('a', 0, 4, replacementLength: 0),
        ]),
        throwsArgumentErrorMentioning('[0, 4) and [2, 6)'),
        reason: 'validation is order-independent',
      );
    });

    test('replacement payload contract failures are loud', () {
      final block = para('a', 'abcdef');
      expect(
        () => deriveViewText(block, [
          Decoration.replace('a', 0, 3, replacementLength: 2, spec: 'nope'),
        ]),
        throwsArgumentErrorMentioning('ReplacementContent'),
      );
      expect(
        () => deriveViewText(block, [
          Decoration.replace('a', 0, 3,
              replacementLength: 2, spec: const ReplacementText('three')),
        ]),
        throwsArgumentErrorMentioning('replacementLength 2'),
      );
    });

    test('hiding replaces never read their spec', () {
      final block = para('a', '**b**');
      final derived = deriveViewText(block, [
        Decoration.replace('a', 0, 2,
            replacementLength: 0, spec: 'the original delimiter **'),
      ]);
      expect(derived.viewText, 'b**');
    });

    test('foreign or out-of-range decorations are rejected', () {
      final block = para('a', 'abc');
      expect(
        () => deriveViewText(block, [Decoration.inline('b', 0, 1)]),
        throwsArgumentErrorMentioning('anchored to block "b"'),
      );
      expect(
        () => deriveViewText(
            block, [Decoration.replace('a', 0, 9, replacementLength: 0)]),
        throwsArgumentErrorMentioning('content length 3'),
      );
    });
  });

  group('determinism', () {
    final fixtureBlock = para('a', '**bold** ((anchor)) ++aside++ end');
    List<Decoration> fixtureDecorations() => [
          Decoration.replace('a', 0, 2, replacementLength: 0),
          Decoration.replace('a', 6, 8, replacementLength: 0),
          Decoration.replace('a', 9, 19,
              replacementLength: 1, spec: const ReplacementText(ors)),
          Decoration.replace('a', 20, 29,
              replacementLength: 5, spec: const ReplacementText('aside')),
          Decoration.widget('a', 33, spec: 'footnote'),
          Decoration.inline('a', 30, 33, spec: 'end-style'),
          Decoration.inline('a', 4, 10, spec: 'clipped'),
        ];

    test('the fixture derivation is pinned', () {
      final derived = deriveViewText(fixtureBlock, fixtureDecorations());
      expect(derived.viewText, 'bold $ors aside end$ors');
      expect(derived.viewMap.triples,
          [0, 2, 0, 6, 2, 0, 9, 10, 1, 20, 9, 5, 33, 0, 1]);
      expect(derived.slots, hasLength(1));
      expect(derived.slots.single.viewOffset, 16);
      expect(
          derived.styledRanges.map((r) => [r.start, r.end, r.decoration.spec]),
          [
            [2, 5, 'clipped'],
            [13, 16, 'end-style'],
          ]);
      checkViewMapRoundTrip(derived.viewMap, fixtureBlock.contentLength);
    });

    test('same inputs, identical outputs', () {
      final first = deriveViewText(fixtureBlock, fixtureDecorations());
      final second = deriveViewText(fixtureBlock, fixtureDecorations());
      expectSameDerivation(second, first);
    });
  });

  group('incremental == full', () {
    (Document, DecorationSet) fixture() {
      final doc = Document([
        para('a', '**bold** text'),
        para('b', 'bravo'),
        para('c', 'see ((note))'),
      ]);
      final set = DecorationSet.of([
        Decoration.replace('a', 0, 2, replacementLength: 0),
        Decoration.replace('a', 6, 8, replacementLength: 0),
        Decoration.inline('b', 1, 4, spec: 'b-style'),
        Decoration.replace('c', 4, 12,
            replacementLength: 1, spec: const ReplacementText(ors)),
        Decoration.widget('c', 3, spec: 'c-slot'),
      ]);
      return (doc, set);
    }

    /// Re-derives only ChangeList-touched blocks on top of [previous] and
    /// expects the result to match a from-scratch derivation of the new
    /// state, block for block.
    void expectIncrementalMatchesFull(
      Map<String, DerivedViewText> previous,
      TransactionResult result,
      DecorationSet mapped,
    ) {
      final incremental = Map<String, DerivedViewText>.of(previous);
      for (final change in result.changes.changes) {
        if (change.isRemoved) {
          incremental.remove(change.blockId);
        } else {
          final block = result.doc.blockById(change.blockId)!;
          incremental[change.blockId] =
              deriveViewText(block, mapped.forBlock(change.blockId));
        }
      }
      final full = deriveAll(result.doc, mapped);
      expect(incremental.keys.toSet(), full.keys.toSet());
      for (final id in full.keys) {
        expectSameDerivation(incremental[id]!, full[id]!, reason: 'block $id');
      }
    }

    test('text edits in decorated blocks', () {
      final (doc, set) = fixture();
      final previous = deriveAll(doc, set);
      final txn = Transaction(doc);
      // Block a content is [1, 14): insert after '**bold**' and at the
      // start of block c's content ([23, 35)).
      txn.insertText(9, 'X');
      txn.insertText(24, 'Z');
      final result = txn.finish();
      final mapped = set.map(result.mapping, result.changes);
      // The prefix/suffix diff reports every block between the two edit
      // points (including b); a and c are the ones that actually changed.
      expect(result.changes.touchedBlockIds, containsAll(['a', 'c']));
      expectIncrementalMatchesFull(previous, result, mapped);
    });

    test('structural edit: splitting a decorated block', () {
      final (doc, set) = fixture();
      final previous = deriveAll(doc, set);
      final txn = Transaction(doc);
      // Split block a between '**bold**' and ' text' (content offset 8).
      txn.splitBlock(9, trailingBlockId: 'a2');
      final result = txn.finish();
      final mapped = set.map(result.mapping, result.changes);
      expectIncrementalMatchesFull(previous, result, mapped);
      final a = result.doc.blockById('a')!;
      expect(deriveViewText(a, mapped.forBlock('a')).viewText, 'bold');
    });
  });

  group('round-trip helper', () {
    test('accepts the identity map and rejects bad lengths', () {
      checkViewMapRoundTrip(ViewMap.identity, 10);
      expect(() => checkViewMapRoundTrip(ViewMap.identity, -1),
          throwsArgumentError);
    });

    test('ViewMap equality follows its triples', () {
      expect(ViewMap(const [1, 2, 0]), ViewMap(const [1, 2, 0]));
      expect(
          ViewMap(const [1, 2, 0]).hashCode, ViewMap(const [1, 2, 0]).hashCode);
      expect(ViewMap(const [1, 2, 0]), isNot(ViewMap(const [1, 2, 1])));
      expect(ViewMap.identity, ViewMap(const []));
    });
  });
}
