import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric_playground/fixtures.dart';
import 'package:homeric_playground/main.dart';
import 'package:homeric_playground/view_models/document_view_model.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('mobile touch selection uses one lazy editor owner',
      (tester) async {
    final actualPlatform = defaultTargetPlatform;
    final isMobile = actualPlatform == TargetPlatform.iOS ||
        actualPlatform == TargetPlatform.android;
    tester.view
      ..physicalSize = const Size(900, 700)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final document = buildTouchFixtureDocument();
    final viewModel = DocumentViewModel(
      document: document,
      decorations: buildTouchFixtureDecorations(document),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      viewModel.dispose();
    });
    final controller = viewModel.editorController;
    final inputSession = viewModel.inputSession;

    await tester.pumpWidget(PlaygroundApp(viewModel: viewModel));
    await tester.pumpAndSettle();

    expect(find.byType(HomericEditableDocument), findsOneWidget);
    final mounted = tester.widgetList<HomericEditableParagraph>(
      find.byType(HomericEditableParagraph),
    );
    expect(mounted, isNotEmpty);
    expect(mounted.length, lessThan(document.blockCount));
    expect(mounted.every((row) => identical(row.controller, controller)), true);
    expect(
      mounted.every((row) => identical(row.inputSession, inputSession)),
      true,
    );

    await tester.longPress(
      find.byType(HomericParagraph).first,
      pointer: 1,
    );
    await tester.pump();
    expect(controller.selection, isNotNull);
    if (isMobile) {
      expect(controller.selection!.isCollapsed, false);
      expect(inputSession.isAttached, true);
      expect(find.byType(CompositedTransformFollower), findsWidgets);
    }
    tester.view.physicalSize = const Size(700, 900);
    await tester.pumpAndSettle();
    expect(viewModel.editorController, same(controller));
    expect(viewModel.inputSession, same(inputSession));
    if (isMobile) expect(controller.selection!.isCollapsed, false);

    binding.reportData ??= <String, dynamic>{};
    binding.reportData!['homeric_touch'] = <String, Object>{
      'actual_platform': actualPlatform.name,
      'physical_mobile_platform': isMobile,
      'blocks': document.blockCount,
      'mounted_rows': mounted.length,
      'long_press_selection':
          isMobile ? 'expanded_on_device' : 'not_asserted_on_desktop_host',
      'rotation_owner_identity': 'preserved',
    };
  });
}
