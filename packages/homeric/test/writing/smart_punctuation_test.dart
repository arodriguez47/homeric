import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric/writing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  HomericEditorController controllerFor(
    String text, {
    int? caret,
    String type = 'paragraph',
    Attributes attributes = emptyAttributes,
  }) {
    final document = Document([
      Block(
        id: 'b',
        type: type,
        runs: [InlineRun(text, attributes: attributes)],
      ),
    ]);
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(
        document.positionAt(0, caret ?? text.length),
      ),
    );
    addTearDown(controller.dispose);
    return controller;
  }

  String textOf(HomericEditorController controller) =>
      controller.document.blocks.single.text;

  int caretOf(HomericEditorController controller) =>
      controller.blockOffsetForGlobalPosition('b', controller.selection!.head);

  /// Types [typed] one character at a time.
  String typeInto(String start, String typed,
      {HomericSmartPunctuation feature = const HomericSmartPunctuation()}) {
    final controller = controllerFor(start);
    feature.installOn(controller);
    for (final char in typed.split('')) {
      controller.replaceSelection(char);
    }
    return textOf(controller);
  }

  group('rules', () {
    const rules = HomericSmartPunctuation();

    test('two hyphens make an em dash, not the end of a longer run', () {
      expect(rules.editFor('a--', 2), const HomericPunctuationEdit(1, 3, '—'));
      expect(rules.editFor('a---', 3), isNull);
    });

    test('three dots make an ellipsis, a fourth stays', () {
      expect(
          rules.editFor('wait...', 6), const HomericPunctuationEdit(4, 7, '…'));
      expect(rules.editFor('....', 3), isNull);
    });

    test('quotes open or close by what comes before them', () {
      expect(rules.editFor('"', 0)!.replacement, '“');
      expect(rules.editFor('say "', 4)!.replacement, '“');
      expect(rules.editFor('word"', 4)!.replacement, '”');
      expect(rules.editFor('don\'', 3)!.replacement, '’');
      expect(rules.editFor('(\'', 1)!.replacement, '‘');
      expect(rules.editFor('end.\'', 4)!.replacement, '’');
    });

    test('code and web addresses keep what was typed', () {
      expect(rules.editFor('`a--', 3), isNull);
      expect(rules.editFor('see https://x.com/a--', 20), isNull);
      expect(rules.editFor('[x](a--', 6), isNull);
      expect(rules.editFor('`a` b--', 6), isNotNull);
    });

    test('each rule can be turned off', () {
      const none = HomericSmartPunctuation(
          emDash: false, ellipsis: false, quotes: false);
      expect(none.editFor('a--', 2), isNull);
      expect(none.editFor('...', 2), isNull);
      expect(none.editFor('"', 0), isNull);
    });
  });

  group('typing', () {
    testWidgets('sets punctuation as it is typed', (tester) async {
      expect(typeInto('', 'He said "wait... -- don\'t."'),
          'He said “wait… — don’t.”');
    });

    testWidgets('the caret follows the substitute', (tester) async {
      final controller = controllerFor('a-');
      const HomericSmartPunctuation().installOn(controller);
      controller.replaceSelection('-');
      expect(textOf(controller), 'a—');
      expect(caretOf(controller), 2);
    });

    testWidgets('mid-text, the rest of the line stays put', (tester) async {
      final controller = controllerFor('a- b', caret: 2);
      const HomericSmartPunctuation().installOn(controller);
      controller.replaceSelection('-');
      expect(textOf(controller), 'a— b');
      expect(caretOf(controller), 2);
    });

    testWidgets('one undo puts back what was typed', (tester) async {
      final controller = controllerFor('a-');
      const HomericSmartPunctuation().installOn(controller);
      controller.replaceSelection('-');
      expect(textOf(controller), 'a—');
      controller.undo();
      expect(textOf(controller), 'a--');
      controller.undo();
      expect(textOf(controller), 'a-');
    });

    testWidgets('Backspace straight after puts back what was typed',
        (tester) async {
      final controller = controllerFor('wait..');
      const HomericSmartPunctuation().installOn(controller);
      controller.replaceSelection('.');
      expect(textOf(controller), 'wait…');
      controller.deleteBackward();
      expect(textOf(controller), 'wait...');
      expect(caretOf(controller), 7);
      // A second Backspace is an ordinary one.
      controller.deleteBackward();
      expect(textOf(controller), 'wait..');
    });

    testWidgets('Backspace after more typing is an ordinary one',
        (tester) async {
      final controller = controllerFor('a-');
      const HomericSmartPunctuation().installOn(controller);
      controller.replaceSelection('-');
      controller.replaceSelection('b');
      controller.deleteBackward();
      controller.deleteBackward();
      expect(textOf(controller), 'a');
    });

    testWidgets('backspaceReverts off deletes the substitute', (tester) async {
      final controller = controllerFor('a-');
      const HomericSmartPunctuation(backspaceReverts: false)
          .installOn(controller);
      controller.replaceSelection('-');
      controller.deleteBackward();
      expect(textOf(controller), 'a');
    });

    testWidgets('a dead key committing its quote with a letter',
        (tester) async {
      final controller = controllerFor('say ');
      const HomericSmartPunctuation().installOn(controller);
      controller.replaceSelection('"a');
      expect(textOf(controller), 'say “a');
      expect(caretOf(controller), 6);
    });

    testWidgets('isActive switches the feature without reinstalling',
        (tester) async {
      var on = false;
      final controller = controllerFor('a-');
      HomericSmartPunctuation(isActive: () => on).installOn(controller);
      controller.replaceSelection('-');
      expect(textOf(controller), 'a--');
      on = true;
      controller.replaceSelection(' "');
      controller.replaceSelection('"');
      expect(textOf(controller), 'a-- "“');
    });

    testWidgets('code blocks, code runs and host literals stay as typed',
        (tester) async {
      final code = controllerFor('a-', type: 'code');
      const HomericSmartPunctuation().installOn(code);
      code.replaceSelection('-');
      expect(textOf(code), 'a--');

      final run = controllerFor('a-', attributes: const {'code': true});
      const HomericSmartPunctuation().installOn(run);
      run.replaceSelection('-');
      expect(textOf(run), 'a--');

      final host = controllerFor('a-');
      HomericSmartPunctuation(isLiteral: (block, offset) => true)
          .installOn(host);
      host.replaceSelection('-');
      expect(textOf(host), 'a--');
    });

    testWidgets('the substitute keeps the run the first character had',
        (tester) async {
      final controller =
          controllerFor('a-', attributes: const {'italic': true});
      const HomericSmartPunctuation().installOn(controller);
      controller.replaceSelection('-');
      final runs = controller.document.blocks.single.runs;
      expect(runs.map((r) => r.text).join(), 'a—');
      expect(runs.every((r) => r.attributes['italic'] == true), isTrue);
    });

    testWidgets('a host chain can prepare the command itself', (tester) async {
      final controller = controllerFor('a-');
      final session = const HomericSmartPunctuation().sessionFor(controller);
      HomericPreparedCommand? seen;
      controller.addCommandInterceptor((command) {
        seen = session.prepare(command);
        if (seen == null) return HomericCommandInterception.ignored;
        return command.controller.applyPreparedCommand(seen!)
            ? HomericCommandInterception.handled
            : HomericCommandInterception.ignored;
      });
      controller.replaceSelection('-');
      expect(seen, isNotNull);
      expect(textOf(controller), 'a—');
    });

    testWidgets('uninstalling stops it', (tester) async {
      final controller = controllerFor('a-');
      final stop = const HomericSmartPunctuation().installOn(controller);
      stop();
      controller.replaceSelection('-');
      expect(textOf(controller), 'a--');
    });
  });

  group('kit', () {
    testWidgets('the standard kit carries smart punctuation', (tester) async {
      final kit = HomericWritingKit.standard();
      expect(kit.has('smartPunctuation'), isTrue);
      final controller = controllerFor('a-');
      kit.installOn(controller);
      controller.replaceSelection('-');
      expect(textOf(controller), 'a—');
    });

    test('without leaves a feature out, with_ replaces it', () {
      expect(
        HomericWritingKit.standard(without: const {'smartPunctuation'})
            .has('smartPunctuation'),
        isFalse,
      );
      const mine = HomericSmartPunctuation(quotes: false);
      final kit = HomericWritingKit.standard(with_: const [mine]);
      expect(
          kit.features.whereType<HomericSmartPunctuation>().single, same(mine));
    });

    test('a feature can be in a kit once', () {
      expect(
        () => HomericWritingKit(const [
          HomericSmartPunctuation(),
          HomericSmartPunctuation(),
        ]),
        throwsArgumentError,
      );
    });

    testWidgets('uninstalling the kit stops every feature', (tester) async {
      final controller = controllerFor('a-');
      final stop = HomericWritingKit.standard().installOn(controller);
      stop();
      controller.replaceSelection('-');
      expect(textOf(controller), 'a--');
    });
  });
}
