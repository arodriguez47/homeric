import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/writing.dart';

void main() {
  HomericMentionQuery? at(String text, [int? caret]) =>
      HomericMentionQuery.at('b', text, caret ?? text.length);

  group('HomericMentionQuery.at', () {
    test('an @ at a word start, with the name typed so far', () {
      expect(
        at('Lunch with @Julien Sor'),
        const HomericMentionQuery(
          blockId: 'b',
          start: 11,
          end: 22,
          name: 'Julien Sor',
        ),
      );
      expect(at('@')!.name, '');
      expect(at('@')!.start, 0);
      expect(at('(@Mat')!.name, 'Mat');
      expect(at('"@Mat')!.name, 'Mat');
      expect(at('“@Mat')!.name, 'Mat');
    });

    test('a #kind as the last word narrows it', () {
      final q = at('@Rouge #bo')!;
      expect(q.name, 'Rouge');
      expect(q.kind, 'bo');
      expect(at('@#book')!.kind, 'book');
      expect(at('@#book')!.name, '');
      expect(at('@Rouge #')!.kind, '');
      expect(at('@Rouge #Book')!.kind, 'book');
      expect(at('@Rouge')!.kind, isNull);
      // With a space after, the #word was a tag: the mention is over.
      expect(at('@Rouge #book '), isNull);
      expect(at('@Julien #idea and then'), isNull);
      expect(at('@#book '), isNull);
      // A # inside a word is part of the name.
      expect(at('@C# in Depth')!.name, 'C# in Depth');
    });

    test('only up to the caret, on its own line', () {
      expect(at('@Julien Sorel', 7)!.name, 'Julien');
      expect(at('@Julien\nSorel'), isNull);
      expect(at('first line\n@Ma')!.start, 11);
    });

    test('not inside a word: an address or a handle in a link', () {
      expect(at('ana@exam'), isNull);
      expect(at('https://example.com/@user'), isNull);
    });

    test('an @ followed by a space is just an at sign', () {
      expect(at('meet @ 5pm'), isNull);
      expect(at('meet @ '), isNull);
    });

    test('it ends where the sentence moves on, or at a bracket', () {
      expect(at('@Julien, then'), isNull);
      expect(at('@Julien. Then'), isNull);
      expect(at('@Julien) and'), isNull);
      expect(at('@Jul[[ien'), isNull);
      // A closing bracket or quote ends it at once: no name ends in one.
      expect(at('(@Julien)'), isNull);
      expect(at('{@Julien}'), isNull);
      expect(at('“@Julien”'), isNull);
      expect(at('«@Julien»'), isNull);
      expect(at('(@Julien'), isNotNull);
      // An apostrophe can be inside a name; with a space after, it closed
      // a quote.
      expect(at('@O’Brien')!.name, 'O’Brien');
      expect(at("@O'Brien")!.name, "O'Brien");
      expect(at("'@Julien' said"), isNull);
      expect(at('‘@Julien’ said'), isNull);
      // Mid-name punctuation with no space after is still the name.
      expect(at('@Dr.Who')!.name, 'Dr.Who');
      // A trailing space keeps it open: names have more than one word.
      expect(at('@Julien ')!.name, 'Julien');
    });

    test('not past its longest', () {
      final long = 'a' * (HomericMentionQuery.maxLength + 1);
      expect(at('@$long'), isNull);
      expect(at('@${long.substring(1)}'), isNotNull);
    });
  });
}
