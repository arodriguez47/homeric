import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';
import 'package:homeric/writing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Block block(String id, String text) =>
      Block(id: id, type: 'paragraph', runs: [InlineRun(text)]);

  String words(int n, {String word = 'word'}) =>
      List.filled(n, word).join(' ');

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
      expect(HomericBrevity.countWords('don’t stop — well-known, 3 ideas'),
          5);
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
