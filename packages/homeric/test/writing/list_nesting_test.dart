import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide Decoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric/writing.dart';

Block _block(String text, {String id = 'b'}) =>
    Block(id: id, type: 'paragraph', runs: [InlineRun(text)]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// A controller over [lines], one block each (`l0`, `l1`, …), the caret
  /// at [caret] of the last line (its end when null), with list nesting and
  /// smart punctuation installed as Sprintnotes installs them.
  HomericEditorController controllerFor(List<String> lines, {int? caret}) {
    final document = Document([
      for (var i = 0; i < lines.length; i++) _block(lines[i], id: 'l$i'),
    ]);
    final last = lines.length - 1;
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(
        document.positionAt(last, caret ?? lines[last].length),
      ),
    );
    final stopPunctuation =
        const HomericSmartPunctuation().installOn(controller);
    final stopNesting = const HomericListNesting().installOn(controller);
    addTearDown(() {
      stopNesting();
      stopPunctuation();
      controller.dispose();
    });
    return controller;
  }

  List<String> linesOf(HomericEditorController controller) =>
      [for (final block in controller.document.blocks) block.text];

  (String, int) caretOf(HomericEditorController controller) {
    final head = controller.selection!.head;
    final at = controller.document.resolve(head) as InlinePosition;
    return (at.block.id, at.offset);
  }

  group('HomericListHang', () {
    test('reads depth and marker from the indent', () {
      final top = HomericListHang.of(_block('- one'))!;
      expect((top.depth, top.mark, top.prefixEnd), (0, '●', 2));
      final nested = HomericListHang.of(_block('  - two'))!;
      expect((nested.depth, nested.mark, nested.prefixEnd), (1, '◯', 4));
      final tab = HomericListHang.of(_block('\t\t* three'))!;
      expect((tab.depth, tab.mark), (2, '□'));
      final numbered = HomericListHang.of(_block('  3. four'))!;
      expect((numbered.depth, numbered.mark), (1, 'c.'));
      expect(
        HomericListHang.of(_block('12. five'), glyphs: false)!.mark,
        '12.',
      );
    });

    test('leaves plain lines, to-dos and an edited marker alone', () {
      expect(HomericListHang.of(_block('plain')), isNull);
      expect(HomericListHang.of(_block('-not a list')), isNull);
      expect(HomericListHang.of(_block('- [ ] a to-do')), isNull);
      expect(HomericListHang.of(_block('  - [x] done')), isNull);
      // The caret inside the marker shows it as typed.
      expect(HomericListHang.of(_block('  - two'), caret: 3), isNull);
      expect(HomericListHang.of(_block('  - two'), caret: 4), isNotNull);
    });

    test('hides exactly the indent, marker and space', () {
      final hide = HomericListHang.of(_block('  - two'))!.hide;
      expect(
        (hide.kind, hide.start, hide.end, hide.replacementLength),
        (DecorationKind.replace, 0, 4, 0),
      );
      expect(hide.spec, same(HomericListHangSpec.instance));
    });
  });

  group('HomericSyntax.hangingLists', () {
    test('off by default: the marker shows in the line', () {
      final decorations =
          HomericSyntax.all.decorationsFor(_block('- one')).toList();
      final replace =
          decorations.singleWhere((d) => d.kind == DecorationKind.replace);
      expect((replace.start, replace.end), (0, 1));
      expect((replace.spec as ReplacementContent).text, '●');
      expect(HomericSyntax.all.listHangFor(_block('- one')), isNull);
    });

    test('on: the marker folds out for the gutter', () {
      const syntax = HomericSyntax(hangingLists: true);
      final block = _block('  - two **bold**');
      final decorations = syntax.decorationsFor(block).toList();
      final hang = decorations
          .where((d) => identical(d.spec, HomericListHangSpec.instance))
          .single;
      expect((hang.start, hang.end), (0, 4));
      expect(
        decorations.whereType<Decoration>().where(
              (d) => d.spec is ReplacementContent,
            ),
        isEmpty,
      );
      expect(syntax.listHangFor(block)!.mark, '◯');
      // Editing the marker: it shows as typed.
      expect(syntax.listHangFor(block, caret: 1), isNull);
      final editing = syntax.decorationsFor(block, caret: 1).toList();
      expect(
        editing.any((d) => identical(d.spec, HomericListHangSpec.instance)),
        isFalse,
      );
    });
  });

  group('HomericListNesting', () {
    test('a space at the start of the words nests under the item above', () {
      final controller = controllerFor(['- one', '- two'], caret: 2);
      controller.replaceSelection(' ');
      expect(linesOf(controller), ['- one', '  - two']);
      expect(caretOf(controller), ('l1', 4));
      // No deeper than one level under its parent.
      controller.replaceSelection(' ');
      expect(linesOf(controller), ['- one', '  -  two']);
    });

    test('a space elsewhere is a space', () {
      final first = controllerFor(['- one'], caret: 2);
      first.replaceSelection(' ');
      expect(linesOf(first), ['-  one'], reason: 'no item above to nest under');
      final middle = controllerFor(['- one', '- two'], caret: 4);
      middle.replaceSelection(' ');
      expect(linesOf(middle), ['- one', '- tw o']);
      final todo = controllerFor(['- one', '- [ ] two'], caret: 2);
      todo.replaceSelection(' ');
      expect(linesOf(todo), ['- one', '-  [ ] two']);
    });

    test('Backspace at the start of the words outdents, then unlists', () {
      final controller = controllerFor(['- one', '  - two'], caret: 4);
      controller.deleteBackward();
      expect(linesOf(controller), ['- one', '- two']);
      expect(caretOf(controller), ('l1', 2));
      controller.deleteBackward();
      expect(linesOf(controller), ['- one', 'two']);
      expect(caretOf(controller), ('l1', 0));
      // Inside the words Backspace deletes a letter.
      final inside = controllerFor(['- one'], caret: 4);
      inside.deleteBackward();
      expect(linesOf(inside), ['- oe']);
    });

    test('numbered items outdent and unlist the same way', () {
      final controller = controllerFor(['1. one', '  1. two'], caret: 5);
      controller.deleteBackward();
      expect(linesOf(controller), ['1. one', '1. two']);
      controller.deleteBackward();
      expect(linesOf(controller), ['1. one', 'two']);
    });

    test('Enter on an empty nested item climbs a level, then leaves', () {
      final controller = controllerFor(['- one', '  - two', '  - ']);
      controller.insertParagraphBreak();
      expect(linesOf(controller), ['- one', '  - two', '- ']);
      expect(caretOf(controller), ('l2', 2));
      controller.insertParagraphBreak();
      expect(linesOf(controller), ['- one', '  - two', '']);
      // Enter on an item with words continues the list as before.
      final words = controllerFor(['  - two']);
      words.insertParagraphBreak();
      expect(linesOf(words), ['  - two', '  - ']);
    });

    test('the dash rules still win on an empty bullet', () {
      // homeric#66: `-` on an empty bullet is an em dash, so `- --` is a
      // divider's way in.
      final controller = controllerFor(['- one', '- ']);
      controller.replaceSelection('-');
      expect(linesOf(controller), ['- one', '—']);
      final nested = controllerFor(['- one', '  - ']);
      nested.replaceSelection('-');
      expect(linesOf(nested), ['- one', '  —']);
    });

    test('indent() nests and outdents for a gesture, keeping the caret', () {
      final controller = controllerFor(['- one', '- two'], caret: 4);
      expect(HomericListNesting.indent(controller, 'l1'), isTrue);
      expect(linesOf(controller), ['- one', '  - two']);
      expect(caretOf(controller), ('l1', 6));
      expect(HomericListNesting.indent(controller, 'l1'), isFalse,
          reason: 'already one level under its parent');
      expect(HomericListNesting.indent(controller, 'l0'), isFalse,
          reason: 'nothing above to nest under');
      expect(
        HomericListNesting.indent(controller, 'l1', outdent: true),
        isTrue,
      );
      expect(linesOf(controller), ['- one', '- two']);
      expect(caretOf(controller), ('l1', 4));
      expect(
        HomericListNesting.indent(controller, 'l1', outdent: true),
        isFalse,
      );
    });

    test('with hung markers the caret stays out of them', () async {
      final document = Document([
        _block('words', id: 'l0'),
        _block('  - two', id: 'l1'),
      ]);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(document.positionAt(1, 7)),
      );
      final stop =
          const HomericListNesting(hangingLists: true).installOn(controller);
      addTearDown(() {
        stop();
        controller.dispose();
      });
      // Home, or a tap at the line's start: to the start of the words.
      controller.setSelection(
        HomericSelection.collapsed(document.positionAt(1, 0)),
      );
      await Future<void>.delayed(Duration.zero);
      expect(caretOf(controller), ('l1', 4));
      // ← from there: on to the line above.
      controller.setSelection(
        HomericSelection.collapsed(document.positionAt(1, 3)),
      );
      await Future<void>.delayed(Duration.zero);
      expect(caretOf(controller), ('l0', 5));
      // A selection may still take the marker in.
      controller.setSelection(HomericSelection(
        anchor: document.positionAt(1, 0),
        head: document.positionAt(1, 7),
      ));
      await Future<void>.delayed(Duration.zero);
      expect(controller.selection!.anchor, document.positionAt(1, 0));
    });

    test('the first ← after installing already moves on', () async {
      final document = Document([
        _block('words', id: 'l0'),
        _block('- two', id: 'l1'),
      ]);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(document.positionAt(1, 2)),
      );
      final stop =
          const HomericListNesting(hangingLists: true).installOn(controller);
      addTearDown(() {
        stop();
        controller.dispose();
      });
      controller.setSelection(
        HomericSelection.collapsed(document.positionAt(1, 1)),
      );
      await Future<void>.delayed(Duration.zero);
      expect(caretOf(controller), ('l0', 5));
    });

    test('is in the standard kit', () {
      expect(HomericWritingKit.standard().has('listNesting'), isTrue);
      expect(
        HomericWritingKit.standard(without: const {'listNesting'})
            .has('listNesting'),
        isFalse,
      );
    });

    test('switched off, typing goes ahead as typed', () {
      final document =
          Document([_block('- one', id: 'l0'), _block('- two', id: 'l1')]);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(document.positionAt(1, 2)),
      );
      addTearDown(controller.dispose);
      final stop =
          HomericListNesting(isActive: () => false).installOn(controller);
      addTearDown(stop);
      controller.replaceSelection(' ');
      expect(linesOf(controller), ['- one', '-  two']);
    });
  });

  group('HomericListLine', () {
    Future<void> swipe(
      WidgetTester tester,
      Finder line,
      double dx,
      PointerDeviceKind kind,
    ) async {
      final start = tester.getCenter(line) + const Offset(-60, 0);
      final gesture = await tester.startGesture(start, kind: kind);
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(Offset(dx / 10, 0));
        await tester.pump(const Duration(milliseconds: 30));
      }
      await gesture.up();
      await tester.pump();
    }

    const style = TextStyle(fontSize: 20, height: 1.5);

    Future<HomericEditorController> pumpList(
      WidgetTester tester, {
      ValueChanged<bool>? onIndent,
      List<String> lines = const [
        '- one',
        '  - a nested item long enough '
            'to wrap onto a second and a third line in a narrow column'
      ],
    }) async {
      final document = Document([
        for (var i = 0; i < lines.length; i++) _block(lines[i], id: 'l$i'),
      ]);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(document.positionAt(0, 3)),
      );
      final session = HomericTextInputSession(controller: controller);
      final stopNesting =
          const HomericListNesting(hangingLists: true).installOn(controller);
      addTearDown(() {
        stopNesting();
        session.dispose();
        controller.dispose();
      });
      const syntax = HomericSyntax(hangingLists: true);
      await tester.pumpWidget(MaterialApp(
        home: Material(
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              child: Column(
                children: [
                  for (final block in document.blocks)
                    HomericListLine(
                      key: ValueKey('line-${block.id}'),
                      hang: syntax.listHangFor(block),
                      markStyle: style,
                      onIndent: onIndent,
                      child: HomericEditableParagraph(
                        key: ValueKey('p-${block.id}'),
                        controller: controller,
                        inputSession: session,
                        blockId: block.id,
                        resolveStyle: (_) => style,
                        deriveDecorations: (b) =>
                            syntax.decorationsFor(b).toList(),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
      return controller;
    }

    testWidgets('wrapped lines start where the words start', (tester) async {
      await pumpList(tester);
      const step = 30.0; // 1.5 × 20
      final top = tester.getTopLeft(find.byKey(const ValueKey('p-l0')));
      final nested = tester.getTopLeft(find.byKey(const ValueKey('p-l1')));
      expect(top.dx, step);
      expect(nested.dx, 2 * step);
      // The nested item wraps, and its words keep their column.
      expect(
        tester.getSize(find.byKey(const ValueKey('p-l1'))).height,
        greaterThan(2 * 30),
      );
      final marks = find.byKey(const ValueKey('homeric-list-mark'));
      expect(marks, findsNWidgets(2));
      expect(find.bySemanticsLabel('●'), findsOneWidget);
      expect(find.bySemanticsLabel('◯'), findsOneWidget);
      // Each marker sits in its own level's column, on the first line.
      final bullet = tester.getCenter(marks.first);
      final nestedBullet = tester.getCenter(marks.last);
      expect(bullet.dx, inExclusiveRange(0, step));
      expect(nestedBullet.dx, inExclusiveRange(step, 2 * step));
      expect(nestedBullet.dy, lessThan(nested.dy + 30));
    });

    testWidgets('a swipe on a touch screen nests or outdents', (tester) async {
      final calls = <bool>[];
      final controller = await pumpList(tester, onIndent: calls.add);
      // Writing the item: its line has focus.
      await tester.tap(find.byKey(const ValueKey('p-l1')));
      await tester.pump(const Duration(milliseconds: 500));
      final selection = controller.selection;
      final line = find.byKey(const ValueKey('line-l1'));
      await swipe(tester, line, 80, PointerDeviceKind.touch);
      await tester.pumpAndSettle();
      await swipe(tester, line, -80, PointerDeviceKind.touch);
      await tester.pumpAndSettle();
      // A short nudge is not a swipe.
      await swipe(tester, line, 12, PointerDeviceKind.touch);
      await tester.pumpAndSettle();
      expect(calls, [false, true]);
      // The swipe is the line's: on an iPhone the caret stays where it was.
      expect(controller.selection, selection);
      // A mouse drag selects text instead.
      await swipe(tester, line, 80, PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(calls, [false, true]);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('a tap at the start of the words puts the caret there',
        (tester) async {
      final controller = await pumpList(tester);
      final paragraph = find.byKey(const ValueKey('p-l1'));
      await tester.tapAt(tester.getTopLeft(paragraph) + const Offset(1, 10));
      await tester.pump(const Duration(milliseconds: 500));
      expect(caretOf(controller), ('l1', 4));
      // The marker stays in the gutter.
      expect(find.byKey(const ValueKey('homeric-list-mark')), findsNWidgets(2));
    });

    testWidgets('typing a marker keeps the paragraph', (tester) async {
      final controller = await pumpList(tester, lines: const ['words']);
      final before = tester.state(find.byKey(const ValueKey('p-l0')));
      controller.setSelection(
        HomericSelection.collapsed(controller.document.positionAt(0, 0)),
      );
      controller.replaceSelection('- ');
      await tester.pumpWidget(tester.widget(find.byType(MaterialApp)));
      await tester.pump();
      expect(tester.state(find.byKey(const ValueKey('p-l0'))), same(before));
    });

    testWidgets('no hang: the paragraph as it is', (tester) async {
      await pumpList(tester, lines: const ['plain words']);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('p-l0'))).dx,
        0,
      );
    });
  });
}
