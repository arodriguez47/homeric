// ParagraphGeometry (U4): the document-coordinate geometry service.
//
// FlutterTest font metrics (pinned by the U2/U3 suites and reused here):
// every glyph — including U+FFFC and non-Latin code points, since the test
// font maps every code point to the same square glyph — is a 1em box; at
// fontSize 14 a glyph is 14px wide, a line is 14.0 tall, the alphabetic
// baseline sits at 10.5.

import 'package:flutter/widgets.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

import 'render_test_utils.dart';

/// A fixed one-em chip: sized so its placeholder box is pixel-identical to
/// the box a literal 1-code-unit glyph would occupy in the FlutterTest font
/// at the same style — the differential guard's "fixed-size chips in both
/// renders" trick (see differential_test.dart).
Widget emChip({Key? key, double em = 14}) => SizedBox(
      key: key,
      width: em,
      height: em,
      child: const ColoredBox(color: Color(0xFF00A000)),
    );

void main() {
  group('caret rect: plain text (happy path)', () {
    testWidgets('matches hand-computed FlutterTest metrics at every offset',
        (tester) async {
      final source = sourceOf('abc');
      await tester.pumpWidget(harness(HomericParagraph(source: source)));
      final geometry = ParagraphGeometry(renderOf(tester));

      // 3 glyphs of 14px each: offsets 0..3 sit at x = 0, 14, 28, 42.
      for (var i = 0; i <= 3; i++) {
        final rect = geometry.caretRect(DocOffset(i)).value;
        expect(rect.left, i * 14.0, reason: 'offset $i');
        expect(rect.right, i * 14.0, reason: 'offset $i is a zero-width rect');
        expect(rect.top, 0);
        expect(rect.bottom, 14);
      }
    });

    testWidgets(
        'upstream assoc at an interior offset anchors the same glyph '
        'edge as downstream for plain text', (tester) async {
      // With no folded content, assoc only matters for wrap-affinity, so
      // for a single-line paragraph both assocs land on the same edge.
      final source = sourceOf('abc');
      await tester.pumpWidget(harness(HomericParagraph(source: source)));
      final geometry = ParagraphGeometry(renderOf(tester));
      expect(geometry.caretRect(const DocOffset(2), assoc: -1).value.left, 28);
      expect(geometry.caretRect(const DocOffset(2), assoc: 1).value.left, 28);
    });
  });

  group('caret rect: hidden-run offsets (test-first, HOM-4\'s named risk)', () {
    // '**bold**' with both delimiter pairs hidden: viewText 'bold',
    // viewMap triples [0, 2, 0, 6, 2, 0] (doc offsets 0-2 and 6-8 fold to
    // nothing).
    ParagraphSource<TextStyle> hiddenSource() => sourceOf(
          '**bold**',
          decorations: [
            Decoration.replace('b', 0, 2, replacementLength: 0),
            Decoration.replace('b', 6, 8, replacementLength: 0),
          ],
        );

    testWidgets(
        'doc offset inside the leading hidden run lands on the '
        'assoc-chosen visible edge', (tester) async {
      await tester
          .pumpWidget(harness(HomericParagraph(source: hiddenSource())));
      final geometry = ParagraphGeometry(renderOf(tester));

      // Doc offset 1 is strictly inside [0, 2): assoc -1 -> view 0 (before
      // 'bold'), assoc 1 -> view 0 as well, since the fold's only visible
      // edge on this side is the very start of 'bold' (view offset 0 for
      // both, because doc offset 0 is the fold's left edge and doc offset
      // 2 is its right edge -- both map to view 0). Use a doc offset that
      // actually distinguishes the two: the trailing hidden run at [6, 8).
      final view = hiddenSource().viewMap;
      expect(view.docToView(1, assoc: -1), 0);
      expect(view.docToView(1, assoc: 1), 0);
      // Both land at the start of 'bold': the caret rect agrees.
      expect(geometry.caretRect(const DocOffset(1), assoc: -1).value.left, 0);
      expect(geometry.caretRect(const DocOffset(1), assoc: 1).value.left, 0);
    });

    testWidgets(
        'doc offset inside the trailing hidden run: assoc chooses '
        'before/after "bold"', (tester) async {
      await tester
          .pumpWidget(harness(HomericParagraph(source: hiddenSource())));
      final geometry = ParagraphGeometry(renderOf(tester));
      final view = hiddenSource().viewMap;
      expect(view.docToView(7, assoc: -1), 4, reason: 'edge before the fold');
      expect(view.docToView(7, assoc: 1), 4,
          reason: 'edge after the fold (end of doc content)');

      // Doc offset 7 sits inside the trailing "**" (doc [6, 8)); both
      // edges of *this* fold map to view offset 4 (end of 'bold') because
      // there is no more visible content after it. The caret rect is
      // therefore identical for both associations: right after 'd'.
      final before = geometry.caretRect(const DocOffset(7), assoc: -1).value;
      final after = geometry.caretRect(const DocOffset(7), assoc: 1).value;
      expect(before.left, 4 * 14.0);
      expect(after.left, 4 * 14.0);
    });

    testWidgets(
        'doc offset exactly between two visible runs picks the correct '
        'side per assoc', (tester) async {
      // 'a**b**c' hides only the leading '**' of the middle run so doc
      // offset 3 (the boundary right after the hidden '**' or, viewed the
      // other way, the boundary that separates 'a' from the hidden run)
      // has two genuinely different visible neighbors on either side.
      final source = sourceOf(
        'a**bc',
        decorations: [Decoration.replace('b', 1, 3, replacementLength: 0)],
      );
      expect(source.viewText, 'abc');
      await tester.pumpWidget(harness(HomericParagraph(source: source)));
      final geometry = ParagraphGeometry(renderOf(tester));

      // Doc offset 1 is the fold's left edge (view 1, "after 'a'") for
      // both assocs; doc offset 3 is the fold's right edge (view 1,
      // "before 'b'") for both. A doc offset strictly inside, e.g. 2,
      // must choose: assoc -1 -> the edge before the fold (view 1, right
      // after 'a'); assoc 1 -> the edge after the fold (view 1 as well,
      // since there is no view content in between). Use the round-trip
      // instead: caret at doc 0 (before 'a') vs doc 3 (right before 'b')
      // must differ.
      expect(geometry.caretRect(const DocOffset(0)).value.left, 0);
      expect(geometry.caretRect(const DocOffset(3)).value.left, 14);
      expect(geometry.caretRect(const DocOffset(5)).value.left, 3 * 14.0);
    });
  });

  group('line boundary affinity through docToView (test-first, wrap risk)', () {
    // 'aaaa bbbb' at width 70 wraps exactly at the space (line 1: 'aaaa ',
    // line 2: 'bbbb' — established by U2's own characterization test).
    // View offset 5 (right after the space, start of 'bbbb') sits exactly
    // at the wrap point.
    testWidgets(
        'a doc offset at the wrap point resolves to the correct line per '
        'assoc', (tester) async {
      final source = sourceOf('aaaa bbbb');
      await tester
          .pumpWidget(harness(HomericParagraph(source: source), width: 70));
      final render = renderOf(tester);
      expect(render.layoutParagraph.numberOfLines, 2);
      final geometry = ParagraphGeometry(render);

      // Doc/view offsets coincide (no decorations): offset 5 is the wrap
      // point. assoc -1 (upstream: stays with line 1's content) must
      // return line 1's range; assoc 1 (downstream: moves onto line 2)
      // must return line 2's range.
      final upstream =
          geometry.lineBoundaryAt(const DocOffset(5), assoc: -1).value;
      final downstream =
          geometry.lineBoundaryAt(const DocOffset(5), assoc: 1).value;
      expect(upstream, DocRange(const DocOffset(0), const DocOffset(5)),
          reason: 'upstream at the wrap point stays on line 1');
      expect(downstream, DocRange(const DocOffset(5), const DocOffset(9)),
          reason: 'downstream at the wrap point moves to line 2');
    });

    testWidgets('line boundary maps back through a hidden run correctly',
        (tester) async {
      // Hide the space so the doc-side wrap point is a folded position:
      // '**bold** wraps' with the delimiters hidden.
      final source = sourceOf(
        '**bold** and more',
        decorations: [
          Decoration.replace('b', 0, 2, replacementLength: 0),
          Decoration.replace('b', 6, 8, replacementLength: 0),
        ],
      );
      expect(source.viewText, 'bold and more');
      await tester
          .pumpWidget(harness(HomericParagraph(source: source), width: 200));
      final render = renderOf(tester);
      final geometry = ParagraphGeometry(render);
      final result = geometry.lineBoundaryAt(const DocOffset(0)).value;
      // Single line (200px is wide enough): the whole doc range maps back,
      // including the hidden delimiters at both ends (the expand
      // convention — see `_docRangeOf`).
      expect(result.start, const DocOffset(0));
      expect(result.end, DocOffset(geometry.docLength));
    });
  });

  group('caret rect: slots', () {
    testWidgets('caret at a slot boundary sits at the placeholder edge',
        (tester) async {
      final source = sourceOf(
        'ab',
        decorations: [Decoration.widget('b', 1, spec: 'chip')],
      );
      await tester.pumpWidget(harness(HomericParagraph(
        source: source,
        slotBuilder: (_) => emChip(),
      )));
      final geometry = ParagraphGeometry(renderOf(tester));
      // viewText 'a￼b': slot occupies view [1, 2). A widget anchor is a
      // pure insertion (oldLen 0), so unlike a replaced span's boundary,
      // assoc genuinely chooses before vs. after the slot (mirrors
      // ViewMap's own footnote-marker example: "caret can sit before/
      // after the marker").
      expect(geometry.caretRect(const DocOffset(1), assoc: -1).value.left, 14,
          reason: 'before the slot, right after "a"');
      expect(geometry.caretRect(const DocOffset(1), assoc: 1).value.left, 28,
          reason: 'after the slot, right before "b"');
    });
  });

  group('caret rect: empty block', () {
    testWidgets('falls back to preferredLineHeight/Baseline', (tester) async {
      final source = sourceOf(
        'abcd',
        decorations: [Decoration.replace('b', 0, 4, replacementLength: 0)],
      );
      await tester.pumpWidget(harness(HomericParagraph(source: source)));
      final render = renderOf(tester);
      final geometry = ParagraphGeometry(render);
      final rect = geometry.caretRect(const DocOffset(2)).value;
      expect(rect.top, 0);
      expect(rect.bottom, render.preferredLineHeight);
      expect(rect.bottom, 14);
      expect(rect.left, 0, reason: 'ltr start-aligned empty block');
    });
  });

  group('caret rect: trailing whitespace is a real caret slot', () {
    testWidgets(
        'caret at the end sits after trailing spaces, not at line.width',
        (tester) async {
      // FlutterTest: every glyph including space is a 14px box, but
      // `line.width` still excludes trailing whitespace (28 for "hi   ").
      // TextPainter clamps to that; an editor caret must not, or typed
      // spaces are invisible until the next non-space key.
      final source = sourceOf('hi   ');
      await tester
          .pumpWidget(harness(HomericParagraph(source: source), width: 200));
      final render = renderOf(tester);
      final line = render.layoutParagraph.getLineMetricsAt(0)!;
      final geometry = ParagraphGeometry(render);
      final afterHi = geometry.caretRect(const DocOffset(2)).value;
      final end = geometry.caretRect(const DocOffset(5)).value;

      expect(line.width, 28,
          reason: 'engine still reports content width without the spaces');
      expect(afterHi.left, 28);
      expect(end.left, 70,
          reason: 'MUTATION: clamping the end caret to line.width snaps '
              'it back onto the last non-space glyph, so three typed '
              'spaces never move the caret');
    });
  });

  group('rects for range: gapless selection across a wrap', () {
    testWidgets('adjacent line rects touch with includeLineSpacingMiddle',
        (tester) async {
      final source = sourceOf('aaaa bbbb');
      await tester
          .pumpWidget(harness(HomericParagraph(source: source), width: 70));
      final geometry = ParagraphGeometry(renderOf(tester));
      final boxes = geometry
          .rectsForRange(DocRange(const DocOffset(0), const DocOffset(9)))
          .value;
      expect(boxes, hasLength(2));
      expect(boxes[0].bottom, boxes[1].top,
          reason: 'gapless: line 1 bottom meets line 2 top');
    });
  });

  group('rects for range: RTL run inside an LTR block', () {
    testWidgets('bidi fragments keep their own per-fragment direction',
        (tester) async {
      // Hebrew "שלום" (4 letters) embedded in an LTR paragraph creates a
      // reordered RTL run — a real Unicode bidi case, independent of the
      // FlutterTest font's uniform glyph shapes.
      final source = sourceOf('ab שלום cd');
      await tester
          .pumpWidget(harness(HomericParagraph(source: source), width: 400));
      final geometry = ParagraphGeometry(renderOf(tester));
      final boxes = geometry
          .rectsForRange(
              DocRange(const DocOffset(0), DocOffset(source.viewText.length)))
          .value;
      final directions = boxes.map((b) => b.direction).toSet();
      expect(directions, contains(TextDirection.rtl),
          reason: 'the embedded Hebrew run must fragment out as its own '
              'rtl-direction box, never merged with the surrounding ltr text');
    });
  });

  group('doc position for a local point', () {
    testWidgets('resolves grapheme-aware, nearest edge', (tester) async {
      final source = sourceOf('abc');
      await tester.pumpWidget(harness(HomericParagraph(source: source)));
      final geometry = ParagraphGeometry(renderOf(tester));
      // Click on the left half of 'b' (glyph [14, 28)): lands before it.
      expect(geometry.positionForPoint(const Offset(16, 7)).value,
          const DocOffset(1));
      // Click on the right half of 'b': lands after it.
      expect(geometry.positionForPoint(const Offset(26, 7)).value,
          const DocOffset(2));
    });

    testWidgets(
        'a point over view-only content resolves to the nearest '
        'doc position, never a phantom one', (tester) async {
      final source = sourceOf(
        'x{{id}}y',
        decorations: [
          Decoration.replace('b', 1, 7, replacementLength: 0),
          Decoration.widget('b', 1, spec: 'mention'),
        ],
      );
      expect(source.viewText, 'x￼y');
      await tester.pumpWidget(harness(HomericParagraph(
        source: source,
        slotBuilder: (_) => emChip(),
      )));
      final geometry = ParagraphGeometry(renderOf(tester));
      // A point squarely inside the slot's box (view [14, 28)) resolves to
      // one of the anchor's two real doc edges (1 or 7), never an offset
      // "inside" the hidden anchor.
      final left = geometry.positionForPoint(const Offset(16, 7)).value;
      final right = geometry.positionForPoint(const Offset(26, 7)).value;
      expect({left.value, right.value}, {1, 7});
    });

    testWidgets('empty block falls back to doc offset zero', (tester) async {
      final source = sourceOf(
        'abcd',
        decorations: [Decoration.replace('b', 0, 4, replacementLength: 0)],
      );
      await tester.pumpWidget(harness(HomericParagraph(source: source)));
      final geometry = ParagraphGeometry(renderOf(tester));
      expect(geometry.positionForPoint(const Offset(5, 5)).value,
          const DocOffset(0));
    });
  });

  group('word boundary: view-space semantics', () {
    testWidgets(
        'a hidden delimiter inside a view word is included in the '
        'mapped doc range (documented residual)', (tester) async {
      // '**bold**' hidden -> view text 'bold' is a single UAX#29 word; the
      // whole doc span (including the hidden delimiters) must come back.
      final source = sourceOf(
        '**bold**',
        decorations: [
          Decoration.replace('b', 0, 2, replacementLength: 0),
          Decoration.replace('b', 6, 8, replacementLength: 0),
        ],
      );
      await tester.pumpWidget(harness(HomericParagraph(source: source)));
      final geometry = ParagraphGeometry(renderOf(tester));
      final range = geometry.wordBoundaryAt(const DocOffset(4)).value;
      expect(range, DocRange(const DocOffset(0), const DocOffset(8)));
    });
  });

  group('per-slot rect', () {
    testWidgets('by index and by spec identity', (tester) async {
      final source = sourceOf(
        'ab',
        decorations: [
          Decoration.widget('b', 1, spec: 'w1'),
          Decoration.widget('b', 1, spec: 'w2'),
        ],
      );
      await tester.pumpWidget(harness(HomericParagraph(
        source: source,
        slotBuilder: (slot) => emChip(em: slot.spec == 'w1' ? 14 : 20),
      )));
      final geometry = ParagraphGeometry(renderOf(tester));
      final first = geometry.slotRectAt(0).value;
      final second = geometry.slotRectForSpec('w2').value;
      expect(first.width, 14);
      expect(second.width, 20);
      expect(second.left, first.right);
    });

    testWidgets('unknown slot index/spec throws UnknownSlotError',
        (tester) async {
      final source = sourceOf(
        'ab',
        decorations: [Decoration.widget('b', 1, spec: 'w1')],
      );
      await tester.pumpWidget(harness(HomericParagraph(
        source: source,
        slotBuilder: (_) => emChip(),
      )));
      final geometry = ParagraphGeometry(renderOf(tester));
      expect(() => geometry.slotRectAt(5), throwsA(isA<UnknownSlotError>()));
      expect(() => geometry.slotRectForSpec('nope'),
          throwsA(isA<UnknownSlotError>()));
    });
  });

  group('block rect', () {
    testWidgets('is the paragraph\'s local bounding box', (tester) async {
      final source = sourceOf('aaaa bbbb');
      await tester
          .pumpWidget(harness(HomericParagraph(source: source), width: 70));
      final geometry = ParagraphGeometry(renderOf(tester));
      expect(geometry.blockRect.value, const Rect.fromLTWH(0, 0, 70, 28));
    });
  });

  group('out-of-range doc offset', () {
    testWidgets('throws DocOffsetOutOfRangeError', (tester) async {
      final source = sourceOf('abc');
      await tester.pumpWidget(harness(HomericParagraph(source: source)));
      final geometry = ParagraphGeometry(renderOf(tester));
      expect(() => geometry.caretRect(const DocOffset(-1)),
          throwsA(isA<DocOffsetOutOfRangeError>()));
      expect(() => geometry.caretRect(const DocOffset(4)),
          throwsA(isA<DocOffsetOutOfRangeError>()));
      expect(geometry.caretRect(const DocOffset(3)).value, isNotNull);
    });
  });

  group('stale generation', () {
    testWidgets('reading .value after a relayout asserts', (tester) async {
      final source = sourceOf('abc');
      await tester.pumpWidget(harness(HomericParagraph(source: source)));
      final render = renderOf(tester);
      final geometry = ParagraphGeometry(render);
      final result = geometry.caretRect(const DocOffset(1));
      expect(result.isStale, isFalse);

      await tester
          .pumpWidget(harness(HomericParagraph(source: sourceOf('help'))));
      expect(result.isStale, isTrue);
      expect(() => result.value, throwsAssertionError);
    });

    testWidgets(
        'querying a held instance after a relayout asserts, not just its '
        'results', (tester) async {
      final source = sourceOf('abc');
      await tester.pumpWidget(harness(HomericParagraph(source: source)));
      final render = renderOf(tester);
      final geometry = ParagraphGeometry(render);

      // Sanity: the instance is fully usable before the relayout, and its
      // per-instance caches (docLength, placeholder boxes) get populated.
      expect(geometry.docLength, 3);
      expect(geometry.caretRect(const DocOffset(1)).value, isNotNull);

      await tester
          .pumpWidget(harness(HomericParagraph(source: sourceOf('help'))));

      // The render object has relaid out under this held instance. Every
      // public query on it — not just a previously-returned
      // GeometryResult's .value — must fail loudly rather than silently
      // answering from the pre-relayout docLength/placeholder-box caches.
      expect(() => geometry.docLength, throwsAssertionError);
      expect(
          () => geometry.caretRect(const DocOffset(1)), throwsAssertionError);
      expect(() => geometry.blockRect, throwsAssertionError);
    });

    testWidgets(
        'a fresh instance constructed after the relayout works normally',
        (tester) async {
      final source = sourceOf('abc');
      await tester.pumpWidget(harness(HomericParagraph(source: source)));
      final render = renderOf(tester);
      final stale = ParagraphGeometry(render);
      expect(stale.docLength, 3);

      await tester
          .pumpWidget(harness(HomericParagraph(source: sourceOf('help'))));

      // The old instance is now stale...
      expect(() => stale.docLength, throwsAssertionError);

      // ...but a fresh instance constructed against the same (now
      // relaid-out) render object behaves exactly as if nothing unusual
      // happened.
      final fresh = ParagraphGeometry(render);
      expect(fresh.docLength, 4);
      expect(fresh.caretRect(const DocOffset(4)).value, isNotNull);
      expect(fresh.caretRect(const DocOffset(4)).isStale, isFalse);
    });
  });

  group('SelectableMixin adapter contract (seam-readiness proof)', () {
    testWidgets('every member is implementable purely from ParagraphGeometry',
        (tester) async {
      final source = sourceOf('abc');
      // Offset the harness so local (0,0) != global (0,0) — a meaningful
      // check of the global-in/local-out convention, not a coincidence of
      // both spaces sharing an origin.
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 50, top: 30),
            child:
                SizedBox(width: 200, child: HomericParagraph(source: source)),
          ),
        ),
      ));
      final render = renderOf(tester);
      final adapter = _SelectableAdapter(render);

      // start() / end().
      expect(adapter.start().offset, 0);
      expect(adapter.end().offset, 3);

      // getBlockRect().
      expect(adapter.getBlockRect(), const Rect.fromLTWH(0, 0, 200, 14));

      // localToGlobal: local origin lands at the padded global offset.
      final origin = adapter.localToGlobal(Offset.zero);
      expect(origin, const Offset(50, 30));

      // getPositionInOffset (global-in): a global point over the left half
      // of glyph 'b' ([14, 28) local) lands before it.
      expect(
          adapter.getPositionInOffset(origin + const Offset(16, 7)).offset, 1);

      // getCursorRectInPosition (the optional-with-default member Nexus
      // also exercises): matches geometry.caretRect directly.
      expect(adapter.getCursorRectInPosition(const _Position(1)),
          adapter.geometry.caretRect(const DocOffset(1)).value);

      // getRectsInSelection: matches geometry.rectsForRange directly,
      // local-out (no global translation on the way back).
      final rects = adapter
          .getRectsInSelection(const _Selection(_Position(0), _Position(3)));
      expect(
          rects,
          adapter.geometry
              .rectsForRange(DocRange(const DocOffset(0), const DocOffset(3)))
              .value
              .map((box) => box.toRect()));

      // getSelectionInRange (global-in twice): from just inside 'a' to
      // just past the right half of 'c'.
      final selection = adapter.getSelectionInRange(
          origin + const Offset(2, 7), origin + const Offset(38, 7));
      expect(selection.start.offset, 0);
      expect(selection.end.offset, 3);
    });
  });
}

/// Stands in for AppFlowy's `Position` — a document offset a caret or
/// selection endpoint sits at. Test-harness only, deliberately not part of
/// `lib/`: the actual type belongs to the Nexus companion plan.
class _Position {
  const _Position(this.offset);
  final int offset;
}

/// Stands in for AppFlowy's `Selection` — a pair of positions.
class _Selection {
  const _Selection(this.start, this.end);
  final _Position start;
  final _Position end;
}

/// A `SelectableMixin`-shaped adapter delegating every member to
/// [ParagraphGeometry] — the seam-readiness proof U4 owes HOM-4: each of
/// the seven no-default members (`getBlockRect`, `getSelectionInRange`,
/// `getRectsInSelection`, `getPositionInOffset`, `localToGlobal`,
/// `start()`, `end()`) plus the optional-with-default `
/// getCursorRectInPosition` is implementable purely in terms of this
/// file's public surface, honoring the global-in/local-out convention
/// AppFlowy's real mixin uses (queries that take a point take a *global*
/// one; every answer comes back in the render object's local space,
/// unless it is itself a global point being handed back out, as
/// [localToGlobal] does by construction).
///
/// This lives only in the test harness, mirroring the plan's instruction
/// that the adapter is proof, not product: the real implementation is the
/// Nexus companion plan's, against Nexus's actual `Position`/`Selection`
/// types.
class _SelectableAdapter {
  _SelectableAdapter(this._render) : geometry = ParagraphGeometry(_render);

  final RenderHomericParagraph _render;

  /// Exposed so tests can cross-check the adapter's answers directly
  /// against the geometry service it delegates to.
  final ParagraphGeometry geometry;

  Offset _toLocal(Offset global) => _render.globalToLocal(global);

  Offset localToGlobal(Offset local) => _render.localToGlobal(local);

  _Position start() => const _Position(0);

  _Position end() => _Position(geometry.docLength);

  Rect getBlockRect() => geometry.blockRect.value;

  Rect getCursorRectInPosition(_Position position) =>
      geometry.caretRect(DocOffset(position.offset)).value;

  _Position getPositionInOffset(Offset global) =>
      _Position(geometry.positionForPoint(_toLocal(global)).value.value);

  List<Rect> getRectsInSelection(_Selection selection) => geometry
      .rectsForRange(DocRange(
          DocOffset(selection.start.offset), DocOffset(selection.end.offset)))
      .value
      .map((box) => box.toRect())
      .toList();

  _Selection getSelectionInRange(Offset globalStart, Offset globalEnd) =>
      _Selection(
          getPositionInOffset(globalStart), getPositionInOffset(globalEnd));
}
