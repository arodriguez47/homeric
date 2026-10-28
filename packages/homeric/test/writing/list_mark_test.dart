import 'package:flutter/material.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric/writing.dart';

void main() {
  setUp(() => HomericLetterMetrics.register('Letters', 0.5));
  tearDown(HomericLetterMetrics.debugReset);

  // Leading the face doesn't split evenly, so a line that took Material's
  // even leading would sit at a different height from its words.
  const style = TextStyle(
    fontFamily: 'Letters',
    fontSize: 20,
    height: 1.7,
    color: Color(0xFF000000),
  );

  Block block(String text) =>
      Block(id: 'b', type: 'paragraph', runs: [InlineRun(text)]);

  Future<void> pumpLine(
    WidgetTester tester,
    HomericListHang hang, {
    double scale = 1,
  }) async {
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 300,
            child: HomericListLine(
              hang: hang,
              markStyle: style,
              todoMark: (context, hang) => const ColoredBox(
                key: ValueKey('box'),
                color: Color(0xFF000000),
              ),
              // The words, laid out as a Homeric paragraph lays them out:
              // their own style, nothing inherited.
              child: Text(
                'xenon',
                key: const ValueKey('words'),
                style: style.copyWith(inherit: false),
              ),
            ),
          ),
        ),
      ),
    ));
  }

  double wordsBaseline(WidgetTester tester) {
    final words =
        tester.renderObject<RenderBox>(find.byKey(const ValueKey('words')));
    RenderObject.debugCheckingIntrinsics = true;
    try {
      return words.localToGlobal(Offset.zero).dy +
          words.getDistanceToBaseline(TextBaseline.alphabetic)!;
    } finally {
      RenderObject.debugCheckingIntrinsics = false;
    }
  }

  Rect markRect(WidgetTester tester, Finder finder) => tester.getRect(
        find
            .descendant(
              of: find.byKey(const ValueKey('homeric-list-mark')),
              matching: finder,
            )
            .first,
      );

  for (final scale in [0.87, 1.0, 1.3]) {
    testWidgets('a bullet centres on the letters at ${scale}x', (tester) async {
      await pumpLine(tester, HomericListHang.of(block('- xenon'))!,
          scale: scale);

      final bullet = markRect(tester, find.byType(CustomPaint));
      final letters = wordsBaseline(tester) - 20 * scale * 0.5 / 2;
      expect(bullet.center.dy, closeTo(letters, 0.01));
      expect(bullet.height, closeTo(20 * scale * 0.3, 0.01));
    });

    testWidgets('a hung line is as tall as its words at ${scale}x',
        (tester) async {
      await pumpLine(tester, HomericListHang.of(block('- xenon'))!,
          scale: scale);

      expect(
        tester
            .getSize(find.descendant(
                of: find.byType(HomericListLine), matching: find.byType(Row)))
            .height,
        closeTo(
            tester.getSize(find.byKey(const ValueKey('words'))).height, 0.01),
      );
    });

    testWidgets('a to-do box centres on the letters at ${scale}x',
        (tester) async {
      await pumpLine(
          tester, HomericListHang.of(block('- [ ] xenon'), todos: true)!,
          scale: scale);

      final box = tester.getRect(find.byKey(const ValueKey('box')));
      expect(box.center.dy,
          closeTo(wordsBaseline(tester) - 20 * scale * 0.5 / 2, 0.01));
      expect(box.height, closeTo(20 * scale * 0.8, 0.01));
      expect(
        tester
            .getSize(find.descendant(
                of: find.byType(HomericListLine), matching: find.byType(Row)))
            .height,
        closeTo(
            tester.getSize(find.byKey(const ValueKey('words'))).height, 0.01),
      );
    });
  }

  testWidgets('a number stands on the words\' baseline', (tester) async {
    await pumpLine(tester, HomericListHang.of(block('1. xenon'))!, scale: 1.3);

    final number = tester.renderObject<RenderBox>(
      find.descendant(
        of: find.byKey(const ValueKey('homeric-list-mark')),
        matching: find.byType(RichText),
      ),
    );
    RenderObject.debugCheckingIntrinsics = true;
    final baseline = number.localToGlobal(Offset.zero).dy +
        number.getDistanceToBaseline(TextBaseline.alphabetic)!;
    RenderObject.debugCheckingIntrinsics = false;
    expect(baseline, closeTo(wordsBaseline(tester), 0.01));
  });

  group('to-dos hang', () {
    test('only when asked', () {
      expect(HomericListHang.of(block('- [ ] task')), isNull);
      final hang = HomericListHang.of(block('- [ ] task'), todos: true)!;
      expect(hang.prefixEnd, 6);
      expect(hang.depth, 0);
      expect(hang.checklist!.done, isFalse);
      expect(hang.checklist!.markerStart, 0);
      expect(hang.checklist!.markerEnd, 5);
    });

    test('ticked, nested, and without a dash', () {
      final done = HomericListHang.of(block('  - [x] done'), todos: true)!;
      expect(done.checklist!.done, isTrue);
      expect(done.depth, 1);
      expect(done.prefixEnd, 8);
      final bare = HomericListHang.of(block('[ ] bare'), todos: true)!;
      expect(bare.prefixEnd, 4);
      expect(bare.checklist!.markerEnd, 3);
    });

    test('not while the caret is in the marker', () {
      expect(
        HomericListHang.of(block('- [ ] task'), todos: true, caret: 3),
        isNull,
      );
      expect(
        HomericListHang.of(block('- [ ] task'), todos: true, caret: 6),
        isNotNull,
      );
    });

    test('the syntax folds the marker and leaves no box slot', () {
      const syntax = HomericSyntax(hangingLists: true, hangingTodos: true);
      final decorations = syntax.decorationsFor(block('- [x] done')).toList();
      expect(
        decorations.where((d) => d.spec is HomericChecklistSpec),
        isEmpty,
      );
      expect(
        decorations.where(
            (d) => d.spec is HomericListHangSpec && d.start == 0 && d.end == 6),
        hasLength(1),
      );
      expect(
        decorations.where((d) =>
            d.spec is HomericMarkSpec &&
            (d.spec as HomericMarkSpec).kind == HomericMarkKind.strike),
        hasLength(1),
      );
    });

    test('off, the box stays a slot in the line', () {
      const syntax = HomericSyntax(hangingLists: true);
      final decorations = syntax.decorationsFor(block('- [ ] task')).toList();
      expect(
        decorations.where((d) => d.spec is HomericChecklistSpec),
        hasLength(1),
      );
    });
  });
}
