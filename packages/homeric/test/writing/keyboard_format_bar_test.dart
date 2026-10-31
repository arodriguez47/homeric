import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart' show MaterialApp, Scaffold;
import 'package:flutter/widgets.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric/writing.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  testWidgets(
      'with the keyboard up, the focused editor shows its format bar '
      'on top of the keys and the page makes room for it', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final harness = await _pump(tester, 'one two');

    expect(_bar, findsOneWidget);
    // Sits on the keyboard, the full width of the screen.
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(tester.getBottomLeft(_bar).dy, screen.height - _keyboard);
    expect(tester.getSize(_bar).width, screen.width);
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
    expect(find.byKey(const ValueKey<String>('homeric-keyboard-hide')),
        findsOneWidget);
    // The page sees the bar as part of the keyboard.
    expect(harness.insets(), _keyboard + HomericKeyboardFormatBar.height);
    await _unmount(tester);
  });

  testWidgets('no bar while the keyboard is down, or on a Mac', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final harness = await _pump(tester, 'one two', keyboard: false);
    expect(_bar, findsNothing);
    expect(harness.insets(), 0);
    await _unmount(tester);

    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await _pump(tester, 'one two');
    expect(_bar, findsNothing);
    await _unmount(tester);
  });

  testWidgets('no bar when the focus is outside the editor', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final harness = await _pump(tester, 'one two');
    expect(_bar, findsOneWidget);

    harness.elsewhere.requestFocus();
    await tester.pump();
    await tester.pump();
    expect(_bar, findsNothing);
    expect(harness.insets(), _keyboard);
    await _unmount(tester);
  });

  testWidgets('a button wraps the selected words and keeps the focus',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final harness = await _pump(tester, 'one two');
    final document = harness.controller.document;
    harness.controller.setSelection(HomericSelection(
      anchor: document.positionAt(0, 4),
      head: document.positionAt(0, 7),
    ));
    await tester.pump();

    await tester.tap(_button('Italic'));
    await tester.pump();

    expect(harness.controller.document.blocks.single.text, 'one *two*');
    expect(_pressed(tester, 'Italic'), isTrue);
    expect(harness.focus().hasFocus, isTrue);

    await tester.tap(_button('Italic'));
    await tester.pump();
    expect(harness.controller.document.blocks.single.text, 'one two');
    await _unmount(tester);
  });

  testWidgets(
      'with a caret, a button acts on the word around it and the caret '
      'stays where it was', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final harness = await _pump(tester, "one don't two");
    final document = harness.controller.document;
    // At the end of the word just typed.
    harness.controller
        .setSelection(HomericSelection.collapsed(document.positionAt(0, 9)));
    await tester.pump();

    await tester.tap(_button('Bold'));
    await tester.pump();

    expect(harness.controller.document.blocks.single.text, "one **don't** two");
    final caret = harness.controller.selection!;
    expect(caret.isCollapsed, isTrue);
    // Inside the marks, after the word: what comes next is bold too.
    expect(caret.head, harness.controller.document.positionAt(0, 11));
    expect(_pressed(tester, 'Bold'), isTrue);
    await _unmount(tester);
  });

  testWidgets(
      'Outdent and Indent stay in sight beside the hide key and move the '
      'line, not the word', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final harness = await _pump(tester, 'one two', indents: true);
    final document = harness.controller.document;
    harness.controller
        .setSelection(HomericSelection.collapsed(document.positionAt(0, 5)));
    await tester.pump();

    expect(_labels(tester).sublist(8), ['Outdent', 'Indent']);
    final hide = tester.getTopLeft(
        find.byKey(const ValueKey<String>('homeric-keyboard-hide')));
    final indent = tester.getTopRight(_button('Indent'));
    // Pinned: right against the hide key, whatever the words' row scrolls.
    expect(hide.dx - indent.dx, lessThan(2));
    expect(_enabled(tester, 'Outdent'), isFalse);

    await tester.tap(_button('Indent'));
    await tester.pump();
    expect(harness.controller.document.blocks.single.text, '  one two');
    final caret = harness.controller.selection!;
    expect(caret.isCollapsed, isTrue);
    expect(caret.head, harness.controller.document.positionAt(0, 7));
    expect(_enabled(tester, 'Outdent'), isTrue);
    expect(_enabled(tester, 'Indent'), isFalse);
    expect(harness.focus().hasFocus, isTrue);
    await _unmount(tester);
  });

  testWidgets('with a caret in a space the wraps are disabled', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final harness = await _pump(tester, 'one  two');
    final document = harness.controller.document;
    harness.controller
        .setSelection(HomericSelection.collapsed(document.positionAt(0, 4)));
    await tester.pump();

    expect(_enabled(tester, 'Bold'), isFalse);
    await tester.tap(_button('Bold'));
    await tester.pump();
    expect(harness.controller.document.blocks.single.text, 'one  two');
    await _unmount(tester);
  });

  testWidgets('Link over a caret word does what typing [[ does',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final harness = await _pump(tester, 'one two');
    final document = harness.controller.document;
    harness.controller
        .setSelection(HomericSelection.collapsed(document.positionAt(0, 1)));
    await tester.pump();

    await tester.tap(_button('Link'));
    await tester.pump();
    expect(harness.controller.document.blocks.single.text, '[[one]] two');
    await _unmount(tester);
  });

  testWidgets('a press closes a drawn selection menu', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final harness = await _pump(tester, 'one two');
    final document = harness.controller.document;
    harness.controller.setSelection(HomericSelection(
      anchor: document.positionAt(0, 0),
      head: document.positionAt(0, 3),
    ));
    await tester.pump();
    final menu = ContextMenuController();
    menu.show(
      context: tester.element(find.byType(Scaffold)),
      contextMenuBuilder: (_) => const SizedBox(
        key: ValueKey<String>('menu'),
        width: 10,
        height: 10,
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('menu')), findsOneWidget);

    await tester.tap(_button('Bold'));
    await tester.pump();
    expect(harness.controller.document.blocks.single.text, '**one** two');
    expect(find.byKey(const ValueKey<String>('menu')), findsNothing);
    await _unmount(tester);
  });

  testWidgets('VoiceOver can press a button', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final handle = tester.ensureSemantics();
    final harness = await _pump(tester, 'one two');
    final document = harness.controller.document;
    harness.controller.setSelection(HomericSelection(
      anchor: document.positionAt(0, 0),
      head: document.positionAt(0, 3),
    ));
    await tester.pump();

    tester.semantics.tap(find.semantics.byLabel('Bold'));
    await tester.pump();
    expect(harness.controller.document.blocks.single.text, '**one** two');
    handle.dispose();
    await _unmount(tester);
  });

  testWidgets('the hide key puts the keyboard away', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final harness = await _pump(tester, 'one two');

    await tester
        .tap(find.byKey(const ValueKey<String>('homeric-keyboard-hide')));
    await tester.pump();
    expect(harness.focus().hasFocus, isFalse);
    expect(_bar, findsNothing);
    await _unmount(tester);
  });
}

const double _keyboard = 300;

final Finder _bar =
    find.byKey(const ValueKey<String>('homeric-keyboard-format-bar'));

Finder _button(String label) =>
    find.byKey(ValueKey<String>('homeric-keyboard-format-$label'));

Semantics _semantics(WidgetTester tester, String label) =>
    tester.widget<Semantics>(find
        .descendant(of: _button(label), matching: find.byType(Semantics))
        .first);

List<String> _labels(WidgetTester tester) => tester
    .widgetList(find.descendant(
      of: _bar,
      matching: find.byWidgetPredicate((widget) =>
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>)
              .value
              .startsWith('homeric-keyboard-format-')),
    ))
    .map((w) => (w.key! as ValueKey<String>).value.substring(24))
    .where((label) => label != 'bar')
    .toList(growable: false);

bool? _pressed(WidgetTester tester, String label) =>
    _semantics(tester, label).properties.selected;

bool? _enabled(WidgetTester tester, String label) =>
    _semantics(tester, label).properties.enabled;

Future<
    ({
      HomericEditorController controller,
      FocusNode Function() focus,
      FocusNode elsewhere,
      double Function() insets,
    })> _pump(
  WidgetTester tester,
  String text, {
  bool keyboard = true,
  bool indents = false,
}) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  tester.view.viewInsets =
      FakeViewPadding(bottom: keyboard ? _keyboard * 3 : 0);
  addTearDown(tester.view.reset);
  final controller = HomericEditorController(
    document: Document([
      Block(id: 'a', type: 'paragraph', runs: [InlineRun(text)]),
    ]),
  );
  final session = HomericTextInputSession(controller: controller);
  final wraps = const HomericTypedWraps(linkAlias: false).sessionFor(
    controller,
  );
  final elsewhere = FocusNode();
  addTearDown(controller.addCommandInterceptor(wraps.intercept));
  addTearDown(session.dispose);
  addTearDown(controller.dispose);
  addTearDown(elsewhere.dispose);
  FocusNode? focus;
  var insets = -1.0;
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => HomericKeyboardFormatBar(child: child!),
    home: Builder(builder: (context) {
      insets = MediaQuery.viewInsetsOf(context).bottom;
      return Scaffold(
        body: Column(
          children: [
            Focus(focusNode: elsewhere, child: const SizedBox(height: 10)),
            SizedBox(
              width: 390,
              height: 300,
              child: HomericEditableDocument.builder(
                controller: controller,
                inputSession: session,
                selectionFormatBarBuilder: (selection, _, __) =>
                    HomericFormatBar.standard(
                  controller,
                  selection,
                  wraps: wraps,
                  indents: indents,
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
          ],
        ),
      );
    }),
  ));
  focus!.requestFocus();
  await tester.pump();
  await tester.pump();
  return (
    controller: controller,
    focus: () => focus!,
    elsewhere: elsewhere,
    insets: () => insets,
  );
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  debugDefaultTargetPlatformOverride = null;
}
