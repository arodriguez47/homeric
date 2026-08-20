import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric_playground/benchmark/benchmark_fixture.dart';
import 'package:homeric_playground/view_models/document_view_model.dart';
import 'package:homeric_playground/views/editor_page.dart';

void main() {
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

  testWidgets('current ListView baseline never eagerly mounts all rows',
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

    expect(
        find.byType(HomericEditableParagraph).evaluate().length, lessThan(50));
    expect(find.text('block 699 has benchmark text'), findsNothing);

    await tester.drag(find.byType(Scrollable), const Offset(0, -600));
    await tester.pump();
    expect(
        find.byType(HomericEditableParagraph).evaluate().length, lessThan(50));
  });
}
