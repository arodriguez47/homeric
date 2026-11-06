import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart' show Icons, MaterialApp, Scaffold;
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
    // A phone's row: Undo, Redo, Aa, then what attaches to the words.
    expect(_key('undo'), findsOneWidget);
    expect(_key('redo'), findsOneWidget);
    expect(_key('styles'), findsOneWidget);
    expect(_labels(tester), ['Link', 'Note']);
    expect(find.byKey(const ValueKey<String>('homeric-keyboard-hide')),
        findsOneWidget);
    // The page sees the bar as part of the keyboard.
    expect(harness.insets(), _keyboard + HomericKeyboardFormatBar.height);
    await _unmount(tester);
  });

  testWidgets(
      'Footnote draws a raised 1 after a letter, not a numbered list, '
      'inked like the icons beside it', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await _pump(tester, 'one two', onFootnote: () {});

    expect(_labels(tester).last, 'Footnote');
    final glyph = find.byType(HomericFootnoteGlyph);
    expect(glyph, findsOneWidget);
    expect(find.byIcon(Icons.format_list_numbered_rounded), findsNothing);
    expect(
        tester.getSize(find.byType(CustomPaint).last), const Size.square(19));
    final note =
        IconTheme.of(tester.element(find.byIcon(Icons.sticky_note_2_outlined)));
    final foot = IconTheme.of(tester.element(glyph));
    expect(foot.size, note.size);
    expect(foot.color, note.color);
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
    await _openStyles(tester);

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
    await _openStyles(tester);

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

    expect(_labels(tester), ['Link', 'Note', 'Outdent', 'Indent']);
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

  testWidgets(
      'with a caret in a space, Bold opens a pair round it, the words '
      'typed go in, and Bold again steps out', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final harness = await _pump(tester, 'one  two');
    final controller = harness.controller;
    controller.setSelection(
        HomericSelection.collapsed(controller.document.positionAt(0, 4)));
    await tester.pump();
    await _openStyles(tester);

    expect(_enabled(tester, 'Bold'), isTrue);
    await tester.tap(_button('Bold'));
    await tester.pump();
    expect(controller.document.blocks.single.text, 'one **** two');
    expect(controller.selection!.head, controller.document.positionAt(0, 6));
    expect(_pressed(tester, 'Bold'), isTrue);

    controller.replaceSelection('new');
    await tester.pump();
    expect(controller.document.blocks.single.text, 'one **new** two');
    // Still inside: Bold shows pressed, not acting on the word "new".
    expect(_pressed(tester, 'Bold'), isTrue);

    await tester.tap(_button('Bold'));
    await tester.pump();
    expect(controller.document.blocks.single.text, 'one **new** two');
    expect(controller.selection!.head, controller.document.positionAt(0, 11));
    expect(_pressed(tester, 'Bold'), isFalse);
    expect(harness.focus().hasFocus, isTrue);
    await _unmount(tester);
  });

  testWidgets(
      'a pair left empty goes away when the caret leaves, with nothing '
      'left to undo', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final harness = await _pump(tester, 'one  two');
    final controller = harness.controller;
    controller.setSelection(
        HomericSelection.collapsed(controller.document.positionAt(0, 4)));
    await tester.pump();
    await _openStyles(tester);
    await tester.tap(_button('Italic'));
    await tester.pump();
    expect(controller.document.blocks.single.text, 'one ** two');

    // The caret goes to the end, past the empty pair.
    controller.setSelection(
        HomericSelection.collapsed(controller.document.positionAt(0, 10)));
    await tester.pump();
    expect(controller.document.blocks.single.text, 'one  two');
    expect(controller.selection!.head, controller.document.positionAt(0, 8));
    expect(controller.canUndo, isFalse);
    await _unmount(tester);
  });

  testWidgets(
      'a caret moved into an empty pair\'s marker lands where the pair '
      'stood', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final harness = await _pump(tester, 'one  two');
    final controller = harness.controller;
    controller.setSelection(
        HomericSelection.collapsed(controller.document.positionAt(0, 4)));
    await tester.pump();
    await _openStyles(tester);
    await tester.tap(_button('Bold'));
    await tester.pump();
    expect(controller.document.blocks.single.text, 'one **** two');

    // One step left: between the two stars of the opening marker.
    controller.setSelection(
        HomericSelection.collapsed(controller.document.positionAt(0, 5)));
    await tester.pump();
    expect(controller.document.blocks.single.text, 'one  two');
    expect(controller.selection!.head, controller.document.positionAt(0, 4));
    await _unmount(tester);
  });

  testWidgets(
      'an empty pair left after another change is taken out, and the '
      'other change stays', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final harness = await _pump(tester, 'one  two', indents: true);
    final controller = harness.controller;
    controller.setSelection(
        HomericSelection.collapsed(controller.document.positionAt(0, 4)));
    await tester.pump();
    await _openStyles(tester);
    await tester.tap(_button('Bold'));
    await tester.pump();
    await tester.tap(_key('styles-back'));
    await tester.pump();
    await tester.tap(_button('Indent'));
    await tester.pump();
    expect(controller.document.blocks.single.text, '  one **** two');

    controller.setSelection(
        HomericSelection.collapsed(controller.document.positionAt(0, 14)));
    await tester.pump();
    expect(controller.document.blocks.single.text, '  one  two');
    await _unmount(tester);
  });

  testWidgets('empty pairs opened one inside another all go together',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final harness = await _pump(tester, 'one  two', indents: true);
    final controller = harness.controller;
    controller.setSelection(
        HomericSelection.collapsed(controller.document.positionAt(0, 4)));
    await tester.pump();
    await _openStyles(tester);
    await tester.tap(_button('Bold'));
    await tester.pump();
    await tester.tap(_button('Highlight'));
    await tester.pump();
    expect(controller.document.blocks.single.text, 'one **====** two');
    // Indent first, so the pairs go by deleting rather than by undo.
    await tester.tap(_key('styles-back'));
    await tester.pump();
    await tester.tap(_button('Indent'));
    await tester.pump();

    controller.setSelection(
        HomericSelection.collapsed(controller.document.positionAt(0, 0)));
    await tester.pump();
    expect(controller.document.blocks.single.text, '  one  two');
    await _unmount(tester);
  });

  testWidgets('with a caret after a space, Note pins to the word before it',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final harness = await _pump(tester, 'one two ');
    final controller = harness.controller;
    controller.setSelection(
        HomericSelection.collapsed(controller.document.positionAt(0, 8)));
    await tester.pump();

    expect(_enabled(tester, 'Note'), isTrue);
    await tester.tap(_button('Note'));
    await tester.pump();
    expect(controller.document.blocks.single.text, 'one {{two|}} ');
    // In the note's slot.
    expect(controller.selection!.head, controller.document.positionAt(0, 10));
    await _unmount(tester);
  });

  testWidgets('with a caret in a space, Link starts [[ there', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final harness = await _pump(tester, 'see ');
    final controller = harness.controller;
    controller.setSelection(
        HomericSelection.collapsed(controller.document.positionAt(0, 4)));
    await tester.pump();

    await tester.tap(_button('Link'));
    await tester.pump();
    expect(controller.document.blocks.single.text, 'see [[');
    expect(controller.selection!.head, controller.document.positionAt(0, 6));
    await _unmount(tester);
  });

  testWidgets('Footnote works with only a caret', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    var pressed = 0;
    final harness =
        await _pump(tester, 'one  two', onFootnote: () => pressed++);
    harness.controller.setSelection(HomericSelection.collapsed(
        harness.controller.document.positionAt(0, 4)));
    await tester.pump();

    expect(_enabled(tester, 'Footnote'), isTrue);
    await tester.tap(_button('Footnote'));
    await tester.pump();
    expect(pressed, 1);
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

    await tester.tap(_button('Link'));
    await tester.pump();
    expect(harness.controller.document.blocks.single.text, '[[one]] two');
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
    tester.semantics.tap(find.semantics.byLabel('Text styles'));
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

  testWidgets(
      'Aa swaps the row for the text styles, Bold, Italic and '
      'Strikethrough boxed together, and Back returns', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final harness = await _pump(tester, 'one two', lines: true);
    harness.controller.setSelection(HomericSelection.collapsed(
        harness.controller.document.positionAt(0, 1)));
    await tester.pump();
    expect(_key('styles-dot'), findsNothing);

    await _openStyles(tester);
    expect(_labels(tester), [
      'Bold',
      'Italic',
      'Strikethrough',
      'Highlight',
      'Quote',
      'Code',
      'Comment',
    ]);
    expect(_key('undo'), findsNothing);
    final box = _key('style-box');
    for (final label in ['Bold', 'Italic', 'Strikethrough']) {
      expect(
          find.descendant(of: box, matching: _button(label)), findsOneWidget);
    }
    expect(
        find.descendant(of: box, matching: _button('Highlight')), findsNothing);
    // Every key fits; nothing scrolls off the side.
    final hide = tester.getTopLeft(_key('hide')).dx;
    expect(tester.getTopRight(_button('Comment')).dx, lessThan(hide + 1));
    expect(
        tester.getSize(_button('Highlight')).width, greaterThanOrEqualTo(34));

    await tester.tap(_button('Bold'));
    await tester.pump();
    expect(harness.controller.document.blocks.single.text, '**one** two');
    expect(harness.focus().hasFocus, isTrue);
    // The row stays open for a second style.
    expect(_button('Italic'), findsOneWidget);

    await tester.tap(_key('styles-back'));
    await tester.pump();
    expect(_key('undo'), findsOneWidget);
    // The word carries a style: Aa says so.
    expect(_key('styles-dot'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('the main row fits a phone without scrolling', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await _pump(tester, 'one two',
        indents: true, onFootnote: () {}, screen: const Size(375, 812));
    expect(_labels(tester), ['Link', 'Note', 'Footnote', 'Outdent', 'Indent']);
    final hide = tester.getTopLeft(_key('hide')).dx;
    expect(tester.getTopRight(_button('Indent')).dx, lessThan(hide + 1));
    expect(tester.getSize(_button('Footnote')).width, greaterThanOrEqualTo(36));
    await _unmount(tester);
  });

  testWidgets('Undo and Redo step through the editor history', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final harness = await _pump(tester, 'one two');
    expect(_enabledKey(tester, 'undo'), isFalse);
    expect(_enabledKey(tester, 'redo'), isFalse);
    harness.controller.setSelection(HomericSelection.collapsed(
        harness.controller.document.positionAt(0, 1)));
    await tester.pump();
    await tester.tap(_button('Link'));
    await tester.pump();
    expect(harness.controller.document.blocks.single.text, '[[one]] two');
    expect(_enabledKey(tester, 'undo'), isTrue);

    await tester.tap(_key('undo'));
    await tester.pump();
    expect(harness.controller.document.blocks.single.text, 'one two');
    expect(_enabledKey(tester, 'redo'), isTrue);
    expect(harness.focus().hasFocus, isTrue);

    await tester.tap(_key('redo'));
    await tester.pump();
    expect(harness.controller.document.blocks.single.text, '[[one]] two');
    await _unmount(tester);
  });

  testWidgets(
      'Quote and Comment put their marker on the caret line, whatever word '
      'the caret is in, and take it off again', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final harness = await _pump(tester, 'one two', lines: true);
    harness.controller.setSelection(HomericSelection.collapsed(
        harness.controller.document.positionAt(0, 5)));
    await tester.pump();
    await _openStyles(tester);

    await tester.tap(_button('Quote'));
    await tester.pump();
    expect(harness.controller.document.blocks.single.text, '> one two');
    final caret = harness.controller.selection!;
    expect(caret.isCollapsed, isTrue);
    expect(caret.head, harness.controller.document.positionAt(0, 7));
    expect(_pressed(tester, 'Quote'), isTrue);

    await tester.tap(_button('Quote'));
    await tester.pump();
    expect(harness.controller.document.blocks.single.text, 'one two');

    await tester.tap(_button('Comment'));
    await tester.pump();
    expect(harness.controller.document.blocks.single.text, '%% one two');
    expect(_pressed(tester, 'Comment'), isTrue);
    await tester.tap(_button('Comment'));
    await tester.pump();
    expect(harness.controller.document.blocks.single.text, 'one two');
    await _unmount(tester);
  });

  testWidgets('Comment over selected words makes them an aside',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final harness = await _pump(tester, 'one two', lines: true);
    final document = harness.controller.document;
    harness.controller.setSelection(HomericSelection(
      anchor: document.positionAt(0, 4),
      head: document.positionAt(0, 7),
    ));
    await tester.pump();
    await _openStyles(tester);

    await tester.tap(_button('Comment'));
    await tester.pump();
    expect(harness.controller.document.blocks.single.text, 'one ++two++');
    expect(_pressed(tester, 'Comment'), isTrue);
    await _unmount(tester);
  });

  test(
      'Quote over a selection quotes every line it runs through, empty '
      'ones too, and not the line it ends at the start of', () {
    final controller = HomericEditorController(
      document: Document([
        Block(id: 'a', type: 'paragraph', runs: [InlineRun('one\n')]),
        Block(id: 'b', type: 'paragraph', runs: [InlineRun('')]),
        Block(id: 'c', type: 'paragraph', runs: [InlineRun('two')]),
        Block(id: 'd', type: 'paragraph', runs: [InlineRun('three')]),
      ]),
    );
    addTearDown(controller.dispose);
    final doc = controller.document;
    final selection = HomericSelection(
        anchor: doc.positionAt(0, 1), head: doc.positionAt(3, 0));
    HomericFormatBar.quote(controller, selection).onPressed!();
    expect(controller.document.blocks.map((b) => b.text).toList(),
        ['> one\n> ', '> ', '> two', 'three']);
    expect(
        HomericSyntax.isQuote(controller.document.blocks.first.text), isTrue);
  });

  testWidgets('a key held names itself and does nothing', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final harness = await _pump(tester, 'one two', lines: true);
    harness.controller.setSelection(HomericSelection.collapsed(
        harness.controller.document.positionAt(0, 1)));
    await tester.pump();
    await _openStyles(tester);

    final gesture =
        await tester.startGesture(tester.getCenter(_button('Highlight')));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Highlight · ==words=='), findsOneWidget);
    // Above the bar.
    expect(tester.getBottomLeft(_key('tip')).dy,
        lessThan(tester.getTopLeft(_bar).dy));
    await gesture.up();
    await tester.pump();
    expect(find.text('Highlight · ==words=='), findsNothing);
    expect(harness.controller.document.blocks.single.text, 'one two');
    await _unmount(tester);
  });

  testWidgets('on a tablet everything sits in one row after Undo and Redo',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await _pump(tester, 'one two',
        lines: true, indents: true, screen: const Size(820, 1180));
    expect(_key('styles'), findsNothing);
    expect(_key('undo'), findsOneWidget);
    expect(_labels(tester), [
      'Bold',
      'Italic',
      'Strikethrough',
      'Highlight',
      'Quote',
      'Code',
      'Comment',
      'Link',
      'Note',
      'Outdent',
      'Indent',
    ]);
    await _unmount(tester);
  });
}

const double _keyboard = 300;

final Finder _bar =
    find.byKey(const ValueKey<String>('homeric-keyboard-format-bar'));

Finder _key(String name) =>
    find.byKey(ValueKey<String>('homeric-keyboard-$name'));

Future<void> _openStyles(WidgetTester tester) async {
  await tester.tap(_key('styles'));
  await tester.pump();
}

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

bool? _enabledKey(WidgetTester tester, String name) => tester
    .widget<Semantics>(
        find.descendant(of: _key(name), matching: find.byType(Semantics)).first)
    .properties
    .enabled;

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
  bool lines = false,
  VoidCallback? onFootnote,
  Size screen = const Size(390, 844),
}) async {
  tester.view.physicalSize = screen * 3;
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
                  quote: lines,
                  comment: lines,
                  onFootnote: onFootnote,
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
