// ParagraphSource: block + decorations + reveal state + per-build style
// resolver -> ParagraphBuilder-ready segments, slots, and ViewMap.
//
// The object replacement character U+FFFC is written as `ors` for
// readability, matching the view-layer tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

import '../transform/transform_test_utils.dart';

const String ors = objectReplacementCharacter;

/// The reference resolver: joins the active decorations' specs, or
/// 'plain' for an undecorated run.
String tagStyle(RunStyleContext run) => run.decorations.isEmpty
    ? 'plain'
    : run.decorations.map((d) => d.spec).join('+');

Matcher textSegment(int viewStart, String text, Object? style) =>
    isA<TextSegment<String>>()
        .having((s) => s.viewStart, 'viewStart', viewStart)
        .having((s) => s.viewEnd, 'viewEnd', viewStart + text.length)
        .having((s) => s.text, 'text', text)
        .having((s) => s.style, 'style', style);

Matcher slotSegment(int viewOffset, int slotIndex, Object? spec) =>
    isA<SlotSegment<String>>()
        .having((s) => s.viewOffset, 'viewOffset', viewOffset)
        .having((s) => s.slotIndex, 'slotIndex', slotIndex)
        .having((s) => s.spec, 'spec', same(spec))
        .having((s) => s.viewEnd, 'viewEnd', viewOffset + 1);

/// Segments must be contiguous, gap-free, and concatenate to the view
/// text (slots contributing exactly one U+FFFC unit).
void expectCoversViewText(ParagraphSource<String> source) {
  var offset = 0;
  final buffer = StringBuffer();
  for (final segment in source.segments) {
    expect(segment.viewStart, offset,
        reason: 'segments must be contiguous: $segment');
    switch (segment) {
      case TextSegment(:final text):
        expect(text, isNotEmpty, reason: 'text segments are never empty');
        buffer.write(text);
      case SlotSegment():
        buffer.write(ors);
    }
    offset = segment.viewEnd;
  }
  expect(buffer.toString(), source.viewText);
  expect(offset, source.viewText.length);
}

void main() {
  group('hidden delimiters (**bold**)', () {
    final block = para('a', '**bold**');
    final lead = Decoration.replace('a', 0, 2, replacementLength: 0);
    final trail = Decoration.replace('a', 6, 8, replacementLength: 0);
    final bold = Decoration.inline('a', 2, 6, spec: 'bold');

    test('segments spell "bold" with the bold-styled range', () {
      final source = ParagraphSource.build(
        block: block,
        decorations: [lead, trail, bold],
        resolveStyle: tagStyle,
      );
      expect(source.viewText, 'bold');
      expect(source.segments, [textSegment(0, 'bold', 'bold')]);
      expect(source.slots, isEmpty);
      expect(source.viewMap.triples, [0, 2, 0, 6, 2, 0]);
      expectCoversViewText(source);
    });

    test('reveal on: delimiters present, styled range follows', () {
      final source = ParagraphSource.build(
        block: block,
        decorations: [lead, trail, bold],
        reveal: RevealState.of([lead, trail]),
        resolveStyle: tagStyle,
      );
      expect(source.viewText, '**bold**');
      expect(source.viewMap.isIdentity, isTrue);
      expect(source.segments, [
        textSegment(0, '**', 'plain'),
        textSegment(2, 'bold', 'bold'),
        textSegment(6, '**', 'plain'),
      ]);
      expectCoversViewText(source);
    });

    test('partial reveal suppresses only the revealed decoration', () {
      final source = ParagraphSource.build(
        block: block,
        decorations: [lead, trail, bold],
        reveal: RevealState.of([lead]),
        resolveStyle: tagStyle,
      );
      expect(source.viewText, '**bold');
      expect(source.viewMap.triples, [6, 2, 0]);
      expect(source.segments, [
        textSegment(0, '**', 'plain'),
        textSegment(2, 'bold', 'bold'),
      ]);
    });

    test('reveal membership of non-replace decorations is ignored', () {
      final source = ParagraphSource.build(
        block: block,
        decorations: [lead, trail, bold],
        reveal: RevealState.of([bold]),
        resolveStyle: tagStyle,
      );
      expect(source.viewText, 'bold');
      expect(source.segments, [textSegment(0, 'bold', 'bold')]);
      expect(RevealState.none.revealsNothing, isTrue);
      expect(RevealState.of(const []).revealsNothing, isTrue);
      expect(RevealState.of([lead]).isRevealed(lead), isTrue);
      expect(RevealState.of([lead]).isRevealed(trail), isFalse);
    });
  });

  group('widget slots', () {
    test('one slot yields exactly one descriptor at the view offset', () {
      final chip = Decoration.widget('a', 2, spec: 'chip');
      final source = ParagraphSource.build(
        block: para('a', 'hello'),
        decorations: [chip],
        resolveStyle: tagStyle,
      );
      expect(source.viewText, 'he${ors}llo');
      expect(source.slots, [slotSegment(2, 0, 'chip')]);
      expect(source.segments, [
        textSegment(0, 'he', 'plain'),
        slotSegment(2, 0, 'chip'),
        textSegment(3, 'llo', 'plain'),
      ]);
      expect(source.slots.single, same(source.segments[1]));
      expect(source.viewMap.triples, [2, 0, 1]);
      expectCoversViewText(source);
    });

    test('styled ranges clip around a slot', () {
      final em = Decoration.inline('a', 1, 4, spec: 'em');
      final chip = Decoration.widget('a', 2, spec: 'chip');
      final source = ParagraphSource.build(
        block: para('a', 'hello'),
        decorations: [em, chip],
        resolveStyle: tagStyle,
      );
      expect(source.viewText, 'he${ors}llo');
      expect(source.segments, [
        textSegment(0, 'h', 'plain'),
        textSegment(1, 'e', 'em'),
        slotSegment(2, 0, 'chip'),
        textSegment(3, 'll', 'em'),
        textSegment(5, 'o', 'plain'),
      ]);
      expectCoversViewText(source);
    });

    test('two slots get consecutive slot indexes in view order', () {
      final first = Decoration.widget('a', 1, spec: 'w1');
      final second = Decoration.widget('a', 3, spec: 'w2');
      final source = ParagraphSource.build(
        block: para('a', 'abcd'),
        decorations: [second, first],
        resolveStyle: tagStyle,
      );
      expect(source.viewText, 'a${ors}bc${ors}d');
      expect(source.slots, [
        slotSegment(1, 0, 'w1'),
        slotSegment(4, 1, 'w2'),
      ]);
      expectCoversViewText(source);
    });

    test('adjacent slots at one offset keep insertion order', () {
      final first = Decoration.widget('a', 2, spec: 'w1');
      final second = Decoration.widget('a', 2, spec: 'w2');
      final source = ParagraphSource.build(
        block: para('a', 'abcd'),
        decorations: [first, second],
        resolveStyle: tagStyle,
      );
      expect(source.viewText, 'ab$ors${ors}cd');
      expect(source.segments, [
        textSegment(0, 'ab', 'plain'),
        slotSegment(2, 0, 'w1'),
        slotSegment(3, 1, 'w2'),
        textSegment(4, 'cd', 'plain'),
      ]);
      expectCoversViewText(source);
    });
  });

  group('edge cases', () {
    test('empty block: no segments, resolver never called', () {
      var calls = 0;
      final source = ParagraphSource.build(
        block: para('a', ''),
        decorations: const [],
        resolveStyle: (run) {
          calls++;
          return 'never';
        },
      );
      expect(source.viewText, '');
      expect(source.segments, isEmpty);
      expect(source.slots, isEmpty);
      expect(source.viewMap.isIdentity, isTrue);
      expect(calls, 0);
    });

    test('whole-block replace hides everything', () {
      var calls = 0;
      final source = ParagraphSource.build(
        block: para('a', 'secret'),
        decorations: [Decoration.replace('a', 0, 6, replacementLength: 0)],
        resolveStyle: (run) {
          calls++;
          return 'never';
        },
      );
      expect(source.viewText, '');
      expect(source.segments, isEmpty);
      expect(source.viewMap.triples, [0, 6, 0]);
      expect(calls, 0);
    });

    test('whole-block replace with content yields one run', () {
      final source = ParagraphSource.build(
        block: para('a', 'secret'),
        decorations: [
          Decoration.replace('a', 0, 6,
              replacementLength: 4, spec: const ReplacementText('####')),
        ],
        resolveStyle: tagStyle,
      );
      expect(source.viewText, '####');
      expect(source.segments, [textSegment(0, '####', 'plain')]);
      expect(source.viewMap.triples, [0, 6, 4]);
      expectCoversViewText(source);
    });

    test('adjacent hidden replaces fold into contiguous text', () {
      final source = ParagraphSource.build(
        block: para('a', 'abXXYYcd'),
        decorations: [
          Decoration.replace('a', 2, 4, replacementLength: 0),
          Decoration.replace('a', 4, 6, replacementLength: 0),
        ],
        resolveStyle: tagStyle,
      );
      expect(source.viewText, 'abcd');
      expect(source.segments, [textSegment(0, 'abcd', 'plain')]);
      // The ViewMap canonicalizes the seam into a single folded span.
      expect(source.viewMap.triples, [2, 4, 0]);
      expectCoversViewText(source);
    });

    test('adjacent replaces with content keep both spans', () {
      final source = ParagraphSource.build(
        block: para('a', 'abXXYYcd'),
        decorations: [
          Decoration.replace('a', 2, 4,
              replacementLength: 1, spec: const ReplacementText('-')),
          Decoration.replace('a', 4, 6,
              replacementLength: 1, spec: const ReplacementText('+')),
        ],
        resolveStyle: tagStyle,
      );
      expect(source.viewText, 'ab-+cd');
      expect(source.segments, [textSegment(0, 'ab-+cd', 'plain')]);
      expect(source.viewMap.triples, [2, 2, 1, 4, 2, 1]);
      expectCoversViewText(source);
    });
  });

  group('style resolver contract (R7)', () {
    final block = para('a', 'abcdef');
    final one = Decoration.inline('a', 0, 4, spec: 'one');
    final two = Decoration.inline('a', 2, 6, spec: 'two');

    test('called exactly once per run per derivation', () {
      final calls = <String>[];
      final source = ParagraphSource.build(
        block: block,
        decorations: [one, two],
        resolveStyle: (run) {
          calls.add('${run.viewStart}-${run.viewEnd}');
          return tagStyle(run);
        },
      );
      expect(calls, ['0-2', '2-4', '4-6']);
      expect(source.segments, [
        textSegment(0, 'ab', 'one'),
        textSegment(2, 'cd', 'one+two'),
        textSegment(4, 'ef', 'two'),
      ]);
    });

    test('never cached across builds: each build re-resolves', () {
      var calls = 0;
      ParagraphSource<String> build() => ParagraphSource.build(
            block: block,
            decorations: [one, two],
            resolveStyle: (run) {
              calls++;
              return tagStyle(run);
            },
          );
      final first = build();
      expect(calls, 3);
      final second = build();
      expect(calls, 6, reason: 'second build must re-resolve every run');
      expect(second.segments, first.segments);
    });

    test(
        'several overlapping ranges produce the same active set per cut '
        'as the reference full-rescan filter (sweep-line regression)', () {
      final block = para('a', 'abcdefgh');
      final r1 = Decoration.inline('a', 0, 5, spec: 'r1');
      final r2 = Decoration.inline('a', 1, 6, spec: 'r2');
      final r3 = Decoration.inline('a', 2, 4, spec: 'r3');
      final r4 = Decoration.inline('a', 3, 8, spec: 'r4');
      final r5 = Decoration.inline('a', 6, 7, spec: 'r5');
      final decorations = [r1, r2, r3, r4, r5];
      final source = ParagraphSource.build(
        block: block,
        decorations: decorations,
        resolveStyle: tagStyle,
      );
      // Reference: recompute each cut's active set by brute-force
      // rescanning, exactly as the pre-sweep-line implementation did.
      final derived = deriveViewText(block, decorations);
      final cuts = <int>{0, derived.viewText.length};
      for (final range in derived.styledRanges) {
        cuts.add(range.start);
        cuts.add(range.end);
      }
      final bounds = cuts.toList()..sort();
      final expected = <(int, int, String)>[];
      for (var i = 0; i + 1 < bounds.length; i++) {
        final start = bounds[i];
        final end = bounds[i + 1];
        final activeSpecs = [
          for (final range in derived.styledRanges)
            if (range.start <= start && end <= range.end) range.decoration.spec,
        ];
        final style = activeSpecs.isEmpty ? 'plain' : activeSpecs.join('+');
        expected.add((start, end, style));
      }
      expect(source.segments.length, expected.length);
      for (var i = 0; i < expected.length; i++) {
        final actual = source.segments[i] as TextSegment<String>;
        final (start, end, style) = expected[i];
        expect(actual.viewStart, start, reason: 'segment $i');
        expect(actual.viewEnd, end, reason: 'segment $i');
        expect(actual.style, style, reason: 'segment $i');
      }
      expectCoversViewText(source);
    });

    test("a build picks up the resolver's current theme", () {
      var theme = 'day';
      ParagraphSource<String> build() => ParagraphSource.build(
            block: block,
            decorations: const [],
            resolveStyle: (run) => theme,
          );
      expect(build().segments, [textSegment(0, 'abcdef', 'day')]);
      theme = 'night';
      expect(build().segments, [textSegment(0, 'abcdef', 'night')],
          reason: 'styles are resolved at call time, never captured');
    });
  });

  group('determinism', () {
    test('same inputs produce deep-equal outputs', () {
      final block = para('a', 'x**bold**y{{id}}z');
      final decorations = [
        Decoration.replace('a', 1, 3, replacementLength: 0),
        Decoration.replace('a', 7, 9, replacementLength: 0),
        Decoration.inline('a', 3, 7, spec: 'bold'),
        Decoration.replace('a', 10, 16, replacementLength: 0),
        Decoration.widget('a', 10, spec: 'mention'),
        Decoration.inline('a', 0, 17, spec: 'body'),
      ];
      const spec = BlockParagraphSpec(
          direction: ParagraphDirection.rtl, lineHeight: 1.5);
      ParagraphSource<String> build() => ParagraphSource.build(
            block: block,
            decorations: decorations,
            resolveStyle: tagStyle,
            spec: spec,
          );
      final first = build();
      final second = build();
      expect(second.viewText, first.viewText);
      expect(second.segments, first.segments);
      expect(second.slots, first.slots);
      expect(second.viewMap, first.viewMap);
      expect(second.spec, first.spec);
      expect(second.spec, spec);
      expectCoversViewText(first);
    });
  });

  group('Nexus workaround shapes (pinned)', () {
    test('#1 hidden delimiters', () {
      final source = ParagraphSource.build(
        block: para('a', '**bold**'),
        decorations: [
          Decoration.replace('a', 0, 2, replacementLength: 0),
          Decoration.replace('a', 6, 8, replacementLength: 0),
        ],
        resolveStyle: tagStyle,
      );
      expect(source.viewText, 'bold');
      expect(source.viewMap.triples, [0, 2, 0, 6, 2, 0]);
      expect(source.segments, [textSegment(0, 'bold', 'plain')]);
    });

    test('#2 aside replacement content', () {
      final source = ParagraphSource.build(
        block: para('a', '%%An aside%%'),
        decorations: [
          Decoration.replace('a', 0, 12,
              replacementLength: 8, spec: const ReplacementText('An aside')),
        ],
        resolveStyle: tagStyle,
      );
      expect(source.viewText, 'An aside');
      expect(source.viewMap.triples, [0, 12, 8]);
      expect(source.segments, [textSegment(0, 'An aside', 'plain')]);
    });

    test('#3 multi-char anchor folds to a single slot', () {
      final source = ParagraphSource.build(
        block: para('a', 'x{{id}}y'),
        decorations: [
          Decoration.replace('a', 1, 7, replacementLength: 0),
          Decoration.widget('a', 1, spec: 'mention'),
        ],
        resolveStyle: tagStyle,
      );
      expect(source.viewText, 'x${ors}y');
      expect(source.slots, [slotSegment(1, 0, 'mention')]);
      expect(source.segments, [
        textSegment(0, 'x', 'plain'),
        slotSegment(1, 0, 'mention'),
        textSegment(2, 'y', 'plain'),
      ]);
      expect(source.viewMap.triples, [1, 6, 1]);
      // Doc offsets inside the anchor land on the slot's visible edges.
      expect(source.viewMap.docToView(4, assoc: -1), 1);
      expect(source.viewMap.docToView(4, assoc: 1), 2);
      expectCoversViewText(source);
    });

    test('#4 trailing footnote-marker-like slot at block end', () {
      final source = ParagraphSource.build(
        block: para('a', 'note'),
        decorations: [Decoration.widget('a', 4, spec: 'fn')],
        resolveStyle: tagStyle,
      );
      expect(source.viewText, 'note$ors');
      expect(source.slots, [slotSegment(4, 0, 'fn')]);
      expect(source.segments, [
        textSegment(0, 'note', 'plain'),
        slotSegment(4, 0, 'fn'),
      ]);
      expect(source.viewMap.triples, [4, 0, 1]);
      expectCoversViewText(source);
    });
  });
}
