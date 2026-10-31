import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kSecondaryMouseButton;
import 'package:flutter/material.dart'
    show AdaptiveTextSelectionToolbar, MaterialApp, Scaffold, Tooltip;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter/widgets.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric/writing.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  testWidgets(
      'a right click on desktop shows the format bar over the edit '
      'items', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final harness = await _pump(tester, 'one two');
    await _rightClickFirstWord(tester);

    expect(_bar, findsOneWidget);
    expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
    expect(_labels(tester), [
      'Bold',
      'Italic',
      'Strikethrough',
      'Highlight',
      'Aside',
      'Code',
      'Link',
      'Note',
    ]);
    // The edit rows sit under the bar, each with its key.
    final barBottom = tester.getBottomLeft(_bar).dy;
    expect(tester.getTopLeft(find.text('Cut')).dy, greaterThan(barBottom));
    expect(find.text('⌘X'), findsOneWidget);
    expect(find.text('⇧⌘Z'), findsOneWidget);
    expect(harness.controller.document.blocks.single.text, 'one two');
    await _unmount(tester);
  });

  testWidgets('a button wraps the right-clicked word and closes the menu',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final harness = await _pump(tester, 'one two');
    await _rightClickFirstWord(tester);

    await tester.tap(_button('Bold'));
    await tester.pump();

    expect(harness.controller.document.blocks.single.text, '**one** two');
    expect(_bar, findsNothing);
    await _unmount(tester);
  });

  testWidgets(
      'a button over words that carry its marker shows pressed and '
      'takes it off', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final harness = await _pump(tester, '==one== two');
    final document = harness.controller.document;
    harness.controller.setSelection(HomericSelection(
      anchor: document.positionAt(0, 2),
      head: document.positionAt(0, 5),
    ));
    await tester.pump();
    final words = tester.getTopLeft(_paragraph) + const Offset(30, 7);
    await tester.tapAt(words, buttons: kSecondaryMouseButton);
    await tester.pump();

    expect(_pressed(tester, 'Highlight'), isTrue);
    expect(_pressed(tester, 'Bold'), isFalse);

    await tester.tap(_button('Highlight'));
    await tester.pump();
    expect(harness.controller.document.blocks.single.text, 'one two');
    await _unmount(tester);
  });

  testWidgets('Link does what typing [[ over the words does', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final harness = await _pump(tester, 'one two');
    await _rightClickFirstWord(tester);

    await tester.tap(_button('Link'));
    await tester.pump();

    expect(harness.controller.document.blocks.single.text, '[[one]] two');
    await _unmount(tester);
  });

  testWidgets('opening the menu leaves Backspace able to undo a typed wrap',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final harness = await _pump(tester, 'one two');
    final controller = harness.controller;
    final document = controller.document;
    controller.setSelection(HomericSelection(
      anchor: document.positionAt(0, 0),
      head: document.positionAt(0, 3),
    ));
    controller.replaceSelection('=');
    controller.replaceSelection('=');
    await tester.pump();
    expect(controller.document.blocks.single.text, '==one== two');

    final words = tester.getTopLeft(_paragraph) + const Offset(30, 7);
    await tester.tapAt(words, buttons: kSecondaryMouseButton);
    await tester.pump();
    expect(_bar, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(_bar, findsNothing);

    controller.deleteBackward();
    expect(controller.document.blocks.single.text, 'one two');
    await _unmount(tester);
  });

  testWidgets('hovering a button explains it', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await _pump(tester, 'one two');
    await _rightClickFirstWord(tester);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(_button('Highlight')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      find.text('Marks the words as a pen would, to find them again.'),
      findsOneWidget,
    );
    expect(find.text('==words=='), findsOneWidget);
    await mouse.moveTo(Offset.zero);
    await tester.pump(const Duration(seconds: 1));
    await _unmount(tester);
  });

  testWidgets('touch keeps the toolbar it had, with no bar', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await _pump(tester, 'one two');
    await _rightClickFirstWord(tester);

    expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
    expect(_bar, findsNothing);
    await _unmount(tester);
  });

  testWidgets('a host without a bar gets the desktop menu without one',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await _pump(tester, 'one two', bar: false);
    await _rightClickFirstWord(tester);

    expect(
      find.byKey(const ValueKey<String>('homeric-context-menu')),
      findsOneWidget,
    );
    expect(_bar, findsNothing);
    expect(find.text('Cut'), findsOneWidget);
    await _unmount(tester);
  });

  test('isWrapped reads exactly the marker, not a longer run', () {
    final document = Document([
      Block(id: 'a', type: 'paragraph', runs: [InlineRun('**one** *two*')]),
    ]);
    HomericSelection words(int start, int end) => HomericSelection(
          anchor: document.positionAt(0, start),
          head: document.positionAt(0, end),
        );
    expect(HomericWrapShortcuts.isWrapped(document, words(2, 5), '**'), isTrue);
    expect(HomericWrapShortcuts.isWrapped(document, words(2, 5), '*'), isFalse);
    expect(HomericWrapShortcuts.isWrapped(document, words(9, 12), '*'), isTrue);
  });
}

final Finder _bar = find.byKey(const ValueKey<String>('homeric-format-bar'));

final Finder _paragraph =
    find.byKey(const ValueKey<String>('homeric-editable-a'));

Finder _button(String label) =>
    find.byKey(ValueKey<String>('homeric-format-$label'));

List<String> _labels(WidgetTester tester) => tester
    .widgetList<Tooltip>(
        find.descendant(of: _bar, matching: find.byType(Tooltip)))
    .map((tip) => (tip.key! as ValueKey<String>).value.substring(15))
    .toList(growable: false);

bool? _pressed(WidgetTester tester, String label) => tester
    .widget<Semantics>(find.descendant(
      of: _button(label),
      matching: find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.label == label,
      ),
    ))
    .properties
    .selected;

Future<({HomericEditorController controller})> _pump(
  WidgetTester tester,
  String text, {
  bool bar = true,
}) async {
  final controller = HomericEditorController(
    document: Document([
      Block(id: 'a', type: 'paragraph', runs: [InlineRun(text)]),
    ]),
  );
  final session = HomericTextInputSession(controller: controller);
  final wraps = const HomericTypedWraps(linkAlias: false).sessionFor(
    controller,
  );
  addTearDown(controller.addCommandInterceptor(wraps.intercept));
  addTearDown(session.dispose);
  addTearDown(controller.dispose);
  FocusNode? focus;
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 500,
        height: 300,
        child: HomericEditableDocument.builder(
          controller: controller,
          inputSession: session,
          selectionFormatBarBuilder: !bar
              ? null
              : (selection, _, __) => HomericFormatBar.standard(
                    controller,
                    selection,
                    wraps: wraps,
                  ),
          blockBuilder: (context, block, focusNode) {
            focus = focusNode;
            return HomericEditableParagraph(
              controller: controller,
              inputSession: session,
              blockId: block.id,
              focusNode: focusNode,
              resolveStyle: (_) => const TextStyle(fontSize: 14),
            );
          },
        ),
      ),
    ),
  ));
  focus!.requestFocus();
  await tester.pump();
  return (controller: controller);
}

Future<void> _rightClickFirstWord(WidgetTester tester) async {
  await tester.tapAt(
    tester.getTopLeft(_paragraph) + const Offset(10, 7),
    buttons: kSecondaryMouseButton,
  );
  await tester.pump();
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  debugDefaultTargetPlatformOverride = null;
}
