import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide Decoration;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric/writing.dart';

Block _block(String text, {String id = 'b', String type = 'paragraph'}) =>
    Block(id: id, type: type, runs: [InlineRun(text)]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// A controller over [lines] (`l0`, `l1`, …), the caret at [caret] of
  /// line [line] (the last, at its end, by default), with list nesting and
  /// block indent installed as Sprintnotes installs them.
  HomericEditorController controllerFor(
    List<String> lines, {
    int? line,
    int? caret,
  }) {
    final document = Document([
      for (var i = 0; i < lines.length; i++) _block(lines[i], id: 'l$i'),
    ]);
    final at = line ?? lines.length - 1;
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(
        document.positionAt(at, caret ?? lines[at].length),
      ),
    );
    final stopNesting =
        const HomericListNesting(hangingLists: true).installOn(controller);
    final stopIndent = const HomericBlockIndent().installOn(controller);
    addTearDown(() {
      stopIndent();
      stopNesting();
      controller.dispose();
    });
    return controller;
  }

  List<String> linesOf(HomericEditorController controller) =>
      [for (final block in controller.document.blocks) block.text];

  (String, int) caretOf(HomericEditorController controller) {
    final at = controller.document.resolve(controller.selection!.head)
        as InlinePosition;
    return (at.block.id, at.offset);
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('the model', () {
    test('a paragraph indent is its leading two-space units or tabs', () {
      expect(
        HomericBlockIndent.paragraphIndentOf(_block('words')),
        const HomericParagraphIndent(level: 0, prefixEnd: 0),
      );
      expect(
        HomericBlockIndent.paragraphIndentOf(_block('    words')),
        const HomericParagraphIndent(level: 2, prefixEnd: 4),
      );
      expect(
        HomericBlockIndent.paragraphIndentOf(_block('\twords')),
        const HomericParagraphIndent(level: 1, prefixEnd: 1),
      );
      expect(
        HomericBlockIndent.paragraphIndentOf(_block('  ')),
        const HomericParagraphIndent(level: 1, prefixEnd: 2),
      );
    });

    test(
        'headings, quotes, fences, drop caps, lists and other types are '
        'not paragraphs', () {
      for (final text in [
        '# Title',
        '  ## Title',
        '> quoted',
        '```',
        '^^Once',
        '%% to self',
        '[^1]: the note',
        '---',
        '- item',
        '  1. item',
        '- [ ] to do',
      ]) {
        expect(
          HomericBlockIndent.paragraphIndentOf(_block(text)),
          isNull,
          reason: text,
        );
      }
      expect(
        HomericBlockIndent.paragraphIndentOf(
          _block('words', type: 'heading'),
        ),
        isNull,
      );
      expect(
        HomericBlockIndent.paragraphIndentOf(
          _block('words', type: 'note'),
          types: const {'paragraph', 'note'},
        ),
        isNotNull,
      );
    });

    test('a list line\'s words are one step past its depth', () {
      expect(HomericBlockIndent.columnOf(_block('- one')), 1);
      expect(HomericBlockIndent.columnOf(_block('    2. three')), 3);
      expect(HomericBlockIndent.columnOf(_block('  - [x] done')), 2);
      expect(HomericBlockIndent.columnOf(_block('  words')), 1);
      expect(HomericBlockIndent.columnOf(_block('# heading')), 0);
    });

    test(
        'an indented paragraph hangs with no marker, its words at its '
        'depth', () {
      final hang = HomericListHang.of(_block('    words'), indents: true)!;
      expect(hang.indent, isTrue);
      expect((hang.depth, hang.mark, hang.prefixEnd), (2, '', 4));
      expect(HomericListLine.gutterFor(hang, 30), 60);
      // A list line at the same depth: its marker takes a step more.
      final item = HomericListHang.of(_block('    - words'))!;
      expect(HomericListLine.gutterFor(item, 30), 90);
      // Off, or at the margin, or with the caret in the indent: no hang.
      expect(HomericListHang.of(_block('    words')), isNull);
      expect(HomericListHang.of(_block('words'), indents: true), isNull);
      expect(
        HomericListHang.of(_block('  words'), indents: true, caret: 1),
        isNull,
      );
    });

    test('the syntax folds the indent only with hangingIndents', () {
      final block = _block('  words');
      const off = HomericSyntax(hangingLists: true);
      expect(off.listHangFor(block), isNull);
      expect(
        off.decorationsFor(block).where((d) => d.spec is HomericListHangSpec),
        isEmpty,
      );
      const on = HomericSyntax(hangingIndents: true);
      expect(on.listHangFor(block)!.indent, isTrue);
      final hide = on
          .decorationsFor(block)
          .singleWhere((d) => d.spec is HomericListHangSpec);
      expect((hide.start, hide.end, hide.replacementLength), (0, 2, 0));
      // Indents alone leave list lines' markers in the line.
      expect(on.listHangFor(_block('- item')), isNull);
      expect(
        const HomericSyntax(hangingLists: true, hangingIndents: true)
            .listHangFor(_block('- item')),
        isNotNull,
      );
    });
  });

  group('indent and outdent', () {
    test('a paragraph moves at most one step past the line above', () {
      final controller = controllerFor(['first', 'second'], caret: 3);
      expect(HomericBlockIndent.indentSelection(controller), isTrue);
      expect(linesOf(controller), ['first', '  second']);
      expect(caretOf(controller), ('l1', 5), reason: 'the caret follows');
      expect(HomericBlockIndent.indentSelection(controller), isFalse);
      expect(linesOf(controller), ['first', '  second']);
      expect(
        HomericBlockIndent.indentSelection(controller, outdent: true),
        isTrue,
      );
      expect(linesOf(controller), ['first', 'second']);
      expect(
        HomericBlockIndent.indentSelection(controller, outdent: true),
        isFalse,
      );
    });

    test('the first line can step in once', () {
      final controller = controllerFor(['only'], caret: 0);
      expect(HomericBlockIndent.indentSelection(controller), isTrue);
      expect(HomericBlockIndent.indentSelection(controller), isFalse);
      expect(linesOf(controller), ['  only']);
    });

    test(
        'under a list item a paragraph lines up with its words, then '
        'with a nested item\'s', () {
      final controller = controllerFor(['- item', 'more about it']);
      expect(HomericBlockIndent.indentSelection(controller), isTrue);
      expect(linesOf(controller), ['- item', '  more about it']);
      expect(HomericBlockIndent.indentSelection(controller), isTrue);
      expect(linesOf(controller), ['- item', '    more about it']);
      expect(HomericBlockIndent.indentSelection(controller), isFalse);
    });

    test(
        'a list line nests as it does with Tab, under a list or an '
        'indented paragraph', () {
      final list = controllerFor(['- one', '- two']);
      expect(HomericBlockIndent.indentSelection(list), isTrue);
      expect(linesOf(list), ['- one', '  - two']);
      expect(HomericBlockIndent.indentSelection(list), isFalse);
      final under = controllerFor(['  a thought', '- item']);
      expect(HomericBlockIndent.indentSelection(under), isTrue);
      expect(linesOf(under), ['  a thought', '  - item']);
      // A top-level item outdents no further: it stays an item.
      final top = controllerFor(['- one']);
      expect(
        HomericBlockIndent.indentSelection(top, outdent: true),
        isFalse,
      );
    });

    test('a selection moves every line it touches, as one undo step', () {
      final controller = controllerFor(['intro', 'a', '- b', '  c', 'after']);
      final document = controller.document;
      controller.setSelection(HomericSelection(
        anchor: document.positionAt(1, 0),
        head: document.positionAt(3, 2),
      ));
      expect(HomericBlockIndent.indentSelection(controller), isTrue);
      expect(linesOf(controller), ['intro', '  a', '  - b', '    c', 'after']);
      controller.undo();
      expect(linesOf(controller), ['intro', 'a', '- b', '  c', 'after']);
    });

    test('a selection ending at a line\'s very start leaves that line', () {
      final controller = controllerFor(['intro', 'a', 'b']);
      final document = controller.document;
      controller.setSelection(HomericSelection(
        anchor: document.positionAt(1, 0),
        head: document.positionAt(2, 0),
      ));
      expect(HomericBlockIndent.indentSelection(controller), isTrue);
      expect(linesOf(controller), ['intro', '  a', 'b']);
    });

    test('headings and quotes stay at the margin', () {
      final controller = controllerFor(['intro', '# Title', '> said']);
      final document = controller.document;
      controller.setSelection(HomericSelection(
        anchor: document.positionAt(1, 0),
        head: document.positionAt(2, 3),
      ));
      expect(HomericBlockIndent.indentSelection(controller), isFalse);
      expect(
        HomericBlockIndent.reachable(
            controller.document, controller.selection!),
        isFalse,
      );
    });

    test('indentBlock moves one line for a swipe, the caret elsewhere', () {
      final controller = controllerFor(['one', 'two'], line: 0, caret: 2);
      expect(HomericBlockIndent.indentBlock(controller, 'l1'), isTrue);
      expect(linesOf(controller), ['one', '  two']);
      expect(caretOf(controller), ('l0', 2));
      expect(
        HomericBlockIndent.indentBlock(controller, 'l1', outdent: true),
        isTrue,
      );
      expect(linesOf(controller), ['one', 'two']);
    });
  });

  group('typing', () {
    test('a space at the start of a paragraph\'s words indents it', () {
      final controller = controllerFor(['one', 'two'], caret: 0);
      controller.replaceSelection(' ');
      expect(linesOf(controller), ['one', '  two']);
      expect(caretOf(controller), ('l1', 2));
      // Further than the line above allows: a space after all.
      controller.replaceSelection(' ');
      expect(linesOf(controller), ['one', '   two']);
    });

    test('a space elsewhere, or in an empty paragraph, is a space', () {
      final middle = controllerFor(['one two'], caret: 3);
      middle.replaceSelection(' ');
      expect(linesOf(middle), ['one  two']);
      final empty = controllerFor(['one', ''], caret: 0);
      empty.replaceSelection(' ');
      expect(linesOf(empty), ['one', ' ']);
    });

    test('Backspace at the start of the words outdents, then joins', () {
      final controller = controllerFor(['- one', '    two'], caret: 4);
      controller.deleteBackward();
      expect(linesOf(controller), ['- one', '  two']);
      expect(caretOf(controller), ('l1', 2));
      controller.deleteBackward();
      expect(linesOf(controller), ['- one', 'two']);
      controller.deleteBackward();
      expect(linesOf(controller), ['- onetwo']);
    });

    test(
        'Enter keeps the indent; Enter on an empty indented line steps '
        'out', () {
      final controller = controllerFor(['- one', '    two']);
      controller.insertParagraphBreak();
      expect(linesOf(controller), ['- one', '    two', '    ']);
      expect(caretOf(controller).$2, 4);
      controller.insertParagraphBreak();
      expect(linesOf(controller), ['- one', '    two', '  ']);
      controller.insertParagraphBreak();
      expect(linesOf(controller), ['- one', '    two', '']);
      controller.insertParagraphBreak();
      expect(linesOf(controller), ['- one', '    two', '', '']);
    });

    test('Enter inside indented words splits them at the same indent', () {
      final controller = controllerFor(['  one two'], caret: 5);
      controller.insertParagraphBreak();
      expect(linesOf(controller), ['  one', '   two']);
    });

    test('the caret stays out of a folded indent', () async {
      final controller = controllerFor(['above', '  words'], caret: 2);
      final document = controller.document;
      controller.setSelection(
        HomericSelection.collapsed(document.positionAt(1, 0)),
      );
      await settle();
      expect(caretOf(controller), ('l1', 2));
      controller.setSelection(
        HomericSelection.collapsed(document.positionAt(1, 1)),
      );
      await settle();
      expect(caretOf(controller), ('l0', 5), reason: '← goes on up');
    });

    test('switched off, typing and Tab are as they were', () {
      final document =
          Document([_block('one', id: 'l0'), _block('two', id: 'l1')]);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(document.positionAt(1, 0)),
      );
      final stop =
          HomericBlockIndent(isActive: () => false).installOn(controller);
      addTearDown(() {
        stop();
        controller.dispose();
      });
      controller.replaceSelection(' ');
      expect(linesOf(controller), ['one', ' two']);
    });

    test('switched off, the caret may sit inside an indent', () async {
      final document = Document([
        _block('above', id: 'l0'),
        _block('  words', id: 'l1'),
      ]);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(document.positionAt(1, 7)),
      );
      final stop =
          HomericBlockIndent(isActive: () => false).installOn(controller);
      addTearDown(() {
        stop();
        controller.dispose();
      });
      controller.setSelection(
        HomericSelection.collapsed(document.positionAt(1, 1)),
      );
      await settle();
      expect(caretOf(controller), ('l1', 1));
    });

    test('a host filter leaves its own lines (code in a fence) alone', () {
      bool prose(Block block) => block.id != 'l1';
      final document =
          Document([_block('```', id: 'l0'), _block('  x = 1', id: 'l1')]);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(document.positionAt(1, 2)),
      );
      final stop = HomericBlockIndent(accepts: prose).installOn(controller);
      addTearDown(() {
        stop();
        controller.dispose();
      });
      controller.deleteBackward();
      expect(linesOf(controller), ['```', ' x = 1']);
      expect(
        HomericBlockIndent.indentSelection(controller, accepts: prose),
        isFalse,
      );
      const syntax = HomericSyntax(hangingIndents: true);
      final code = _block('  x = 1', id: 'l1');
      expect(syntax.listHangFor(code, indentFilter: prose), isNull);
      expect(
        syntax
            .decorationsFor(code, indentFilter: prose)
            .where((d) => d.spec is HomericListHangSpec),
        isEmpty,
      );
    });

    test('joins the standard kit; tab: false drops the shortcuts', () {
      expect(HomericWritingKit.standard().has('blockIndent'), isTrue);
      expect(
        const HomericBlockIndent(tab: false).commandBindings,
        isEmpty,
      );
    });
  });

  group('in the editor', () {
    Future<HomericEditorController> pumpEditor(
      WidgetTester tester,
      List<String> lines, {
      int line = 1,
      int caret = 0,
    }) async {
      final controller = controllerFor(lines, line: line, caret: caret);
      final session = HomericTextInputSession(controller: controller);
      addTearDown(session.dispose);
      const syntax = HomericSyntax(hangingLists: true, hangingIndents: true);
      const style = TextStyle(fontSize: 20, height: 1.5);
      await tester.pumpWidget(MaterialApp(
        home: Material(
          child: SizedBox(
            width: 400,
            height: 400,
            child: HomericEditableDocument.builder(
              controller: controller,
              inputSession: session,
              commandBindings: const HomericBlockIndent().commandBindings,
              estimatedBlockHeight: 44,
              blockBuilder: (context, block, focusNode) => ListenableBuilder(
                listenable: controller,
                builder: (context, child) => HomericListLine(
                  key: ValueKey('line-${block.id}'),
                  hang: syntax.listHangFor(
                    controller.document.blockById(block.id) ?? block,
                  ),
                  markStyle: style,
                  textScaler: TextScaler.noScaling,
                  swipesAtMargin: true,
                  onIndent: (outdent) => HomericBlockIndent.indentBlock(
                    controller,
                    block.id,
                    outdent: outdent,
                  ),
                  child: child!,
                ),
                child: HomericEditableParagraph(
                  key: ValueKey('p-${block.id}'),
                  controller: controller,
                  inputSession: session,
                  blockId: block.id,
                  focusNode: focusNode,
                  resolveStyle: (_) => style,
                  deriveDecorations: (b) => syntax.decorationsFor(b).toList(),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
      return controller;
    }

    testWidgets('Tab and Shift-Tab indent and outdent a paragraph',
        (tester) async {
      final controller = await pumpEditor(tester, ['one', 'two']);
      await tester.tap(find.byKey(const ValueKey('homeric-editable-l1')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(linesOf(controller), ['one', '  two']);
      // The words sit one step (1.5 × 20) in, the indent folded away.
      double x(String id) => tester.getTopLeft(find.byKey(ValueKey(id))).dx;
      expect(x('p-l1') - x('line-l1'), 30);
      // No further: Tab stays in the text.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(linesOf(controller), ['one', '  two']);
      expect(controller.selection, isNotNull);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(linesOf(controller), ['one', 'two']);
      expect(x('p-l1') - x('line-l1'), 0);
    });

    testWidgets('Control-Tab still leaves the line, so Tab is no trap',
        (tester) async {
      final controller = await pumpEditor(tester, ['one', 'two']);
      await tester.tap(find.byKey(const ValueKey('homeric-editable-l1')));
      await tester.pump();
      final before = FocusManager.instance.primaryFocus;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(linesOf(controller), ['one', 'two']);
      expect(FocusManager.instance.primaryFocus, isNot(same(before)));
    });

    testWidgets('a paragraph and a list item under it line up', (tester) async {
      await pumpEditor(tester, ['- item', '  more', '  - nested', '    under']);
      double x(String id) => tester.getTopLeft(find.byKey(ValueKey(id))).dx;
      final margin = x('line-l0');
      expect(x('p-l0') - margin, 30);
      expect(x('p-l1') - margin, 30,
          reason: 'a continuation lines up with the words');
      expect(x('p-l2') - margin, 60);
      expect(x('p-l3') - margin, 60);
    });

    testWidgets('a swipe right on the line being written indents it',
        (tester) async {
      final controller = await pumpEditor(tester, ['one', 'two']);
      await tester.tap(find.byKey(const ValueKey('p-l1')));
      await tester.pump(const Duration(milliseconds: 500));
      final line = find.byKey(const ValueKey('line-l1'));
      final gesture = await tester.startGesture(
        tester.getCenter(line),
        kind: PointerDeviceKind.touch,
      );
      for (var i = 0; i < 8; i++) {
        await gesture.moveBy(const Offset(10, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(linesOf(controller), ['one', '  two']);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  });

  group('format bar', () {
    test('Outdent and Indent end the bar as a group, acting on the line', () {
      final controller = controllerFor(['one', 'two'], caret: 1);
      final actions = HomericFormatBar.standard(
        controller,
        controller.selection!,
        indents: true,
      );
      final labels = [for (final a in actions) a.label];
      expect(labels.sublist(labels.length - 2), ['Outdent', 'Indent']);
      final outdent = actions[actions.length - 2];
      final indent = actions.last;
      expect(outdent.startsGroup, isTrue);
      expect(indent.actsOnBlock && outdent.actsOnBlock, isTrue);
      expect(indent.shortcut, 'Tab');
      expect(outdent.onPressed, isNull, reason: 'already at the margin');
      indent.onPressed!();
      expect(linesOf(controller), ['one', '  two']);
      final after = HomericFormatBar.standard(
        controller,
        controller.selection!,
        indents: true,
      );
      expect(after.last.onPressed, isNull);
      expect(after[after.length - 2].onPressed, isNotNull);
      expect(
        HomericFormatBar.standard(controller, controller.selection!)
            .any((a) => a.label == 'Indent'),
        isFalse,
        reason: 'off by default',
      );
    });
  });
}
