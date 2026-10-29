import 'package:flutter/material.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

void main() {
  Future<HomericEditorController> pump(
    WidgetTester tester, {
    required HomericBlockGrabberAlignment alignment,
    bool holdsRowHeight = true,
    TextDirection textDirection = TextDirection.ltr,
    TextStyle style = const TextStyle(fontSize: 20, height: 1.7),
    EdgeInsets padding = EdgeInsets.zero,
    double textScale = 1,
  }) async {
    final controller = HomericEditorController(
      document: Document([
        Block(id: 'a', type: 'paragraph', runs: [InlineRun('First line')]),
        Block(id: 'b', type: 'paragraph', runs: [InlineRun('Second')]),
      ]),
    );
    final session = HomericTextInputSession(controller: controller);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Directionality(
          textDirection: textDirection,
          child: HomericEditableDocument.builder(
            controller: controller,
            inputSession: session,
            blockGrabberStyle: HomericBlockGrabberStyle(
              alignment: alignment,
              holdsRowHeight: holdsRowHeight,
              textStyle: const TextStyle(fontSize: 14, height: 1),
              letterStyle: (_) => style,
            ),
            blockBuilder: (context, block, focusNode) => Padding(
              padding: padding,
              child: HomericEditableParagraph(
                controller: controller,
                inputSession: session,
                blockId: block.id,
                focusNode: focusNode,
                resolveStyle: (_) => style,
                baseStyle: style,
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return controller;
  }

  // Baselines may only be read during layout; tests read them afterwards.
  double baselineOf(RenderBox box) {
    RenderObject.debugCheckingIntrinsics = true;
    try {
      return box.getDistanceToBaseline(TextBaseline.alphabetic)!;
    } finally {
      RenderObject.debugCheckingIntrinsics = false;
    }
  }

  double glyphBaseline(WidgetTester tester) {
    final glyph = tester.renderObject<RenderBox>(find.text('⋮').first);
    return glyph.localToGlobal(Offset.zero).dy + baselineOf(glyph);
  }

  double firstLineBaseline(WidgetTester tester) {
    final box =
        tester.renderObject<RenderBox>(find.byType(HomericParagraph).first);
    return box.localToGlobal(Offset.zero).dy + baselineOf(box);
  }

  testWidgets('firstBaseline puts the grabber glyph on the text baseline',
      (tester) async {
    await pump(
      tester,
      alignment: HomericBlockGrabberAlignment.firstBaseline,
      padding: const EdgeInsets.only(top: 18),
    );

    expect(glyphBaseline(tester), closeTo(firstLineBaseline(tester), 0.01));
  });

  testWidgets('firstBaseline does not move the text', (tester) async {
    await pump(tester, alignment: HomericBlockGrabberAlignment.center);
    final centred = firstLineBaseline(tester);

    await pump(tester, alignment: HomericBlockGrabberAlignment.firstBaseline);

    expect(firstLineBaseline(tester), centred);
  });

  testWidgets('center keeps the glyph off the baseline (regression guard)',
      (tester) async {
    // Deeper first-line spacing than the default 22px centre allows for.
    await pump(
      tester,
      alignment: HomericBlockGrabberAlignment.center,
      padding: const EdgeInsets.only(top: 18),
    );

    expect(
      (glyphBaseline(tester) - firstLineBaseline(tester)).abs(),
      greaterThan(1),
    );
  });

  double secondLineTop(WidgetTester tester) => tester
      .renderObject<RenderBox>(find.byType(HomericParagraph).at(1))
      .localToGlobal(Offset.zero)
      .dy;

  double firstLineTop(WidgetTester tester) => tester
      .renderObject<RenderBox>(find.byType(HomericParagraph).first)
      .localToGlobal(Offset.zero)
      .dy;

  final glyphFinder = find.byKey(const ValueKey('homeric-grabber-glyph'));

  for (final alignment in HomericBlockGrabberAlignment.values) {
    testWidgets('${alignment.name}: a short row is held to the grabber',
        (tester) async {
      // A 12px line, under the 44px grabber square.
      await pump(
        tester,
        alignment: alignment,
        style: const TextStyle(fontSize: 10, height: 1.2),
      );

      expect(secondLineTop(tester) - firstLineTop(tester),
          closeTo(kHomericBlockGrabberWidth, 0.01));
    });

    testWidgets('${alignment.name}: without holdsRowHeight a row is its line',
        (tester) async {
      await pump(
        tester,
        alignment: alignment,
        holdsRowHeight: false,
        style: const TextStyle(fontSize: 10, height: 1.2),
      );

      expect(secondLineTop(tester) - firstLineTop(tester), closeTo(12, 0.01));
      // The text keeps its column.
      expect(
        tester
            .renderObject<RenderBox>(find.byType(HomericParagraph).first)
            .localToGlobal(Offset.zero)
            .dx,
        closeTo(kHomericBlockGrabberWidth, 0.01),
      );
      // The glyph keeps its alignment, and stays inside its own row.
      if (alignment == HomericBlockGrabberAlignment.firstBaseline) {
        expect(glyphBaseline(tester), closeTo(firstLineBaseline(tester), 0.01));
      }
      final glyph = tester.getCenter(glyphFinder.first).dy;
      expect(glyph, greaterThanOrEqualTo(firstLineTop(tester)));
      expect(glyph, lessThan(secondLineTop(tester)));
      // A pointer on the glyph reaches its own row's drag handle.
      final hit = tester.hitTestOnBinding(tester.getCenter(glyphFinder.first));
      final handles = find.byType(ReorderableDragStartListener);
      final first = tester.renderObject(handles.first);
      final second = tester.renderObject(handles.at(1));
      final targets = hit.path.map((e) => e.target).toList();
      expect(targets, contains(first));
      expect(targets, isNot(contains(second)));
    });
  }

  testWidgets('without holdsRowHeight the grabber still leads in RTL',
      (tester) async {
    Rect glyph() => tester.getRect(find.text('⋮').first);
    Rect text() => tester.getRect(find.byType(HomericParagraph).first);
    await pump(
      tester,
      alignment: HomericBlockGrabberAlignment.center,
      textDirection: TextDirection.rtl,
    );
    final held = (glyph: glyph(), text: text());

    await pump(
      tester,
      alignment: HomericBlockGrabberAlignment.center,
      textDirection: TextDirection.rtl,
      holdsRowHeight: false,
    );

    expect(glyph().center.dx, closeTo(held.glyph.center.dx, 0.01));
    expect(text().left, closeTo(held.text.left, 0.01));
    expect(glyph().center.dx, greaterThan(text().right));
  });

  testWidgets('without holdsRowHeight a row that holds the centre keeps it',
      (tester) async {
    double glyphCenter() =>
        tester.getCenter(find.text('⋮').first).dy - firstLineTop(tester);
    // A 34px line: the default 22px centre is inside it.
    const style = TextStyle(fontSize: 20, height: 1.7);
    await pump(tester, alignment: HomericBlockGrabberAlignment.center);
    final held = glyphCenter();

    await pump(
      tester,
      alignment: HomericBlockGrabberAlignment.center,
      holdsRowHeight: false,
      style: style,
    );

    expect(glyphCenter(), closeTo(held, 0.01));
  });

  group('firstLineLetters', () {
    setUp(() => HomericLetterMetrics.register('Letters', 0.5));
    tearDown(HomericLetterMetrics.debugReset);

    for (final scale in [1.0, 1.3]) {
      testWidgets('centres the dots on the letters at ${scale}x',
          (tester) async {
        const style =
            TextStyle(fontFamily: 'Letters', fontSize: 20, height: 1.7);
        await pump(
          tester,
          alignment: HomericBlockGrabberAlignment.firstLineLetters,
          padding: const EdgeInsets.only(top: 18),
          style: style,
          textScale: scale,
        );

        // Half an x-height (0.5 of the scaled size) above the baseline.
        final letters = firstLineBaseline(tester) - 20 * scale * 0.5 / 2;
        expect(tester.getCenter(glyphFinder.first).dy, closeTo(letters, 0.01));
      });
    }

    testWidgets('block geometry reports the line baseline', (tester) async {
      const style = TextStyle(fontFamily: 'Letters', fontSize: 20, height: 1.7);
      await pump(
        tester,
        alignment: HomericBlockGrabberAlignment.firstLineLetters,
        style: style,
      );
      final state = tester.state<HomericEditableDocumentState>(
          find.byType(HomericEditableDocument));
      final block = state.documentGeometry.block('a')!;
      final top = tester
          .renderObject<RenderBox>(find.byType(HomericParagraph).first)
          .localToGlobal(Offset.zero)
          .dy;
      expect(block.globalOrigin!.dy + block.baselineAt(0)!,
          closeTo(firstLineBaseline(tester), 0.01));
      expect(top, lessThan(firstLineBaseline(tester)));
    });
  });
}
