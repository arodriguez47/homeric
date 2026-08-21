import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric_playground/benchmark/benchmark_fixture.dart';
import 'package:homeric_playground/view_models/document_view_model.dart';
import 'package:homeric_playground/views/editor_page.dart';

void main() {
  test('benchmark corpus identity uses exact bytes and whitespace words', () {
    expect(
      benchmarkFixtureIdentity('a b\n'),
      (words: 2, fnv1a32: '2a228168'),
    );
  });

  test('benchmark calibration balances first-trace cache warming', () {
    expect(
      [
        for (var sample = 0; sample < benchmarkSamplePairCount; sample++)
          benchmarkInstrumentedFirst(sample),
      ],
      [false, true, false, true],
    );
    expect(
      benchmarkPairedDeltaBasisPoints(
        controlP95Us: [10000, 10000, 10000, 10000],
        instrumentedP95Us: [9000, 11000, 9200, 10800],
      ),
      0,
      reason: 'equal first-trace warming bias must cancel across both orders',
    );
    expect(
      benchmarkPairedDeltaBasisPoints(
        controlP95Us: [10000, 10000, 10000, 10000],
        instrumentedP95Us: [10000, 12000, 10200, 11800],
      ),
      1000,
      reason: 'balanced pairing must retain real instrumentation overhead',
    );
  });

  test('benchmark calibration rejects invalid pairs and frame windows', () {
    int calculate(List<int> control, List<int> instrumented) =>
        benchmarkPairedDeltaBasisPoints(
          controlP95Us: control,
          instrumentedP95Us: instrumented,
        );

    expect(() => calculate([], []), throwsArgumentError);
    expect(() => calculate([1, 1], [1]), throwsArgumentError);
    expect(() => calculate([1, 1, 1], [1, 1, 1]), throwsArgumentError);
    expect(() => calculate([0, 1], [1, 1]), throwsArgumentError);
    expect(() => calculate([1, 1], [-1, 1]), throwsArgumentError);
    expect(() => benchmarkRequireExactFrameCount(99), throwsStateError);
    expect(() => benchmarkRequireExactFrameCount(101), throwsStateError);
    expect(
      () => benchmarkRequireExactFrameCount(
        1,
        expected: benchmarkColdMountFrameCount,
      ),
      returnsNormally,
    );
    expect(
      () => benchmarkRequireExactFrameCount(benchmarkTraceFrameCount),
      returnsNormally,
    );
  });

  test('benchmark Markdown parser assigns stable blocks and types', () {
    final document = benchmarkDocumentFromMarkdown(
      '# Title\n\nparagraph words\n\n- one\n- two\n\n> quote',
    );

    expect(document.blocks.map((block) => block.id), [
      'benchmark-block-0',
      'benchmark-block-1',
      'benchmark-block-2',
      'benchmark-block-3',
    ]);
    expect(document.blocks.map((block) => block.type), [
      'heading',
      'paragraph',
      'list',
      'blockquote',
    ]);
  });

  testWidgets('document viewport stays lazy across playground scrolling',
      (tester) async {
    tester.view
      ..physicalSize = const Size(1440, 900)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final document = Document([
      for (var index = 0; index < 700; index++)
        Block(
          id: 'block-$index',
          type: 'paragraph',
          runs: [InlineRun('block $index has benchmark text')],
        ),
    ]);
    final viewModel = DocumentViewModel(document: document);
    addTearDown(viewModel.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EditorPage(viewModel: viewModel, cacheExtent: 250),
      ),
    ));

    expect(find.byType(HomericEditableDocument), findsOneWidget);
    expect(
        find.byType(HomericEditableParagraph).evaluate().length, lessThan(50));
    expect(find.text('⋮'), findsWidgets);
    expect(find.text('block 699 has benchmark text'), findsNothing);

    await tester.drag(find.byType(Scrollable), const Offset(0, -600));
    await tester.pump();
    expect(
        find.byType(HomericEditableParagraph).evaluate().length, lessThan(50));
  });
}
