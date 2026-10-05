import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/margin.dart';
import 'package:homeric_playground/fixtures.dart';
import 'package:homeric_playground/view_models/document_view_model.dart';
import 'package:homeric_playground/views/editor_page.dart';

void main() {
  testWidgets('the margin demo places sparse, colliding and crowded notes',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final viewModel = DocumentViewModel(document: buildFixtureDocument());
    addTearDown(viewModel.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: EditorPage(viewModel: viewModel, marginDemo: true)),
    ));
    await tester.pump();
    await tester.pump();

    Finder note(String id) =>
        find.byKey(ValueKey<String>('homeric-margin-note-$id'));
    expect(note('typo'), findsOneWidget);
    expect(note('bold'), findsOneWidget);
    expect(note('hidden'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('homeric-margin-connector-hidden')),
      findsOneWidget,
      reason: 'the colliding note is displaced',
    );
    expect(note('crowd-0'), findsOneWidget);
    expect(tester.getSize(note('crowd-0')).height, closeTo(14 * 1.4, 0.01),
        reason: 'the crowded paragraph shows previews');

    // The demo expands a note activated in its compact form.
    final layer = tester.state<HomericMarginLayerState>(
      find.byType(HomericMarginLayer),
    );
    expect(layer.formOf('crowd-1'), MarginNoteForm.compact);
    await tester.tap(note('crowd-1'));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('homeric-margin-expanded-crowd-1')),
      findsOneWidget,
    );
    // Tapping the expanded note activates it again, which closes it.
    await tester.tap(
      find.byKey(const ValueKey<String>('homeric-margin-expanded-crowd-1')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('homeric-margin-expanded-crowd-1')),
      findsNothing,
    );
    expect(note('crowd-1'), findsOneWidget);

    await tester.tap(find.text('Annotate selection'));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('homeric-margin-composer')),
        findsOneWidget);
    await tester.enterText(find.byType(TextField), 'A new thought');
    await tester.tap(find.text('Save'));
    await tester.pump();
    await tester.pump();
    expect(find.text('A new thought'), findsOneWidget);
    expect(find.byType(HomericMarginLayer), findsOneWidget);
  });

  testWidgets('the demo is off unless asked for', (tester) async {
    final viewModel = DocumentViewModel(document: buildFixtureDocument());
    addTearDown(viewModel.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: EditorPage(viewModel: viewModel)),
    ));
    expect(find.byType(HomericMarginLayer), findsNothing);
  });
}
