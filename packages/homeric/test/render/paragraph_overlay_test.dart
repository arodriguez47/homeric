import 'dart:ui' as ui;

import 'package:flutter/widgets.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

import 'render_test_utils.dart';

void main() {
  testWidgets('mounts a geometry-derived overlay after the first layout',
      (tester) async {
    const markerKey = Key('first-layout-marker');
    final generations = <int>[];

    await tester.pumpWidget(harness(ParagraphOverlay(
      paragraph: HomericParagraph(source: sourceOf('abc')),
      slotLayoutRevision: null,
      overlayBuilder: (context, geometry) {
        generations.add(geometry.generation);
        return <Widget>[
          Positioned.fromRect(
            rect: geometry.caretRect(const DocOffset(1)).value,
            child: const SizedBox(key: markerKey),
          ),
        ];
      },
    )));

    expect(find.byKey(markerKey), findsNothing);

    await tester.pump();

    expect(find.byKey(markerKey), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(markerKey)), const Offset(14, 0));
    expect(generations, <int>[1]);
  });

  testWidgets('re-resolves overlay geometry after paragraph relayout',
      (tester) async {
    const markerKey = Key('relayout-marker');
    final generations = <int>[];

    Widget build(double width) => harness(
          ParagraphOverlay(
            paragraph: HomericParagraph(source: sourceOf('ab cd')),
            slotLayoutRevision: null,
            overlayBuilder: (context, geometry) {
              generations.add(geometry.generation);
              return <Widget>[
                Positioned.fromRect(
                  rect: geometry.caretRect(const DocOffset(4)).value,
                  child: const SizedBox(key: markerKey),
                ),
              ];
            },
          ),
          width: width,
        );

    await tester.pumpWidget(build(200));
    await tester.pump();
    expect(tester.getTopLeft(find.byKey(markerKey)), const Offset(56, 0));

    await tester.pumpWidget(build(30));
    await tester.pump();

    expect(tester.getTopLeft(find.byKey(markerKey)), const Offset(14, 14));
    expect(generations, <int>[1, 2]);
  });

  testWidgets('does not build from the old source before its relayout',
      (tester) async {
    final observedLengths = <int>[];

    Widget build(String text) => harness(
          ParagraphOverlay(
            paragraph: HomericParagraph(source: sourceOf(text)),
            slotLayoutRevision: null,
            overlayBuilder: (context, geometry) {
              observedLengths.add(geometry.docLength);
              return const <Widget>[];
            },
          ),
        );

    await tester.pumpWidget(build('abc'));
    await tester.pump();
    await tester.pumpWidget(build('abcdef'));
    await tester.pump();

    expect(observedLengths, <int>[3, 6],
        reason: 'the parent rebuild occurs before HomericParagraph receives '
            'its new source; generation 1 must be suppressed in that gap');
  });

  group('suppresses completed geometry while new layout inputs are pending',
      () {
    testWidgets('base style', (tester) async {
      final source = sourceOf('abc');
      await expectOnlyFreshGenerations(
        tester,
        HomericParagraph(
          source: source,
          baseStyle: const TextStyle(fontSize: 14),
        ),
        HomericParagraph(
          source: source,
          baseStyle: const TextStyle(fontSize: 20),
        ),
      );
    });

    testWidgets('text alignment', (tester) async {
      final source = sourceOf('abc');
      await expectOnlyFreshGenerations(
        tester,
        HomericParagraph(source: source),
        HomericParagraph(source: source, textAlign: TextAlign.center),
      );
    });

    testWidgets('text scaler', (tester) async {
      final source = sourceOf('abc');
      await expectOnlyFreshGenerations(
        tester,
        HomericParagraph(source: source, textScaler: TextScaler.noScaling),
        HomericParagraph(
          source: source,
          textScaler: const TextScaler.linear(2),
        ),
      );
    });

    testWidgets('slot alignment', (tester) async {
      final source = sourceOf(
        'ab',
        decorations: <Decoration>[
          Decoration.widget('b', 1, spec: 'chip'),
        ],
      );
      Widget slotBuilder(SlotSegment<TextStyle> _) =>
          const SizedBox(width: 20, height: 10);
      await expectOnlyFreshGenerations(
        tester,
        HomericParagraph(source: source, slotBuilder: slotBuilder),
        HomericParagraph(
          source: source,
          slotBuilder: slotBuilder,
          slotAlignment: ui.PlaceholderAlignment.top,
        ),
      );
    });

    testWidgets('slot baseline', (tester) async {
      final source = sourceOf(
        'ab',
        decorations: <Decoration>[
          Decoration.widget('b', 1, spec: 'chip'),
        ],
      );
      Widget slotBuilder(SlotSegment<TextStyle> _) =>
          const SizedBox(width: 20, height: 10);
      await expectOnlyFreshGenerations(
        tester,
        HomericParagraph(
          source: source,
          slotBuilder: slotBuilder,
          slotAlignment: ui.PlaceholderAlignment.baseline,
          slotBaseline: TextBaseline.alphabetic,
        ),
        HomericParagraph(
          source: source,
          slotBuilder: slotBuilder,
          slotAlignment: ui.PlaceholderAlignment.baseline,
          slotBaseline: TextBaseline.ideographic,
        ),
      );
    });
  });

  testWidgets('does not build from old geometry while an inline slot resizes',
      (tester) async {
    const markerKey = Key('slot-resize-marker');
    final generations = <int>[];
    final source = sourceOf(
      'ab',
      decorations: <Decoration>[
        Decoration.widget('b', 1, spec: 'chip'),
      ],
    );

    Widget build(double chipWidth, int slotLayoutRevision) => harness(
          ParagraphOverlay(
            paragraph: HomericParagraph(
              source: source,
              slotBuilder: (_) => SizedBox(width: chipWidth, height: 10),
            ),
            slotLayoutRevision: slotLayoutRevision,
            overlayBuilder: (context, geometry) {
              generations.add(geometry.generation);
              return <Widget>[
                Positioned.fromRect(
                  rect: geometry.caretRect(const DocOffset(2)).value,
                  child: const SizedBox(key: markerKey),
                ),
              ];
            },
          ),
          width: 100,
        );

    await tester.pumpWidget(build(20, 1));
    await tester.pump();
    expect(tester.getTopLeft(find.byKey(markerKey)), const Offset(48, 0));

    await tester.pumpWidget(build(40, 2));
    await tester.pump();

    expect(tester.getTopLeft(find.byKey(markerKey)), const Offset(68, 0));
    expect(generations, <int>[1, 2],
        reason: 'the explicit slot layout revision suppresses generation 1 '
            'until the resized child has been measured');
  });

  testWidgets('does not query a replaced paragraph render object',
      (tester) async {
    final paragraphs = <RenderHomericParagraph>[];
    final overlayCalls = <int>[];
    final source = sourceOf('abc');

    Widget build(Key paragraphKey) => harness(ParagraphOverlay(
          paragraph: HomericParagraph(
            key: paragraphKey,
            source: source,
            onGeometryChanged: (paragraph, _) => paragraphs.add(paragraph),
          ),
          slotLayoutRevision: null,
          overlayBuilder: (context, geometry) {
            overlayCalls.add(geometry.generation);
            return const <Widget>[];
          },
        ));

    await tester.pumpWidget(build(const ValueKey<String>('first')));
    await tester.pump();
    await tester.pumpWidget(build(const ValueKey<String>('second')));
    await tester.pump();

    expect(paragraphs, hasLength(2));
    expect(identical(paragraphs.first, paragraphs.last), isFalse);
    expect(overlayCalls, <int>[1, 1],
        reason: 'the old render object must be suppressed during replacement');
  });

  testWidgets('a conservative slot revision cannot strand the overlay',
      (tester) async {
    const markerKey = Key('slot-revision-catch-up');
    final generations = <int>[];
    final source = sourceOf(
      'ab',
      decorations: <Decoration>[
        Decoration.widget('b', 1, spec: 'chip'),
      ],
    );

    Widget build(int slotLayoutRevision) => harness(ParagraphOverlay(
          paragraph: HomericParagraph(
            source: source,
            slotBuilder: (_) => const SizedBox(width: 20, height: 10),
          ),
          slotLayoutRevision: slotLayoutRevision,
          overlayBuilder: (context, geometry) {
            generations.add(geometry.generation);
            return const <Widget>[
              Positioned(
                left: 0,
                top: 0,
                width: 1,
                height: 1,
                child: SizedBox(key: markerKey),
              ),
            ];
          },
        ));

    await tester.pumpWidget(build(1));
    await tester.pump();
    await tester.pumpWidget(build(2));
    await tester.pump();

    expect(find.byKey(markerKey), findsOneWidget);
    expect(generations, <int>[1, 1],
        reason: 'when the child measures identically, the wrapper accepts '
            'the still-current generation after layout instead of waiting '
            'forever for a notification that correctly never fires');
  });

  testWidgets('overlay content cannot affect paragraph layout', (tester) async {
    const oversizedKey = Key('oversized-overlay');
    var geometryNotifications = 0;

    await tester.pumpWidget(harness(ParagraphOverlay(
      paragraph: HomericParagraph(
        source: sourceOf('abc'),
        onGeometryChanged: (_, __) => geometryNotifications += 1,
      ),
      slotLayoutRevision: null,
      overlayBuilder: (context, geometry) => const <Widget>[
        SizedBox(key: oversizedKey, width: 1000, height: 1000),
      ],
    )));
    await tester.pump();
    await tester.pump();

    expect(tester.getSize(find.byType(ParagraphOverlay)), const Size(200, 14));
    expect(tester.getSize(find.byType(HomericParagraph)), const Size(200, 14));
    expect(tester.getSize(find.byKey(oversizedKey)), const Size(200, 14));
    expect(geometryNotifications, 1,
        reason: 'the fixed overlay plane must not create a relayout loop');
    expect(tester.takeException(), isNull);
  });

  testWidgets('in-bounds overlay presentation may handle pointer input',
      (tester) async {
    var taps = 0;

    await tester.pumpWidget(harness(ParagraphOverlay(
      paragraph: HomericParagraph(source: sourceOf('abc')),
      slotLayoutRevision: null,
      overlayBuilder: (context, geometry) => <Widget>[
        Positioned(
          left: 0,
          top: 0,
          width: 20,
          height: 14,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => taps += 1,
          ),
        ),
      ],
    )));
    await tester.pump();

    await tester.tapAt(const Offset(5, 5));
    await tester.pump();

    expect(taps, 1);
  });

  testWidgets('forwards paragraph inputs and the public geometry callback',
      (tester) async {
    const paragraphKey = Key('owned-paragraph');
    final callbackGenerations = <int>[];
    final source = sourceOf('abc');

    await tester.pumpWidget(harness(ParagraphOverlay(
      paragraph: HomericParagraph(
        key: paragraphKey,
        source: source,
        baseStyle: const TextStyle(fontSize: 20),
        textAlign: TextAlign.center,
        paintLayers: <PaintLayer>[
          PaintLayer(
            range: DocRange(const DocOffset(0), const DocOffset(1)),
            band: PaintBand.underlay,
            painter: solidWashPainter,
            spec: const SolidWashSpec(Color(0x11000000)),
          ),
        ],
        semanticsSource: sourceOf('accessible'),
        onGeometryChanged: (_, generation) {
          callbackGenerations.add(generation);
        },
      ),
      slotLayoutRevision: null,
      overlayBuilder: (_, __) => const <Widget>[],
    )));
    await tester.pump();

    final paragraph = tester.widget<HomericParagraph>(find.byKey(paragraphKey));
    expect(paragraph.source, same(source));
    expect(paragraph.baseStyle, const TextStyle(fontSize: 20));
    expect(paragraph.textAlign, TextAlign.center);
    expect(paragraph.paintLayers, hasLength(1));
    expect(paragraph.semanticsSource?.viewText, 'accessible');
    expect(callbackGenerations, <int>[1]);
  });

  testWidgets('a public callback attached after layout receives catch-up',
      (tester) async {
    final callbacks = <(RenderHomericParagraph, int)>[];
    final source = sourceOf('abc');

    Widget build({required bool observed}) => harness(ParagraphOverlay(
          paragraph: HomericParagraph(
            source: source,
            onGeometryChanged: observed
                ? (paragraph, generation) {
                    callbacks.add((paragraph, generation));
                  }
                : null,
          ),
          slotLayoutRevision: null,
          overlayBuilder: (_, __) => const <Widget>[],
        ));

    await tester.pumpWidget(build(observed: false));
    await tester.pump();
    final generation = renderOf(tester).layoutGeneration;

    await tester.pumpWidget(build(observed: true));
    await tester.pump();

    expect(callbacks, hasLength(1));
    expect(callbacks.single.$1, same(renderOf(tester)));
    expect(callbacks.single.$2, generation,
        reason: 'attaching the public observer must not force a relayout');
  });

  testWidgets(
      'a public callback attached with a same-size slot revision catches up',
      (tester) async {
    final callbacks = <int>[];
    final source = sourceOf(
      'ab',
      decorations: <Decoration>[
        Decoration.widget('b', 1, spec: 'chip'),
      ],
    );
    void onGeometryChanged(_, int generation) => callbacks.add(generation);

    Widget build({required int revision, required bool observed}) =>
        harness(ParagraphOverlay(
          paragraph: HomericParagraph(
            source: source,
            slotBuilder: (_) => const SizedBox(width: 20, height: 10),
            onGeometryChanged: observed ? onGeometryChanged : null,
          ),
          slotLayoutRevision: revision,
          overlayBuilder: (_, __) => const <Widget>[],
        ));

    await tester.pumpWidget(build(revision: 1, observed: false));
    await tester.pump();
    final generation = renderOf(tester).layoutGeneration;

    await tester.pumpWidget(build(revision: 2, observed: true));
    await tester.pump();
    await tester.pump();

    expect(callbacks, <int>[generation],
        reason: 'accepting an unchanged generation for the new slot revision '
            'must resume the pending public catch-up');
  });

  testWidgets(
      'a same-size slot revision does not re-notify an attached callback',
      (tester) async {
    final callbacks = <int>[];
    final source = sourceOf(
      'ab',
      decorations: <Decoration>[
        Decoration.widget('b', 1, spec: 'chip'),
      ],
    );

    Widget build(int revision) => harness(ParagraphOverlay(
          paragraph: HomericParagraph(
            source: source,
            slotBuilder: (_) => const SizedBox(width: 20, height: 10),
            onGeometryChanged: (_, generation) {
              callbacks.add(generation);
            },
          ),
          slotLayoutRevision: revision,
          overlayBuilder: (_, __) => const <Widget>[],
        ));

    await tester.pumpWidget(build(1));
    await tester.pump();
    final generation = renderOf(tester).layoutGeneration;
    expect(callbacks, <int>[generation]);

    await tester.pumpWidget(build(2));
    await tester.pump();
    await tester.pump();

    expect(callbacks, <int>[generation],
        reason: 'a conservative slot revision updates overlay freshness but '
            'does not invent a paragraph geometry notification');
  });

  testWidgets('reattaching the same public callback catches up again',
      (tester) async {
    final callbacks = <int>[];
    final source = sourceOf('abc');
    void onGeometryChanged(_, int generation) => callbacks.add(generation);

    Widget build(bool observed) => harness(ParagraphOverlay(
          paragraph: HomericParagraph(
            source: source,
            onGeometryChanged: observed ? onGeometryChanged : null,
          ),
          slotLayoutRevision: null,
          overlayBuilder: (_, __) => const <Widget>[],
        ));

    await tester.pumpWidget(build(true));
    await tester.pump();
    final generation = renderOf(tester).layoutGeneration;
    expect(callbacks, <int>[generation]);

    await tester.pumpWidget(build(false));
    await tester.pump();
    await tester.pumpWidget(build(true));
    await tester.pump();

    expect(callbacks, <int>[generation, generation],
        reason: 'each null-to-non-null attachment has its own catch-up epoch');
  });

  testWidgets('held geometry results expose staleness after relayout',
      (tester) async {
    GeometryResult<Rect>? held;

    Widget build(double width) => harness(
          ParagraphOverlay(
            paragraph: HomericParagraph(source: sourceOf('ab cd')),
            slotLayoutRevision: null,
            overlayBuilder: (context, geometry) {
              held ??= geometry.caretRect(const DocOffset(4));
              return const <Widget>[];
            },
          ),
          width: width,
        );

    await tester.pumpWidget(build(200));
    await tester.pump();
    expect(held, isNotNull);
    expect(held!.isStale, isFalse);

    await tester.pumpWidget(build(30));
    await tester.pump();

    expect(held!.isStale, isTrue,
        reason: 'async consumers can drop a response stamped by the old '
            'layout generation instead of painting it');
  });
}

Future<void> expectOnlyFreshGenerations(
  WidgetTester tester,
  HomericParagraph first,
  HomericParagraph second,
) async {
  final generations = <int>[];

  Widget build(HomericParagraph paragraph) => harness(ParagraphOverlay(
        paragraph: paragraph,
        slotLayoutRevision: null,
        overlayBuilder: (context, geometry) {
          generations.add(geometry.generation);
          return const <Widget>[];
        },
      ));

  await tester.pumpWidget(build(first));
  await tester.pump();
  await tester.pumpWidget(build(second));
  await tester.pump();

  expect(generations, <int>[1, 2]);
}
