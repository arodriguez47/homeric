import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric/writing.dart';

/// Corrections the way the Mac gives them, answered when the test says.
final class _FakeCorrections extends ChangeNotifier
    implements HomericTypingCorrections {
  @override
  bool correctsSpellingAutomatically = true;

  @override
  bool replacesTextAutomatically = true;

  @override
  Map<String, String> textReplacements = const <String, String>{
    'omw': 'On my way!',
    ';sig': 'Alvaro',
  };

  final Map<String, String> fixes = <String, String>{
    'teh': 'the',
    'recieve': 'receive',
    'Teh': 'The',
  };

  final asked = <String>[];
  final _pending = <Completer<void>>[];

  @override
  Listenable get typingCorrectionsChanged => this;

  @override
  Future<String?> correction(String text, int start, int end) async {
    final word = text.substring(start, end);
    asked.add(word);
    final gate = Completer<void>();
    _pending.add(gate);
    await gate.future;
    return fixes[word];
  }

  /// Answers every question asked so far.
  Future<void> answer() async {
    for (final gate in _pending) {
      if (!gate.isCompleted) gate.complete();
    }
    _pending.clear();
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late _FakeCorrections corrections;

  setUp(() => corrections = _FakeCorrections());

  HomericEditorController controllerFor(
    String text, {
    String type = 'paragraph',
    Attributes attributes = emptyAttributes,
    bool? Function()? isActive,
  }) {
    final document = Document([
      Block(
        id: 'b',
        type: type,
        runs: [if (text.isNotEmpty) InlineRun(text, attributes: attributes)],
      ),
    ]);
    final controller = HomericEditorController(
      document: document,
      selection:
          HomericSelection.collapsed(document.positionAt(0, text.length)),
    );
    addTearDown(controller.dispose);
    HomericSystemCorrections(
      corrections: corrections,
      isActive: isActive == null ? null : () => isActive() ?? true,
    ).installOn(controller);
    return controller;
  }

  String textOf(HomericEditorController controller) =>
      controller.document.blocks.first.text;

  int caretOf(HomericEditorController controller) =>
      controller.blockOffsetForGlobalPosition(
        controller.document.blocks.first.id,
        controller.selection!.head,
      );

  void type(HomericEditorController controller, String typed) {
    for (final char in typed.split('')) {
      controller.replaceSelection(char);
    }
  }

  group('text replacement', () {
    test('a shortcut becomes its phrase when a space follows it', () {
      final controller = controllerFor('');
      type(controller, 'omw ');
      expect(textOf(controller), 'On my way! ');
      expect(caretOf(controller), 'On my way! '.length);
    });

    test('punctuation ends a shortcut too, and keeps its place', () {
      final controller = controllerFor('Sent by ');
      type(controller, ';sig.');
      expect(textOf(controller), 'Sent by Alvaro.');
    });

    test('one undo puts the shortcut back, as typed', () {
      final controller = controllerFor('');
      type(controller, 'omw ');
      controller.undo();
      expect(textOf(controller), 'omw ');
    });

    test('Backspace straight after puts the shortcut back', () {
      final controller = controllerFor('');
      type(controller, 'omw ');
      controller.deleteBackward();
      expect(textOf(controller), 'omw');
      expect(caretOf(controller), 3);
    });

    test('only a whole shortcut: inside a longer word it stays', () {
      final controller = controllerFor('');
      type(controller, 'xomw ');
      expect(textOf(controller), 'xomw ');
    });

    test('off with the system setting', () {
      corrections.replacesTextAutomatically = false;
      final controller = controllerFor('');
      type(controller, 'omw ');
      expect(textOf(controller), 'omw ');
    });

    test('code keeps what was typed', () {
      final controller = controllerFor('', type: 'code');
      type(controller, 'omw ');
      expect(textOf(controller), 'omw ');
      final inline = controllerFor('`');
      type(inline, 'omw ');
      expect(textOf(inline), '`omw ');
    });
  });

  group('autocorrect', () {
    test('a misspelled word is corrected once a space ends it', () async {
      final controller = controllerFor('I');
      type(controller, ' teh cat');
      // `cat` is still being typed: nothing ends it yet.
      expect(corrections.asked, ['teh']);
      await corrections.answer();
      expect(textOf(controller), 'I the cat');
      expect(caretOf(controller), 'I the cat'.length);
    });

    test('the correction is its own undo step', () async {
      final controller = controllerFor('I');
      type(controller, ' recieve ');
      await corrections.answer();
      expect(textOf(controller), 'I receive ');
      controller.undo();
      expect(textOf(controller), 'I recieve ');
    });

    test('keeps the capital the writer typed', () async {
      final controller = controllerFor('');
      type(controller, 'Teh,');
      await corrections.answer();
      expect(textOf(controller), 'The,');
    });

    test('nothing changes when the word changed before the answer', () async {
      final controller = controllerFor('');
      type(controller, 'teh ');
      controller.deleteBackward();
      controller.deleteBackward();
      await corrections.answer();
      expect(textOf(controller), 'te');
    });

    test('a word the writer went back into is left alone', () async {
      final controller = controllerFor('');
      type(controller, 'teh ');
      controller.setSelection(HomericSelection.collapsed(
        controller.document.positionAt(0, 2),
      ));
      await corrections.answer();
      expect(textOf(controller), 'teh ');
    });

    test('Return ends a word too', () async {
      final controller = controllerFor('teh');
      controller.insertParagraphBreak();
      await corrections.answer();
      expect(controller.document.blocks.first.text, 'the');
      expect(controller.document.blocks, hasLength(2));
    });

    test('tags, links, names and addresses keep what was typed', () async {
      for (final start in ['#', '[[', '@', 'example.com/']) {
        final controller = controllerFor(start);
        type(controller, 'teh ');
        await corrections.answer();
        expect(textOf(controller), '${start}teh ', reason: start);
      }
      expect(corrections.asked, isEmpty);
    });

    test('off with the system setting, or the host', () async {
      corrections.correctsSpellingAutomatically = false;
      final controller = controllerFor('');
      type(controller, 'teh ');
      await corrections.answer();
      expect(textOf(controller), 'teh ');
      expect(corrections.asked, isEmpty);

      corrections.correctsSpellingAutomatically = true;
      var on = false;
      final hosted = controllerFor('', isActive: () => on);
      type(hosted, 'teh ');
      await corrections.answer();
      expect(textOf(hosted), 'teh ');
    });

    test('an apostrophe or hyphen stays inside the word', () {
      expect(HomericSystemCorrections.endsWord("'"), isFalse);
      expect(HomericSystemCorrections.endsWord('-'), isFalse);
      expect(HomericSystemCorrections.endsWord(' '), isTrue);
      expect(HomericSystemCorrections.endsWord(','), isTrue);
      expect(HomericSystemCorrections.wordBefore("I don't", 7),
          (start: 2, word: "don't"));
      expect(HomericSystemCorrections.wordBefore('well-known', 10),
          (start: 0, word: 'well-known'));
      expect(HomericSystemCorrections.wordBefore('a -b', 4),
          (start: 3, word: 'b'));
    });
  });
}
