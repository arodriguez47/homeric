// An app-wide zoom draws the editor scaled: window (global) distances are
// longer than the editor's own. Caret reveal, selection autoscroll and
// pointer drags must measure in the editor's units, or a zoomed-in editor
// scrolls when nothing is out of view and drags stop short of line ends.

import 'package:flutter/widgets.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

const _style = TextStyle(fontSize: 14);
const _zoom = 2.0;

void main() {
  Future<
      ({
        HomericEditorController controller,
        ScrollController scroll,
        GlobalKey<HomericEditableDocumentState> key,
      })> pumpScaled(WidgetTester tester, List<String> rows) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final document = Document(<Block>[
      for (var index = 0; index < rows.length; index++)
        Block(
          id: 'block-$index',
          type: 'paragraph',
          runs: <InlineRun>[InlineRun(rows[index])],
        ),
    ]);
    final controller = HomericEditorController(document: document);
    final session = HomericTextInputSession(controller: controller);
    final scroll = ScrollController();
    final key = GlobalKey<HomericEditableDocumentState>();
    addTearDown(scroll.dispose);
    addTearDown(session.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Localizations(
        locale: const Locale('en'),
        delegates: const <LocalizationsDelegate<dynamic>>[
          DefaultWidgetsLocalizations.delegate,
        ],
        child: Overlay(
          initialEntries: <OverlayEntry>[
            OverlayEntry(
              builder: (_) => Align(
                alignment: Alignment.topLeft,
                child: Transform.scale(
                  scale: _zoom,
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 500,
                    height: 300,
                    child: HomericEditableDocument.builder(
                      key: key,
                      controller: controller,
                      inputSession: session,
                      scrollController: scroll,
                      cacheExtent: 0,
                      estimatedBlockHeight: 44,
                      blockBuilder: (context, block, focusNode) =>
                          HomericEditableParagraph(
                        controller: controller,
                        inputSession: session,
                        blockId: block.id,
                        focusNode: focusNode,
                        resolveStyle: (_) => _style,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ));
    await tester.pump();
    return (controller: controller, scroll: scroll, key: key);
  }

  testWidgets('a caret inside a scaled viewport is not scrolled to',
      (tester) async {
    final editor = await pumpScaled(
      tester,
      List<String>.generate(40, (index) => 'line $index'),
    );
    final document = editor.controller.document;
    // Focus the editor: the caret is revealed only while editing.
    final first = find.byKey(const ValueKey('homeric-editable-block-0'));
    await tester.tapAt(tester.getTopLeft(first) + const Offset(15, 7));
    await tester.pump();
    // Row 5 sits in the lower half of the 300px viewport: on screen, but
    // twice as far from its top in window units.
    final row = tester.getRect(
      find.byKey(const ValueKey('homeric-editable-block-5')),
    );
    expect(row.bottom, lessThan(300 * _zoom),
        reason: 'precondition: the row is drawn inside the viewport');
    expect(row.top, greaterThan(300),
        reason: 'precondition: unscaled, the row would read as below it');
    editor.controller.setSelection(
      HomericSelection.collapsed(document.positionAt(5, 2)),
    );
    for (var frame = 0; frame < 4; frame++) {
      await tester.pump();
    }
    expect(editor.scroll.offset, 0,
        reason: 'MUTATION: measuring the caret in window units scrolls a '
            'visible caret');
  });

  testWidgets('dragging inside a scaled viewport does not autoscroll',
      (tester) async {
    final editor = await pumpScaled(
      tester,
      List<String>.generate(40, (index) => 'row $index content'),
    );
    final document = editor.controller.document;
    editor.key.currentState!
        .beginPointerSelectionDrag(document.positionAt(0, 1));
    // Two thirds down the drawn viewport, well clear of its bottom band.
    editor.key.currentState!
        .updatePointerSelectionDrag(const Offset(200, 300 * _zoom * 2 / 3));
    for (var tick = 0; tick < 4; tick++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(editor.scroll.offset, 0,
        reason: 'MUTATION: an unscaled edge band covers the lower half');

    // The drawn bottom band still scrolls.
    editor.key.currentState!
        .updatePointerSelectionDrag(const Offset(200, 300 * _zoom - 10));
    for (var tick = 0; tick < 4; tick++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(editor.scroll.offset, greaterThan(0));
    editor.key.currentState!.cancelPointerSelectionDrag();
  });

  testWidgets('a drag in a scaled viewport reaches the end of a line',
      (tester) async {
    const text = 'a line long enough to run past half the column width';
    final editor = await pumpScaled(tester, <String>['first', text]);
    final document = editor.controller.document;
    final row = tester.getRect(
      find.byKey(const ValueKey('homeric-editable-block-1')),
    );
    editor.key.currentState!
        .beginPointerSelectionDrag(document.positionAt(0, 0));
    editor.key.currentState!.updatePointerSelectionDrag(
      Offset(row.right - 2, row.center.dy),
    );
    await tester.pump();
    expect(
        editor.controller.selection!.head, document.positionAt(1, text.length),
        reason: 'MUTATION: an unscaled block rect clamps the pointer to '
            'half the drawn line');
    editor.key.currentState!.cancelPointerSelectionDrag();
  });
}
