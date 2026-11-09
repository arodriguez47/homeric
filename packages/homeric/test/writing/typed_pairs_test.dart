import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric/writing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  HomericEditorController controllerFor(String text, {int? caret}) {
    final document = Document([
      Block(id: 'b', type: 'paragraph', runs: [InlineRun(text)]),
    ]);
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(
        document.positionAt(0, caret ?? text.length),
      ),
    );
    addTearDown(controller.dispose);
    addTearDown(const HomericTypedPairs().installOn(controller));
    return controller;
  }

  String textOf(HomericEditorController controller) =>
      controller.document.blocks.single.text;

  int caretOf(HomericEditorController controller) =>
      controller.blockOffsetForGlobalPosition('b', controller.selection!.head);

  Future<void> type(HomericEditorController controller, String typed) async {
    for (final char in typed.split('')) {
      controller.replaceSelection(char);
      // Pairs left behind are tidied in a microtask.
      await Future<void>.delayed(Duration.zero);
    }
  }

  group('closeAt', () {
    test('closes an opening where a mark can start', () {
      expect(HomericTypedPairs.closeAt('*', 1, '**'), isTrue);
      expect(HomericTypedPairs.closeAt('a *', 3, '**'), isTrue);
      expect(HomericTypedPairs.closeAt('(=', 2, '=='), isTrue);
      expect(HomericTypedPairs.closeAt('a ~ b', 3, '~~'), isTrue);
    });

    test('leaves closings, arithmetic and longer runs as typed', () {
      // After a word: a closing marker.
      expect(HomericTypedPairs.closeAt('**bold*', 7, '**'), isFalse);
      expect(HomericTypedPairs.closeAt('2*', 2, '**'), isFalse);
      expect(HomericTypedPairs.closeAt('a=', 2, '=='), isFalse);
      // Before a word.
      expect(HomericTypedPairs.closeAt('*word', 1, '**'), isFalse);
      // `***`.
      expect(HomericTypedPairs.closeAt('**', 2, '**'), isFalse);
      // An odd count before: this one closes `**bold **`.
      expect(HomericTypedPairs.closeAt('**bold *', 8, '**'), isFalse);
      // A single marker never pairs.
      expect(HomericTypedPairs.closeAt('a ', 2, '**'), isFalse);
    });
  });

  test('typing ** closes it, the caret between the markers', () async {
    final controller = controllerFor('Say ');
    await type(controller, '**');
    expect(textOf(controller), 'Say ****');
    expect(caretOf(controller), 6);
  });

  test('typing a whole **bold** by hand steps over the closing', () async {
    final controller = controllerFor('Say ');
    await type(controller, '**bold** now');
    expect(textOf(controller), 'Say **bold** now');
    expect(caretOf(controller), 16);
  });

  test('==, ~~ pair too; ++, %% and a single * do not', () async {
    for (final (typed, after) in const [
      ('==hi==', '==hi=='),
      ('~~hi~~', '~~hi~~'),
      ('++', '++'),
      ('%%', '%%'),
      ('*', '*'),
    ]) {
      final controller = controllerFor('');
      await type(controller, typed);
      expect(textOf(controller), after, reason: typed);
    }
  });

  test('one undo takes back only the closing marker', () async {
    final controller = controllerFor('');
    await type(controller, '**');
    expect(textOf(controller), '****');
    controller.undo();
    expect(textOf(controller), '**');
  });

  test('left empty, the added closing goes and the typed opening stays',
      () async {
    final controller = controllerFor('a ');
    await type(controller, '**');
    expect(textOf(controller), 'a ****');
    controller.setSelection(
      HomericSelection.collapsed(controller.document.positionAt(0, 0)),
    );
    await Future<void>.delayed(Duration.zero);
    expect(textOf(controller), 'a **');
  });

  test('stepOut puts the caret past the closing marker', () async {
    final controller = controllerFor('');
    await type(controller, '**hi');
    expect(HomericOpenPairs.of(controller).stepOut(), isTrue);
    expect(textOf(controller), '**hi**');
    expect(caretOf(controller), 6);
  });

  test('an italic closed inside bold takes its own *', () async {
    final controller = controllerFor('');
    await type(controller, '**a *b*');
    expect(textOf(controller), '**a *b***');
    expect(caretOf(controller), 7);
  });

  test('only the stepped marker\'s own second half is swallowed', () async {
    final controller = controllerFor('');
    await type(controller, '**bold*=');
    expect(textOf(controller), '**bold**=');
  });

  test('a pair opened in an italic run keeps the italic', () async {
    final document = Document([
      Block(id: 'b', type: 'paragraph', runs: [
        InlineRun('so ', attributes: const {'italic': true}),
      ]),
    ]);
    final controller = HomericEditorController(
      document: document,
      selection: HomericSelection.collapsed(document.positionAt(0, 3)),
    );
    addTearDown(controller.dispose);
    addTearDown(const HomericTypedPairs().installOn(controller));
    await type(controller, '**a');
    expect(textOf(controller), 'so **a**');
    for (final run in controller.document.blocks.single.runs) {
      expect(run.attributes['italic'], isTrue, reason: run.text);
    }
  });

  test('the standard kit carries it before the indent', () {
    final ids = [for (final f in HomericWritingKit.standardFeatures) f.id];
    expect(ids.indexOf('typedPairs'), lessThan(ids.indexOf('blockIndent')));
  });
}
