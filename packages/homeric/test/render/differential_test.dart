// The differential guard (R5, HOM-4's named risk): for each decorated
// corpus block, a baseline block is constructed whose DOCUMENT TEXT EQUALS
// THE DECORATED BLOCK'S DERIVED VIEW TEXT (identity ViewMap, no
// decorations). Decorated-render geometry at every document offset must
// equal the baseline's geometry at the ViewMap-mapped offset — a caret or
// selection bug introduced by the doc<->view translation has nowhere to
// hide, because the baseline never does that translation at all.
//
// Slot fixtures use a fixed one-em (14x14) chip in the decorated render:
// under the FlutterTest font (every code point — including U+FFFC — is a
// 1em square glyph), a 14x14 middle-aligned placeholder box is
// pixel-identical to the box a literal U+FFFC character would occupy in
// the baseline's plain-text rendering, so the two renders are directly
// comparable without teaching the baseline about slots at all.

import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

import '../transform/transform_test_utils.dart';

const TextStyle style14 = TextStyle(fontSize: 14);

Widget emChip(SlotSegment<TextStyle> slot) => const SizedBox(
    width: 14, height: 14, child: ColoredBox(color: Color(0xFF00A000)));

/// Pumps a decorated render and its baseline (document text == decorated
/// view text, no decorations) as siblings, and returns both render
/// objects.
Future<(RenderHomericParagraph decorated, RenderHomericParagraph baseline)>
    pumpPair(
  WidgetTester tester, {
  required ParagraphSource<TextStyle> decoratedSource,
  SlotWidgetBuilder? decoratedSlotBuilder,
  double width = 300,
}) async {
  const decoratedKey = Key('decorated');
  const baselineKey = Key('baseline');
  final baselineSource = ParagraphSource.build(
    block: para('base', decoratedSource.viewText),
    decorations: const <Decoration>[],
    resolveStyle: (_) => style14,
  );
  await tester.pumpWidget(Directionality(
    textDirection: TextDirection.ltr,
    child: Align(
      alignment: Alignment.topLeft,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: width,
            child: HomericParagraph(
              key: decoratedKey,
              source: decoratedSource,
              slotBuilder: decoratedSlotBuilder,
            ),
          ),
          SizedBox(
            width: width,
            child: HomericParagraph(key: baselineKey, source: baselineSource),
          ),
        ],
      ),
    ),
  ));
  return (
    tester.renderObject<RenderHomericParagraph>(find.byKey(decoratedKey)),
    tester.renderObject<RenderHomericParagraph>(find.byKey(baselineKey)),
  );
}

bool _rectsEqual(Rect a, Rect b) => a == b;

/// Merges adjacent same-direction, same-vertical-band boxes that touch
/// (`a.right == b.left`) into one box spanning both.
///
/// A placeholder is always its own run in the engine, so a decorated
/// paragraph containing a slot fragments a selection into more `TextBox`es
/// than an otherwise-identical plain-text baseline would for the same
/// visual span (the baseline's uniform-style run merges into one box; the
/// decorated run cannot merge across an embedded placeholder). That
/// fragmentation is *correct* engine behavior — `rectsForRange`'s contract
/// is "never naively merged" — not a translation bug, so the differential
/// compares fragment lists after normalizing away exactly this
/// placeholder-shaped difference: same total coverage, same per-fragment
/// direction, regardless of how many pieces either side's rendering
/// happened to split it into. A genuine geometry bug (a shifted or
/// misdirected box) still fails this comparison — normalization only
/// merges boxes that already agree on position and direction.
List<ui.TextBox> _normalizeBoxes(List<ui.TextBox> boxes) {
  final sorted = [...boxes]..sort((a, b) {
      final byTop = a.top.compareTo(b.top);
      return byTop != 0 ? byTop : a.left.compareTo(b.left);
    });
  final merged = <ui.TextBox>[];
  for (final box in sorted) {
    if (merged.isNotEmpty) {
      final last = merged.last;
      if (last.top == box.top &&
          last.bottom == box.bottom &&
          last.direction == box.direction &&
          last.right == box.left) {
        merged[merged.length - 1] = ui.TextBox.fromLTRBD(
            last.left, last.top, box.right, box.bottom, box.direction);
        continue;
      }
    }
    merged.add(box);
  }
  return merged;
}

bool _boxesEqual(List<ui.TextBox> rawA, List<ui.TextBox> rawB) {
  final a = _normalizeBoxes(rawA);
  final b = _normalizeBoxes(rawB);
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    final x = a[i], y = b[i];
    if (x.left != y.left ||
        x.top != y.top ||
        x.right != y.right ||
        x.bottom != y.bottom ||
        x.direction != y.direction) {
      return false;
    }
  }
  return true;
}

/// Checks caretRect(d, assoc) on [decorated] equals the baseline's caret
/// rect at `viewMap.docToView(d, assoc)`, for every doc offset and both
/// associations. Returns false (rather than throwing) so the mutation test
/// can assert this comes back false for a corrupted map, proving the
/// check has teeth.
bool caretsMatch(
  RenderHomericParagraph decorated,
  RenderHomericParagraph baseline,
  ViewMap viewMap,
) {
  final decoratedGeometry = ParagraphGeometry(decorated);
  final baselineGeometry = ParagraphGeometry(baseline);
  final docLength = decoratedGeometry.docLength;
  for (var d = 0; d <= docLength; d++) {
    for (final assoc in const [-1, 1]) {
      final decoratedRect =
          decoratedGeometry.caretRect(DocOffset(d), assoc: assoc).value;
      final view = viewMap.docToView(d, assoc: assoc);
      try {
        final baselineRect =
            baselineGeometry.caretRect(DocOffset(view), assoc: assoc).value;
        if (!_rectsEqual(decoratedRect, baselineRect)) return false;
      } on Error {
        return false;
      }
    }
  }
  return true;
}

/// Checks rectsForRange over `[a, b)` on [decorated] equals the baseline's
/// rects for the mapped view range, over [ranges] plus the full-document
/// range and every adjacent single-unit range.
bool rangesMatch(
  RenderHomericParagraph decorated,
  RenderHomericParagraph baseline,
  ViewMap viewMap, {
  List<(int, int)> extraRanges = const [],
}) {
  final decoratedGeometry = ParagraphGeometry(decorated);
  final baselineGeometry = ParagraphGeometry(baseline);
  final docLength = decoratedGeometry.docLength;
  final ranges = <(int, int)>[
    (0, docLength),
    for (var d = 0; d < docLength; d++) (d, d + 1),
    ...extraRanges,
  ];
  for (final (a, b) in ranges) {
    final decoratedBoxes = decoratedGeometry
        .rectsForRange(DocRange(DocOffset(a), DocOffset(b)))
        .value;
    final viewStart = viewMap.docToView(a, assoc: 1);
    final viewEnd = viewMap.docToView(b, assoc: -1);
    try {
      final baselineBoxes = viewEnd <= viewStart
          ? const <ui.TextBox>[]
          : baselineGeometry
              .rectsForRange(DocRange(DocOffset(viewStart), DocOffset(viewEnd)))
              .value;
      if (!_boxesEqual(decoratedBoxes, baselineBoxes)) return false;
    } on Error {
      return false;
    }
  }
  return true;
}

/// A deterministic lexicon-based paragraph generator mirroring
/// `tools/corpus/generate.dart`'s approach (same idea, reimplemented
/// locally so this test has no file-system dependency on generated
/// output): a fixed lexicon and a seeded PRNG, so the same seed always
/// produces the same paragraph.
String corpusParagraph(int seed, int sentences) {
  const lexicon = [
    'the',
    'and',
    'a',
    'of',
    'to',
    'in',
    'it',
    'is',
    'that',
    'with',
    'on',
    'for',
    'as',
    'by',
    'draft',
    'chapter',
    'section',
    'idea',
    'sentence',
    'paragraph',
    'thought',
    'plot',
    'character',
    'scene',
    'editor',
    'writer',
    'reader',
    'manuscript',
    'narrative',
    'voice',
  ];
  final rng = Random(seed);
  final buffer = StringBuffer();
  for (var s = 0; s < sentences; s++) {
    final length = 4 + rng.nextInt(5);
    final words =
        List.generate(length, (_) => lexicon[rng.nextInt(lexicon.length)]);
    if (s > 0) buffer.write(' ');
    buffer.write(words.join(' '));
    buffer.write('.');
  }
  return buffer.toString();
}

void main() {
  group('four Nexus shapes', () {
    testWidgets('#1 hidden delimiters (**bold**)', (tester) async {
      final source = ParagraphSource.build(
        block: para('a', '**bold**'),
        decorations: [
          Decoration.replace('a', 0, 2, replacementLength: 0),
          Decoration.replace('a', 6, 8, replacementLength: 0),
        ],
        resolveStyle: (_) => style14,
      );
      final (decorated, baseline) =
          await pumpPair(tester, decoratedSource: source);
      expect(caretsMatch(decorated, baseline, source.viewMap), isTrue);
      expect(rangesMatch(decorated, baseline, source.viewMap), isTrue);
    });

    testWidgets('#2 aside replacement content (%%An aside%%)', (tester) async {
      final source = ParagraphSource.build(
        block: para('a', '%%An aside%%'),
        decorations: [
          Decoration.replace('a', 0, 12,
              replacementLength: 8, spec: const ReplacementText('An aside')),
        ],
        resolveStyle: (_) => style14,
      );
      final (decorated, baseline) =
          await pumpPair(tester, decoratedSource: source);
      expect(caretsMatch(decorated, baseline, source.viewMap), isTrue);
      expect(rangesMatch(decorated, baseline, source.viewMap), isTrue);
    });

    testWidgets('#3 multi-char anchor folds to a single slot', (tester) async {
      final source = ParagraphSource.build(
        block: para('a', 'x{{id}}y'),
        decorations: [
          Decoration.replace('a', 1, 7, replacementLength: 0),
          Decoration.widget('a', 1, spec: 'mention'),
        ],
        resolveStyle: (_) => style14,
      );
      final (decorated, baseline) = await pumpPair(
        tester,
        decoratedSource: source,
        decoratedSlotBuilder: emChip,
      );
      expect(caretsMatch(decorated, baseline, source.viewMap), isTrue);
      expect(rangesMatch(decorated, baseline, source.viewMap), isTrue);
    });

    testWidgets('#4 trailing footnote-marker-like slot at block end',
        (tester) async {
      final source = ParagraphSource.build(
        block: para('a', 'note'),
        decorations: [Decoration.widget('a', 4, spec: 'fn')],
        resolveStyle: (_) => style14,
      );
      final (decorated, baseline) = await pumpPair(
        tester,
        decoratedSource: source,
        decoratedSlotBuilder: emChip,
      );
      expect(caretsMatch(decorated, baseline, source.viewMap), isTrue);
      expect(rangesMatch(decorated, baseline, source.viewMap), isTrue);
    });
  });

  group('wrapped lines', () {
    testWidgets('hidden delimiters across a forced wrap', (tester) async {
      final source = ParagraphSource.build(
        block: para('a', '**aaaa** bbbb cccc'),
        decorations: [
          Decoration.replace('a', 0, 2, replacementLength: 0),
          Decoration.replace('a', 6, 8, replacementLength: 0),
        ],
        resolveStyle: (_) => style14,
      );
      // viewText 'aaaa bbbb cccc' at width 70 wraps across 3 lines.
      final (decorated, baseline) =
          await pumpPair(tester, decoratedSource: source, width: 70);
      expect(decorated.layoutParagraph.numberOfLines, greaterThan(1));
      expect(caretsMatch(decorated, baseline, source.viewMap), isTrue);
      expect(rangesMatch(decorated, baseline, source.viewMap), isTrue);
    });
  });

  group('slots inside a wrap', () {
    testWidgets('a slot near a wrap boundary', (tester) async {
      final source = ParagraphSource.build(
        block: para('a', 'aaaa bb'),
        decorations: [Decoration.widget('a', 7, spec: 'chip')],
        resolveStyle: (_) => style14,
      );
      final (decorated, baseline) = await pumpPair(
        tester,
        decoratedSource: source,
        decoratedSlotBuilder: emChip,
        width: 70,
      );
      expect(decorated.layoutParagraph.numberOfLines, 2);
      expect(caretsMatch(decorated, baseline, source.viewMap), isTrue);
      expect(rangesMatch(decorated, baseline, source.viewMap), isTrue);
    });
  });

  group('tools/corpus-derived paragraphs', () {
    testWidgets('seed 1: two hidden words + a widget marker', (tester) async {
      final text = corpusParagraph(0xC0FFEE ^ 'seed1'.hashCode, 4);
      final firstSpace = text.indexOf(' ');
      final secondSpace = text.indexOf(' ', firstSpace + 1);
      final source = ParagraphSource.build(
        block: para('a', text),
        decorations: [
          // Hide the first word (as if it were markdown-wrapped) and mark
          // a footnote after the second word.
          Decoration.replace('a', 0, firstSpace, replacementLength: 0),
          Decoration.widget('a', secondSpace, spec: 'fn'),
        ],
        resolveStyle: (_) => style14,
      );
      final (decorated, baseline) = await pumpPair(
        tester,
        decoratedSource: source,
        decoratedSlotBuilder: emChip,
        width: 120,
      );
      expect(decorated.layoutParagraph.numberOfLines, greaterThan(1));
      expect(caretsMatch(decorated, baseline, source.viewMap), isTrue);
      expect(rangesMatch(decorated, baseline, source.viewMap), isTrue);
    });

    testWidgets('seed 2: an aside replacement inside a longer paragraph',
        (tester) async {
      final text = corpusParagraph(0xC0FFEE ^ 'seed2'.hashCode, 5);
      final source = ParagraphSource.build(
        block: para('a', text),
        decorations: [
          Decoration.replace('a', 0, 8,
              replacementLength: 3, spec: const ReplacementText('...')),
        ],
        resolveStyle: (_) => style14,
      );
      final (decorated, baseline) =
          await pumpPair(tester, decoratedSource: source, width: 140);
      expect(decorated.layoutParagraph.numberOfLines, greaterThan(1));
      expect(caretsMatch(decorated, baseline, source.viewMap), isTrue);
      expect(rangesMatch(decorated, baseline, source.viewMap), isTrue);
    });
  });

  group('mutation tooth: a corrupted ViewMap must fail the differential', () {
    testWidgets('perturbed triples desync caret geometry', (tester) async {
      final source = ParagraphSource.build(
        block: para('a', '**bold**'),
        decorations: [
          Decoration.replace('a', 0, 2, replacementLength: 0),
          Decoration.replace('a', 6, 8, replacementLength: 0),
        ],
        resolveStyle: (_) => style14,
      );
      final (decorated, baseline) =
          await pumpPair(tester, decoratedSource: source);

      // The real map: the guard passes.
      expect(caretsMatch(decorated, baseline, source.viewMap), isTrue);

      // A perturbed map (the leading fold shortened by one unit): the same
      // guard, fed the wrong translation, must catch the desync.
      final corrupted = ViewMap([0, 1, 0, 6, 2, 0]);
      expect(caretsMatch(decorated, baseline, corrupted), isFalse,
          reason: 'a corrupted ViewMap must desync at least one caret — '
              'if this ever passes, the differential guard has gone blind');
    });

    testWidgets('perturbed triples desync selection rects', (tester) async {
      final source = ParagraphSource.build(
        block: para('a', 'x{{id}}y'),
        decorations: [
          Decoration.replace('a', 1, 7, replacementLength: 0),
          Decoration.widget('a', 1, spec: 'mention'),
        ],
        resolveStyle: (_) => style14,
      );
      final (decorated, baseline) = await pumpPair(
        tester,
        decoratedSource: source,
        decoratedSlotBuilder: emChip,
      );
      expect(rangesMatch(decorated, baseline, source.viewMap), isTrue);

      final corrupted = ViewMap([1, 5, 1]); // anchor one unit too short.
      expect(rangesMatch(decorated, baseline, corrupted), isFalse);
    });
  });
}
