// Semantics (U6): screen readers get **document** text, not view text —
// hidden delimiters never enter the accessibility label, and widget
// slots participate via child semantics at the correct reading
// position (R6).
//
// "Document text" resolved concretely against this repo's real model
// (verified against `paragraph_source_test.dart`'s Nexus-workaround
// fixtures, not guessed): `Block.text` stores markdown syntax
// literally — `para('a', '**bold**')` is a block whose content is the
// eight raw characters `**bold**`. A `replace` decoration with
// `replacementLength: 0` (a hidden delimiter) folds those characters
// out of view text; `RevealState.of([...])` un-folds them back in for
// editing. The label must track the reveal-*invariant* derivation
// (delimiters always folded) even while the render object's `source`
// paints a reveal-*sensitive* one — that's the whole point of
// `semanticsSource` (see its doc on `RenderHomericParagraph`). A real
// (non-hiding) `replace` decoration's substituted text — e.g. an aside
// marker's `ReplacementContent` — is not reveal-sensitive at all and
// already reads as ordinary prose in either derivation (Nexus
// workaround #2, `paragraph_source_test.dart`).
//
// These are platform-independent SemanticsTester assertions
// (`matchesSemantics`), standing in for the VoiceOver manual check the
// plan calls for.

import 'package:flutter/widgets.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

import '../transform/transform_test_utils.dart';

const TextStyle style14 = TextStyle(fontSize: 14);

Block textBlock(String text) =>
    Block(id: 'b', type: 'paragraph', runs: [InlineRun(text)]);

ParagraphSource<TextStyle> sourceOf(
  String text, {
  TextStyle style = style14,
  Iterable<Decoration> decorations = const <Decoration>[],
  RevealState reveal = RevealState.none,
  BlockParagraphSpec spec = const BlockParagraphSpec(),
}) {
  return ParagraphSource.build(
    block: textBlock(text),
    decorations: decorations,
    reveal: reveal,
    resolveStyle: (_) => style,
    spec: spec,
  );
}

/// A reveal-invariant semantics-only derivation: same block and
/// decorations as a paint-time [sourceOf] call, but always with
/// `RevealState.none` regardless of what the paint source used — the
/// documented contract of [RenderHomericParagraph.semanticsSource].
/// Style is irrelevant to the label, so the resolver returns nothing.
ParagraphSource<Object?> semanticsOf(
  Block block, {
  Iterable<Decoration> decorations = const <Decoration>[],
  BlockParagraphSpec spec = const BlockParagraphSpec(),
}) {
  return ParagraphSource.build(
    block: block,
    decorations: decorations,
    resolveStyle: (_) => null,
    spec: spec,
  );
}

/// Pumps [paragraph] inside a top-left aligned box of [width].
Widget harness(Widget paragraph, {double width = 200}) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: width, child: paragraph),
    ),
  );
}

/// A hit-testable, labeled chip standing in for a real inline widget
/// (e.g. a mention or footnote marker) — its own `Semantics` annotation
/// is what the paragraph's semantics delegate must surface at the right
/// reading position.
Widget chip(String label, {Key? key}) {
  return Semantics(
    label: label,
    child: SizedBox(key: key, width: 20, height: 10),
  );
}

/// A spy [RenderHomericParagraph] that counts [markNeedsSemanticsUpdate]
/// calls, so "fires on content change, not on paint-only change" (R6)
/// is checked directly rather than inferred from tree side effects.
class _SpyRenderHomericParagraph extends RenderHomericParagraph {
  _SpyRenderHomericParagraph({
    required super.source,
    super.paintStyler,
    super.semanticsSource,
  });

  int semanticsUpdateCount = 0;

  @override
  void markNeedsSemanticsUpdate() {
    semanticsUpdateCount += 1;
    super.markNeedsSemanticsUpdate();
  }
}

/// The [HomericParagraph] wrapper for [_SpyRenderHomericParagraph]:
/// [HomericParagraph.createRenderObject] hard-codes the plain render
/// class, so the spy needs its own creation site. [updateRenderObject]
/// is inherited unchanged — it only calls property setters, which work
/// identically on the subclass.
class _SpyHomericParagraph extends HomericParagraph {
  // A fixed, non-null textScaler sidesteps HomericParagraph's ambient
  // MediaQuery fallback: createRenderObject (overridden below, so it
  // cannot reach the library-private resolver) and the inherited
  // updateRenderObject must agree on the resolved value, or the mere
  // act of updating would spuriously relayout and confound this test's
  // dirty-tracking counts with an unrelated textScaler "change".
  _SpyHomericParagraph({
    required super.source,
    required this.captured,
    super.paintStyler,
    super.semanticsSource,
  }) : super(textScaler: TextScaler.noScaling);

  final List<_SpyRenderHomericParagraph> captured;

  @override
  RenderHomericParagraph createRenderObject(BuildContext context) {
    final render = _SpyRenderHomericParagraph(
      source: source,
      paintStyler: paintStyler,
      semanticsSource: semanticsSource,
    );
    captured.add(render);
    return render;
  }
}

void main() {
  group('document text label (R6)', () {
    testWidgets('**bold** with hidden delimiters: label is exactly "bold"',
        (tester) async {
      final handle = tester.ensureSemantics();
      final source = sourceOf(
        '**bold**',
        decorations: [
          Decoration.replace('b', 0, 2, replacementLength: 0),
          Decoration.replace('b', 6, 8, replacementLength: 0),
          Decoration.inline('b', 2, 6, spec: 'bold'),
        ],
      );
      expect(source.viewText, 'bold', reason: 'sanity: view text folds too');

      await tester.pumpWidget(harness(HomericParagraph(source: source)));
      expect(
        tester.getSemantics(find.byType(HomericParagraph)),
        matchesSemantics(label: 'bold', textDirection: TextDirection.ltr),
      );
      handle.dispose();
    });

    testWidgets(
        'reveal on for paint does not flicker the label (document text, '
        'not view text)', (tester) async {
      final handle = tester.ensureSemantics();
      final block = textBlock('**bold**');
      final lead = Decoration.replace('b', 0, 2, replacementLength: 0);
      final trail = Decoration.replace('b', 6, 8, replacementLength: 0);
      final bold = Decoration.inline('b', 2, 6, spec: 'bold');
      final paintSource = ParagraphSource.build(
        block: block,
        decorations: [lead, trail, bold],
        reveal: RevealState.of([lead, trail]),
        resolveStyle: (_) => style14,
      );
      // The paint source really does show the raw delimiters — reveal
      // is a real view-text effect, not a no-op.
      expect(paintSource.viewText, '**bold**');

      final semantics = semanticsOf(block, decorations: [lead, trail, bold]);
      await tester.pumpWidget(harness(HomericParagraph(
        source: paintSource,
        semanticsSource: semantics,
      )));

      expect(
        tester.getSemantics(find.byType(HomericParagraph)),
        matchesSemantics(label: 'bold', textDirection: TextDirection.ltr),
        reason: 'semantics must reflect document semantics, not the '
            'reveal-on view currently being painted',
      );
      handle.dispose();
    });

    testWidgets(
        'without an explicit semanticsSource, source doubles as the '
        'semantics derivation (documented fallback)', (tester) async {
      final handle = tester.ensureSemantics();
      final lead = Decoration.replace('b', 0, 2, replacementLength: 0);
      final trail = Decoration.replace('b', 6, 8, replacementLength: 0);
      final revealedSource = sourceOf(
        '**bold**',
        decorations: [lead, trail, Decoration.inline('b', 2, 6)],
        reveal: RevealState.of([lead, trail]),
      );

      await tester
          .pumpWidget(harness(HomericParagraph(source: revealedSource)));
      expect(
        tester.getSemantics(find.byType(HomericParagraph)),
        matchesSemantics(label: '**bold**', textDirection: TextDirection.ltr),
        reason: 'no semanticsSource supplied: the render object has only '
            "source's (reveal-on) text to work with — callers that use "
            'reveal must supply a reveal-invariant semanticsSource',
      );
      handle.dispose();
    });

    testWidgets(
        'real replacement content (e.g. an aside marker) reads as prose — '
        'never vanishes, never leaks raw delimiters', (tester) async {
      final handle = tester.ensureSemantics();
      final block = textBlock('%%An aside%%');
      final source = ParagraphSource.build(
        block: block,
        decorations: [
          Decoration.replace('b', 0, 12,
              replacementLength: 8, spec: const ReplacementText('An aside')),
        ],
        resolveStyle: (_) => style14,
      );
      expect(source.viewText, 'An aside');

      await tester.pumpWidget(harness(HomericParagraph(source: source)));
      expect(
        tester.getSemantics(find.byType(HomericParagraph)),
        matchesSemantics(label: 'An aside', textDirection: TextDirection.ltr),
      );
      handle.dispose();
    });

    testWidgets('no text-field semantics flags — read-only static text',
        (tester) async {
      final handle = tester.ensureSemantics();
      final source = sourceOf('hello');
      await tester.pumpWidget(harness(HomericParagraph(source: source)));
      // matchesSemantics defaults every flag/action to false; matching
      // with only `label` set asserts every text-field-ish flag
      // (isTextField, isFocusable, hasSetTextAction, ...) is absent.
      expect(
        tester.getSemantics(find.byType(HomericParagraph)),
        matchesSemantics(label: 'hello', textDirection: TextDirection.ltr),
      );
      handle.dispose();
    });

    testWidgets('per-run semantics label override replaces the run\'s text',
        (tester) async {
      final handle = tester.ensureSemantics();
      final source = sourceOf('abc');
      await tester.pumpWidget(harness(HomericParagraph(
        source: source,
        semanticsLabelForRun: (text, start) =>
            text == 'abc' ? 'alphabet' : null,
      )));
      expect(
        tester.getSemantics(find.byType(HomericParagraph)),
        matchesSemantics(label: 'alphabet', textDirection: TextDirection.ltr),
      );
      handle.dispose();
    });
  });

  group('widget slots participate in reading order (U3 integration, R6)', () {
    testWidgets('a widget slot appears between the right text runs',
        (tester) async {
      final handle = tester.ensureSemantics();
      final source = sourceOf(
        'ab',
        decorations: [Decoration.widget('b', 1, spec: 'chip')],
      );
      expect(source.viewText, 'a${objectReplacementCharacter}b');

      await tester.pumpWidget(harness(HomericParagraph(
        source: source,
        slotBuilder: (_) => chip('mention'),
      )));

      final data = tester.getSemantics(find.byType(HomericParagraph));
      // One merged node: the widget's own label reads in between the
      // surrounding text runs, in view-text order — never before 'a'
      // nor after 'b', and the placeholder character itself never
      // appears as literal text.
      expect(data.label, 'a\nmention\nb');
      expect(data.label, isNot(contains(objectReplacementCharacter)));
      handle.dispose();
    });

    testWidgets('a block that is only a widget still gets a semantics node',
        (tester) async {
      final handle = tester.ensureSemantics();
      final source = ParagraphSource.build(
        block: Block(id: 'b', type: 'paragraph'),
        decorations: [Decoration.widget('b', 0, spec: 'chip')],
        resolveStyle: (_) => style14,
      );
      expect(source.segments, hasLength(1));

      await tester.pumpWidget(harness(HomericParagraph(
        source: source,
        slotBuilder: (_) => chip('marker'),
      )));

      expect(
        tester.getSemantics(find.byType(HomericParagraph)),
        matchesSemantics(label: 'marker', textDirection: TextDirection.ltr),
        reason: 'the block-level semantics node must not vanish just '
            'because it has no text of its own',
      );
      handle.dispose();
    });

    testWidgets('two widget slots each merge in at their own position',
        (tester) async {
      final handle = tester.ensureSemantics();
      final source = sourceOf(
        'xy',
        decorations: [
          Decoration.widget('b', 0, spec: 'first'),
          Decoration.widget('b', 2, spec: 'last'),
        ],
      );
      await tester.pumpWidget(harness(HomericParagraph(
        source: source,
        slotBuilder: (slot) => chip(slot.spec == 'first' ? 'start' : 'end'),
      )));

      final data = tester.getSemantics(find.byType(HomericParagraph));
      expect(data.label, 'start\nxy\nend');
      handle.dispose();
    });
  });

  group('semantics update wiring (R6 — dirty tracking)', () {
    testWidgets(
        'a content change marks semantics dirty; a paint-only change does '
        'not', (tester) async {
      final handle = tester.ensureSemantics();
      final captured = <_SpyRenderHomericParagraph>[];
      final helloSource = sourceOf('hello');

      await tester.pumpWidget(harness(
          _SpyHomericParagraph(source: helloSource, captured: captured)));
      final render = captured.single;
      expect(
        tester.getSemantics(find.byType(_SpyHomericParagraph)),
        matchesSemantics(label: 'hello'),
      );
      final afterBuild = render.semanticsUpdateCount;

      // Paint-only change: a repaint-band styler never touches content.
      TextStyle greenify(TextSegment<TextStyle> segment) =>
          segment.style.copyWith(color: const Color(0xFF00FF00));
      await tester.pumpWidget(harness(_SpyHomericParagraph(
        source: helloSource,
        captured: captured,
        paintStyler: greenify,
      )));
      expect(captured.single, same(render), reason: 'same render object');
      expect(render.semanticsUpdateCount, afterBuild,
          reason: 'a paint-only styler change must not mark semantics dirty');

      // Content change: different document text.
      final helpSource = sourceOf('help');
      await tester.pumpWidget(harness(_SpyHomericParagraph(
        source: helpSource,
        captured: captured,
        paintStyler: greenify,
      )));
      expect(render.semanticsUpdateCount, greaterThan(afterBuild),
          reason: 'a real content change must mark semantics dirty');
      expect(
        tester.getSemantics(find.byType(_SpyHomericParagraph)),
        matchesSemantics(label: 'help'),
      );
      handle.dispose();
    });

    testWidgets(
        'supplying a differently-derived semanticsSource marks '
        'semantics dirty even though source is unchanged', (tester) async {
      final handle = tester.ensureSemantics();
      final captured = <_SpyRenderHomericParagraph>[];
      final source = sourceOf('hello');

      await tester.pumpWidget(
          harness(_SpyHomericParagraph(source: source, captured: captured)));
      final render = captured.single;
      final afterBuild = render.semanticsUpdateCount;

      final override = semanticsOf(textBlock('hi'));
      await tester.pumpWidget(harness(_SpyHomericParagraph(
        source: source,
        captured: captured,
        semanticsSource: override,
      )));
      expect(render.semanticsUpdateCount, greaterThan(afterBuild));
      expect(
        tester.getSemantics(find.byType(_SpyHomericParagraph)),
        matchesSemantics(label: 'hi'),
      );
      handle.dispose();
    });
  });
}
