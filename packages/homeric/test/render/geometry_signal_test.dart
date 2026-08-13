// HomericParagraph.onGeometryChanged (HOM-15): the subscription half of
// the U4 geometry service.
//
// The bug this suite exists to prevent: geometry does not exist until
// after layout, so a consumer placing *positioned overlays* from it —
// footnote markers, hover and tap targets, a caret — has nothing to
// position against on the first build. Inline slot children render fine,
// because they are inside the paragraph rather than derived from it, and
// that split is what makes the failure so easy to misread as a consumer
// bug. Only Homeric knows when its paragraph relaid out.
//
// The "does not fire" half of this file is the interesting half. The
// signal must be free for paragraphs that do not use it: Nexus's focus dim
// animates every visible block through `paintLayers` on every frame, and a
// paint-only tick that turned into a rebuild would be a far worse bug than
// the one being fixed.
//
// Harness note: dispatch is deferred to a post-frame callback (mutating
// render objects during `flushLayout` asserts), but `pumpWidget` drains
// post-frame callbacks inside its own frame — so the callback has already
// run when it returns. The extra `pump()` every case here performs is for
// the *consumer's* reaction: a `setState` from the callback marks the
// element dirty after that frame's build phase, so the overlay appears one
// frame later. That extra pump touches neither selection nor the source —
// it is exactly the "pump without touching anything" the issue names as
// the missing test.

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

import 'render_test_utils.dart';

void main() {
  group('fires', () {
    testWidgets('once when geometry first becomes available', (tester) async {
      final generations = <int>[];
      final phases = <SchedulerPhase>[];
      await tester.pumpWidget(harness(HomericParagraph(
        source: sourceOf('hello'),
        onGeometryChanged: (_, generation) {
          generations.add(generation);
          phases.add(SchedulerBinding.instance.schedulerPhase);
        },
      )));

      expect(generations, <int>[1]);
      expect(generations.single, renderOf(tester).layoutGeneration);
      // The deferral, pinned directly: dispatching from inside
      // performLayout would land in persistentCallbacks, and a listener
      // touching any render object outside this subtree would then trip
      // `A RenderObject was mutated in PipelineOwner.flushLayout()`.
      expect(phases, <SchedulerPhase>[SchedulerPhase.postFrameCallbacks]);
    });

    testWidgets('on relayout from a width change', (tester) async {
      final generations = <int>[];
      final source = sourceOf('hello');
      HomericParagraph build() => HomericParagraph(
            source: source,
            onGeometryChanged: (_, generation) => generations.add(generation),
          );

      await tester.pumpWidget(harness(build()));
      await tester.pump();
      // Width-only: the same ui.Paragraph relaid out, not a rebuild — the
      // signal must still fire, because every rect moved.
      await tester.pumpWidget(harness(build(), width: 60));
      await tester.pump();

      expect(generations, <int>[1, 2]);
    });

    testWidgets('on a text change and on a base-style change', (tester) async {
      final generations = <int>[];
      Widget build(ParagraphSource<TextStyle> source, {TextStyle? base}) =>
          harness(HomericParagraph(
            source: source,
            baseStyle: base,
            onGeometryChanged: (_, generation) => generations.add(generation),
          ));

      await tester.pumpWidget(build(sourceOf('hello')));
      await tester.pump();
      await tester.pumpWidget(build(sourceOf('help')));
      await tester.pump();
      await tester.pumpWidget(
          build(sourceOf('help'), base: const TextStyle(fontSize: 28)));
      await tester.pump();

      expect(generations, <int>[1, 2, 3],
          reason: 'not just the width path — every relayout trigger');
    });

    testWidgets('with geometry that is current, clean, and final-size',
        (tester) async {
      var asserted = 0;
      await tester.pumpWidget(harness(HomericParagraph(
        source: sourceOf('hello'),
        onGeometryChanged: (paragraph, generation) {
          expect(paragraph.debugNeedsLayout, isFalse);
          final geometry = ParagraphGeometry(paragraph);
          expect(geometry.generation, generation);
          final block = geometry.blockRect;
          expect(block.isStale, isFalse);
          // `size` lands after the generation bump, and slot offsets after
          // that — dispatching any earlier would answer with a half-built
          // layout.
          expect(block.value.size, paragraph.size);
          asserted += 1;
        },
      )));
      await tester.pump();
      expect(asserted, 1);
    });

    testWidgets('with a generation that strictly increases and matches',
        (tester) async {
      final observed = <int>[];
      final live = <int>[];
      final source = sourceOf('hello');
      Widget build(double width) => harness(
            HomericParagraph(
              source: source,
              onGeometryChanged: (paragraph, generation) {
                observed.add(generation);
                live.add(paragraph.layoutGeneration);
              },
            ),
            width: width,
          );

      for (final width in <double>[200, 160, 120, 80]) {
        await tester.pumpWidget(build(width));
        await tester.pump();
      }

      expect(observed, <int>[1, 2, 3, 4]);
      expect(live, observed,
          reason: 'the carried generation is read live at dispatch, so it is '
              'the one a ParagraphGeometry built now would capture');
    });

    testWidgets('once when a callback is attached after the first layout',
        (tester) async {
      // The reported bug in miniature: a consumer whose overlay builder
      // only becomes non-null on a later build installs the callback with
      // no relayout behind it, and would otherwise wait for an unrelated
      // edit that may never come.
      final source = sourceOf('hello');
      await tester.pumpWidget(harness(HomericParagraph(source: source)));
      await tester.pump();
      final generation = renderOf(tester).layoutGeneration;

      final generations = <int>[];
      await tester.pumpWidget(harness(HomericParagraph(
        source: source,
        onGeometryChanged: (_, g) => generations.add(g),
      )));
      await tester.pump();

      expect(generations, <int>[generation],
          reason: 'catch-up fires at the unchanged generation — installing '
              'an observer must not relayout what it observes');
    });

    testWidgets('only once per frame when a fresh closure arrives each build',
        (tester) async {
      var calls = 0;
      final source = sourceOf('hello');
      // A new closure every build is the normal consumer shape; it must
      // not read as a newly-attached observer and re-fire.
      Widget build() => harness(HomericParagraph(
            source: source,
            onGeometryChanged: (_, __) => calls += 1,
          ));

      await tester.pumpWidget(build());
      await tester.pump();
      expect(calls, 1);

      await tester.pumpWidget(build());
      await tester.pump();
      await tester.pumpWidget(build());
      await tester.pump();

      expect(calls, 1, reason: 'no relayout happened in either rebuild');
    });
  });

  group('does not fire', () {
    testWidgets('on paintLayers-only changes (the animated dim)',
        (tester) async {
      var calls = 0;
      final source = sourceOf('hello');
      final range = DocRange(DocOffset.zero, const DocOffset(5));
      Widget build(double amount) => harness(HomericParagraph(
            source: source,
            paintLayers: [
              PaintLayer(
                range: range,
                band: PaintBand.underlay,
                painter: solidWashPainter,
                spec: SolidWashSpec(Color.fromRGBO(0, 0, 0, amount)),
              ),
            ],
            onGeometryChanged: (_, __) => calls += 1,
          ));

      await tester.pumpWidget(build(0.0));
      await tester.pump();
      expect(calls, 1);
      final render = renderOf(tester);
      final generation = render.layoutGeneration;

      // Ten frames of a dim animating, exactly as the journal ticks it.
      for (var frame = 1; frame <= 10; frame += 1) {
        await tester.pumpWidget(build(frame / 10));
        await tester.pump();
      }

      expect(calls, 1,
          reason: 'a paint-only tick must never become a consumer rebuild');
      expect(render.layoutGeneration, generation);
    });

    testWidgets('on a paintStyler-only change', (tester) async {
      var calls = 0;
      final source = sourceOf('hello');
      TextStyle dim(TextSegment<TextStyle> segment) =>
          segment.style.copyWith(color: const Color(0x80000000));

      await tester.pumpWidget(harness(HomericParagraph(
        source: source,
        onGeometryChanged: (_, __) => calls += 1,
      )));
      await tester.pump();
      final render = renderOf(tester);
      final generation = render.layoutGeneration;

      await tester.pumpWidget(harness(HomericParagraph(
        source: source,
        paintStyler: dim,
        onGeometryChanged: (_, __) => calls += 1,
      )));
      await tester.pump();

      // paint() swaps in a freshly built paragraph here — but it never
      // relaid out, so no held GeometryResult went stale and there is
      // nothing for a consumer to re-place.
      expect(calls, 1);
      expect(render.layoutGeneration, generation);
    });

    testWidgets('when an equal source is re-derived', (tester) async {
      var calls = 0;
      Widget build() => harness(HomericParagraph(
            source: sourceOf('hello'),
            onGeometryChanged: (_, __) => calls += 1,
          ));

      await tester.pumpWidget(build());
      await tester.pump();
      await tester.pumpWidget(build());
      await tester.pump();

      expect(calls, 1,
          reason: 'a fresh-but-equal derivation is the per-build norm');
    });

    testWidgets('after dispose', (tester) async {
      var calls = 0;
      await tester.pumpWidget(harness(HomericParagraph(
        source: sourceOf('hello'),
        onGeometryChanged: (_, __) => calls += 1,
      )));
      await tester.pump();
      expect(calls, 1);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await tester.pump();

      // A post-frame callback cannot be cancelled once registered, so a
      // dispatch queued by the final layout must no-op rather than hand
      // over a render object whose layoutParagraph asserts.
      expect(calls, 1);
    });
  });

  group('the overlay a consumer could not previously mount', () {
    testWidgets(
        'is placed on a plain pump, touching neither selection '
        'nor the source', (tester) async {
      await tester.pumpWidget(harness(const _OverlayHost()));
      expect(find.byKey(_OverlayHost.markerKey), findsNothing,
          reason: 'no geometry exists during the first build — this is the '
              'state the consumer used to be stuck in permanently');

      await tester.pump();

      expect(find.byKey(_OverlayHost.markerKey), findsOneWidget);
      // Offset 1 of 'abc' in the 14px-square test font.
      expect(tester.getTopLeft(find.byKey(_OverlayHost.markerKey)),
          const Offset(14, 0));
    });

    testWidgets('re-places itself when the paragraph relayouts',
        (tester) async {
      // 'ab cd' at width 200 is one line; at width 30 it wraps, moving
      // offset 4 onto the second line. A consumer that mounted its overlay
      // once and never heard again would paint it at the old position.
      await tester.pumpWidget(harness(const _OverlayHost(
        text: 'ab cd',
        anchor: DocOffset(4),
      )));
      await tester.pump();
      expect(tester.getTopLeft(find.byKey(_OverlayHost.markerKey)),
          const Offset(56, 0));

      await tester.pumpWidget(harness(
        const _OverlayHost(text: 'ab cd', anchor: DocOffset(4)),
        width: 30,
      ));
      await tester.pump();

      expect(tester.getTopLeft(find.byKey(_OverlayHost.markerKey)),
          const Offset(14, 14),
          reason: 'second line, second glyph');
    });
  });
}

/// A minimal version of the consumer shape that HOM-15 broke: a paragraph
/// with a geometry-derived overlay positioned over it, subscribed to
/// nothing but [HomericParagraph.onGeometryChanged].
class _OverlayHost extends StatefulWidget {
  const _OverlayHost({
    this.text = 'abc',
    this.anchor = const DocOffset(1),
  });

  static const Key markerKey = Key('overlay-marker');

  final String text;
  final DocOffset anchor;

  @override
  State<_OverlayHost> createState() => _OverlayHostState();
}

class _OverlayHostState extends State<_OverlayHost> {
  RenderHomericParagraph? _paragraph;
  int _generation = 0;

  @override
  Widget build(BuildContext context) {
    final paragraph = _paragraph;
    return Stack(
      children: <Widget>[
        HomericParagraph(
          source: sourceOf(widget.text),
          onGeometryChanged: (render, generation) {
            if (!mounted) {
              return;
            }
            setState(() {
              _paragraph = render;
              _generation = generation;
            });
          },
        ),
        if (paragraph != null)
          Positioned.fromRect(
            rect: _caretRect(paragraph),
            // Layout-neutral, per the widget's doc: an overlay child that
            // fed back into the paragraph's constraints would be a real
            // relayout loop.
            child: const IgnorePointer(
                child: SizedBox(key: _OverlayHost.markerKey)),
          ),
      ],
    );
  }

  Rect _caretRect(RenderHomericParagraph paragraph) {
    final geometry = ParagraphGeometry(paragraph);
    // Constructed fresh here, in build, rather than held from the
    // callback — the supported pattern, and why the callback hands back
    // the render object instead of a ParagraphGeometry.
    expect(geometry.generation, _generation);
    return geometry.caretRect(widget.anchor).value;
  }
}
