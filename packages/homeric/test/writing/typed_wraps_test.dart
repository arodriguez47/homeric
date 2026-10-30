import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric/writing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// A controller over one paragraph of [text] with `[anchor, head)`
  /// selected, running [feature].
  HomericEditorController controllerFor(
    String text,
    int anchor,
    int head, {
    HomericTypedWraps feature = const HomericTypedWraps(),
    String type = 'paragraph',
  }) {
    final document = Document([
      Block(id: 'b', type: type, runs: [InlineRun(text)]),
    ]);
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection(
        anchor: document.positionAt(0, anchor),
        head: document.positionAt(0, head),
      ),
    );
    addTearDown(controller.dispose);
    addTearDown(feature.installOn(controller));
    return controller;
  }

  String textOf(HomericEditorController controller) =>
      controller.document.blocks.single.text;

  /// The selection as block-local (anchor, head).
  (int, int) selected(HomericEditorController controller) {
    final selection = controller.selection!;
    final base = controller.document.positionAt(0, 0);
    return (selection.anchor - base, selection.head - base);
  }

  group('typing a marker over a selection', () {
    test('wraps the words and keeps them selected', () {
      for (final (typed, wrapped) in const [
        ('=', 'a =word= here'),
        ('~', 'a ~word~ here'),
        ('+', 'a +word+ here'),
        ('%', 'a %word% here'),
        ('*', 'a *word* here'),
        ('_', 'a _word_ here'),
        ('`', 'a `word` here'),
        ('(', 'a (word) here'),
        ('{', 'a {word} here'),
        ('[', 'a [word] here'),
        ('"', 'a “word” here'),
        ("'", 'a ‘word’ here'),
      ]) {
        final controller = controllerFor('a word here', 2, 6);
        expect(controller.replaceSelection(typed), isTrue);
        expect(textOf(controller), wrapped, reason: typed);
        expect(selected(controller), (3, 7), reason: typed);
      }
    });

    test('a second press doubles the marker', () {
      final controller = controllerFor('a word here', 2, 6);
      controller
        ..replaceSelection('=')
        ..replaceSelection('=');
      expect(textOf(controller), 'a ==word== here');
      expect(selected(controller), (4, 8));
    });

    test('a backwards selection stays backwards', () {
      final controller = controllerFor('a word here', 6, 2);
      controller.replaceSelection('~');
      expect(textOf(controller), 'a ~word~ here');
      expect(selected(controller), (7, 3));
    });

    test('one press past the syntax takes the wrap off', () {
      for (final (start, typed) in const [
        ('a ==word== here', '='),
        ('a ~~word~~ here', '~'),
        ('a ++word++ here', '+'),
        ('a %%word%% here', '%'),
        ('a ***word*** here', '*'),
        ('a (word) here', '('),
        ('a `word` here', '`'),
      ]) {
        final open = start.indexOf('w');
        final controller = controllerFor(start, open, open + 4);
        controller.replaceSelection(typed);
        expect(textOf(controller), 'a word here', reason: start);
        expect(selected(controller), (2, 6), reason: start);
      }
    });

    test('bold from ⌘B takes a third * as bold italic', () {
      final controller = controllerFor('a **word** here', 4, 8);
      controller.replaceSelection('*');
      expect(textOf(controller), 'a ***word*** here');
    });

    test('a different marker nests inside', () {
      final controller = controllerFor('a ==word== here', 4, 8);
      controller.replaceSelection('*');
      expect(textOf(controller), 'a ==*word*== here');
    });

    test('each wrap is one undo step', () {
      final controller = controllerFor('a word here', 2, 6);
      controller
        ..replaceSelection('=')
        ..replaceSelection('=');
      controller.undo();
      expect(textOf(controller), 'a =word= here');
      controller.undo();
      expect(textOf(controller), 'a word here');
    });

    test('a collapsed caret types as usual', () {
      final controller = controllerFor('a word here', 6, 6);
      controller.replaceSelection('=');
      expect(textOf(controller), 'a word= here');
    });

    test('other characters replace the selection as usual', () {
      final controller = controllerFor('a word here', 2, 6);
      controller.replaceSelection('x');
      expect(textOf(controller), 'a x here');
    });

    test('blank selections are replaced as usual', () {
      final controller = controllerFor('a   here', 1, 3);
      controller.replaceSelection('=');
      expect(textOf(controller), 'a= here');
    });

    test('code blocks wrap only in backticks', () {
      final controller = controllerFor('let x = 1', 4, 5, type: 'code');
      controller.replaceSelection('(');
      expect(textOf(controller), 'let ( = 1');
    });

    test('quotes are straight when curly quotes are off', () {
      final controller = controllerFor(
        'a word here',
        2,
        6,
        feature: HomericTypedWraps(curlyQuotes: () => false),
      );
      controller.replaceSelection('"');
      expect(textOf(controller), 'a "word" here');
    });

    test('isActive false leaves typing as typed', () {
      final controller = controllerFor(
        'a word here',
        2,
        6,
        feature: HomericTypedWraps(isActive: () => false),
      );
      controller.replaceSelection('=');
      expect(textOf(controller), 'a = here');
    });
  });

  group('{{ and [[', () {
    test('{{ leaves the caret in the note slot', () {
      final controller = controllerFor('a word here', 2, 6);
      controller
        ..replaceSelection('{')
        ..replaceSelection('{');
      expect(textOf(controller), 'a {{word|}} here');
      expect(selected(controller), (9, 9));
    });

    test('without the note slot {{ keeps the words selected', () {
      final controller = controllerFor(
        'a word here',
        2,
        6,
        feature: const HomericTypedWraps(annotationNoteSlot: false),
      );
      controller
        ..replaceSelection('{')
        ..replaceSelection('{');
      expect(textOf(controller), 'a {{word}} here');
      expect(selected(controller), (4, 8));
    });

    test('[[ keeps the words as the alias, caret on the target', () {
      final controller = controllerFor('a word here', 2, 6);
      controller
        ..replaceSelection('[')
        ..replaceSelection('[');
      expect(textOf(controller), 'a [[|word]] here');
      expect(selected(controller), (4, 4));

      final text = textOf(controller);
      expect(HomericLinkQuery.at('b', text, 4), isNull,
          reason: 'only the wrapped [[ reads the alias after the caret');
      final query = HomericLinkQuery.at('b', text, 4, wrappedAt: 2)!;
      expect(query.target, '');
      expect(query.alias, 'word');
      expect(query.sourceEnd, 11);

      // Typing the target narrows the query and keeps the alias.
      controller.replaceSelection('Ro');
      final typed =
          HomericLinkQuery.at('b', textOf(controller), 6, wrappedAt: 2)!;
      expect(typed.target, 'Ro');
      expect(typed.alias, 'word');
      expect(typed.sourceEnd, 13);
    });

    testWidgets('onWrapped hears the wrap after the frame', (tester) async {
      final heard = <HomericTypedWrap>[];
      final controller = controllerFor(
        'a word here',
        2,
        6,
        feature: HomericTypedWraps(
          annotationNoteSlot: false,
          onWrapped: heard.add,
        ),
      );
      controller.replaceSelection('{');
      controller.replaceSelection('{');
      expect(heard, isEmpty);
      await tester.pump();
      expect(
          heard.last,
          const HomericTypedWrap(
            blockId: 'b',
            typed: '{',
            depth: 2,
            start: 2,
            end: 10,
            innerStart: 4,
            innerEnd: 8,
          ));
    });
  });

  testWidgets('onWrapped stays quiet for a wrap that was not applied',
      (tester) async {
    final heard = <HomericTypedWrap>[];
    final controller = controllerFor('a word here', 2, 6);
    final session =
        HomericTypedWraps(onWrapped: heard.add).sessionFor(controller);
    expect(session.prepareMenuWrap(controller.selection, '='), isNotNull);
    await tester.pump();
    expect(heard, isEmpty);
  });

  group('Backspace straight after', () {
    test('puts the words back, selected', () {
      final controller = controllerFor('a word here', 2, 6);
      controller
        ..replaceSelection('=')
        ..replaceSelection('=');
      expect(controller.deleteBackward(), isTrue);
      expect(textOf(controller), 'a word here');
      expect(selected(controller), (2, 6));
    });

    test('takes back a {{ note slot', () {
      final controller = controllerFor('a word here', 2, 6);
      controller
        ..replaceSelection('{')
        ..replaceSelection('{');
      controller.deleteBackward();
      expect(textOf(controller), 'a word here');
      expect(selected(controller), (2, 6));
    });

    test('takes back a [[ link', () {
      final controller = controllerFor('a word here', 6, 2);
      controller
        ..replaceSelection('[')
        ..replaceSelection('[');
      controller.deleteBackward();
      expect(textOf(controller), 'a word here');
      expect(selected(controller), (6, 2));
    });

    test('takes back nested wraps of one run', () {
      final controller = controllerFor('a word here', 2, 6);
      controller
        ..replaceSelection('=')
        ..replaceSelection('=')
        ..replaceSelection('*');
      expect(textOf(controller), 'a ==*word*== here');
      controller.deleteBackward();
      expect(textOf(controller), 'a word here');
    });

    test('deletes at the caret once the caret moved', () {
      final controller = controllerFor('a word here', 2, 6);
      controller.replaceSelection('=');
      controller.setSelection(
        HomericSelection.collapsed(controller.document.positionAt(0, 13)),
      );
      controller.deleteBackward();
      expect(textOf(controller), 'a =word= her');
    });

    test('keeps the words\' own formatting', () {
      final document = Document([
        Block(id: 'b', type: 'paragraph', runs: [
          InlineRun('a '),
          InlineRun('word', attributes: const {'bold': true}),
          InlineRun(' here'),
        ]),
      ]);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection(
          anchor: document.positionAt(0, 2),
          head: document.positionAt(0, 6),
        ),
      );
      addTearDown(controller.dispose);
      addTearDown(const HomericTypedWraps().installOn(controller));
      controller
        ..replaceSelection('=')
        ..replaceSelection('=');
      controller.deleteBackward();
      final runs = controller.document.blocks.single.runs;
      expect(controller.document.blocks.single.text, 'a word here');
      expect(
        runs.where((run) => run.attributes['bold'] == true).single.text,
        'word',
      );
    });

    test('deletes as usual once something else happened', () {
      final controller = controllerFor('a word here', 2, 6);
      controller.replaceSelection('=');
      controller.replaceSelection('x');
      controller.deleteBackward();
      expect(textOf(controller), 'a == here');
    });

    test('a wrap the run unwrapped reverts to the start', () {
      final controller = controllerFor('a (word) here', 3, 7);
      controller.replaceSelection('(');
      expect(textOf(controller), 'a word here');
      controller.deleteBackward();
      expect(textOf(controller), 'a (word) here');
      expect(selected(controller), (3, 7));
    });
  });

  group('menu wraps', () {
    test('wrap the selection to the full marker and back', () {
      final controller = controllerFor('a word here', 2, 6);
      final session = const HomericTypedWraps().sessionFor(controller);
      controller.applyPreparedCommand(
        session.prepareMenuWrap(controller.selection, '=')!,
      );
      expect(textOf(controller), 'a ==word== here');
      expect(selected(controller), (4, 8));
      controller.applyPreparedCommand(
        session.prepareMenuWrap(controller.selection, '=')!,
      );
      expect(textOf(controller), 'a word here');
    });

    test('a menu link writes [[|words]]', () {
      final controller = controllerFor('a word here', 2, 6);
      final session = const HomericTypedWraps().sessionFor(controller);
      controller.applyPreparedCommand(
        session.prepareMenuWrap(controller.selection, '[')!,
      );
      expect(textOf(controller), 'a [[|word]] here');
    });

    test('nothing for a collapsed selection', () {
      final controller = controllerFor('a word here', 2, 2);
      final session = const HomericTypedWraps().sessionFor(controller);
      expect(session.prepareMenuWrap(controller.selection, '='), isNull);
    });
  });

  test('the standard kit carries typed wraps', () {
    expect(HomericWritingKit.standard().has('typedWraps'), isTrue);
  });
}
