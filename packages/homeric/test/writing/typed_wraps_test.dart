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

  group('@ over a selection', () {
    const mentions = HomericTypedWraps(mentionSelection: true);

    test('writes @ before the words, the caret after them', () {
      final controller =
          controllerFor('see Julien Sorel here', 4, 16, feature: mentions);
      expect(controller.replaceSelection('@'), isTrue);
      expect(textOf(controller), 'see @Julien Sorel here');
      expect(selected(controller), (17, 17));
      // The mention being typed is exactly those words.
      final query = HomericMentionQuery.at('b', textOf(controller), 17)!;
      expect(query.start, 4);
      expect(query.name, 'Julien Sorel');
      expect(query.kind, isNull);
    });

    test('a backwards selection makes the same mention', () {
      final controller =
          controllerFor('see Julien Sorel here', 16, 4, feature: mentions);
      controller.replaceSelection('@');
      expect(textOf(controller), 'see @Julien Sorel here');
      expect(selected(controller), (17, 17));
    });

    test('after an opening bracket or quote, and at the line start', () {
      for (final (start, from, to, mentioned, caret) in const [
        ('(Julien Sorel)', 1, 13, '(@Julien Sorel)', 14),
        ('“Julien” said', 1, 7, '“@Julien” said', 8),
        ('Julien said', 0, 6, '@Julien said', 7),
      ]) {
        final controller = controllerFor(start, from, to, feature: mentions);
        controller.replaceSelection('@');
        expect(textOf(controller), mentioned, reason: start);
        expect(selected(controller), (caret, caret), reason: start);
      }
    });

    test('spaces around and punctuation after stay out of it', () {
      final controller =
          controllerFor('see  Julien Sorel. Then', 4, 19, feature: mentions);
      controller.replaceSelection('@');
      expect(textOf(controller), 'see  @Julien Sorel. Then');
      expect(selected(controller), (18, 18));
      expect(
        HomericMentionQuery.at('b', textOf(controller), 18)!.name,
        'Julien Sorel',
      );
    });

    test('a #kind as the last word narrows, as typed', () {
      final controller =
          controllerFor('a Rouge #book here', 2, 13, feature: mentions);
      controller.replaceSelection('@');
      expect(textOf(controller), 'a @Rouge #book here');
      final query = HomericMentionQuery.at('b', textOf(controller), 14)!;
      expect(query.name, 'Rouge');
      expect(query.kind, 'book');
    });

    test('Backspace straight after puts the words back, selected', () {
      final controller =
          controllerFor('see Julien Sorel here', 4, 16, feature: mentions);
      controller.replaceSelection('@');
      expect(controller.deleteBackward(), isTrue);
      expect(textOf(controller), 'see Julien Sorel here');
      expect(selected(controller), (4, 16));
    });

    test('Backspace gives back the selection as it was made', () {
      final controller =
          controllerFor('see  Julien Sorel. Then', 19, 4, feature: mentions);
      controller.replaceSelection('@');
      controller.deleteBackward();
      expect(textOf(controller), 'see  Julien Sorel. Then');
      expect(selected(controller), (19, 4));
    });

    test('Backspace deletes as usual once something was typed', () {
      final controller =
          controllerFor('see Julien here', 4, 10, feature: mentions);
      controller
        ..replaceSelection('@')
        ..replaceSelection(' ');
      controller.deleteBackward();
      expect(textOf(controller), 'see @Julien here');
    });

    test('is one undo step', () {
      final controller =
          controllerFor('see Julien Sorel here', 4, 16, feature: mentions);
      controller.replaceSelection('@');
      controller.undo();
      expect(textOf(controller), 'see Julien Sorel here');
      controller.redo();
      expect(textOf(controller), 'see @Julien Sorel here');
    });

    test('keeps the words\' own formatting', () {
      final document = Document([
        Block(id: 'b', type: 'paragraph', runs: [
          InlineRun('see '),
          InlineRun('Julien', attributes: const {'bold': true}),
          InlineRun(' here'),
        ]),
      ]);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection(
          anchor: document.positionAt(0, 4),
          head: document.positionAt(0, 10),
        ),
      );
      addTearDown(controller.dispose);
      addTearDown(mentions.installOn(controller));
      controller.replaceSelection('@');
      final runs = controller.document.blocks.single.runs;
      expect(controller.document.blocks.single.text, 'see @Julien here');
      expect(
        runs.where((run) => run.attributes['bold'] == true).single.text,
        'Julien',
      );
    });

    test('words that can\'t all be one mention are typed over', () {
      for (final (start, from, to, typed) in [
        // Punctuation that ends a mention, or a closing bracket or quote.
        ('see Julien, Sorel here', 4, 17, 'see @ here'),
        ('see (Julien) here', 4, 12, 'see @ here'),
        ('see Julien” here', 4, 11, 'see @ here'),
        ('see Rouge #book of here', 4, 18, 'see @ here'),
        // Inside a word: an address, not a mention.
        ('see banana here', 6, 10, 'see ba@ here'),
        // An @ already there.
        ('see @Julien here', 4, 11, 'see @ here'),
        ('see @Julien here', 5, 11, 'see @@ here'),
        // A line break.
        ('see Julien\nSorel here', 4, 16, 'see @ here'),
        // Only a #kind, no name.
        ('see #book here', 4, 9, 'see @ here'),
        // Past the longest mention.
        ('see ${'word ' * 13}here', 4, 69, 'see @here'),
      ]) {
        final controller = controllerFor(start, from, to, feature: mentions);
        controller.replaceSelection('@');
        expect(textOf(controller), typed, reason: start);
      }
    });

    test('inside or around a [[link]] it types over the words', () {
      for (final (from, to, typed) in const [
        (6, 18, 'see [[@]] here'),
        (6, 12, 'see [[@ Sorel]] here'),
        (4, 20, 'see @ here'),
        (0, 20, '@ here'),
      ]) {
        final controller = controllerFor('see [[Julien Sorel]] here', from, to,
            feature: mentions);
        controller.replaceSelection('@');
        expect(textOf(controller), typed, reason: '$from–$to');
      }
    });

    test('code blocks type over the words', () {
      final controller =
          controllerFor('let x = 1', 4, 5, type: 'code', feature: mentions);
      controller.replaceSelection('@');
      expect(textOf(controller), 'let @ = 1');
    });

    test('a selection across blocks is left to the editor', () {
      String typeAt(bool wraps) {
        final document = Document([
          Block(id: 'a', type: 'paragraph', runs: [InlineRun('see Julien')]),
          Block(id: 'b', type: 'paragraph', runs: [InlineRun('Sorel here')]),
        ]);
        final controller = HomericEditorController(
          document: document,
          selection: HomericSelection(
            anchor: document.positionAt(0, 4),
            head: document.positionAt(1, 5),
          ),
        );
        addTearDown(controller.dispose);
        if (wraps) {
          addTearDown(mentions.installOn(controller));
        }
        controller.replaceSelection('@');
        return controller.document.blocks.map((b) => b.text).join('\n');
      }

      expect(typeAt(true), typeAt(false));
      expect(typeAt(true), isNot(contains('@Julien')));
    });

    test('off by default: @ types over the words', () {
      final controller = controllerFor('see Julien here', 4, 10);
      controller.replaceSelection('@');
      expect(textOf(controller), 'see @ here');
      expect(selected(controller), (5, 5));
    });

    testWidgets('an @ an input method is composing types over the words',
        (tester) async {
      final controller =
          controllerFor('see Julien here', 4, 10, feature: mentions);
      controller.applyBlockEditBatch(
        blockId: 'b',
        edits: const [CanonicalTextEdit(4, 10, '@')],
        selection: const BlockTextSelection.collapsed(5),
        composing: const BlockTextRange(4, 5),
      );
      await tester.pump();
      expect(textOf(controller), 'see @ here');
    });

    testWidgets('onWrapped hears the mention after the frame', (tester) async {
      final heard = <HomericTypedWrap>[];
      final controller = controllerFor(
        'see Julien Sorel here',
        4,
        16,
        feature: HomericTypedWraps(
          mentionSelection: true,
          onWrapped: heard.add,
        ),
      );
      controller.replaceSelection('@');
      expect(heard, isEmpty);
      await tester.pump();
      expect(
          heard.single,
          const HomericTypedWrap(
            blockId: 'b',
            typed: '@',
            depth: 1,
            start: 4,
            end: 17,
            innerStart: 5,
            innerEnd: 17,
          ));
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
