import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kLongPressTimeout;
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
    final isIos = actualPlatform == TargetPlatform.iOS;
    final isMobile = actualPlatform == TargetPlatform.iOS ||
        actualPlatform == TargetPlatform.android;
    final initialPhysicalSize = tester.view.physicalSize;
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

    final paragraph = find.byType(HomericParagraph).first;
    final paragraphGeometry = ParagraphGeometry(
      tester.renderObject<RenderHomericParagraph>(paragraph),
    );
    final firstWordRect = paragraphGeometry
        .rectsForRange(
          DocRange(const DocOffset(0), const DocOffset(7)),
        )
        .value
        .first
        .toRect();
    final firstWordCenter = tester.getTopLeft(paragraph) + firstWordRect.center;
    final documentState = tester.state<HomericEditableDocumentState>(
      find.byType(HomericEditableDocument),
    );
    int? iosStateRevisionAfterLongPress;
    TestGesture? activeTouch;
    if (isMobile) {
      activeTouch = await tester.startGesture(
        firstWordCenter,
        pointer: 1,
        kind: PointerDeviceKind.touch,
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
      if (isIos) {
        expect(controller.selection, isNotNull);
        expect(controller.selection!.isCollapsed, true,
            reason: 'focused iOS long press leaves word selection to the '
                'epoch-bound floating cursor');
        iosStateRevisionAfterLongPress = controller.stateRevision;
      }
      await activeTouch.moveBy(const Offset(40, 0));
      await tester.pump();
    } else {
      await tester.longPress(paragraph, pointer: 1);
      await tester.pump();
    }
    expect(controller.selection, isNotNull);
    if (isMobile) {
      if (isIos) {
        expect(controller.stateRevision, iosStateRevisionAfterLongPress,
            reason: 'pointer movement after focused iOS long press cannot '
                'become a second selection route');
      } else {
        expect(controller.selection!.isCollapsed, false,
            reason: 'Android long press expands the visible word selection');
      }
      expect(inputSession.isAttached, true);
      expect(documentState.hasEditingFocus, true,
          reason: 'the active long press retains the mounted editing focus');
      if (isIos) {
        expect(documentState.touchSelectionChromeVisible, true,
            reason: 'the focused iOS caret keeps one derived touch overlay '
                'while canonical movement remains platform-owned');
        expect(documentState.debugTouchStartHandleVisible, true,
            reason: 'the collapsed iOS caret exposes one handle');
        expect(documentState.debugTouchEndHandleVisible, false,
            reason: 'a collapsed iOS caret never exposes a second handle');
      } else {
        final startGeometry = documentState.selectionEndpointGeometry(
          HomericSelectionEndpoint.start,
        );
        final endGeometry = documentState.selectionEndpointGeometry(
          HomericSelectionEndpoint.end,
        );
        expect(startGeometry, isNotNull,
            reason: 'the expanded selection exposes current start geometry');
        expect(endGeometry, isNotNull,
            reason: 'the expanded selection exposes current end geometry');
        expect(documentState.touchSelectionChromeVisible, true,
            reason: 'the mobile host owns one current selection overlay');
        expect(documentState.debugTouchStartHandleVisible, true,
            reason: 'the expanded selection exposes its start handle');
        expect(documentState.debugTouchEndHandleVisible, true,
            reason: 'the expanded selection exposes its end handle');
      }
      documentState.beginPointerSelectionDrag(
        controller.selection!.anchor,
        owner: Object(),
      );
      expect(documentState.pointerSelectionDragActive, true,
          reason: 'rotation starts with one active document capability');
    }
    addTearDown(tester.view.reset);
    tester.view.physicalSize = Size(
      initialPhysicalSize.height,
      initialPhysicalSize.width,
    );
    await tester.pumpAndSettle();
    expect(viewModel.editorController, same(controller));
    expect(viewModel.inputSession, same(inputSession));
    if (isMobile) {
      expect(controller.selection!.isCollapsed, isIos);
      expect(documentState.pointerSelectionDragActive, false);
      expect(documentState.debugTouchMovingEndpoint, isNull);
      expect(documentState.debugTouchMagnifierVisible, false);
      final selectionAfterRotation = controller.selection;
      await activeTouch!.moveBy(const Offset(-40, 0));
      await activeTouch.up();
      await tester.pump();
      expect(controller.selection, selectionAfterRotation,
          reason: 'the pre-rotation touch capability stays revoked');
    }

    binding.reportData ??= <String, dynamic>{};
    binding.reportData!['homeric_touch'] = <String, Object>{
      'actual_platform': actualPlatform.name,
      'physical_mobile_platform': isMobile,
      'blocks': document.blockCount,
      'mounted_rows': mounted.length,
      'long_press_selection': isIos
          ? 'focused_editor_deferred_to_floating_cursor'
          : isMobile
              ? 'expanded_on_device'
              : 'not_asserted_on_desktop_host',
      'rotation_active_capability':
          isMobile ? 'revoked_with_owner_preserved' : 'not_run_on_desktop',
    };
  });
}
