import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric/writing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Block block(String id, String text) =>
      Block(id: id, type: 'paragraph', runs: [InlineRun(text)]);

  String words(int n, {String word = 'word'}) => List.filled(n, word).join(' ');

  HomericBrevity feature({
    int first = 3,
    int second = 5,
    HomericWordTest? isCounted,
  }) =>
      HomericBrevity(
        firstMark: first,
        secondMark: second,
        onReading: (_) {},
        isCounted: isCounted,
      );

  group('counting', () {
    test('a word joins letters across inner apostrophes and hyphens', () {
      expect(HomericBrevity.countWords('don’t stop — well-known, 3 ideas'), 5);
      expect(HomericBrevity.countWords('  ...  -- '), 0);
      expect(HomericBrevity.countWords('café naïve 東京'), 3);
    });

    test('stages follow the marks, inclusive', () {
      HomericBrevityStage stageAt(int n) =>
          feature().read(Document([block('a', words(n))])).stage;
      expect(stageAt(0), HomericBrevityStage.brief);
      expect(stageAt(3), HomericBrevityStage.brief);
      expect(stageAt(4), HomericBrevityStage.long);
      expect(stageAt(5), HomericBrevityStage.long);
      expect(stageAt(6), HomericBrevityStage.overlong);
    });

    test('counts every block', () {
      final reading = feature().read(
        Document([block('a', 'one two'), block('b', ''), block('c', 'three')]),
      );
      expect(reading.words, 3);
      expect(reading.progress, closeTo(0.6, 1e-9));
    });

    test('isCounted leaves words out', () {
      final reading = feature(
        isCounted: (block, start, end) =>
            block.text.substring(start, end) != 'skip',
      ).read(Document([block('a', 'one skip two skip')]));
      expect(reading.words, 2);
    });
  });

  group('past the second mark', () {
    test('marks where the first word past it starts', () {
      final document = Document([
        block('a', 'one two three'),
        block('b', 'four five six seven'),
        block('c', 'eight'),
        block('d', ''),
      ]);
      final reading = feature().read(document);
      expect(reading.words, 8);
      expect(reading.pastBlockId, 'b');
      expect(reading.pastOffset, 'four five '.length);
      expect(reading.laterBlockIds, {'c', 'd'});

      final b = reading.decorationsFor(document.blocks[1]).single;
      expect((b.kind, b.start, b.end),
          (DecorationKind.inline, 10, document.blocks[1].contentLength));
      final c = reading.decorationsFor(document.blocks[2], spec: #past).single;
      expect((c.start, c.end, c.spec), (0, 5, #past));
      expect(reading.decorationsFor(document.blocks[0]), isEmpty);
      // An empty block has nothing to set apart.
      expect(reading.decorationsFor(document.blocks[3]), isEmpty);
    });

    test('nothing to decorate within the mark', () {
      final document = Document([block('a', words(5))]);
      final reading = feature().read(document);
      expect(reading.pastBlockId, isNull);
      expect(reading.decorationsFor(document.blocks.single), isEmpty);
    });
  });

  group('characters', () {
    HomericBrevity chars(
            {int second = 5, int? goal, HomericWordTest? isCounted}) =>
        HomericBrevity(
          firstMark: 0,
          secondMark: second,
          unit: HomericBrevityUnit.characters,
          goal: goal,
          onReading: (_) {},
          isCounted: isCounted,
        );

    test('counts what a reader sees, spaces and line breaks included', () {
      expect(HomericBrevity.countCharacters('a b'), 3);
      // One flag, one family: one character each.
      expect(HomericBrevity.countCharacters('🇪🇸👨‍👩‍👧'), 2);
      expect(HomericBrevity.countIn('one two', HomericBrevityUnit.words), 2);
      final reading = chars(second: 50).read(
        Document([block('a', 'ab'), block('b', ''), block('c', 'é')]),
      );
      // ab + break + break + é
      expect(reading.count, 5);
      expect(reading.unit, HomericBrevityUnit.characters);
    });

    test('fades from the first character past the mark', () {
      final document = Document([block('a', 'abc'), block('b', 'defg')]);
      final reading = chars().read(document);
      // abc, break, d are the five; e is the sixth.
      expect(reading.count, 8);
      expect(reading.stage, HomericBrevityStage.overlong);
      expect(reading.pastBlockId, 'b');
      expect(reading.pastOffset, 1);
    });

    test('a line break past the mark fades the whole next block', () {
      final document = Document(
        [block('a', 'abcde'), block('b', 'f'), block('c', 'g')],
      );
      final reading = chars().read(document);
      expect(reading.count, 9);
      expect(reading.pastBlockId, 'b');
      expect(reading.pastOffset, 0);
      expect(reading.laterBlockIds, {'c'});
    });

    test('isCounted is asked of each character', () {
      final reading = chars(
        second: 50,
        isCounted: (block, start, end) => block.text[start] != '#',
      ).read(Document([block('a', '#a#b')]));
      expect(reading.count, 2);
    });
  });

  group('goal', () {
    test('rides on each reading without changing the stage', () {
      final f = HomericBrevity(
        firstMark: 0,
        secondMark: 10,
        goal: 4,
        onReading: (_) {},
      );
      final short = f.read(Document([block('a', words(2))]));
      expect(short.goal, 4);
      expect(short.reachedGoal, isFalse);
      expect(short.goalProgress, closeTo(0.5, 1e-9));
      expect(short.stage, HomericBrevityStage.long);
      final reached = f.read(Document([block('a', words(4))]));
      expect(reached.reachedGoal, isTrue);
      expect(reached.goalProgress, 1);
      expect(short == reached, isFalse);
    });

    test('no goal reads as reached', () {
      final reading = feature().read(Document([block('a', 'one')]));
      expect(reading.goal, isNull);
      expect(reading.reachedGoal, isTrue);
      expect(reading.goalProgress, 1);
    });
  });

  group('installOn', () {
    test('reads on install and again only when the reading changes', () {
      final document = Document([block('a', 'one')]);
      final controller = HomericEditorController(
        document: document,
        selection: HomericSelection.collapsed(document.positionAt(0, 3)),
      );
      addTearDown(controller.dispose);
      final readings = <HomericBrevityReading>[];
      final stop = HomericBrevity(
        firstMark: 1,
        secondMark: 2,
        onReading: readings.add,
      ).installOn(controller);

      expect(readings.map((r) => r.words), [1]);
      controller.replaceSelection(' ');
      // A space adds no word.
      expect(readings.map((r) => r.words), [1]);
      controller.replaceSelection('two');
      controller.replaceSelection(' three');
      expect(readings.map((r) => r.stage), [
        HomericBrevityStage.brief,
        HomericBrevityStage.long,
        HomericBrevityStage.overlong,
      ]);
      // Caret moves are not edits.
      controller.setSelection(
        HomericSelection.collapsed(controller.document.positionAt(0, 0)),
      );
      expect(readings, hasLength(3));

      stop();
      controller.replaceSelection('zero ');
      expect(readings, hasLength(3));
    });
  });
}
